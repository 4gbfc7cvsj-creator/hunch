import AppKit
import HunchCore

private final class GhostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class GhostView: NSView {
    var text = ""
    var font = NSFont.systemFont(ofSize: 13)
    /// Extra spacing per character (points), for a stand-in font that runs wider than the host's.
    var kern: CGFloat = 0
    var color = NSColor(white: 0.55, alpha: 1)
    /// Background box for suggestions drawn below the line (mid-line), so the next line of the
    /// host's text doesn't show through. Nil = plain text (inline).
    var box: NSColor?
    /// Width (points) at the left of the view covering host text to strike through; the ghost
    /// text starts after it.
    var strikeWidth: CGFloat = 0
    /// Sub-point shift of the drawing: the window server snaps panel origins to whole points, so the
    /// remainder is applied inside the view to keep the baseline where it was asked for.
    var nudge = CGPoint.zero
    /// Scramble / Color fade pop-in: the characters to show in place of `text` (same count; the real
    /// ones without Scramble), and how much of `scrambleColor` each one shows (0 = `color`, 1 = all
    /// fade color). Nil = plain text.
    var decode: [Character]?
    var decodeTint: [Double] = []
    var scrambleColor: NSColor?
    /// Hang, Flicker, Wave, Assemble, Glow: each letter's pose (offsets in points, already scaled to
    /// the text size). Empty = none of them.
    var poses: [PopIn.LetterPose] = []
    /// Glow's halo color and blur radius (points).
    var glowColor: NSColor = .orange
    var glowRadius: CGFloat = 6
    /// Phase: how many afterimages, the outermost one's starting size (1 = the letter's) and blur
    /// (points), and their halo color (nil = their own).
    var phaseEchoes = 3
    var phaseScale: CGFloat = 2.2
    var phaseBlur: CGFloat = 2.5
    var echoHalo: NSColor?
    /// Ripple: waves across a letter's height.
    var rippleWaves: CGFloat = 1.5
    /// Paw walk: the prints showing, and their size (points, already scaled to the text size).
    var paws: [PopIn.PawPrint] = []
    var pawSize: CGFloat = 7
    /// Imprint: how far the pressed-in highlight sits below a letter (points).
    var insetOffset: CGFloat = 0.8

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill(using: .copy)
        // Plain text only: no background, border, or hint glyph, so the ghost reads as text that
        // hasn't been typed yet. Core Text places the baseline exactly (NSString.draw(at:) treats the
        // point as the bottom of a line box that is taller than ascender + descender).
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var inset: CGFloat = 0
        if let box {
            inset = Self.boxPadding
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            box.setFill()
            path.fill()
            color.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        if strikeWidth > 0 {
            // A line through the middle of the lowercase letters of the host's misspelled word.
            let y = Self.padding - font.descender + font.xHeight * 0.55
            let strike = NSBezierPath()
            strike.move(to: NSPoint(x: inset, y: y))
            strike.line(to: NSPoint(x: inset + strikeWidth, y: y))
            strike.lineWidth = max(1, font.pointSize / 14)
            NSColor.systemRed.withAlphaComponent(0.75).setStroke()
            strike.stroke()
            inset += strikeWidth + Self.correctionGap
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .kern: kern, .foregroundColor: color]))
        context.textMatrix = .identity
        let origin = CGPoint(x: inset + nudge.x, y: Self.padding - font.descender + nudge.y)
        guard let decode, decode.count == text.count else {
            context.textPosition = origin
            CTLineDraw(line, context)
            return
        }
        // Each character (real or scrambled) is centered in the real one's slot, so the line keeps
        // its final width and words don't shift as letters lock in.
        let utf16 = (text as NSString).length
        var index = 0
        for (i, real) in text.enumerated() {
            let start = CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)
            index += real.utf16.count
            let end = CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)
            let shown = decode[i]
            guard !shown.isWhitespace else { continue }
            var tint = color
            if let scrambleColor, i < decodeTint.count, decodeTint[i] > 0 {
                tint = color.blended(withFraction: decodeTint[i], of: scrambleColor) ?? color
            }
            let pose = i < poses.count ? poses[i] : nil
            // The letter's color before its own visibility, for Phase's afterimages.
            let echoTint = tint
            if let pose {
                guard pose.alpha > 0 || pose.echoAlpha > 0 else { continue }
                tint = tint.withAlphaComponent(tint.alphaComponent * CGFloat(pose.alpha))
            }
            var glyph = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(shown), attributes: [.font: font, .foregroundColor: tint]))
            let width = shown == real ? end - start : CGFloat(CTLineGetTypographicBounds(glyph, nil, nil, nil))
            let position = CGPoint(x: origin.x + start + (end - start - width) / 2, y: origin.y)
            if let pose {
                context.saveGState()
                let mid = origin.x + (start + end) / 2
                context.translateBy(x: CGFloat(pose.dx), y: CGFloat(pose.dy))
                if pose.tilt != 0 {
                    // Hinged at the top middle of the letter's slot.
                    let pivot = CGPoint(x: mid, y: origin.y + font.ascender)
                    context.translateBy(x: pivot.x, y: pivot.y)
                    context.rotate(by: CGFloat(pose.tilt * .pi / 180))
                    context.translateBy(x: -pivot.x, y: -pivot.y)
                }
                if pose.spin != 0 {
                    let pivot = CGPoint(x: mid, y: origin.y + font.xHeight / 2)
                    context.translateBy(x: pivot.x, y: pivot.y)
                    context.rotate(by: CGFloat(pose.spin * .pi / 180))
                    context.translateBy(x: -pivot.x, y: -pivot.y)
                }
                if pose.scaleX != 1 || pose.scaleY != 1 {
                    // Stamped onto the line: scaled about the middle of the letter's baseline.
                    context.translateBy(x: mid, y: origin.y)
                    context.scaleBy(x: CGFloat(pose.scaleX), y: CGFloat(pose.scaleY))
                    context.translateBy(x: -mid, y: -origin.y)
                }
                if pose.echoAlpha > 0, pose.echo > 0, phaseEchoes > 0 {
                    drawEchoes(String(shown), pose: pose, color: echoTint, at: position,
                               center: CGPoint(x: mid, y: origin.y + font.capHeight / 2), in: context)
                }
                if pose.glow > 0, pose.alpha > 0 {
                    // A hot core in the glow color with a halo around it, under the letter itself.
                    let g = CGFloat(pose.glow)
                    context.saveGState()
                    context.setShadow(offset: .zero, blur: glowRadius * g,
                                      color: glowColor.withAlphaComponent(min(1, g * 1.2)).cgColor)
                    let hot = CTLineCreateWithAttributedString(NSAttributedString(
                        string: String(shown),
                        attributes: [.font: font, .foregroundColor: glowColor.withAlphaComponent(g * CGFloat(pose.alpha))]))
                    // Twice for a brighter halo; each draw moves the text position on, so reset it.
                    for _ in 0..<2 {
                        if pose.ripple > 0.05 {
                            // Warped like the letter. Drawn as one layer so the halo goes around the
                            // whole letter, not clipped to each band.
                            context.beginTransparencyLayer(auxiliaryInfo: nil)
                            drawRippled(hot, pose: pose, at: position, width: width, in: context)
                            context.endTransparencyLayer()
                        } else {
                            context.textPosition = position
                            CTLineDraw(hot, context)
                        }
                    }
                    context.restoreGState()
                }
            }
            if let pose, pose.alpha <= 0 {
                context.restoreGState()
                continue
            }
            if let pose, pose.inset > 0.01 {
                // Pressed into the page: a light edge just below the letter, and the letter itself
                // a little darker, as in letterpress.
                let k = CGFloat(pose.inset)
                let edge = CTLineCreateWithAttributedString(NSAttributedString(
                    string: String(shown),
                    attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.75 * k * tint.alphaComponent)]))
                context.textPosition = CGPoint(x: position.x, y: position.y - insetOffset)
                CTLineDraw(edge, context)
                let deep = (tint.blended(withFraction: 0.3 * k, of: .black) ?? tint).withAlphaComponent(
                    min(1, tint.alphaComponent * (1 + 0.3 * k)))
                glyph = CTLineCreateWithAttributedString(
                    NSAttributedString(string: String(shown), attributes: [.font: font, .foregroundColor: deep]))
            }
            if let pose, pose.ripple > 0.05 {
                drawRippled(glyph, pose: pose, at: position, width: width, in: context)
            } else {
                context.textPosition = position
                CTLineDraw(glyph, context)
            }
            if pose != nil { context.restoreGState() }
        }
        if !paws.isEmpty { drawPaws(line: line, origin: origin, in: context) }
    }

    /// Paw walk: each print beside its letters, above or below the line, toes pointing on.
    private func drawPaws(line: CTLine, origin: CGPoint, in context: CGContext) {
        let utf16 = (text as NSString).length
        var offsets: [CGFloat] = [0]
        var index = 0
        for ch in text {
            index += ch.utf16.count
            offsets.append(CTLineGetOffsetForStringIndex(line, min(index, utf16), nil))
        }
        let s = pawSize
        for paw in paws where paw.alpha > 0.01 && paw.last + 1 < offsets.count {
            let x = origin.x + (offsets[paw.first] + offsets[paw.last + 1]) / 2
            let y = paw.above ? origin.y + font.ascender + s * 0.15 : origin.y + font.descender - s * 0.15
            let fur = PopIn.pawColors[paw.color % PopIn.pawColors.count]
            let a: CGFloat = 1
            context.saveGState()
            // One layer, faded as a whole: overlapping fur and pads don't show through each other.
            context.setAlpha(CGFloat(paw.alpha) * 0.92)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.translateBy(x: x, y: y)
            // Pointing up, turned to point right, then tilted a little per step.
            context.rotate(by: CGFloat((-90 + paw.tilt) * .pi / 180))
            context.scaleBy(x: CGFloat(paw.scale), y: CGFloat(paw.scale))
            let pads = PopIn.pawPads(size: Double(s))
            let rim = max(0.8, s * 0.11)
            context.setFillColor(CGColor(srgbRed: fur.red, green: fur.green, blue: fur.blue, alpha: a))
            // The fur: one soft blob behind the pads, so the calico color reads, not just an outline.
            context.fillEllipse(in: CGRect(x: -0.36 * s, y: -0.42 * s, width: 0.72 * s, height: 0.62 * s))
            for p in pads {
                context.fillEllipse(in: CGRect(x: p.x - p.rx - rim, y: p.y - p.ry - rim,
                                               width: 2 * (p.rx + rim), height: 2 * (p.ry + rim)))
            }
            let pink = PopIn.beanPink
            context.setFillColor(CGColor(srgbRed: pink.red, green: pink.green, blue: pink.blue, alpha: a))
            for p in pads {
                context.fillEllipse(in: CGRect(x: p.x - p.rx, y: p.y - p.ry, width: 2 * p.rx, height: 2 * p.ry))
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    /// Phase: the afterimages around a letter, each larger and softer than the one inside it, all
    /// shrinking toward the letter as `pose.echo` goes to 0. Core Graphics has no cheap blur, so a
    /// soft echo is several faint copies on a small ring (its blur radius) inside a halo.
    private func drawEchoes(_ s: String, pose: PopIn.LetterPose, color: NSColor, at position: CGPoint,
                            center: CGPoint, in context: CGContext) {
        let n = max(1, phaseEchoes)
        let base = color.alphaComponent
        // Tinted toward the glow, so the haze reads as colored light rather than grey.
        let color = echoHalo.flatMap { color.blended(withFraction: 0.45, of: $0.withAlphaComponent(base)) } ?? color
        for k in (1...n).reversed() {
            let f = CGFloat(k) / CGFloat(n)
            let scale = 1 + (phaseScale - 1) * CGFloat(pose.echo) * f
            let alpha = CGFloat(pose.echoAlpha) * base * (0.6 - 0.3 * f)
            guard alpha > 0.005 else { continue }
            let blur = phaseBlur * CGFloat(pose.echo) * f
            let copies = blur > 0.4 ? 6 : 1
            let halo = (echoHalo ?? color).withAlphaComponent(min(1, alpha * 1.6))
            let echo = CTLineCreateWithAttributedString(NSAttributedString(
                string: s, attributes: [.font: font, .foregroundColor: color.withAlphaComponent(alpha / CGFloat(copies) * 1.6)]))
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -center.x, y: -center.y)
            context.setShadow(offset: .zero, blur: 2 + blur * 2 * scale, color: halo.cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for c in 0..<copies {
                let a = CGFloat(c) / CGFloat(copies) * 2 * .pi
                let r = copies > 1 ? blur * 0.6 : 0
                context.textPosition = CGPoint(x: position.x + r * cos(a), y: position.y + r * sin(a))
                CTLineDraw(echo, context)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    /// Ripple: the letter drawn in thin horizontal bands, each pushed sideways along a sine wave
    /// running up its height.
    private func drawRippled(_ glyph: CTLine, pose: PopIn.LetterPose, at position: CGPoint, width: CGFloat,
                             in context: CGContext) {
        let bottom = position.y + font.descender - 1
        let height = font.ascender - font.descender + 2
        let bands = 14
        let band = height / CGFloat(bands)
        let reach = CGFloat(abs(pose.ripple)) + 2
        for j in 0..<bands {
            let y0 = bottom + CGFloat(j) * band
            let along = (CGFloat(j) + 0.5) / CGFloat(bands)
            let dx = CGFloat(pose.ripple) * sin(CGFloat(pose.ripplePhase) + rippleWaves * 2 * .pi * along)
            context.saveGState()
            // A hair of overlap so the bands don't show seams.
            context.clip(to: CGRect(x: position.x - reach, y: y0 - 0.25, width: width + 2 * reach, height: band + 0.5))
            context.textPosition = CGPoint(x: position.x + dx, y: position.y)
            CTLineDraw(glyph, context)
            context.restoreGState()
        }
    }

    /// Glow, Phase and Ripple's settings from `r`, distances scaled by `unit`.
    func applyLook(_ r: PopInRecipe, unit: Double) {
        let c = r.glowColor
        glowColor = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        glowRadius = CGFloat(r.glowRadius * unit)
        phaseEchoes = max(0, Int(r.phaseEchoes.rounded()))
        phaseScale = CGFloat(max(1, r.phaseScale / 100))
        phaseBlur = CGFloat(max(0, r.phaseBlur) * unit)
        echoHalo = r.glowOn ? glowColor : nil
        rippleWaves = CGFloat(r.rippleWaves)
        pawSize = CGFloat(max(1, r.pawSize) * unit)
        insetOffset = CGFloat(0.8 * unit)
    }

    /// Room above and below the glyphs so accents and descenders are never clipped.
    static let padding: CGFloat = 2
    /// Horizontal room inside the mid-line box.
    static let boxPadding: CGFloat = 4
    /// Space between a struck-through word and its correction.
    static let correctionGap: CGFloat = 4

    static func width(_ s: String, _ f: NSFont, kern: CGFloat = 0) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f, .kern: kern]).width)
    }
}

/// Reusable non-activating, click-through panel that renders ghost text in the host's own font,
/// directly after the caret. The panel is capturable like the host's text (no `sharingType`
/// override); Hunch's own screen-context capture only ever targets the focused app's window.
@MainActor
public final class GhostOverlayPresenter: GhostPresenting {
    private let panel: NSPanel
    /// Embedded mode: the view the ghost draws inside instead of its own panel (Write for me's draft,
    /// so the effect scrolls with the text). Nil = the floating panel.
    private weak var host: NSView?
    private let embedded: Bool
    private let view = GhostView()
    /// The panel's content: holds `view` with `animationMargin` around it, so a pop-in that moves
    /// the text isn't clipped by the panel's edge.
    private let container = NSView()
    /// Mirror mode's line-covering panel; this panel stays hidden while it shows.
    private let mirror = TextMirrorPresenter()
    /// Settings → Appearance. Applies from the next suggestion drawn.
    public var appearance = AppearanceSettings()
    /// What was last drawn and when it was hidden, to tell new text from a redraw (`PopIn`).
    private var lastShown: String?
    private var hiddenAt: Date?
    private var isShown = false
    /// Settled text color instead of the suggestion color (dictation and Write for me draw real
    /// text, so the effect ends in the text's own color). Nil = the suggestion color.
    public var colorOverride: NSColor?

    public convenience init() { self.init(host: nil) }

    /// Draws inside `host` (screen coordinates passed to `present` are converted to it) instead of
    /// a floating panel.
    public convenience init(embeddedIn host: NSView) { self.init(host: host) }

    private init(host: NSView?) {
        self.host = host
        embedded = host != nil
        let p = GhostPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        container.wantsLayer = true
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        container.addSubview(view)
        container.addSubview(particles.view, positioned: .below, relativeTo: view)
        if let host {
            container.isHidden = true
            host.addSubview(container)
        } else {
            p.contentView = container
        }
        panel = p
    }

    /// The font (and extra letter spacing) a presentation's text is drawn in.
    public func resolvedFont(for presentation: GhostPresentation) -> (font: NSFont, kern: CGFloat) {
        let f = fontChoice(presentation)
        return (f.font, f.kern)
    }

    /// Width of `text` drawn in `font` with `kern`, as the ghost lays it out.
    public static func textWidth(_ text: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
        GhostView.width(text, font, kern: kern)
    }

    private func fontChoice(_ presentation: GhostPresentation) -> (font: NSFont, kern: CGFloat, lookalike: Bool, standIn: String?) {
        let hint = presentation.geometry.font
        var font = Self.font(for: hint, caretHeight: presentation.geometry.caretRect.height)
        // A stand-in for a web font (Discord's gg sans → Avenir Next) already has the host's height
        // at the reported size; the learned width difference goes into letter spacing instead.
        let standIn = Self.lookalikeFamily(for: hint)
        let lookalike = standIn != nil && font.familyName == standIn
        var kern: CGFloat = 0
        if lookalike, hint?.pointSize != nil {
            kern = FontLookalike.tracking(widthScale: presentation.geometry.widthScale,
                                          meanAdvance: Self.meanAdvance(font))
        }
        // Size: the host's reported size, scaled by how wide the host's text runs compared with ours
        // (learned from caret positions while typing), kept within 10%; the scale is only
        // meaningful against a reported size. The on-screen match sets the baseline, not the size:
        // matching our face against the host's (Helvetica in Mail) biased sizes low.
        // A confirmed measured size correction already sets the size.
        if !lookalike, (hint?.sizeFactor ?? 1) == 1, let scale = presentation.geometry.widthScale, hint?.pointSize != nil {
            let size = font.pointSize * min(max(scale, 0.9), 1.1)
            if let resized = NSFont(descriptor: font.fontDescriptor, size: size) { font = resized }
        }
        // Per-app size adjustment on top of the width scale (the identity leaves the font alone).
        let tweaks = presentation.tweaks
        if tweaks.fontSizeFactor != 1,
           let resized = NSFont(descriptor: font.fontDescriptor,
                                size: OverlayLayout.adjustedFontSize(font.pointSize, factor: tweaks.fontSizeFactor)) {
            font = resized
        }
        return (font, kern, lookalike, standIn)
    }

    /// Puts the ghost's frame (screen coordinates) on screen: the panel, or the container in `host`.
    private func place(_ screenFrame: CGRect) {
        if embedded {
            guard let host, let window = host.window else { return }
            container.frame = host.convert(window.convertFromScreen(screenFrame), from: nil)
        } else {
            panel.setFrame(screenFrame, display: false)
            container.frame = CGRect(origin: .zero, size: screenFrame.size)
        }
    }

    private func orderFront() {
        if embedded { container.isHidden = false } else { panel.orderFrontRegardless() }
    }

    private func orderOut() {
        if embedded { container.isHidden = true } else { panel.orderOut(nil) }
    }

    private var isOnScreen: Bool { embedded ? !container.isHidden : panel.isVisible }

    public func present(_ presentation: GhostPresentation) {
        let text = presentation.text.replacingOccurrences(of: "\n", with: " ")
        let caret = presentation.geometry.caretRect
        guard !text.isEmpty else { hide(); return }

        let screens = NSScreen.screens
        let idx = OverlayLayout.screenIndex(for: caret, frames: screens.map(\.frame))
        guard let screen = idx.map({ screens[$0] }) ?? NSScreen.main ?? screens.first else { hide(); return }
        let visible = screen.visibleFrame

        let hint = presentation.geometry.font
        let choice = fontChoice(presentation)
        let font = choice.font, kern = choice.kern, lookalike = choice.lookalike, standIn = choice.standIn
        let tweaks = presentation.tweaks
        checkAlignment(presentation, font: font, standIn: lookalike ? standIn : nil)
        // Mirror: the line is redrawn with the ghost in it, so this panel hides (after the mirror is
        // up, so the host's line never shows through in between). A line that can't be mirrored
        // gets the card below.
        if !embedded, presentation.mode == .mirror, let content = presentation.mirror,
           mirror.present(ghost: text, content: content, presentation: presentation, font: font, visible: visible,
                          ghostColor: ghostColor(textColor: hint?.textColor, tweaks: tweaks)) {
            orderOut()
            noteShown(text)
            return
        }
        mirror.hide()
        let lineHeight = ceil(font.ascender - font.descender) + GhostView.padding * 2
        // Inline: on the caret's line. Fallback (untrusted caret or text after the caret): the same
        // plain text on the line below, starting under the caret, so it never paints over host text.
        let x: CGFloat
        let baseline: CGFloat
        // Line metrics for placing the baseline without a measurement. A stand-in's line box is far
        // taller than the web font's (Avenir Next: 1.37 em); the system face's is closer, as before.
        let metrics = lookalike ? NSFont.systemFont(ofSize: font.pointSize) : font
        switch presentation.mode {
        case .inline:
            x = OverlayLayout.inlineX(caretRect: caret)
            baseline = OverlayLayout.inlineBaselineY(caretRect: caret, measuredBaseline: presentation.measuredBaseline,
                                                     descender: -metrics.descender, ascender: metrics.ascender,
                                                     offset: tweaks.verticalOffset)
        case .card, .mirror:
            x = caret.minX
            baseline = caret.minY - OverlayLayout.cardGap + font.descender
        }
        let avail = OverlayLayout.availableWidth(fromX: x, visibleFrame: visible)
        let shown = OverlayLayout.truncate(text, maxWidth: avail) { GhostView.width($0, font, kern: kern) }
        guard !shown.isEmpty else { hide(); return }
        let y = OverlayLayout.panelOriginY(baseline: baseline, fontDescent: -font.descender) - GhostView.padding
        if DrawDebugLog.isEnabled {
            DrawDebugLog.note("draw mode=\(presentation.mode) caret=\(DrawDebugLog.fmt(caret)) axSize=\(hint?.pointSize.map { "\($0)" } ?? "nil") "
                + "measuredX=\(presentation.measuredXHeight.map { String(format: "%.2f", $0) } ?? "nil") widthScale=\(presentation.geometry.widthScale.map { String(format: "%.3f", $0) } ?? "nil") "
                + "measuredBaseline=\(presentation.measuredBaseline.map { String(format: "%.2f", $0) } ?? "nil") "
                + "axFont=\(hint?.family ?? "nil")/\(hint?.name ?? "nil") "
                + "fontUsed=\(font.fontName)@\(String(format: "%.2f", font.pointSize)) kern=\(String(format: "%.2f", kern)) baselineY=\(String(format: "%.2f", baseline)) "
                + "fallbackBaselineY=\(String(format: "%.2f", OverlayLayout.baselineY(caretRect: caret, descender: -metrics.descender, ascender: metrics.ascender)))")
        }
        let previousShown = view.text
        view.font = font
        view.kern = kern
        view.color = colorOverride ?? ghostColor(textColor: hint?.textColor, tweaks: tweaks)
        view.text = shown
        var frame = CGRect(x: x, y: y, width: GhostView.width(shown, font, kern: kern), height: lineHeight)
        // Autocorrect: extend the panel left over the host's misspelled word to strike it through.
        let struckWidth = presentation.struckText.map { GhostView.width($0, font) } ?? 0
        view.strikeWidth = struckWidth
        if struckWidth > 0 {
            frame.origin.x -= struckWidth
            frame.size.width += struckWidth + GhostView.correctionGap
        }
        if presentation.mode != .inline {
            // Below the line the ghost overlaps the host's next line: give it an opaque box in the
            // field's own background tone, text still starting under the caret.
            view.box = Self.boxColor(textColor: hint?.textColor)
            frame = frame.insetBy(dx: -GhostView.boxPadding, dy: 0)
        } else {
            view.box = nil
        }
        // Whole-point origin (rounded down), with the remainder drawn inside the view.
        let snapped = CGPoint(x: frame.origin.x.rounded(.down), y: frame.origin.y.rounded(.down))
        view.nudge = CGPoint(x: frame.origin.x - snapped.x, y: frame.origin.y - snapped.y)
        frame.origin = snapped
        frame.size.width += 1
        frame.size.height += 1
        let recipe = PopIn.effective((tweaks.appearance ?? appearance).currentRecipe,
                                     reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        // Movement scales with the text so it reads the same at 11 and 24 pt.
        let unit = Double(max(0.8, min(2, font.pointSize / 13)))
        let m = PopIn.margin(recipe, unit: unit, size: frame.size)
        let animate = PopIn.shouldAnimate(previous: lastShown, hiddenFor: hiddenFor, next: text)
        let outer = frame.insetBy(dx: -m, dy: -m)
        place(outer)
        view.frame = CGRect(origin: CGPoint(x: m, y: m), size: frame.size)
        view.needsDisplay = true
        let textStart = (view.box == nil ? 0 : GhostView.boxPadding)
            + (struckWidth > 0 ? struckWidth + GhostView.correctionGap : 0)
        self.textStart = textStart
        particles.place(frame: container.bounds, screenOrigin: outer.origin, edge: max(4, m * 0.5))
        if animate {
            playPopIn(recipe, unit: unit, textStart: textStart)
        } else {
            // A redraw mid-reveal (the suggestion grew, or was typed into): typewriter and decode
            // carry on over the new text where they had got to, instead of being cut short.
            let shift = PopIn.typewriterShift(previous: lastShown ?? "", next: text)
            // Words streamed in after an effect had caught up get the effect too, from where it stopped.
            let resumeFrom = shift == 0 ? PopIn.revealResume(previousShown: previousShown, nextShown: shown) : nil
            if let shift {
                pawWalk?.dropFront(shift)
            } else {
                pawWalk = nil
                view.paws = []
            }
            if var typing = typewriter {
                if let shift {
                    typing.shift += shift
                    typewriter = typing
                    runTypewriter(textStart: textStart)
                } else {
                    finishTypewriter()
                }
            } else if let rate = typewriterRate, let from = resumeFrom {
                typewriter = Typing(start: Date().addingTimeInterval(-Double(from) * rate), rate: rate, shift: 0)
                runTypewriter(textStart: textStart)
            }
            if var decoding = decoder {
                if let shift {
                    decoding.shift += shift
                    decoder = decoding
                    runDecodeTimer()
                    decodeTick()
                } else {
                    finishDecode()
                }
            } else if var decoding = lastDecoding, let from = resumeFrom {
                // Same clock as a fresh pop-in reaching letter `from` now; the letters before it
                // stay as they finished.
                decoding.start = Date().addingTimeInterval(-Double(from) * decoding.rate)
                decoding.shift = 0
                decoding.settled = from
                decoder = decoding
                if decoding.recipe.pawsOn {
                    // The cat carries on from where it stopped, in step, instead of starting over.
                    if pawWalk == nil {
                        pawWalk = PawWalk(decoding.recipe, characters: text.count)
                        pawWalkStart = Date()
                    }
                    pawWalk?.skip(to: from)
                }
                if var plan = particlePlan {
                    plan.start = decoding.start
                    plan.shift = 0
                    plan.scheduled = from
                    particlePlan = plan
                }
                runDecodeTimer()
                decodeTick()
            }
            if var plan = particlePlan {
                if let shift {
                    plan.shift += shift
                    particlePlan = plan
                    shedNewParticles()
                } else {
                    particlePlan = nil
                }
            }
            particles.resumeTrickle()
            // A faded trail stays under the finished text, following it as it is typed through.
            if decoder == nil, let walk = pawWalk, let r = lastDecoding?.recipe {
                view.paws = walk.prints(r, at: Date().timeIntervalSince(pawWalkStart))
            }
        }
        orderFront()
        noteShown(text)
    }

    /// The mirror goes first: the host's line is revealed exactly as the host drew it.
    public func hide() {
        mirror.hide()
        orderOut()
        // Nothing to animate while hidden; a quick redraw carries on from the clock, not the timer.
        decodeTimer?.invalidate()
        decodeTimer = nil
        particles.pauseTrickle()
        if isShown {
            isShown = false
            hiddenAt = Date()
        }
    }

    /// The next text plays the pop-in whatever was shown before (a ghost reused for new text).
    public func forgetShown() {
        lastShown = nil
        hiddenAt = nil
    }

    private var hiddenFor: TimeInterval? {
        isShown ? nil : hiddenAt.map { Date().timeIntervalSince($0) } ?? .infinity
    }

    private func noteShown(_ text: String) {
        lastShown = text
        isShown = true
        hiddenAt = nil
    }

    /// The ghost color from the app's own look, else Settings → Appearance (mirror mode uses it too).
    func ghostColor(textColor: RGBAColor?, tweaks: GhostTweaks) -> NSColor {
        let appearance = tweaks.appearance ?? self.appearance
        let greyForced = tweaks.greyForced
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let c = PopIn.color(choice: appearance.color, opacity: appearance.clampedOpacity, textColor: textColor,
                            greyForced: greyForced,
                            accent: RGBAColor(red: accent?.redComponent ?? 0, green: accent?.greenComponent ?? 0.48,
                                              blue: accent?.blueComponent ?? 1),
                            custom: appearance.customColor.rgba, effect: appearance.effectColor?.rgba)
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    // MARK: Pop-in

    /// Starts a pop-in on the ghost's layer: every switched-on effect at once, each with its own
    /// length. `textStart` is where the suggestion's own text begins in the view (after a box's
    /// padding or a struck-through word).
    private func playPopIn(_ r: PopInRecipe, unit: Double, textStart: CGFloat) {
        guard let layer = view.layer else { return }
        layer.removeAllAnimations()
        finishTypewriter()
        typewriterRate = nil
        finishDecode()
        lastDecoding = nil
        pawWalk = nil
        view.paws = []
        particlePlan = nil
        particles.stopTrickle()
        blurToken = nil
        view.contentFilters = []
        guard !r.isEmpty else { return }
        if r.fadeOn {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            layer.add(Self.configured(fade, ms: r.fadeMs), forKey: "popIn.fade")
        }
        if r.slideOn {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = r.slideDistance * unit
            slide.toValue = 0
            layer.add(Self.configured(slide, ms: r.slideMs), forKey: "popIn.slide")
        }
        // Rise and wiggle both move vertically; with both on they add up.
        if r.riseOn {
            let k = PopIn.riseKeyframes(distance: r.riseDistance, bob: r.bobDistance)
            let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
            rise.values = k.values.map { $0 * unit }
            rise.keyTimes = k.times.map { NSNumber(value: $0) }
            rise.isAdditive = true
            rise.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: k.values.count - 1)
            layer.add(Self.configured(rise, ms: r.riseMs, ease: false), forKey: "popIn.rise")
        }
        if r.wiggleOn {
            let k = PopIn.wiggleKeyframes(height: r.wiggleHeight, count: r.wiggleCount)
            let wobble = CAKeyframeAnimation(keyPath: "transform.translation.y")
            wobble.values = k.values.map { $0 * unit }
            wobble.keyTimes = k.times.map { NSNumber(value: $0) }
            wobble.calculationMode = .cubic
            wobble.isAdditive = true
            layer.add(Self.configured(wobble, ms: r.wiggleMs, ease: false), forKey: "popIn.wiggle")
        }
        if r.growOn {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = max(0.05, r.growFromPercent / 100)
            grow.toValue = 1
            grow.isAdditive = false
            layer.add(Self.configured(grow, ms: r.growMs), forKey: "popIn.grow")
        }
        if r.blurOn, r.blurRadius > 0, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            view.layerUsesCoreImageFilters = true
            view.contentFilters = [blur]
            let sharpen = CABasicAnimation(keyPath: "filters.blur.inputRadius")
            sharpen.fromValue = r.blurRadius * unit
            sharpen.toValue = 0
            layer.add(Self.configured(sharpen, ms: r.blurMs), forKey: "popIn.blur")
            // The filter costs a GPU pass on every redraw: drop it once sharp.
            let token = UUID()
            blurToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + r.blurMs / 1000 + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.blurToken == token else { return }
                    self.view.contentFilters = []
                }
            }
        }
        if PopIn.isPerLetter(r) { startDecode(r, unit: unit) }
        if r.particlesOn { startParticles(r, unit: unit) }
        if r.typewriterOn {
            startTypewriter(on: layer, textStart: textStart,
                            duration: PopIn.typewriterDuration(r, characters: view.text.count))
        }
    }

    private static func configured<A: CAPropertyAnimation>(_ a: A, ms: Double, ease: Bool = true) -> A {
        a.duration = max(0.01, ms / 1000)
        if ease { a.timingFunction = CAMediaTimingFunction(name: .easeOut) }
        a.fillMode = .backwards
        return a
    }

    private var blurToken: UUID?

    /// A typewriter reveal in progress: when it started, seconds per character, and how many
    /// characters the current text has lost (+) or gained (-) at its front since then.
    private struct Typing {
        var start: Date
        var rate: TimeInterval
        var shift: Int
    }

    private var typewriter: Typing?
    /// The current pop-in's typewriter pace, kept after the reveal ends so words streamed in later
    /// type in too. Nil when the pop-in has no typewriter.
    private var typewriterRate: TimeInterval?

    private func startTypewriter(on layer: CALayer, textStart: CGFloat, duration: TimeInterval) {
        let count = max(1, view.text.count)
        typewriterRate = duration / Double(count)
        typewriter = Typing(start: Date(), rate: duration / Double(count), shift: 0)
        runTypewriter(textStart: textStart)
    }

    /// (Re)builds the reveal mask for the current text from where the reveal has got to, so the
    /// remaining characters keep appearing at the same pace.
    private func runTypewriter(textStart: CGFloat) {
        guard let typing = typewriter, let layer = view.layer else { return }
        let text = view.text
        let shown = PopIn.typewriterRevealed(elapsed: Date().timeIntervalSince(typing.start), rate: typing.rate,
                                             shift: typing.shift)
        guard shown < Double(text.count) else { finishTypewriter(); return }
        let size = view.bounds.size
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: view.font, .kern: view.kern]))
        let utf16 = (text as NSString).length
        // Mask widths after each character, from the next one still hidden.
        var edges: [CGFloat] = [textStart]
        var index = 0
        for ch in text {
            index += ch.utf16.count
            edges.append(textStart + view.nudge.x + CTLineGetOffsetForStringIndex(line, min(index, utf16), nil))
        }
        edges[edges.count - 1] = size.width
        let first = max(0, Int(shown.rounded(.down)))
        let remaining = Double(text.count) - shown
        let duration = remaining * typing.rate
        var values: [CGFloat] = []
        var times: [NSNumber] = []
        for i in first...text.count {
            values.append(edges[i])
            let t = i == first ? 0 : (Double(i) - shown) / remaining
            times.append(NSNumber(value: min(1, max(0, t))))
        }
        let mask = layer.mask ?? CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = .zero
        mask.frame = CGRect(origin: .zero, size: size)
        layer.mask = mask
        mask.removeAllAnimations()
        let reveal = CAKeyframeAnimation(keyPath: "bounds.size.width")
        reveal.values = values
        reveal.keyTimes = times
        reveal.calculationMode = .discrete
        reveal.duration = max(0.01, duration)
        mask.add(reveal, forKey: "popIn.type")
        let token = UUID()
        typewriterToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.typewriterToken == token else { return }
                self.finishTypewriter()
            }
        }
    }

    private var typewriterToken: UUID?

    // MARK: Decode

    /// Scramble and/or Color fade in progress (see `Typing` for `shift`), with the recipe's look.
    private struct Decoding {
        var start: Date
        var rate: TimeInterval
        var shift: Int
        var recipe: PopInRecipe
        /// Text-size scale for distances.
        var unit: Double
        /// Letters, counted from the original text's front, that had finished before words streamed
        /// in after the effect ended: drawn as finished while the new ones run.
        var settled = 0
    }

    private var decoder: Decoding?
    /// The current pop-in's per-letter settings, kept after the effect ends so words streamed in
    /// later get it too. Nil when the pop-in has no per-letter effect.
    private var lastDecoding: Decoding?
    private var decodeTimer: Timer?
    /// Paw walk's cat for the current suggestion, kept after the effect ends (its faded trail, and
    /// words streamed in later), on its own clock from `pawWalkStart`.
    private var pawWalk: PawWalk?
    private var pawWalkStart = Date()

    private func startDecode(_ r: PopInRecipe, unit: Double) {
        pawWalk = r.pawsOn ? PawWalk(r, characters: view.text.count) : nil
        pawWalkStart = Date()
        decoder = Decoding(start: Date(), rate: PopIn.sweepRate(r, characters: view.text.count), shift: 0, recipe: r,
                           unit: unit)
        lastDecoding = decoder
        runDecodeTimer()
        decodeTick()
    }

    private func runDecodeTimer() {
        guard decodeTimer == nil else { return }
        // ~60 frames a second; scramble changes are paced by the recipe, not the timer.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.decodeTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        decodeTimer = timer
    }

    /// Draws the current frame, and ends once every letter is in and done fading.
    private func decodeTick() {
        guard let d = decoder else { return }
        let r = d.recipe
        let now = Date()
        let elapsed = now.timeIntervalSince(d.start)
        let text = view.text
        let locked = PopIn.typewriterRevealed(elapsed: elapsed, rate: d.rate, shift: d.shift)
        let walkTime = now.timeIntervalSince(pawWalkStart)
        pawWalk?.advance(to: walkTime, characters: text.count)
        if locked >= PopIn.sweepEnd(r, characters: text.count),
           pawWalk?.isQuiet(r, at: walkTime, characters: text.count) ?? true {
            finishDecode()
            return
        }
        let walk = pawWalk
        // Seconds from the sweep reaching letter `i` to its paw stamping it (far off if not yet).
        func pawLag(_ i: Int) -> TimeInterval {
            guard let walk else { return 0 }
            guard let start = walk.letterStart(r, index: i) else { return 3600 }
            return pawWalkStart.timeIntervalSince(d.start) + start - Double(i + d.shift) * d.rate
        }
        if r.decodeOn {
            let tick = Int(elapsed / max(0.005, r.decodeScrambleMs / 1000))
            view.decode = PopIn.decodeFrame(text, locked: locked, tick: tick, pool: r.decodeCharacters.pool)
        } else {
            view.decode = Array(text)
        }
        let fadeMs = PopIn.letterFadeMs(r)
        let settled = d.settled - d.shift
        view.decodeTint = (0..<text.count).map {
            $0 < settled ? 0 : PopIn.decodeTint(index: $0, locked: locked, rate: d.rate, fadeMs: fadeMs,
                             delay: PopIn.letterFadeDelay(r, index: $0 + d.shift) + pawLag($0))
        }
        view.scrambleColor = r.colorFadeOn ? fadeColor(r) : nil
        if PopIn.hasLetterPose(r) {
            // Pose randomness keys on the letter's place in the original text, so typing through
            // doesn't reshuffle it.
            let unit = d.unit
            view.poses = (0..<text.count).map { i in
                if i < settled { return PopIn.LetterPose() }
                let t: TimeInterval
                if let walk {
                    t = walk.letterStart(r, index: i).map { walkTime - $0 } ?? -1
                } else {
                    t = elapsed - PopIn.letterStart(r, index: i + d.shift, rate: d.rate)
                }
                var pose = PopIn.letterPose(r, index: i + d.shift, t: t)
                pose.dx *= unit
                pose.dy *= unit
                pose.ripple *= unit
                return pose
            }
            view.applyLook(r, unit: unit)
        } else {
            view.poses = []
        }
        view.paws = walk?.prints(r, at: walkTime) ?? []
        view.needsDisplay = true
    }

    /// Color fade's starting color. Green and custom colors stay vivid even on a faint suggestion.
    private func fadeColor(_ r: PopInRecipe) -> NSColor {
        let vivid = max(0.85, view.color.alphaComponent)
        switch r.colorFadeColor {
        case .bright: return view.color.withAlphaComponent(1)
        case .green: return Self.matrixGreen.withAlphaComponent(vivid)
        case .custom:
            let c = r.colorFadeCustom
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: vivid)
        }
    }

    static let matrixGreen = NSColor(srgbRed: 0.2, green: 0.95, blue: 0.4, alpha: 1)

    private func finishDecode() {
        decodeTimer?.invalidate()
        decodeTimer = nil
        guard let d = decoder else { return }
        decoder = nil
        view.decode = nil
        view.decodeTint = []
        view.poses = []
        // A faded trail stays; four live paws have walked off.
        view.paws = pawWalk?.prints(d.recipe, at: Date().timeIntervalSince(pawWalkStart)) ?? []
        view.needsDisplay = true
    }

    // MARK: Particles

    private let particles = ParticleEmitter()
    /// Where the suggestion's own text starts in `view` (see `playPopIn`).
    private var textStart: CGFloat = 0

    /// Particles for the current pop-in: its clock (as `Decoding`), and how many letters, counted
    /// from the original text's front, have had theirs scheduled.
    private struct ParticlePlan {
        var start: Date
        var rate: TimeInterval
        var shift: Int
        var scheduled: Int
        var recipe: PopInRecipe
        var unit: Double
    }

    private var particlePlan: ParticlePlan?

    private func startParticles(_ r: PopInRecipe, unit: Double) {
        let count = view.text.count
        let rate = PopIn.sweepRate(r, characters: count)
        particlePlan = ParticlePlan(start: Date(), rate: rate, shift: 0, scheduled: 0, recipe: r, unit: unit)
        shedNewParticles()
        particles.startTrickle(r, unit: unit, after: rate * Double(count) + PopIn.landDelay(r)) { [weak self] in
            self?.lineRect()
        }
    }

    /// Schedules particles for letters that haven't had theirs: all of them at the start, then the ones
    /// a growing suggestion adds while its pop-in is still running.
    private func shedNewParticles() {
        guard var plan = particlePlan else { return }
        let text = view.text
        let first = max(0, plan.scheduled - plan.shift)
        defer {
            plan.scheduled = max(plan.scheduled, text.count + plan.shift)
            particlePlan = plan
        }
        // Letters added after the pop-in finished just appear.
        guard first < text.count, decoder != nil || plan.scheduled == 0 else { return }
        let centers = letterCenters()
        let elapsed = Date().timeIntervalSince(plan.start)
        let delays = (0..<text.count).map {
            PopIn.letterStart(plan.recipe, index: $0 + plan.shift, rate: plan.rate)
                + PopIn.letterLandDelay(plan.recipe, index: $0 + plan.shift) - elapsed
        }
        let tail = String(text.dropFirst(first))
        particles.shed(plan.recipe, text: tail, centers: Array(centers.dropFirst(first)),
                    delays: Array(delays.dropFirst(first)), unit: plan.unit)
    }

    /// Each letter's middle, in the panel's content coords (where `particles.view` sits).
    private func letterCenters() -> [CGPoint] {
        let text = view.text
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: view.font, .kern: view.kern]))
        let utf16 = (text as NSString).length
        let base = view.frame.origin
        let y = base.y + GhostView.padding - view.font.descender + view.font.xHeight * 0.5 + view.nudge.y
        var index = 0
        return text.map { ch in
            let a = CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)
            index += ch.utf16.count
            let b = CTLineGetOffsetForStringIndex(line, min(index, utf16), nil)
            return CGPoint(x: base.x + textStart + view.nudge.x + (a + b) / 2, y: y)
        }
    }

    /// The suggestion's text box, for the trickle; nil while hidden.
    private func lineRect() -> CGRect? {
        guard isShown, isOnScreen else { return nil }
        let f = view.frame
        return CGRect(x: f.minX + textStart, y: f.minY + GhostView.padding,
                      width: max(0, f.width - textStart), height: max(1, f.height - 2 * GhostView.padding))
    }

    private func finishTypewriter() {
        typewriterToken = nil
        typewriter = nil
        view.layer?.mask = nil
    }

    /// The host's font when it can be rebuilt (by name, then family), else the system font, at the
    /// hinted size or one derived from the caret height.
    static func font(for hint: FontHint?, caretHeight: CGFloat) -> NSFont {
        let size = OverlayLayout.fontSize(hint: hint?.pointSize, caretHeight: caretHeight)
        if let own = hostFont(for: hint, size: size * (hint?.sizeFactor ?? 1)) { return own }
        if let stand = lookalikeFamily(for: hint),
           let f = NSFontManager.shared.font(withFamily: stand, traits: [], weight: 5, size: size) { return f }
        if hint?.isMonospaced == true { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont.systemFont(ofSize: size)
    }

    /// The host's own font by name, then family, when it loads.
    static func hostFont(for hint: FontHint?, size: CGFloat) -> NSFont? {
        // Names starting with "." are private system faces (SF); the system font is the same face.
        if let name = hint?.name, !name.hasPrefix("."), let f = NSFont(name: name, size: size) { return f }
        if let family = hint?.family, !family.hasPrefix("."),
           let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) { return f }
        return nil
    }

    /// The installed stand-in for a host font macOS can't load (known by name, else picked from
    /// on-screen measurement), nil otherwise.
    static func lookalikeFamily(for hint: FontHint?) -> String? {
        FontLookalike.standIn(for: hint)
    }

    /// Alignment check (opt-in): compares the letter height the ghost is drawn with against the
    /// host's, both read from ink by the last calibration, and logs a noticeable difference.
    private func checkAlignment(_ p: GhostPresentation, font: NSFont, standIn: String?) {
        guard AlignmentCheckLog.isEnabled, let host = p.measuredXHeight, let at = p.measuredAtSize, at > 0
        else { return }
        let hint = p.geometry.font
        let key: String
        if let standIn {
            key = standIn
        } else if Self.hostFont(for: hint, size: font.pointSize) != nil {
            key = "@host"
        } else if font.familyName?.hasPrefix(".") == true {
            key = FaceMatch.systemFamily
        } else {
            return   // monospaced fallback: not measured
        }
        guard let ref = p.drawnXHeights[key] else { return }
        let drawn = ref * font.pointSize / at
        let logKey = "\(p.appID ?? "?")|\(Int((at * 2).rounded()))"
        let okKey = "ok|" + logKey
        guard FaceMatch.isDrift(host: host, drawn: drawn) else {
            // Once per app and size until it drifts again, so an empty log can't hide a dead check.
            AlignmentCheckLog.clear(key: logKey)
            AlignmentCheckLog.noteOnce(String(format: "aligned app=%@ size=%.1f drawn=%@@%.2f x(drawn)=%.2f x(host)=%.2f diff=%+.2f",
                                              p.appID ?? "?", at, key, font.pointSize, drawn, host, drawn - host), key: okKey)
            return
        }
        AlignmentCheckLog.clear(key: okKey)
        AlignmentCheckLog.note(String(format: "drift app=%@ reported=%@/%@ size=%.1f drawn=%@@%.2f x(drawn)=%.2f x(host)=%.2f diff=%+.2f",
                                      p.appID ?? "?", hint?.family ?? "nil", hint?.name ?? "nil", at,
                                      key, font.pointSize, drawn, host, drawn - host), key: logKey)
    }

    /// Average advance of lowercase text in `font`, for spreading a width difference over characters.
    static func meanAdvance(_ font: NSFont) -> CGFloat {
        let sample = "the quick brown fox jumps over a lazy dog"
        return (sample as NSString).size(withAttributes: [.font: font]).width / CGFloat(sample.count)
    }

    /// Background for the mid-line box: light behind dark text, dark behind light text; the
    /// system text background when the host reports no color.
    static func boxColor(textColor: RGBAColor?) -> NSColor {
        guard let c = textColor else { return NSColor.textBackgroundColor.withAlphaComponent(0.97) }
        return c.luminance < 0.5 ? NSColor(white: 0.985, alpha: 0.97) : NSColor(white: 0.13, alpha: 0.97)
    }
}

#if DEBUG
public extension GhostOverlayPresenter {
    /// Manual visual check: shows a ghost at a fixed global point (AppKit coords) in both modes.
    func demo(at point: CGPoint = CGPoint(x: 400, y: 400), mode: GhostMode = .inline) {
        let g = CaretGeometry(caretRect: CGRect(x: point.x, y: point.y, width: 1, height: 18), quality: .exact)
        present(GhostPresentation(text: "demo ghost suggestion text", geometry: g, mode: mode))
    }

    /// Offscreen check: the ghost's own drawing `elapsed` seconds into a per-letter pop-in, as an image
    /// (particles are Core Animation and don't show here).
    static func snapshot(_ text: String, recipe r: PopInRecipe, elapsed: TimeInterval, fontSize: CGFloat = 26,
                         color: NSColor = NSColor(white: 0.1, alpha: 0.6),
                         background: NSColor = .white, scale: CGFloat? = nil) -> NSBitmapImageRep? {
        let view = GhostView()
        view.font = NSFont.systemFont(ofSize: fontSize)
        view.color = color
        view.text = text
        let unit = Double(max(0.8, min(2, fontSize / 13)))
        let rate = PopIn.sweepRate(r, characters: text.count)
        let locked = elapsed / max(0.0001, rate)
        view.decode = r.decodeOn
            ? PopIn.decodeFrame(text, locked: locked, tick: Int(elapsed / max(0.005, r.decodeScrambleMs / 1000)),
                                pool: r.decodeCharacters.pool)
            : Array(text)
        view.decodeTint = (0..<text.count).map {
            PopIn.decodeTint(index: $0, locked: locked, rate: rate, fadeMs: PopIn.letterFadeMs(r),
                             delay: PopIn.letterFadeDelay(r, index: $0) + PopIn.letterLag(r, index: $0, rate: rate))
        }
        if r.colorFadeOn {
            let c = r.colorFadeCustom
            view.scrambleColor = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 0.9)
        }
        if PopIn.hasLetterPose(r) {
            view.poses = (0..<text.count).map {
                var pose = PopIn.letterPose(r, index: $0, t: elapsed - PopIn.letterStart(r, index: $0, rate: rate))
                pose.dx *= unit
                pose.dy *= unit
                pose.ripple *= unit
                return pose
            }
            view.applyLook(r, unit: unit)
            view.paws = PopIn.pawPrints(r, characters: text.count, shift: 0, elapsed: elapsed, rate: rate)
        }
        let width = GhostView.width(text, view.font) + 2
        let height = ceil(view.font.ascender - view.font.descender) + GhostView.padding * 2
        let pad = CGFloat(PopIn.margin(r, unit: unit, size: CGSize(width: width, height: height)))
        let container = NSView(frame: CGRect(x: 0, y: 0, width: width + 2 * pad, height: height + 2 * pad))
        container.wantsLayer = true
        container.layer?.backgroundColor = background.cgColor
        view.frame = CGRect(x: pad, y: pad, width: width, height: height)
        container.addSubview(view)
        // A set `scale` gives the same pixels on any display (the intro video's frames); nil follows
        // the screen.
        let rep: NSBitmapImageRep?
        if let scale {
            let size = container.bounds.size
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                                   pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = size
        } else {
            rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)
        }
        guard let rep else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep
    }
}
#endif
