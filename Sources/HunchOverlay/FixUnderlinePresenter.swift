import AppKit
import HunchCore

/// A word Hunch fixed that can still be changed, where the host shows it.
public struct FixMark: Sendable, Equatable {
    public var id: Int
    /// The fixed word's bounds, global AppKit coordinates.
    public var rect: CGRect
    /// What the user typed there.
    public var typed: String

    public init(id: Int, rect: CGRect, typed: String) {
        self.id = id
        self.rect = rect
        self.typed = typed
    }
}

/// What the menu under a fixed word offers.
public struct FixChoices: Sendable, Equatable {
    /// The word as typed (the Revert row).
    public var typed: String
    /// The fix in place now.
    public var current: String
    /// Other words it could be, likeliest first.
    public var alternatives: [String]

    public init(typed: String, current: String, alternatives: [String]) {
        self.typed = typed
        self.current = current
        self.alternatives = alternatives
    }
}

private final class LinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The menu takes keys while open (a word typed into it, a digit picking a row), without
/// activating Hunch: the host stays the frontmost app.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Autocorrect "undo a fix later": a faint line under each recently fixed word; a click on such a
/// word opens a small menu under it: the other words the fix could have been (1, 2, 3 pick them),
/// "Revert to" the word as typed, and a field to type the right word (Enter replaces, Esc closes).
/// Drawn only where the host gave the word's bounds (the caller passes no mark otherwise; the
/// shortcut still works). The lines never take clicks: a click is seen through a global monitor,
/// so it still reaches the host (and moves its caret, which the change puts back).
@MainActor
public final class FixUnderlinePresenter: NSObject, NSTextFieldDelegate {
    /// A word was picked for a mark: the word as typed (revert), an alternative, or one typed in.
    public var onChoose: ((_ id: Int, _ word: String) -> Void)?
    /// What to offer for a mark, asked when its menu opens. Nil: nothing to offer, no menu.
    public var choicesFor: ((_ id: Int) -> FixChoices?)?
    /// The menu closed after having the keyboard: the host should get it back.
    public var onMenuClosed: (() -> Void)?
    /// The menu is about to take the keyboard (true), or gave it up (false): the focus tracker must
    /// not take this app's own field for the user leaving theirs.
    public var onMenuKeyboard: ((Bool) -> Void)?

    private var marks: [FixMark] = []
    private var lines: [LinePanel] = []
    private var menu: MenuPanel?
    private var menuID: Int?
    private var menuChoices: FixChoices?
    private var field: NSTextField?
    private var menuTimeout: Task<Void, Never>?
    private var clickMonitor: Any?

    /// An untouched menu closes after this.
    public static let menuDuration: Duration = .seconds(10)
    static let maxAlternatives = 3

    public override init() {}

    /// The marks to draw now (replaces the previous ones). A menu whose word is gone closes.
    public func show(_ marks: [FixMark]) {
        let marks = marks.filter { $0.rect.width > 0.5 && $0.rect.height > 2 }
        self.marks = marks
        while lines.count < marks.count { lines.append(makeLine()) }
        for (i, line) in lines.enumerated() {
            guard i < marks.count else {
                line.orderOut(nil)
                continue
            }
            let r = marks[i].rect
            line.setFrame(NSRect(x: r.minX, y: r.minY - 1, width: r.width, height: 1.5).integral, display: false)
            line.orderFrontRegardless()
        }
        if let id = menuID, !marks.contains(where: { $0.id == id }), !isEditing { dismissOffer() }
        marks.isEmpty && menuID == nil ? stopWatchingClicks() : watchClicks()
    }

    /// Everything off (focus left the field, text is being changed).
    public func hide() {
        show([])
        dismissOffer()
    }

    /// Closes the menu (a key reached the host, a click went elsewhere).
    public func dismissOffer() {
        menuTimeout?.cancel()
        menuTimeout = nil
        menuID = nil
        menuChoices = nil
        let hadKeyboard = menu?.isKeyWindow == true
        let wasOpen = menu != nil
        menu?.orderOut(nil)
        menu = nil
        field = nil
        if marks.isEmpty { stopWatchingClicks() }
        if hadKeyboard { onMenuClosed?() }
        if wasOpen { onMenuKeyboard?(false) }
    }

    public var isOffering: Bool { menuID != nil }
    /// The menu has the keyboard: keys the monitor sees go to it, not to the host.
    public var isEditing: Bool { menuID != nil && menu?.isKeyWindow == true }

    // MARK: Clicks

    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.clicked(at: point) }
        }
    }

    private func stopWatchingClicks() {
        guard let monitor = clickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        clickMonitor = nil
    }

    private func clicked(at point: CGPoint) {
        // Clicks in the menu itself are this app's own events and never come here.
        guard let mark = marks.last(where: { $0.rect.insetBy(dx: -1, dy: -3).contains(point) }) else {
            dismissOffer()
            return
        }
        guard let choices = choicesFor?(mark.id) else { return }
        showMenu(for: mark, choices: choices)
    }

    // MARK: The menu

    private func showMenu(for mark: FixMark, choices: FixChoices) {
        if menu != nil { dismissOffer() }
        let panel = makeMenu(choices)
        menu = panel
        menuID = mark.id
        menuChoices = choices
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 200, height: 120)
        var origin = CGPoint(x: mark.rect.minX - 6, y: mark.rect.minY - size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mark.rect.origin) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY + 4 { origin.y = mark.rect.maxY + 4 }  // no room below: above
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size).integral, display: true)
        onMenuKeyboard?(true)
        panel.makeKeyAndOrderFront(nil)
        if let field { panel.makeFirstResponder(field) }
        restartTimeout()
    }

    private func restartTimeout() {
        menuTimeout?.cancel()
        menuTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.menuDuration)
            guard !Task.isCancelled, let self, self.field?.stringValue.isEmpty ?? true else { return }
            self.dismissOffer()
        }
    }

    private func choose(_ word: String) {
        guard let id = menuID else { return }
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        dismissOffer()
        guard !word.isEmpty else { return }
        onChoose?(id, word)
    }

    // MARK: NSTextFieldDelegate

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            choose(field?.stringValue ?? "")
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissOffer()
            return true
        default:
            return false
        }
    }

    public func controlTextDidChange(_ note: Notification) {
        restartTimeout()
        // A digit alone picks that row.
        guard let text = field?.stringValue, text.count == 1, let n = Int(text),
              let choices = menuChoices, n >= 1, n <= min(choices.alternatives.count, Self.maxAlternatives)
        else { return }
        choose(choices.alternatives[n - 1])
    }

    // MARK: Panels

    private func setUp(_ p: NSPanel) {
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    private func makeLine() -> LinePanel {
        let p = LinePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        setUp(p)
        p.hasShadow = false
        p.ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        view.layer?.cornerRadius = 0.75
        p.contentView = view
        return p
    }

    private func makeMenu(_ choices: FixChoices) -> MenuPanel {
        let p = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        setUp(p)
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = false
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true

        var rows: [NSView] = []
        for (i, word) in choices.alternatives.prefix(Self.maxAlternatives).enumerated() {
            rows.append(MenuRow(key: "\(i + 1)", title: word) { [weak self] in self?.choose(word) })
        }
        if !rows.isEmpty { rows.append(Separator()) }
        rows.append(MenuRow(key: "↺", title: "Revert to “\(choices.typed)”") { [weak self] in
            self?.choose(choices.typed)
        })
        let field = NSTextField()
        field.placeholderString = "Type a word…"
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        self.field = field
        let pencil = NSTextField(labelWithString: "✎")
        pencil.textColor = .secondaryLabelColor
        pencil.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let fieldRow = NSStackView(views: [pencil, field])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 6
        fieldRow.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        rows.append(fieldRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        p.contentView = background
        return p
    }
}

/// One clickable row: a key hint ("1", "↺") and a title; highlighted under the pointer.
private final class MenuRow: NSView {
    private let action: () -> Void
    private var tracking: NSTrackingArea?

    init(key: String, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        keyLabel.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let stack = NSStackView(views: [keyLabel, titleLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.85).cgColor
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}

private final class Separator: NSBox {
    init() {
        super.init(frame: .zero)
        boxType = .separator
    }
    required init?(coder: NSCoder) { nil }
}
