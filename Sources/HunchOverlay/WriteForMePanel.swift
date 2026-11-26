import AppKit
import HunchCore

/// What the write-for-me panel tells its owner.
@MainActor
public protocol WriteForMePanelDelegate: AnyObject {
    func writePanel(didChooseMode mode: WriteMode)
    func writePanel(didRefine request: String, currentDraft: String)
    func writePanel(didAccept draft: String)
    func writePanelDidCancel()
    /// The notice's buttons.
    func writePanelDownloadModel()
    func writePanelSetWritingModel()
    func writePanelTryBaseModel()
    /// The spoken instruction was edited in its row and Return pressed: run it again in its place.
    func writePanel(didEditSpoken instruction: String)
}

extension WriteForMePanelDelegate {
    public func writePanel(didEditSpoken instruction: String) {}
}

/// A panel that takes keys without activating Hunch, so the host app stays frontmost.
private final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// The write-for-me preview: a Write / Polish switch, the draft as it is written (polish marks the
/// words it changed), a refine box, and Insert / Cancel. Nothing is replaced in the host until the
/// user inserts.
///
/// Keys: ⌘Return inserts; Return in an empty refine box inserts, with text it refines; Tab inserts
/// unless the draft is being edited; Esc cancels; ⌘1 / ⌘2 pick Write / Polish.
@MainActor
public final class WriteForMePanel: NSObject, NSTextFieldDelegate {
    public weak var delegate: WriteForMePanelDelegate?

    private let panel: KeyPanel
    private let modeControl = NSSegmentedControl(labels: ["Write", "Polish"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let draftView = NSTextView()
    private let scroll = NSScrollView()
    private let refineField = NSTextField()
    /// Voice instructions (experimental): what the user said last, editable; Return runs it again.
    private let spokenRow = NSStackView()
    private let spokenLabel = NSTextField(labelWithString: "You said:")
    private let spokenField = NSTextField()
    /// Write / Polish can't be switched (a spoken instruction or description is not text to polish).
    private var modeLocked = false
    private let hint = NSTextField(labelWithString: "⌘↩ Insert   Esc Cancel   ⌘1 Write   ⌘2 Polish")
    private let insertButton = NSButton(title: "Insert", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let notice = NSStackView()
    private let noticeText = NSTextField(wrappingLabelWithString: "")
    /// What a polished prompt may still be missing ("Missing: which file"). Never inserted.
    private let gapsText = NSTextField(wrappingLabelWithString: "")
    private let downloadButton = NSButton(title: "Download instruct model", target: nil, action: nil)
    private let baseButton = NSButton(title: "Try base model", target: nil, action: nil)
    private let writingModelButton = NSButton(title: "Set a separate writing model", target: nil, action: nil)

    private var generating = false
    private var original = ""

    // MARK: Effect state
    /// The pop-in look the draft plays as it streams (the app's own look, else Appearance); nil = off.
    public var effectLook: AppearanceSettings? {
        didSet { effects.appearance = effectLook ?? AppearanceSettings() }
    }
    private lazy var effects = TextEffectPlayer(embeddedIn: draftView)
    /// The draft the effect is playing over, and how much of it (UTF-16) has started its pop-in.
    private var effectText = ""
    private var played = 0
    /// Pieces still playing, hidden in the text view under their ghost.
    private var hiddenRanges: [Int: NSRange] = [:]
    private var nextPiece = 0
    private var flushTimer: Timer?
    /// When the last piece started so far is done, and the reveal of the whole draft that follows a
    /// finished draft's last piece (in case a piece's own reveal never comes).
    private var piecesEnd = Date.distantPast
    private var revealRest: DispatchWorkItem?
    private var effectsOn: Bool {
        effectLook != nil && !effects.recipe(tweaks: GhostTweaks()).isEmpty
    }
    private var mode: WriteMode = .write

    static let size = NSSize(width: 540, height: 340)

    public override init() {
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                         backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 380, height: 220)
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        build()
    }

    public var isVisible: Bool { panel.isVisible }

    // MARK: Layout

    private func build() {
        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        panel.contentView = content

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        draftView.isRichText = false
        draftView.font = .systemFont(ofSize: 13)
        draftView.textContainerInset = NSSize(width: 6, height: 6)
        draftView.isAutomaticQuoteSubstitutionEnabled = false
        draftView.isAutomaticDashSubstitutionEnabled = false
        draftView.isAutomaticTextReplacementEnabled = false
        draftView.allowsUndo = true
        draftView.isVerticallyResizable = true
        draftView.autoresizingMask = [.width]
        draftView.textContainer?.widthTracksTextView = true
        scroll.documentView = draftView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        draftView.drawsBackground = false
        let scrollBox = NSBox()
        scrollBox.boxType = .custom
        scrollBox.cornerRadius = 6
        scrollBox.borderColor = .separatorColor
        scrollBox.fillColor = .textBackgroundColor.withAlphaComponent(0.6)
        scrollBox.contentView = scroll
        scrollBox.contentViewMargins = .zero

        refineField.placeholderString = "Refine: shorter, more formal, mention the deadline… (Return)"
        refineField.delegate = self
        refineField.font = .systemFont(ofSize: 12)
        refineField.focusRingType = .none

        spokenLabel.font = .systemFont(ofSize: 11)
        spokenLabel.textColor = .secondaryLabelColor
        spokenLabel.setContentHuggingPriority(.required, for: .horizontal)
        spokenField.font = .systemFont(ofSize: 12)
        spokenField.focusRingType = .none
        spokenField.toolTip = "Fix a misheard word and press Return to run it again."
        spokenRow.orientation = .horizontal
        spokenRow.spacing = 6
        spokenRow.addArrangedSubview(spokenLabel)
        spokenRow.addArrangedSubview(spokenField)
        spokenRow.isHidden = true

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        insertButton.target = self
        insertButton.action = #selector(insertPressed)
        insertButton.keyEquivalent = "\r"
        insertButton.keyEquivalentModifierMask = [.command]
        insertButton.bezelStyle = .push
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.bezelStyle = .push

        noticeText.font = .systemFont(ofSize: 12)
        gapsText.font = .systemFont(ofSize: 11)
        gapsText.textColor = .systemOrange
        gapsText.isHidden = true
        downloadButton.target = self
        downloadButton.action = #selector(downloadPressed)
        downloadButton.bezelStyle = .push
        baseButton.target = self
        baseButton.action = #selector(basePressed)
        baseButton.bezelStyle = .push
        writingModelButton.target = self
        writingModelButton.action = #selector(writingModelPressed)
        writingModelButton.bezelStyle = .push
        let noticeButtons = NSStackView(views: [downloadButton, writingModelButton, baseButton])
        noticeButtons.spacing = 8
        notice.orientation = .vertical
        notice.alignment = .leading
        notice.spacing = 8
        notice.addArrangedSubview(noticeText)
        notice.addArrangedSubview(noticeButtons)
        notice.isHidden = true

        let top = NSStackView(views: [modeControl, spinner, status])
        top.spacing = 8
        let bottom = NSStackView(views: [hint, NSView(), cancelButton, insertButton])
        bottom.spacing = 8
        bottom.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [top, spokenRow, notice, scrollBox, gapsText, refineField, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollBox.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            scrollBox.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            refineField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            spokenRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            spokenRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            refineField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            bottom.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            notice.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            gapsText.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            gapsText.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            scrollBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        scrollBox.setContentHuggingPriority(.defaultLow, for: .vertical)
        // Editing the finished draft while its last words still play: show it all as it is.
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: draftView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopEffects(revealAll: true) }
        }
    }

    // MARK: Showing

    /// Opens the panel below the caret (above it when there's no room), keyed for typing, without
    /// activating Hunch. `original` is the text in the range, for polish highlights.
    public func show(near caret: CGRect, mode: WriteMode, original: String, spoken: String? = nil) {
        self.original = original
        modeLocked = spoken != nil
        modeControl.isEnabled = !modeLocked
        showSpoken(spoken)
        setMode(mode)
        stopEffects(revealAll: false)
        draftView.string = ""
        refineField.stringValue = ""
        notice.isHidden = true
        gapsText.isHidden = true
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size.width > 10 ? panel.frame.size : Self.size
        var origin = NSPoint(x: caret.minX - 20, y: caret.minY - size.height - 8)
        if origin.y < visible.minY { origin.y = caret.maxY + 8 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(refineField)
    }

    public func hide() {
        stopEffects(revealAll: false)
        generating = false
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    public func setMode(_ mode: WriteMode) {
        self.mode = mode
        switch mode {
        case .write: modeControl.selectedSegment = 0
        case .polish: modeControl.selectedSegment = 1
        case .transform: modeControl.selectedSegment = -1
        }
    }

    /// Shows (or hides, for nil) the spoken instruction, editable.
    public func showSpoken(_ text: String?) {
        spokenField.stringValue = text ?? ""
        spokenRow.isHidden = text == nil
    }

    /// A draft is streaming or loading.
    public var isGenerating: Bool { generating }

    /// The draft as shown (and maybe edited) in the panel.
    public var currentDraft: String { draftView.string }

    /// Puts words in the refine box without running them (a spoken refinement that arrived while a
    /// draft was still streaming: Return runs it once the draft is done).
    public func fillRefine(_ text: String) {
        refineField.stringValue = text
        panel.makeFirstResponder(refineField)
    }

    /// A draft is on its way (or loading the model first).
    public func showWorking(_ message: String) {
        generating = true
        notice.isHidden = true
        gapsText.isHidden = true
        status.stringValue = message
        spinner.startAnimation(nil)
        draftView.isEditable = false
        insertButton.isEnabled = false
    }

    /// The draft so far (streaming) or in full (`finished`). `gaps`: what a polished prompt may still
    /// be missing, shown under the draft once it is finished.
    public func showDraft(_ text: String, finished: Bool, gaps: String? = nil) {
        guard panel.isVisible else { return }
        let animate = effectsOn
        if animate {
            if !text.hasPrefix(effectText) {
                // A new draft (or a final text that differs from what streamed): start over; a
                // rewrite of text already shown appears as it is.
                let shownBefore = !effectText.isEmpty
                stopEffects(revealAll: false)
                if shownBefore, finished { played = (text as NSString).length }
            }
            effectText = text
        } else if !effectText.isEmpty || !hiddenRanges.isEmpty {
            stopEffects(revealAll: false)
        }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        if finished, mode != .write {
            for range in highlights(text) {
                attributed.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3),
                                        range: NSRange(range, in: text))
            }
        }
        if animate {
            // Text waiting for its pop-in, and pieces still playing, stay hidden under their ghosts.
            let length = attributed.length
            var hidden = Array(hiddenRanges.values)
            if played < length { hidden.append(NSRange(location: played, length: length - played)) }
            for r in hidden where NSMaxRange(r) <= length {
                attributed.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
            }
        }
        draftView.textStorage?.setAttributedString(attributed)
        draftView.scrollToEndOfDocument(nil)
        if finished {
            generating = false
            spinner.stopAnimation(nil)
            draftView.isEditable = true
            insertButton.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            draftView.scrollToBeginningOfDocument(nil)
            status.stringValue = mode != .write ? "Changed words are highlighted." : ""
            gapsText.stringValue = gaps.map { "Missing: " + $0 } ?? ""
            gapsText.isHidden = gaps == nil
        }
        if animate {
            if finished {
                flushTimer?.invalidate()
                flushTimer = nil
                flushEffects(finished: true)
                revealRest?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.revealEverything() }
                }
                revealRest = item
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, piecesEnd.timeIntervalSinceNow) + 0.3,
                                              execute: item)
            } else if flushTimer == nil {
                // New words are gathered and played a few at a time.
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.flushEffects(finished: false) }
                }
                RunLoop.main.add(timer, forMode: .common)
                flushTimer = timer
            }
        }
    }

    // MARK: Effect

    /// Starts the pop-in on the words that have come in since the last piece: one ghost per line they
    /// cover, drawn over the hidden text, which shows again when its ghost has settled. A word still
    /// being written waits (it could still wrap); `finished` plays the rest.
    private func flushEffects(finished: Bool) {
        let ns = effectText as NSString
        guard let storage = draftView.textStorage, storage.length == ns.length else { return }
        let end = EffectWrap.readyEnd(ns, from: played, finished: finished)
        guard end > played else { return }
        let range = NSRange(location: played, length: end - played)
        played = end
        guard let layout = draftView.layoutManager, let container = draftView.textContainer,
              let window = draftView.window else {
            reveal(range)
            return
        }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var lines: [(glyphs: NSRange, rect: CGRect)] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, _ in
            let g = NSIntersectionRange(lineGlyphs, glyphs)
            if g.length > 0 { lines.append((g, rect)) }
        }
        let origin = draftView.textContainerOrigin
        let visible = draftView.visibleRect
        let font = draftView.font ?? NSFont.systemFont(ofSize: 13)
        for line in lines {
            let chars = layout.characterRange(forGlyphRange: line.glyphs, actualGlyphRange: nil)
            var piece = ns.substring(with: chars)
            while let last = piece.last, last.isNewline { piece.removeLast() }
            let at = layout.location(forGlyphAt: line.glyphs.location)
            let top = origin.y + line.rect.minY
            let local = CGRect(x: origin.x + line.rect.minX + at.x - OverlayLayout.inlineXOffset, y: top,
                               width: 0, height: line.rect.height)
            // Off screen or blank: nothing to see play.
            guard piece.contains(where: { !$0.isWhitespace }), local.intersects(visible.insetBy(dx: -1, dy: -1))
            else { reveal(chars); continue }
            let screen = window.convertToScreen(draftView.convert(local, to: nil))
            let geometry = CaretGeometry(caretRect: screen, font: FontHint(pointSize: font.pointSize), quality: .exact)
            let presentation = GhostPresentation(text: piece, geometry: geometry, mode: .inline,
                                                 measuredBaseline: line.rect.height - at.y)
            let id = nextPiece
            nextPiece += 1
            hiddenRanges[id] = chars
            let seconds = effects.playPiece(presentation, color: .labelColor) { [weak self] in
                guard let self, let r = self.hiddenRanges.removeValue(forKey: id) else { return }
                self.reveal(r)
            }
            if let seconds {
                piecesEnd = max(piecesEnd, Date().addingTimeInterval(seconds))
            } else {
                hiddenRanges[id] = nil
                reveal(chars)
            }
        }
    }

    /// Shows the real text in `range` again (still inside the current draft).
    private func reveal(_ range: NSRange) {
        guard let storage = draftView.textStorage, NSMaxRange(range) <= storage.length, range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
    }

    /// A finished draft's pieces are all done: show any text still hidden (a piece whose reveal never
    /// came), keeping the draft as the one played so it isn't played again.
    private func revealEverything() {
        revealRest = nil
        guard !hiddenRanges.isEmpty || played < (effectText as NSString).length else { return }
        effects.hideAll()
        hiddenRanges = [:]
        played = (effectText as NSString).length
        reveal(NSRange(location: 0, length: draftView.textStorage?.length ?? 0))
    }

    /// Ends every pop-in. `revealAll`: the draft shows in full (else the next draft replaces it).
    private func stopEffects(revealAll: Bool) {
        flushTimer?.invalidate()
        flushTimer = nil
        revealRest?.cancel()
        revealRest = nil
        piecesEnd = .distantPast
        let wasPlaying = !hiddenRanges.isEmpty || played < (effectText as NSString).length
        effects.hideAll()
        hiddenRanges = [:]
        effectText = ""
        played = 0
        if revealAll, wasPlaying, let storage = draftView.textStorage, storage.length > 0 {
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                 range: NSRange(location: 0, length: storage.length))
        }
    }

    /// Ranges to highlight in a finished polish; set by the owner (HunchText's diff).
    public var highlights: (String) -> [Range<String.Index>] = { _ in [] }

    public func showError(_ message: String) {
        stopEffects(revealAll: true)
        generating = false
        spinner.stopAnimation(nil)
        status.stringValue = message
        draftView.isEditable = true
        insertButton.isEnabled = !draftView.string.isEmpty
    }

    /// No model can write: offer the download, and the base model with a quality warning.
    /// `endpointDown`: the chosen endpoint isn't answering and there is no local model to fall back on.
    public func showNoModel(canTryBase: Bool, endpointDown: Bool = false) {
        generating = false
        spinner.stopAnimation(nil)
        status.stringValue = ""
        noticeText.stringValue = endpointDown
            ? "The writing endpoint isn't answering, and there's no writing model to use instead. Download the "
                + "recommended one, or try again in a moment."
            : canTryBase
            ? "Write for me needs an instruct model (or an endpoint). You can download one, or try your "
                + "Language Model: if it's a base model, drafts will be rougher."
            : "Write for me needs an instruct model (or an endpoint). Download one to start."
        downloadButton.isHidden = false
        writingModelButton.isHidden = true
        baseButton.isHidden = !canTryBase
        notice.isHidden = false
        insertButton.isEnabled = false
    }

    /// The separate writing model is off and no Language Model is loaded: point to Settings,
    /// without offering a writing model.
    public func showNoAutocompleteModel(endpointDown: Bool = false) {
        generating = false
        spinner.stopAnimation(nil)
        status.stringValue = ""
        noticeText.stringValue = endpointDown
            ? "The Language Model's endpoint isn't answering, and no local Language Model is loaded to use "
                + "instead. Choose one in Settings → Models, or try again in a moment."
            : "Write for me uses your Language Model, and none is loaded. "
                + "Choose one in Settings → Models."
        downloadButton.isHidden = true
        writingModelButton.isHidden = true
        baseButton.isHidden = true
        notice.isHidden = false
        insertButton.isEnabled = false
    }

    /// Write for me would use the Language Model, and it is a base model: offer a separate writing
    /// model, or the base model with a quality warning.
    public func showBaseLanguageModel() {
        generating = false
        spinner.stopAnimation(nil)
        status.stringValue = ""
        noticeText.stringValue = "Your Language Model is a base model. Base models aren't trained to follow "
            + "instructions, so drafts will be rougher and may ignore what you asked. Set a separate writing "
            + "model (an instruct model) for Write for me, or try the base model anyway."
        downloadButton.isHidden = true
        writingModelButton.isHidden = false
        baseButton.isHidden = false
        notice.isHidden = false
        insertButton.isEnabled = false
    }

    // MARK: Actions

    @objc private func modeChanged() {
        guard !modeLocked else { return }
        let chosen: WriteMode = modeControl.selectedSegment == 0 ? .write : .polish
        guard chosen != mode else { return }
        mode = chosen
        delegate?.writePanel(didChooseMode: chosen)
    }

    @objc private func insertPressed() { accept() }
    @objc private func cancelPressed() { delegate?.writePanelDidCancel() }
    @objc private func downloadPressed() { delegate?.writePanelDownloadModel() }
    @objc private func writingModelPressed() { delegate?.writePanelSetWritingModel() }
    @objc private func basePressed() { delegate?.writePanelTryBaseModel() }

    private func accept() {
        guard !generating else { return }
        let text = draftView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        delegate?.writePanel(didAccept: text)
    }

    private func refine() {
        let ask = refineField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty, !generating else { return }
        refineField.stringValue = ""
        delegate?.writePanel(didRefine: ask, currentDraft: draftView.string)
    }

    /// Panel-wide keys, before the focused control sees them. True = handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 53:  // Escape
            delegate?.writePanelDidCancel()
            return true
        case 36, 76:  // Return, Enter
            if mods == .command { accept(); return true }
            if mods.isEmpty, !spokenRow.isHidden, panel.firstResponder === spokenField.currentEditor() {
                let edited = spokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !edited.isEmpty { delegate?.writePanel(didEditSpoken: edited) }
                return true
            }
            if mods.isEmpty, panel.firstResponder === refineField.currentEditor() {
                if refineField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { accept() } else { refine() }
                return true
            }
            return false
        case 48:  // Tab
            if mods.isEmpty, panel.firstResponder !== draftView, panel.firstResponder !== spokenField.currentEditor(),
               refineField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                accept()
                return true
            }
            return false
        default:
            if mods == .command || mods == [.command, .shift], let c = event.charactersIgnoringModifiers?.lowercased() {
                // Hunch isn't the active app, so its Edit menu doesn't see these: do them here.
                let edit: Selector? = switch (c, mods == .command) {
                case ("a", true): #selector(NSText.selectAll(_:))
                case ("c", true): #selector(NSText.copy(_:))
                case ("x", true): #selector(NSText.cut(_:))
                case ("v", true): #selector(NSText.paste(_:))
                case ("z", true): Selector(("undo:"))
                case ("z", false): Selector(("redo:"))
                default: nil
                }
                if let edit { return NSApp.sendAction(edit, to: nil, from: panel) }
                if c == "1" || c == "2", modeLocked { return true }
                if c == "1" || c == "2" {
                    let chosen: WriteMode = c == "1" ? .write : .polish
                    if chosen != mode {
                        setMode(chosen)
                        delegate?.writePanel(didChooseMode: chosen)
                    }
                    return true
                }
            }
            return false
        }
    }
}
