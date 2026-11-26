import AppKit
import HunchCore

/// The small pill dictation shows next to the caret: the cat face with a mic pulsing red while recording
/// (a circle, nothing else), the cat face with a mic pulsing grey to white with a word while transcribing
/// and cleaning up, then a short message, or the cat face with sparkles pulsing electric blue to offer Polish
/// (called Boost in the code). It never
/// takes focus, so the app being dictated into stays frontmost and keeps its caret; it takes clicks
/// only while it shows a button (Undo) or offers Boost.
@MainActor
public final class DictationPill {
    public enum State: Equatable {
        case recording
        case working(String)
        /// A short line (a result, a problem); `isProblem` tints it.
        case message(String, isProblem: Bool)
        /// The sparkle face alone, pulsing electric blue: a click polishes what was just dictated.
        case boost
    }

    let panel: NSPanel
    /// The Hunch cat face: red while recording, the text color (white on the dark pill) while working.
    let glyph = NSImageView()
    private static func glyphImage(_ color: NSColor, _ draw: @escaping (NSColor) -> Void) -> NSImage {
        NSImage(size: MenuBarIcon.size, flipped: false) { _ in
            draw(color)
            return true
        }
    }
    /// The mic face while dictating, transcribing and cleaning up.
    private let recordingGlyph = DictationPill.glyphImage(.systemRed, MenuBarIcon.drawFaceMicrophone)
    /// Drawn at display time, so the color follows the pill's appearance.
    private let workingGlyph = DictationPill.glyphImage(.labelColor, MenuBarIcon.drawFaceMicrophone)
    static let electricBlue = NSColor(srgbRed: 0.15, green: 0.6, blue: 1.0, alpha: 1)
    /// The sparkle face offering Polish.
    private let boostGlyph = DictationPill.glyphImage(DictationPill.electricBlue, MenuBarIcon.drawFaceSparkle)
    /// Covers the pill while it offers Boost, so a click anywhere on it counts.
    private let boostCatcher = ClickCatcher()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var buttonAction: (() -> Void)?
    private let buttonTarget = ButtonTarget()
    private let stack: NSStackView
    private var hideTask: Task<Void, Never>?
    private var anchor: CGRect = .zero

    static let height: CGFloat = 30

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.height / 2
        background.layer?.masksToBounds = true

        glyph.image = recordingGlyph
        glyph.wantsLayer = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([glyph.widthAnchor.constraint(equalToConstant: MenuBarIcon.size.width),
                                     glyph.heightAnchor.constraint(equalToConstant: MenuBarIcon.size.height)])
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        button.bezelStyle = .inline
        button.controlSize = .small
        button.isHidden = true
        stack = NSStackView(views: [glyph, label, button])
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        boostCatcher.isHidden = true
        boostCatcher.translatesAutoresizingMaskIntoConstraints = false
        boostCatcher.toolTip = "Polish"
        boostCatcher.setAccessibilityElement(true)
        boostCatcher.setAccessibilityRole(.button)
        boostCatcher.setAccessibilityLabel("Polish what you dictated")
        background.addSubview(boostCatcher)
        NSLayoutConstraint.activate([
            boostCatcher.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            boostCatcher.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            boostCatcher.topAnchor.constraint(equalTo: background.topAnchor),
            boostCatcher.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        boostCatcher.handler = { [weak self] in self?.boostClicked() }
        panel.contentView = background
        button.target = buttonTarget
        button.action = #selector(ButtonTarget.fire(_:))
        buttonTarget.handler = { [weak self] in self?.buttonClicked() }
    }

    private func buttonClicked() {
        let action = buttonAction
        setButton(nil, action: nil)
        hide()
        action?()
    }

    private func setButton(_ title: String?, action: (() -> Void)?) {
        button.title = title ?? ""
        button.isHidden = title == nil
        buttonAction = action
        panel.ignoresMouseEvents = title == nil && boostAction == nil
    }

    private var boostAction: (() -> Void)?

    private func setBoost(_ action: (() -> Void)?) {
        boostAction = action
        boostCatcher.isHidden = action == nil
        panel.ignoresMouseEvents = button.isHidden && action == nil
    }

    private func boostClicked() {
        let action = boostAction
        hide()
        action?()
    }

    /// Offers Boost where the pill last was for `seconds`; `action` runs on a click. `isOfferingBoost`
    /// stays true until then, or until the pill shows something else or hides.
    public func showBoost(near caret: CGRect? = nil, for seconds: Double, action: @escaping () -> Void) {
        show(.boost, near: caret)
        setBoost(action)
        hide(after: seconds)
    }

    public var isOfferingBoost: Bool { boostAction != nil && panel.isVisible }

    /// A screen point (bottom-left origin) is on the pill.
    public func contains(_ point: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }

    /// A message with a button (Undo) where the pill last was; hidden after `seconds`.
    public func show(_ text: String, button title: String, for seconds: Double, action: @escaping () -> Void) {
        show(.message(text, isProblem: false))
        setButton(title, action: action)
        place()
        hide(after: seconds)
    }

    public var isVisible: Bool { panel.isVisible }

    /// Shows `state` next to `caret` (screen coordinates, bottom-left origin); a zero rect puts the
    /// pill at the bottom center of the main screen.
    public func show(_ state: State, near caret: CGRect? = nil) {
        hideTask?.cancel()
        setBoost(nil)
        setButton(nil, action: nil)
        if let caret { anchor = caret }
        let boost = state == .boost
        recording = state == .recording
        circle = recording || boost
        let working = if case .working = state { true } else { false }
        glyph.isHidden = !circle && !working
        glyph.image = boost ? boostGlyph : recording ? recordingGlyph : workingGlyph
        label.isHidden = circle
        stack.edgeInsets = circle ? NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
                                  : NSEdgeInsets(top: 0, left: working ? 8 : 12, bottom: 0, right: 12)
        setGlow(boost)
        if recording || working || boost {
            startPulse(fast: boost)
        } else {
            glyph.layer?.removeAnimation(forKey: "pulse")
        }
        switch state {
        case .recording:
            glyph.setAccessibilityLabel("Listening")
        case .working(let text):
            glyph.setAccessibilityLabel(text)
            label.stringValue = text
            label.textColor = .labelColor
        case .message(let text, let isProblem):
            label.stringValue = text
            label.textColor = isProblem ? .systemOrange : .labelColor
        case .boost:
            glyph.setAccessibilityLabel("Polish")
        }
        place()
        panel.orderFrontRegardless()
    }

    private var recording = false
    /// Recording or Boost: a circle just big enough for the glyph.
    private var circle = false
    private var pulseIsFast = false

    /// Fades the glyph in and out: red while recording, grey to white while working, and a quicker
    /// blue for Boost (so it doesn't read as still listening).
    private func startPulse(fast: Bool = false) {
        guard let layer = glyph.layer else { return }
        if layer.animation(forKey: "pulse") != nil {
            guard pulseIsFast != fast else { return }
            layer.removeAnimation(forKey: "pulse")
        }
        pulseIsFast = fast
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = fast ? 0.45 : 0.35
        pulse.duration = fast ? 0.55 : 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }

    /// A soft blue glow around the Boost face.
    private func setGlow(_ on: Bool) {
        guard let layer = glyph.layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = Self.electricBlue.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 4
        layer.shadowOpacity = on ? 0.9 : 0
    }

    /// Hides the pill after `delay` seconds (now when 0).
    public func hide(after delay: Double = 0) {
        hideTask?.cancel()
        guard delay > 0 else { close(); return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func close() {
        panel.orderOut(nil)
        setBoost(nil)
        setButton(nil, action: nil)
    }

    private func place() {
        stack.layoutSubtreeIfNeeded()
        // Recording or Boost: a circle just big enough for the glyph.
        let width = circle ? Self.height : min(520, max(90, stack.fittingSize.width))
        let size = NSSize(width: width, height: Self.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        if anchor.isEmpty || anchor == .zero {
            origin = NSPoint(x: visible.midX - width / 2, y: visible.minY + 60)
        } else {
            origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
            if origin.y < visible.minY { origin.y = anchor.maxY + 6 }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// The pill isn't an NSObject; its button calls through this.
private final class ButtonTarget: NSObject {
    var handler: (() -> Void)?
    @objc func fire(_ sender: Any?) { handler?() }
}

/// A clear view that takes the first click even though the pill never becomes key.
private final class ClickCatcher: NSView {
    var handler: (() -> Void)?
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
