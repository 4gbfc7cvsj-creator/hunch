import AppKit
import HunchCore

/// The suggested-replies bubble: up to three replies, the one Tab picked highlighted (the keys are
/// explained next to the Settings toggle). Three layouts (`SuggestedRepliesLayout`): stacked in one
/// panel above the caret, one-line chips in a row above the text box, or outlined one-line chips
/// inline at the caret. It never takes focus (the host keeps its caret and stays frontmost); a click
/// on a reply picks it.
@MainActor
public final class SuggestedRepliesBubble {
    /// A reply was clicked (its index).
    public var onClick: ((Int) -> Void)?

    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let stack = NSStackView()
    private var rows: [ReplyRow] = []
    /// The chip layouts: a clear view holding one `ReplyChip` per reply.
    private let chipsView = NSView()
    private var chips: [ReplyChip] = []
    private var chipPlacement: (geometry: CaretGeometry, layout: SuggestedRepliesLayout)?

    /// The look the replies' text pops in with: the app's own look, else Settings → Appearance (set
    /// before `show`). Nil plays nothing.
    public var effectLook: AppearanceSettings? {
        didSet { effects.appearance = effectLook ?? AppearanceSettings() }
    }
    private let effects = TextEffectPlayer()
    /// Text hidden while its pop-in plays: each call shows it again.
    private var hiddenText: [(Bool) -> Void] = []
    private var revealWork: DispatchWorkItem?

    nonisolated static let maxWidth: CGFloat = 460
    nonisolated static let gap: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 13)

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilityLabel("Quick replies")

        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        chipsView.wantsLayer = true
    }

    public var isVisible: Bool { panel.isVisible }

    /// How the replies shown are arranged, for the arrow keys: some sit on lines above or below each
    /// other (`stacked`), some next to each other on one line (`sideBySide`).
    public var arrangement: (stacked: Bool, sideBySide: Bool) {
        if !rows.isEmpty { return (rows.count > 1, false) }
        return Self.arrangement(of: chips.map(\.frame))
    }

    /// The pure rule behind `arrangement`: lines are chips sharing a vertical center.
    public nonisolated static func arrangement(of frames: [CGRect]) -> (stacked: Bool, sideBySide: Bool) {
        var lines: [CGFloat: Int] = [:]
        for f in frames { lines[(f.midY).rounded(), default: 0] += 1 }
        return (lines.count > 1, lines.values.contains { $0 > 1 })
    }

    /// A screen point (bottom-left origin) is on the bubble.
    public func contains(_ point: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }

    /// Shows `replies` in `layout` at `geometry` (AppKit screen coordinates).
    public func show(_ replies: [String], highlighted: Int?, geometry: CaretGeometry, layout: SuggestedRepliesLayout) {
        guard layout != .verticalStack else { return show(replies, highlighted: highlighted, caret: geometry.caretRect) }
        guard !replies.isEmpty else { return hide() }
        clearContents()
        let inline = layout == .inlineAtCaret
        let font = inline ? Self.inlineFont(geometry) : Self.font
        let tint = inline ? Self.inlineTint(geometry.font?.textColor) : NSColor.labelColor
        chips = replies.enumerated().map { i, text in
            let chip = ReplyChip(text: text, font: font, style: inline ? .outlined : .filled, tint: tint,
                                 backdrop: Self.inlineBackdrop(geometry.font?.backgroundColor, text: geometry.font?.textColor))
            chip.handler = { [weak self] in self?.onClick?(i) }
            chipsView.addSubview(chip)
            return chip
        }
        chipPlacement = (geometry, layout)
        panel.contentView = chipsView
        panel.hasShadow = !inline
        setHighlight(highlighted)
        panel.orderFrontRegardless()
        playEffects(chips.map { chip in
            let frame = screenRect(chip.textRect, in: chip)
            let line = Self.drawnLines(chip.text, font: chip.font, width: chip.textRect.width, maxLines: 1).first ?? ""
            return EffectTarget(lines: [(line, frame)], font: chip.font, color: chip.textColor) { [weak chip] hidden in
                chip?.textHidden = hidden
            }
        })
    }

    /// Shows `replies` stacked next to `caret` (AppKit screen coordinates): above it, or below when
    /// there is no room above.
    public func show(_ replies: [String], highlighted: Int?, caret: CGRect) {
        guard !replies.isEmpty else { return hide() }
        clearContents()
        panel.contentView = background
        panel.hasShadow = true
        rows = replies.enumerated().map { i, text in
            let row = ReplyRow(text: text, font: Self.font, maxWidth: Self.maxWidth - 12)
            row.handler = { [weak self] in self?.onClick?(i) }
            return row
        }
        rows.forEach { stack.addArrangedSubview($0) }
        setHighlight(highlighted)
        let size = stack.fittingSize
        let width = min(Self.maxWidth, max(size.width, 160))
        for row in rows { row.widthAnchor.constraint(equalToConstant: width - 12).isActive = true }
        let height = stack.fittingSize.height
        panel.setFrame(Self.frame(size: CGSize(width: width, height: height), caret: caret), display: true)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        playEffects(rows.map { row in
            let label = row.label
            let font = label.font ?? Self.font
            let local = label.bounds.insetBy(dx: ReplyRow.textInset, dy: 0)
            let frame = screenRect(local, in: label)
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let texts = Self.drawnLines(label.stringValue, font: font, width: local.width,
                                        maxLines: max(1, label.maximumNumberOfLines))
            let lines = texts.enumerated().map { i, text in
                (text, CGRect(x: frame.minX, y: frame.maxY - CGFloat(i + 1) * lineHeight, width: frame.width,
                              height: lineHeight))
            }
            return EffectTarget(lines: lines, font: font, color: label.textColor ?? .labelColor) { [weak label] hidden in
                label?.alphaValue = hidden ? 0 : 1
            }
        })
    }

    /// Moves the highlight (Tab) without rebuilding the bubble. Chips are laid out again: the
    /// highlighted one grows to show its whole reply.
    public func setHighlight(_ index: Int?) {
        // Chips move when one grows: a pop-in still playing would be left behind.
        finishEffects()
        for (i, row) in rows.enumerated() { row.highlighted = i == index }
        guard !chips.isEmpty, let (geometry, layout) = chipPlacement else { return }
        for (i, chip) in chips.enumerated() { chip.highlighted = i == index }
        layoutChips(geometry: geometry, layout: layout)
    }

    public func hide() {
        finishEffects()
        panel.orderOut(nil)
        clearContents()
    }

    private func clearContents() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        chips.forEach { $0.removeFromSuperview() }
        chips = []
        chipPlacement = nil
    }

    // MARK: Pop-in

    /// A reply's text on screen: its lines as the bubble draws them (AppKit screen coordinates, each
    /// line's own box), how, and how to hide the real text while the effect plays over it.
    private struct EffectTarget {
        var lines: [(text: String, frame: CGRect)]
        var font: NSFont
        var color: NSColor
        var setHidden: (Bool) -> Void
    }

    /// `text` broken into lines the way it is drawn `width` wide in `font` (up to `maxLines`; a
    /// truncated last line keeps only what shows before the ellipsis, the rest appears with the text).
    static func drawnLines(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> [String] {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var lines: [String] = []
        let ns = text as NSString
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, stop in
            let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append(ns.substring(with: chars).trimmingCharacters(in: .whitespacesAndNewlines))
            if lines.count == maxLines { stop.pointee = true }
        }
        if lines.count == maxLines, let last = lines.last {
            // The last line drawn is cut with an ellipsis when more follows: play the words that fit.
            let shown = lines.dropLast().joined(separator: " ").count + last.count
            if shown < text.trimmingCharacters(in: .whitespacesAndNewlines).count - 1 {
                var words = last.split(separator: " ").map(String.init)
                let ellipsis = ("\u{2026}" as NSString).size(withAttributes: [.font: font]).width
                while !words.isEmpty,
                      (words.joined(separator: " ") as NSString).size(withAttributes: [.font: font]).width + ellipsis > width {
                    words.removeLast()
                }
                lines[lines.count - 1] = words.joined(separator: " ")
            }
        }
        return lines.filter { !$0.isEmpty }
    }

    private func screenRect(_ rect: CGRect, in view: NSView) -> CGRect {
        panel.convertToScreen(view.convert(rect, to: nil))
    }

    /// Plays the suggestions' pop-in on each reply's text where it sits (wrapped like the label), with
    /// the real text hidden until every reply has settled. Nothing plays for None (`effectLook` nil
    /// or an empty recipe); Reduce Motion plays a plain fade.
    private func playEffects(_ targets: [EffectTarget]) {
        finishEffects()
        guard effectLook != nil, !effects.recipe(tweaks: GhostTweaks()).isEmpty else { return }
        let layout = NSLayoutManager()
        var settle: TimeInterval = 0
        for t in targets {
            let lineHeight = layout.defaultLineHeight(for: t.font)
            var played = false
            // Each line exactly as the bubble breaks it: no field, so the effect never re-wraps it (its
            // own measuring can differ by a point and push the last word onto a line that never plays).
            for line in t.lines where line.frame.width > 1 && !line.text.isEmpty {
                let caret = CGRect(x: line.frame.minX - OverlayLayout.inlineXOffset, y: line.frame.maxY - lineHeight,
                                   width: 0, height: lineHeight)
                let geometry = CaretGeometry(caretRect: caret, font: FontHint(pointSize: t.font.pointSize), quality: .exact)
                let base = GhostPresentation(text: line.text, geometry: geometry, mode: .inline,
                                             measuredBaseline: lineHeight - layout.defaultBaselineOffset(for: t.font))
                let (seconds, _) = effects.playWrapped(line.text, base: base, color: t.color)
                guard seconds > 0 else { continue }
                played = true
                settle = max(settle, seconds)
            }
            guard played else { continue }
            t.setHidden(true)
            hiddenText.append(t.setHidden)
        }
        guard settle > 0 else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finishEffects() } }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    /// Ends any pop-in: the real text shows and the effect's text goes.
    private func finishEffects() {
        revealWork?.cancel()
        revealWork = nil
        hiddenText.forEach { $0(false) }
        hiddenText = []
        effects.hideAll()
    }

    // MARK: Chip layouts

    nonisolated static let chipSpacing: CGFloat = 6
    /// Widest a chip that isn't highlighted gets; longer replies are cut with "…".
    static let chipCollapsedWidth: CGFloat = 220
    /// A text box taller than this is a document, not a message box: the row goes above the caret.
    nonisolated static let messageBoxMaxHeight: CGFloat = 160

    private func layoutChips(geometry: CaretGeometry, layout: SuggestedRepliesLayout) {
        let caret = geometry.caretRect
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: caret.midX, y: caret.midY)) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        let widths = chips.map { chip in
            min(chip.naturalWidth, chip.highlighted ? Self.maxWidth : Self.chipCollapsedWidth)
        }
        let height = chips.first?.naturalHeight ?? 24
        let frames = Self.chipFrames(widths: widths, height: height, caret: caret, field: geometry.fieldFrame,
                                     layout: layout, visible: visible)
        guard let union = frames.dropFirst().reduce(frames.first, { $0?.union($1) }) else { return }
        panel.setFrame(union, display: false)
        chipsView.frame = CGRect(origin: .zero, size: union.size)
        for (chip, f) in zip(chips, frames) {
            chip.frame = f.offsetBy(dx: -union.minX, dy: -union.minY)
            chip.needsDisplay = true
        }
        panel.display()
        panel.invalidateShadow()
    }

    /// Where each chip goes (screen coordinates) — the pure layout behind the two chip layouts.
    /// Row above the box: lines start at the box's left edge (the caret's when the box is unknown or
    /// a tall document), sit just above it, or just below when there's no room above. Inline: the
    /// first line starts right of the caret, centered on it; further lines go below, at the caret's x.
    public nonisolated static func chipFrames(widths: [CGFloat], height: CGFloat, caret: CGRect, field: CGRect?,
                                              layout: SuggestedRepliesLayout, visible: CGRect) -> [CGRect] {
        guard !widths.isEmpty else { return [] }
        let box = field.flatMap { f -> CGRect? in
            f.height <= messageBoxMaxHeight && f.minX <= caret.midX && caret.midX <= f.maxX ? f : nil
        }
        let step = height + chipSpacing
        switch layout {
        case .inlineAtCaret:
            let rightLimit = min(box.map { $0.maxX - 6 } ?? caret.minX + maxWidth + 100, visible.maxX - 4)
            let start = caret.maxX + 4
            let lineStart = caret.minX
            let maxX = max(rightLimit, lineStart + 120)
            let placed = flow(widths: widths, firstStart: start, lineStart: lineStart, maxX: maxX, spacing: chipSpacing)
            let top = caret.midY + height / 2
            return placed.map { p in
                CGRect(x: p.x, y: top - height - CGFloat(p.line) * step, width: p.width, height: height)
            }
        case .rowAboveField, .verticalStack:
            let anchor = box ?? caret
            let start = max(visible.minX + 4, box?.minX ?? caret.minX - 6)
            let maxX = min(max(box?.maxX ?? 0, start + maxWidth), visible.maxX - 4)
            let placed = flow(widths: widths, firstStart: start, lineStart: start, maxX: maxX, spacing: chipSpacing)
            let lines = (placed.map(\.line).max() ?? 0) + 1
            let total = CGFloat(lines) * height + CGFloat(lines - 1) * chipSpacing
            var bottom = anchor.maxY + gap
            if bottom + total > visible.maxY { bottom = anchor.minY - gap - total }
            bottom = max(bottom, visible.minY + 4)
            return placed.map { p in
                CGRect(x: p.x, y: bottom + CGFloat(lines - 1 - p.line) * step, width: p.width, height: height)
            }
        }
    }

    /// Lays widths out left to right, wrapping to a new line at `lineStart` when one doesn't fit
    /// before `maxX`; a chip wider than its line is narrowed to fit (its text is cut with "…").
    public nonisolated static func flow(widths: [CGFloat], firstStart: CGFloat, lineStart: CGFloat, maxX: CGFloat,
                                        spacing: CGFloat) -> [(line: Int, x: CGFloat, width: CGFloat)] {
        var out: [(line: Int, x: CGFloat, width: CGFloat)] = []
        var line = 0
        var x = firstStart
        var onLine = 0
        for w in widths {
            if x + w > maxX, onLine > 0 || x > lineStart {
                line += 1
                x = lineStart
                onLine = 0
            }
            let width = max(40, min(w, maxX - x))
            out.append((line, x, width))
            x += width + spacing
            onLine += 1
        }
        return out
    }

    /// The host's font size when it reports one (else from the caret's height), in the system face.
    static func inlineFont(_ geometry: CaretGeometry) -> NSFont {
        let reported = geometry.font?.pointSize.map { $0 * (geometry.font?.sizeFactor ?? 1) }
        let size = reported ?? geometry.caretRect.height * 0.8
        return NSFont.systemFont(ofSize: min(max(size, 11), 18))
    }

    /// The inline chips' opaque fill, so placeholder text in the box doesn't show through: the box's
    /// own background when the app reports it; else dark under light text and light under dark text
    /// (Discord reports only its text color, and its dark box would get light chips from a light
    /// system appearance); else the system control background.
    static func inlineBackdrop(_ background: RGBAColor?, text: RGBAColor? = nil) -> NSColor {
        if let c = background, c.alpha > 0.5 { return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1) }
        switch text.flatMap(backdropShade(forText:)) {
        case .dark?: return NSColor(srgbRed: 0.17, green: 0.18, blue: 0.2, alpha: 1)
        case .light?: return NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        default: return .controlBackgroundColor
        }
    }

    public enum Shade: Equatable { case dark, light }

    /// The background a text color is drawn on: light text sits on a dark box. Nil for mid grays.
    public nonisolated static func backdropShade(forText c: RGBAColor) -> Shade? {
        let luminance = 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
        if luminance > 0.6 { return .dark }
        if luminance < 0.4 { return .light }
        return nil
    }

    /// Ghost-text gray: the host's text color faded, else the secondary label color.
    static func inlineTint(_ text: RGBAColor?) -> NSColor {
        guard let c = text else { return .secondaryLabelColor }
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 0.55)
    }

    /// Above the caret, its left edge at the caret's, kept on the caret's screen.
    static func frame(size: CGSize, caret: CGRect) -> CGRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: caret.midX, y: caret.midY)) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        return placement(size: size, caret: caret, visible: visible)
    }

    /// The pure placement behind `frame`.
    public nonisolated static func placement(size: CGSize, caret: CGRect, visible: CGRect) -> CGRect {
        var origin = CGPoint(x: caret.minX - 6, y: caret.maxY + gap)
        if origin.y + size.height > visible.maxY { origin.y = caret.minY - gap - size.height }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return CGRect(origin: origin, size: size)
    }
}

/// One reply: its text on a rounded highlight when picked; a click picks it.
private final class ReplyRow: NSView {
    var handler: (() -> Void)?
    var highlighted = false {
        didSet {
            layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor : nil
            label.textColor = highlighted ? .white : .labelColor
        }
    }
    let label: NSTextField
    /// How far a label's text starts inside its frame.
    static let textInset: CGFloat = 2

    init(text: String, font: NSFont, maxWidth: CGFloat) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = font
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = maxWidth - 16
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { handler?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool {
        handler?()
        return true
    }
}

/// One reply as a one-line chip: filled (row above the box) or outlined in ghost gray on an opaque
/// backdrop (inline);
/// accent-filled when Tab picked it. A click picks it.
private final class ReplyChip: NSView {
    enum Style { case filled, outlined }
    var handler: (() -> Void)?
    var highlighted = false { didSet { needsDisplay = true } }
    /// The text isn't drawn while its pop-in plays over it.
    var textHidden = false { didSet { needsDisplay = true } }
    let text: String
    let font: NSFont
    private let style: Style
    private let tint: NSColor
    private let backdrop: NSColor
    static let padding: CGFloat = 10

    init(text: String, font: NSFont, style: Style, tint: NSColor, backdrop: NSColor) {
        self.text = text
        self.font = font
        self.style = style
        self.tint = tint
        self.backdrop = backdrop
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { nil }

    /// Where the text is drawn, in the chip's coordinates.
    var textRect: CGRect {
        let lineHeight = ceil(font.ascender - font.descender)
        return CGRect(x: Self.padding, y: (bounds.height - lineHeight) / 2,
                      width: bounds.width - 2 * Self.padding, height: lineHeight)
    }
    var textColor: NSColor { highlighted ? .white : style == .filled ? .labelColor : tint }

    var naturalWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2 * Self.padding
    }
    var naturalHeight: CGFloat { ceil(font.ascender - font.descender) + (style == .filled ? 10 : 6) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let textColor = self.textColor
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
            path.fill()
        } else {
            switch style {
            case .filled:
                NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
            case .outlined:
                // Opaque, so placeholder text under the caret doesn't show through.
                backdrop.setFill()
                path.fill()
                tint.withAlphaComponent(0.08).setFill()
                path.fill()
                tint.withAlphaComponent(0.7).setStroke()
            }
            path.lineWidth = 1
            path.stroke()
        }
        guard !textHidden else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .paragraphStyle: para]
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attrs)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { handler?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool {
        handler?()
        return true
    }
}
