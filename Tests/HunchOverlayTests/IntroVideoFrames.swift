import AppKit
import Foundation
import HunchCore
import Testing
@testable import HunchOverlay

/// Opt-in: writes the intro video's effect frames. Each effect's letters are the overlay's own drawing
/// (`GhostOverlayPresenter.snapshot`) at 60 frames a second on a clear background; its particles are
/// planned the way `ParticleEmitter` does and written to `manifest.json` for the video page to draw.
/// Run with `GHOSTTYPE_INTRO_FRAMES=<folder> swift test --filter IntroVideoFrames` (see
/// `scripts/intro-video/make.sh`); skipped otherwise.
@Suite struct IntroVideoFrames {
    static let folder = ProcessInfo.processInfo.environment["GHOSTTYPE_INTRO_FRAMES"]

    static let fps = 60.0
    static let fontSize: CGFloat = 26
    /// Pixels per point: the video shows the frames 1.25 times their size on a 2x canvas.
    static let scale: CGFloat = 3
    /// The ghost view's inset around its text (`GhostView.padding`, private to the overlay).
    static let padding: CGFloat = 2
    /// Suggestion strength (Settings → Appearance; 0.5 is the default): stronger, so the colors read on video.
    static let strength = 0.75
    /// The effects beat: the same typed words, a new suggestion per effect. Paws has no color of its
    /// own (its letters match the text), so it is drawn once per theme in that theme's text color;
    /// its dot in the video takes the calico orange.
    static let shots: [(style: PopInAnimation, text: String, name: String, ink: StoredColor?)] = [
        (.paws, "light on its feet.", "paws-dark", StoredColor(hex: 0xECECF1)),
        (.paws, "light on its feet.", "paws-light", StoredColor(hex: 0x1C1C21)),
        (.decode, "like a simulation.", "decode", nil),
        (.neon, "electric tonight.", "neon", nil),
        (.wisteria, "like spring again.", "wisteria", nil),
    ]

    struct Particle: Codable {
        var shape: String
        var size: Double
        var color: [Double]
        var delay: Double
        var life: Double
        /// Evenly timed points, x from the text's left edge, y up from its baseline.
        var path: [[Double]]
        var rotation: Double
        var spin: Double
        var fadeIn: Double
        var fadeOut: Double
    }

    struct Shot: Codable {
        var name: String
        var text: String
        var frames: Int
        /// The frame images' size in points, and where the text sits in them.
        var width: Double
        var height: Double
        var textX: Double
        var baselineFromBottom: Double
        var textWidth: Double
        var ascender: Double
        var descender: Double
        /// Whole-suggestion fade (ms), which Core Animation plays in the app; 0 = none.
        var fadeMs: Double
        /// The particles' box around the text and its fade-out band, in points.
        var margin: Double
        var edge: Double
        var color: [Double]
        var particles: [Particle]
    }

    struct Manifest: Codable {
        var fps: Double
        var fontSize: Double
        var scale: Double
        var shots: [Shot]
    }

    /// SplitMix64, so the particles are the same on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @MainActor
    @Test(.enabled(if: folder != nil)) func writeFrames() throws {
        let dir = URL(fileURLWithPath: Self.folder!)
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let font = NSFont.systemFont(ofSize: Self.fontSize)
        let unit = Double(max(0.8, min(2, Self.fontSize / 13)))
        var shots: [Shot] = []

        for (k, shot) in Self.shots.enumerated() {
            let r = PopInRecipe.preset(shot.style)
            let text = shot.text
            let c = try #require(shot.ink ?? AppearanceSettings(animation: shot.style).effectColor)
            let ink = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: Self.strength)
            let calico = PopIn.pawColors[0]
            let dot = shot.ink == nil ? [c.red, c.green, c.blue]
                : [Double(calico.red), Double(calico.green), Double(calico.blue)]
            let name = shot.name
            let sub = dir.appendingPathComponent(name)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)

            // Letters: until every letter has settled, plus a few frames.
            let duration = PopIn.totalDuration(r, characters: text.count) + 0.1
            let frames = Int((duration * Self.fps).rounded(.up))
            var size = CGSize.zero
            for i in 0..<frames {
                let rep = try #require(GhostOverlayPresenter.snapshot(
                    text, recipe: r, elapsed: Double(i) / Self.fps, fontSize: Self.fontSize, color: ink,
                    background: .clear, scale: Self.scale))
                size = rep.size
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: sub.appendingPathComponent(String(format: "%04d.png", i)))
            }

            // Where the text sits in a frame (as `snapshot` lays it out).
            let textWidth = GhostOverlayPresenter.textWidth(text, font: font) + 2
            let lineHeight = ceil(font.ascender - font.descender) + Self.padding * 2
            let margin = Double(PopIn.margin(r, unit: unit, size: CGSize(width: textWidth, height: lineHeight)))

            var rng = Seeded(state: 0xC0FFEE &+ UInt64(k))
            var particles: [Particle] = []
            if r.particlesOn, !r.particleShapes.isEmpty {
                let rate = PopIn.sweepRate(r, characters: text.count)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                let utf16 = (text as NSString).length
                var index = 0
                let centers: [CGPoint] = text.map { ch in
                    let a = CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)
                    index += ch.utf16.count
                    let b = CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)
                    return CGPoint(x: (a + b) / 2, y: font.xHeight * 0.5)
                }
                let counts = PopIn.particleCounts(text, density: r.particleDensity)
                for (i, n) in counts.enumerated() where n > 0 {
                    let delay = Double(i) * rate + PopIn.letterLandDelay(r, index: i)
                    for _ in 0..<n { particles.append(Self.spawn(r, at: centers[i], delay: delay, unit: unit, rng: &rng)) }
                }
                // The trickle from along the line after the pop-in.
                if let seconds = PopIn.particleTrickleSeconds(r), seconds > 0 {
                    let after = rate * Double(text.count) + PopIn.landDelay(r)
                    let interval = 1 / max(0.1, r.particleTrickle)
                    var t = after
                    let height = max(1, lineHeight - 2 * Self.padding)
                    while t < after + seconds {
                        let x = Double.random(in: 0...1, using: &rng) * Double(textWidth)
                        let y = Double(font.descender) + Double.random(in: 0.3...0.7, using: &rng) * Double(height)
                        particles.append(Self.spawn(r, at: CGPoint(x: x, y: y), delay: t, unit: unit, rng: &rng))
                        t += interval
                    }
                }
            }
            shots.append(Shot(
                name: name, text: text, frames: frames, width: size.width, height: size.height,
                textX: margin, baselineFromBottom: margin + Double(Self.padding) - Double(font.descender),
                textWidth: Double(textWidth), ascender: Double(font.ascender), descender: Double(font.descender),
                fadeMs: r.fadeOn ? r.fadeMs : 0, margin: margin, edge: max(4, margin * 0.5),
                color: dot + [Self.strength], particles: particles))
        }
        // The dictation pill's mic face, white on clear, for the video to tint.
        for (file, draw) in [("glyph-mic", MenuBarIcon.drawFaceMicrophone(color:))] {
            let px = Int(MenuBarIcon.size.width * 8)
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = MenuBarIcon.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(.white)
            NSGraphicsContext.restoreGraphicsState()
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("\(file).png"))
        }
        let manifest = Manifest(fps: Self.fps, fontSize: Double(Self.fontSize), scale: Double(Self.scale), shots: shots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
    }

    /// One particle, as `ParticleEmitter.spawn` makes it.
    static func spawn(_ r: PopInRecipe, at point: CGPoint, delay: Double, unit: Double, rng: inout Seeded) -> Particle {
        let shape = r.particleShapes.randomElement(using: &rng)!
        let life = max(0.1, r.particleLifeMs / 1000)
        let variation = min(0.95, max(0, r.particleSizeVariation / 100))
        let size = max(1, r.particleSize * unit * (1 + variation * Double.random(in: -1...1, using: &rng)))
        let t = Double.random(in: 0...1, using: &rng)
        let a = r.particleColorA, b = r.particleColorB
        let color = [a.red + (b.red - a.red) * t, a.green + (b.green - a.green) * t, a.blue + (b.blue - a.blue) * t]
        let spread = r.particleSpread / 2
        let path = PopIn.particlePath(
            start: point, speed: r.particleSpeed * unit * Double.random(in: 0.7...1.3, using: &rng),
            direction: r.particleDirection + Double.random(in: -spread...max(-spread, spread), using: &rng),
            gravity: max(0, r.particleGravity) * unit, gravityDirection: r.particleGravityDirection,
            flutter: r.particleFlutter * unit * Double.random(in: 0.5...1, using: &rng),
            phase: Double.random(in: 0...(2 * .pi), using: &rng), life: life)
        let upright = shape == .wisp || shape == .mist
        let r0 = upright ? Double.random(in: -0.25...0.25, using: &rng) : Double.random(in: 0...(2 * .pi), using: &rng)
        let spin = r.particleSpin * .pi / 180 * (Bool.random(using: &rng) ? 1 : -1)
            * Double.random(in: 0.6...1.2, using: &rng)
        let fadeIn = min(0.08, life / 4) / life
        let fadeOut = min(1 - fadeIn, max(0, r.particleFadeMs / 1000) / life)
        return Particle(shape: shape.rawValue, size: size, color: color, delay: delay, life: life,
                        path: path.map { [Double($0.x), Double($0.y)] }, rotation: r0, spin: spin,
                        fadeIn: fadeIn, fadeOut: fadeOut)
    }
}
