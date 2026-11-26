import AppKit
import HunchCore
import QuartzCore

/// The Particles effect: small shapes shed from letters, each a layer flying a precomputed path (see
/// `PopIn.particlePath`). Used by the overlay and by the Settings preview. Particles already in flight
/// keep their place on screen when the view moves (`place`), so typing through a suggestion doesn't
/// drag them along.
@MainActor
public final class ParticleEmitter {
    /// Clips the particles and fades them out toward its edges. Put it behind the text.
    public let view: NSView
    /// Holds the particles; moved inside `view` so they stay put on screen.
    private let host = CALayer()
    private let edgeMask = CALayer()
    private let vertical = CAGradientLayer()
    private let horizontal = CAGradientLayer()
    /// Screen position of `host`'s origin while particles are flying.
    private var anchor: CGPoint?
    /// Screen position of `view`'s origin, from the last `place`.
    private var viewOrigin = CGPoint.zero
    private var live = 0
    private var trickle: Timer?
    private var trickleUntil: Date?
    private var trickleRecipe: PopInRecipe?
    private var trickleUnit = 1.0
    private var trickleLine: (() -> CGRect?)?

    /// At most this many particles at once, whatever the density.
    public static let maxLive = 300

    public init() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        view = v
        host.anchorPoint = .zero
        host.masksToBounds = false
        v.layer?.addSublayer(host)
        for g in [vertical, horizontal] {
            g.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        }
        horizontal.startPoint = CGPoint(x: 0, y: 0.5)
        horizontal.endPoint = CGPoint(x: 1, y: 0.5)
        vertical.mask = horizontal
        edgeMask.addSublayer(vertical)
        v.layer?.mask = edgeMask
    }

    /// Sets the view's frame (in its superview) and where its origin is on screen. `edge` is how
    /// wide the fade-out band along each side is.
    public func place(frame: CGRect, screenOrigin: CGPoint, edge: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame
        viewOrigin = screenOrigin
        if live == 0 { anchor = screenOrigin }
        let a = anchor ?? screenOrigin
        host.frame = CGRect(x: a.x - screenOrigin.x, y: a.y - screenOrigin.y, width: 1, height: 1)
        let size = frame.size
        edgeMask.frame = CGRect(origin: .zero, size: size)
        vertical.frame = edgeMask.bounds
        horizontal.frame = vertical.bounds
        let fy = size.height > 0 ? min(0.45, edge / size.height) : 0
        let fx = size.width > 0 ? min(0.45, edge / size.width) : 0
        vertical.locations = [0, NSNumber(value: fy), NSNumber(value: 1 - fy), 1]
        horizontal.locations = [0, NSNumber(value: fx), NSNumber(value: 1 - fx), 1]
        CATransaction.commit()
    }

    /// Sheds each letter's particles (`PopIn.particleCounts`) as the sweep lands on it. `centers` are the
    /// letters' middles in `view` coords; letter `i` lands `delays[i]` seconds from now.
    public func shed(_ recipe: PopInRecipe, text: String, centers: [CGPoint], delays: [TimeInterval], unit: Double) {
        guard recipe.particlesOn, !recipe.particleShapes.isEmpty else { return }
        let counts = PopIn.particleCounts(text, density: recipe.particleDensity)
        for (i, n) in counts.enumerated() where n > 0 && i < centers.count && i < delays.count {
            for _ in 0..<n { spawn(recipe, at: centers[i], delay: max(0, delays[i]), unit: unit) }
        }
    }

    /// Keeps a light trickle of particles coming from along `line` (in `view` coords; nil = nothing
    /// to shed from right now), starting `after` seconds from now, for `PopIn.particleTrickleSeconds`.
    public func startTrickle(_ recipe: PopInRecipe, unit: Double, after: TimeInterval, line: @escaping () -> CGRect?) {
        stopTrickle()
        // nil = while shown, 0 = no trickle.
        let seconds = PopIn.particleTrickleSeconds(recipe)
        if seconds == 0 { return }
        trickleRecipe = recipe
        trickleUnit = unit
        trickleLine = line
        trickleUntil = seconds.map { Date().addingTimeInterval(after + $0) }
        let start = Date().addingTimeInterval(after)
        let interval = 1 / max(0.1, recipe.particleTrickle)
        let timer = Timer(fire: start, interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trickleTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trickle = timer
    }

    /// Pauses the trickle (the suggestion hid); `resumeTrickle` carries on if it's still due.
    public func pauseTrickle() {
        trickle?.invalidate()
        trickle = nil
    }

    public func resumeTrickle() {
        guard trickle == nil, let recipe = trickleRecipe, let line = trickleLine else { return }
        if let until = trickleUntil, until <= Date() { return }
        let until = trickleUntil
        startTrickle(recipe, unit: trickleUnit, after: 0, line: line)
        trickleUntil = until
    }

    public func stopTrickle() {
        pauseTrickle()
        trickleRecipe = nil
        trickleLine = nil
        trickleUntil = nil
    }

    /// Removes every particle and stops the trickle.
    public func clear() {
        stopTrickle()
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        live = 0
        anchor = viewOrigin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame.origin = .zero
        CATransaction.commit()
    }

    private func trickleTick() {
        guard let recipe = trickleRecipe else { return }
        if let until = trickleUntil, until <= Date() { stopTrickle(); return }
        guard let line = trickleLine?(), line.width > 0 else { return }
        let x = line.minX + CGFloat.random(in: 0...1) * line.width
        let y = line.minY + CGFloat.random(in: 0.3...0.7) * line.height
        spawn(recipe, at: CGPoint(x: x, y: y), delay: 0, unit: trickleUnit)
    }

    // MARK: One particle

    private func spawn(_ r: PopInRecipe, at point: CGPoint, delay: TimeInterval, unit: Double) {
        guard live < Self.maxLive, let shape = r.particleShapes.randomElement() else { return }
        let life = max(0.1, r.particleLifeMs / 1000)
        let variation = min(0.95, max(0, r.particleSizeVariation / 100))
        let size = max(1, r.particleSize * unit * (1 + variation * Double.random(in: -1...1)))
        let t = Double.random(in: 0...1)
        let a = r.particleColorA, b = r.particleColorB
        let color = NSColor(srgbRed: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
                            blue: a.blue + (b.blue - a.blue) * t, alpha: 0.9).cgColor

        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
        layer.path = Self.path(shape, size: size)
        layer.fillColor = color
        if shape == .bubble || shape == .wisp { layer.fillRule = .evenOdd }
        if shape == .mist {
            // Faint body, wide soft edge: reads as a puff of fog rather than a shape.
            layer.fillColor = NSColor(cgColor: color)?.withAlphaComponent(0.3).cgColor
            layer.shadowColor = color
            layer.shadowOpacity = 0.55
            layer.shadowRadius = size * 0.35
            layer.shadowOffset = .zero
            layer.shadowPath = layer.path
        }
        if shape == .wisp {
            layer.shadowColor = color
            layer.shadowOpacity = 0.8
            layer.shadowRadius = size * 0.3
            layer.shadowOffset = .zero
            layer.shadowPath = layer.path
        }
        if shape == .dot {
            layer.shadowColor = color
            layer.shadowOpacity = 0.9
            layer.shadowRadius = size * 0.45
            layer.shadowOffset = .zero
            layer.shadowPath = layer.path
        }
        let start = CGPoint(x: point.x - host.frame.minX, y: point.y - host.frame.minY)
        layer.position = start
        layer.opacity = 0

        let spread = r.particleSpread / 2
        let path = PopIn.particlePath(start: start, speed: r.particleSpeed * unit * Double.random(in: 0.7...1.3),
                                   direction: r.particleDirection + Double.random(in: -spread...max(-spread, spread)),
                                   gravity: max(0, r.particleGravity) * unit,
                                   gravityDirection: r.particleGravityDirection, flutter: r.particleFlutter * unit * Double.random(in: 0.5...1),
                                   phase: Double.random(in: 0...(2 * .pi)), life: life)
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = path.map { NSValue(point: $0) }
        move.calculationMode = .cubic
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        // Wisps and mist stay about upright (a ghost upside down looks wrong); the rest start any way.
        let upright = shape == .wisp || shape == .mist
        let r0 = upright ? Double.random(in: -0.25...0.25) : Double.random(in: 0...(2 * .pi))
        let spin = r.particleSpin * .pi / 180 * (Bool.random() ? 1 : -1) * Double.random(in: 0.6...1.2)
        turn.fromValue = r0
        turn.toValue = r0 + spin * life
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        let fadeIn = min(0.08, life / 4) / life
        let fadeOut = min(1 - fadeIn, max(0, r.particleFadeMs / 1000) / life)
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: fadeIn), NSNumber(value: 1 - fadeOut), 1]
        let group = CAAnimationGroup()
        group.animations = [move, turn, fade]
        if shape == .mist {
            // Swells as it thins out.
            let swell = CABasicAnimation(keyPath: "transform.scale")
            swell.fromValue = 0.7
            swell.toValue = 1.9
            swell.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.animations?.append(swell)
        } else if shape == .wisp {
            // A gentle lean back and forth as it floats, on top of any spin.
            let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let lean = 0.22
            sway.values = [r0, r0 + lean, r0 - lean, r0 + lean * 0.6, r0]
            sway.duration = life
            if r.particleSpin == 0 { group.animations = [move, sway, fade] }
        }
        group.duration = life
        group.beginTime = begin
        group.fillMode = .backwards
        group.isRemovedOnCompletion = true
        layer.add(group, forKey: "particle")
        host.addSublayer(layer)
        live += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + life + 0.05) { [weak self, weak layer] in
            MainActor.assumeIsolated {
                guard let layer, layer.superlayer != nil else { return }
                layer.removeFromSuperlayer()
                self?.live -= 1
            }
        }
    }

    /// The shapes, centered on the origin, `size` across.
    static func path(_ shape: ParticleShape, size s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        switch shape {
        case .petal:
            // A teardrop: pointed top, round bottom.
            p.move(to: CGPoint(x: 0, y: s / 2))
            p.addCurve(to: CGPoint(x: 0, y: -s / 2), control1: CGPoint(x: s * 0.45, y: s * 0.05),
                       control2: CGPoint(x: s * 0.4, y: -s / 2))
            p.addCurve(to: CGPoint(x: 0, y: s / 2), control1: CGPoint(x: -s * 0.4, y: -s / 2),
                       control2: CGPoint(x: -s * 0.45, y: s * 0.05))
            p.closeSubpath()
        case .dot:
            p.addEllipse(in: CGRect(x: -s * 0.35, y: -s * 0.35, width: s * 0.7, height: s * 0.7))
        case .blossom:
            let r = s * 0.22
            for i in 0..<5 {
                let a = Double(i) * 2 * .pi / 5 + .pi / 2
                let c = CGPoint(x: s * 0.26 * cos(a), y: s * 0.26 * sin(a))
                p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
            p.addEllipse(in: CGRect(x: -r * 0.8, y: -r * 0.8, width: r * 1.6, height: r * 1.6))
        case .sparkle:
            let inner = s * 0.12, outer = s / 2
            for i in 0..<8 {
                let a = Double(i) * .pi / 4 + .pi / 2
                let rad = i % 2 == 0 ? outer : inner
                let pt = CGPoint(x: rad * cos(a), y: rad * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        case .leaf:
            // Pointed at both ends, a little lopsided, with a short stem.
            p.move(to: CGPoint(x: 0, y: s / 2))
            p.addQuadCurve(to: CGPoint(x: 0, y: -s * 0.35), control: CGPoint(x: s * 0.5, y: s * 0.05))
            p.addQuadCurve(to: CGPoint(x: 0, y: s / 2), control: CGPoint(x: -s * 0.4, y: -s * 0.05))
            p.closeSubpath()
            p.addRect(CGRect(x: -s * 0.03, y: -s / 2, width: s * 0.06, height: s * 0.18))
        case .star:
            let inner = s * 0.2, outer = s / 2
            for i in 0..<10 {
                let a = Double(i) * .pi / 5 + .pi / 2
                let rad = i % 2 == 0 ? outer : inner
                let pt = CGPoint(x: rad * cos(a), y: rad * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        case .square:
            p.addRect(CGRect(x: -s * 0.35, y: -s * 0.35, width: s * 0.7, height: s * 0.7))
        case .heart:
            // Point at the bottom (AppKit y is up).
            p.move(to: CGPoint(x: 0, y: -s * 0.45))
            p.addCurve(to: CGPoint(x: 0, y: s * 0.25), control1: CGPoint(x: s * 0.6, y: -s * 0.05),
                       control2: CGPoint(x: s * 0.35, y: s * 0.6))
            p.addCurve(to: CGPoint(x: 0, y: -s * 0.45), control1: CGPoint(x: -s * 0.35, y: s * 0.6),
                       control2: CGPoint(x: -s * 0.6, y: -s * 0.05))
            p.closeSubpath()
        case .bubble:
            // A thin ring with a small shine inside (drawn even-odd, so the middle stays clear).
            p.addEllipse(in: CGRect(x: -s * 0.45, y: -s * 0.45, width: s * 0.9, height: s * 0.9))
            p.addEllipse(in: CGRect(x: -s * 0.33, y: -s * 0.33, width: s * 0.66, height: s * 0.66))
            p.addEllipse(in: CGRect(x: -s * 0.22, y: s * 0.04, width: s * 0.14, height: s * 0.14))
        case .wisp:
            // A small ghost like the app icon: domed head, straight sides, three scallops along the
            // hem, and two eyes cut out (drawn even-odd).
            let w = s * 0.78, top = s / 2, hem = -s * 0.32
            let left = -w / 2, right = w / 2
            p.move(to: CGPoint(x: left, y: hem))
            p.addLine(to: CGPoint(x: left, y: top - w / 2))
            p.addArc(center: CGPoint(x: 0, y: top - w / 2), radius: w / 2, startAngle: .pi, endAngle: 0, clockwise: true)
            p.addLine(to: CGPoint(x: right, y: hem))
            let scallop = w / 3
            for k in 0..<3 {
                let x1 = right - CGFloat(k) * scallop
                let x0 = x1 - scallop
                p.addQuadCurve(to: CGPoint(x: x0, y: hem), control: CGPoint(x: (x0 + x1) / 2, y: -s / 2))
            }
            p.closeSubpath()
            let eyeW = s * 0.11, eyeH = s * 0.19, eyeY = top - w / 2 - eyeH * 0.35
            for x in [-s * 0.15, s * 0.15] {
                p.addEllipse(in: CGRect(x: x - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: eyeH))
            }
        case .mist:
            // Three overlapping lobes, wider than tall.
            p.addEllipse(in: CGRect(x: -s * 0.5, y: -s * 0.25, width: s * 0.55, height: s * 0.45))
            p.addEllipse(in: CGRect(x: -s * 0.2, y: -s * 0.15, width: s * 0.55, height: s * 0.5))
            p.addEllipse(in: CGRect(x: s * 0.05, y: -s * 0.28, width: s * 0.45, height: s * 0.4))
        case .snowflake:
            // Six thin arms, each with a pair of small branches, all filled shapes.
            let arm = max(0.5, s * 0.09), half = s / 2
            for i in 0..<6 {
                let t = CGAffineTransform(rotationAngle: CGFloat(i) * .pi / 3)
                p.addRect(CGRect(x: -arm / 2, y: 0, width: arm, height: half), transform: t)
                for side in [-1.0, 1.0] {
                    let b = t.translatedBy(x: 0, y: half * 0.55).rotated(by: CGFloat(side) * .pi / 4)
                    p.addRect(CGRect(x: -arm / 2, y: 0, width: arm, height: half * 0.35), transform: b)
                }
            }
        }
        return p
    }
}
