import AppKit
import HunchCore

private final class MirrorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The mirrored line: the field's background, then one Core Text line holding the typed text in the
/// host's color and the ghost after it (one line keeps the kerning across the caret).
private final class MirrorView: NSView {
    var line: CTLine?
    var background = NSColor.textBackgroundColor
    /// Start of the text's baseline, in view coordinates (sub-point exact).
    var textOrigin = CGPoint.zero

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        background.set()
        bounds.fill(using: .copy)
        guard let line, let context = NSGraphicsContext.current?.cgContext else { return }
        context.textMatrix = .identity
        context.textPosition = textOrigin
        CTLineDraw(line, context)
    }
}

/// Mirror mode (per-app opt-in, for hosts where an inline ghost can't line up): a second,
/// opaque, non-activating, click-through panel covers the caret's line from its first character to
/// the field's right edge and redraws the typed text in the host's font and color, the ghost after
/// it, and a system caret (`NSTextInsertionIndicator`, which blinks on its own) between them.
/// It only draws; the host's text is never changed, and hiding the panel reveals it as it was.
@MainActor
final class TextMirrorPresenter {
    private let panel: NSPanel
    private let view = MirrorView()
    private let caret = NSTextInsertionIndicator()
    private(set) var isVisible = false

    init() {
        let p = MirrorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        // Same level and behavior as the ghost panel; opaque, since it hides the host's line.
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isOpaque = true
        p.hasShadow = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = view
        caret.displayMode = .automatic
        view.addSubview(caret)
        panel = p
    }

    /// Covers the caret's line and redraws it with `ghost`. False (nothing shown) when the line
    /// can't be laid out, so the caller falls back to the card. `font` is the one the ghost would be
    /// drawn in (the host's, sized as for inline).
    func present(ghost: String, content: MirrorContent, presentation: GhostPresentation, font: NSFont,
                 visible: CGRect, ghostColor: NSColor) -> Bool {
        let geometry = presentation.geometry
        let caretRect = geometry.caretRect
        let hint = geometry.font
        let typed = content.lineBefore
        let measure = { (s: String) in Self.width(s, font) }
        let baseline = MirrorLayout.baselineY(caretRect: caretRect, measuredBaseline: presentation.measuredBaseline,
                                              descender: -font.descender, ascender: font.ascender,
                                              offset: presentation.tweaks.verticalOffset)
        let frame = MirrorLayout.frame(lineStartX: content.lineStartX, baseline: baseline, ascender: font.ascender,
                                       descender: font.descender, leading: font.leading,
                                       fieldFrame: geometry.fieldFrame, caretRect: caretRect,
                                       typedWidth: measure(typed), ghostWidth: measure(ghost), visible: visible)
        guard frame.height > 0, frame.minX <= content.lineStartX else { hide(); return false }
        let fitted = MirrorLayout.fit(typed: typed, ghost: ghost,
                                      maxWidth: frame.maxX - content.lineStartX - MirrorLayout.caretRoom,
                                      measure: measure)
        // A mirror without the ghost would only hide the host's line.
        guard fitted.ghost.contains(where: { !$0.isWhitespace }) else { hide(); return false }

        let textColor = hint?.textColor.map(Self.color) ?? NSColor.textColor
        let shown = NSMutableAttributedString()
        if fitted.truncatedHead {
            // Secondary: the host's text color at the ghost's strength.
            shown.append(NSAttributedString(string: MirrorLayout.ellipsis, attributes: [.font: font, .foregroundColor: ghostColor]))
        }
        shown.append(NSAttributedString(string: fitted.typed, attributes: [.font: font, .foregroundColor: textColor]))
        let caretIndex = shown.length
        shown.append(NSAttributedString(string: fitted.ghost, attributes: [.font: font, .foregroundColor: ghostColor]))
        let line = CTLineCreateWithAttributedString(shown)
        let caretOffset = CTLineGetOffsetForStringIndex(line, caretIndex, nil)

        let snapped = MirrorLayout.snappedOutward(frame)
        view.line = line
        view.background = (content.backgroundColor.map(Self.color)
            ?? GhostOverlayPresenter.boxColor(textColor: hint?.textColor)).withAlphaComponent(1)
        view.textOrigin = CGPoint(x: content.lineStartX - snapped.minX, y: baseline - snapped.minY)
        if DrawDebugLog.isEnabled {
            // Geometry only: the mirrored text itself is never logged.
            DrawDebugLog.note("mirror frame=\(DrawDebugLog.fmt(snapped)) lineStartX=\(String(format: "%.2f", content.lineStartX)) "
                + "caret=\(DrawDebugLog.fmt(caretRect)) baselineY=\(String(format: "%.2f", baseline)) "
                + "typedEnd=\(String(format: "%.2f", content.lineStartX + caretOffset)) head=\(fitted.truncatedHead) "
                + "background=\(content.backgroundColor == nil ? "derived" : "known")")
        }
        panel.backgroundColor = view.background
        panel.setFrame(snapped, display: false)
        view.frame = CGRect(origin: .zero, size: snapped.size)
        // The host's caret rect width; the panel's full height (one line).
        caret.frame = CGRect(x: view.textOrigin.x + caretOffset, y: 0,
                             width: max(1, caretRect.width), height: snapped.height)
        caret.displayMode = .automatic
        view.needsDisplay = true
        panel.orderFrontRegardless()
        isVisible = true
        return true
    }

    func hide() {
        guard isVisible else { return }
        caret.displayMode = .hidden
        panel.orderOut(nil)
        isVisible = false
    }

    /// Typographic width, unrounded: positions on the mirrored line must stay exact.
    static func width(_ s: String, _ font: NSFont) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func color(_ c: RGBAColor) -> NSColor {
        NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}
