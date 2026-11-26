import AppKit
import ApplicationServices
import Foundation
import HunchCore
import HunchPolicy

public enum ContextReadError: Error, Sendable, Equatable {
    /// The pass is expired or was issued for a different field.
    case passInvalid
    case valueUnavailable
    case selectionUnavailable
    /// A terminal whose caret is not in an AI-agent input box (a shell prompt, output, a menu).
    case notAgentPrompt
    /// A field with no text worth reading: a code editor's integrated terminal.
    case unsupportedSurface
    /// A terminal in shell-command mode whose caret is not at the end of a typed shell command.
    case notShellPrompt
    /// A terminal in Automatic mode whose title shows another program in front (vim, ssh, a REPL).
    case otherTerminalProgram
}

/// Reads element metadata (`probe`) and, only with a valid `SecureGatePass`, field text (`read`)
/// and caret geometry (`caret`). Confined to the AX thread; not thread-safe.
public final class ContextReader: ContextReading {
    /// Fields longer than this (UTF-16 units) are read through `AXStringForRange` windows
    /// instead of copying the whole value.
    static let windowedReadThreshold = 32_768
    /// Fields up to this size are read through text markers when the host supports them.
    static let markerReadLimit = 32_768
    /// Larger cap for editable web areas, where markers are the only route (long quoted email
    /// threads); the text is sliced to `ContextLimits` around the caret afterwards.
    static let webAreaReadLimit = 262_144

    let client: AXClient
    /// Whether the window title is wanted at all; when false the AX read is skipped entirely.
    var windowTitleEnabled: @Sendable () -> Bool = { true }
    /// Per terminal bundle id: shell commands at the shell prompt, agent prompts, or Automatic.
    var shellCommandMode: @Sendable (String) -> ShellCommandMode = { _ in .never }

    private struct ProbeCache {
        let element: AXUIElement
        let probe: ElementProbe
    }

    private struct ReadSnapshot {
        let field: FieldID
        let element: AXUIElement
        let caretUTF16: Int
        let selectionUTF16: Int
        let previousIsNewlineOrStart: Bool
        let nextIsNewlineOrEnd: Bool
        let bundleID: String
        /// Unicode scalar right after the caret (diagnostics only: tells "mid-line" hosts apart from
        /// hosts that keep an invisible trailing character).
        var nextScalar: UInt32? = nil
        /// Text from the start of the caret's line to the caret (capped), for extrapolating the caret
        /// from an earlier exact reading when the host stops reporting text bounds.
        var lineBefore: String? = nil
        /// Terminal caret past the line's trimmed end (a typed trailing space): the reported caret
        /// is one past the line, so the caret is placed a cell after the line's last character.
        var pastLineEnd = false
        /// Offset of the caret line's first character (same units as `caretUTF16`), when the text
        /// read shows where the line starts and the line isn't empty.
        var lineStartUTF16: Int? = nil
    }

    /// Last exact caret reading: where the caret was, after which line text (AX coordinates).
    private struct CaretAnchor {
        let field: FieldID
        let line: String
        let rect: CGRect
    }
    private var caretAnchor: CaretAnchor?
    /// Host text width ÷ the same text's width in the font the ghost is drawn with (the host's
    /// reported font when it loads, else the system font), learned from consecutive exact
    /// readings. Kept per app and reported font, so switching apps or fields (Mail's subject vs
    /// body) neither loses it nor mixes fonts.
    private struct WidthKey: Hashable {
        let pid: pid_t
        let font: String
        let halfPoints: Int
    }
    private var widthStates: [WidthKey: (scale: CGFloat, samples: Int)] = [:]
    /// Samples needed before the learned scale is used for the ghost's size.
    static let widthScaleMinSamples = 4

    private static func widthKey(pid: pid_t, font: FontHint?) -> WidthKey {
        WidthKey(pid: pid, font: (font?.name ?? font?.family ?? "") + "|" + (font?.measuredFamily ?? "")
                     + String(format: "|%.3f", font?.sizeFactor ?? 1),
                 halfPoints: Int(((font?.pointSize ?? 0) * 2).rounded()))
    }

    /// Exposed scale, or nil while still learning.
    private func learnedWidthScale(pid: pid_t, font: FontHint?) -> CGFloat? {
        guard let state = widthStates[Self.widthKey(pid: pid, font: font)],
              state.samples >= Self.widthScaleMinSamples else { return nil }
        return state.scale
    }

    private var lastProbe: ProbeCache?
    private var lastRead: ReadSnapshot?
    private var hostCache: (field: FieldID, host: String?)?
    /// Window title per field, re-read every few seconds (switching chats can keep the same field).
    private var titleCache: (field: FieldID, title: String?, at: ContinuousClock.Instant)?
    /// Terminal title kind per field for Automatic mode, re-read every second (starting `claude`
    /// keeps the same field).
    private var terminalKindCache: (field: FieldID, kind: TerminalTitleKind, at: ContinuousClock.Instant)?
    /// Keyed by caret offset too: headings and body text in one field use different fonts.
    private var fontCache: (field: FieldID, caret: Int, font: FontHint?)?
    private var appCache: [pid_t: AppIdentity] = [:]
    private var catalystCache: [pid_t: CGFloat] = [:]
    /// Opt-in terminal screen dump for fixtures (`HUNCH_DEBUG_TERMINAL_DUMP`); nil by default.
    private let terminalDump = TerminalScreenDump.fromEnvironment()

    public convenience init(messagingTimeout: Float = 0.1) {
        self.init(client: AXClient(timeout: messagingTimeout))
    }

    init(client: AXClient) { self.client = client }

    // MARK: Probe (metadata only)

    public func probe(_ element: AXUIElement) -> ElementProbe {
        // Metadata attributes only. AXValue, selected text, and ranges are never touched here.
        let role = client.string(element, AXName.role)
        let subrole = client.string(element, AXName.subrole)
        let title = client.string(element, AXName.title)
        let desc = client.string(element, AXName.description)
        // AXDescription carries aria-label / accessibility labels; fold it into `title` so the
        // gate's sensitive-marker check sees it too (ElementProbe has no separate label field).
        let combinedTitle = [title, desc].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let probe = ElementProbe(
            role: role,
            subrole: subrole,
            roleDescription: client.string(element, AXName.roleDescription),
            identifier: client.string(element, AXName.identifier),
            title: combinedTitle.isEmpty ? nil : combinedTitle,
            placeholder: client.string(element, AXName.placeholder),
            protectedContent: client.bool(element, AXName.protectedContent),
            isEditable: EditabilityRule.isEditable(
                role: role, subrole: subrole, valueSettable: client.isSettable(element, AXName.value),
                characterCount: role == "AXComboBox" ? client.int(element, AXName.numberOfCharacters) : nil,
                caretLine: role == "AXComboBox" ? client.int(element, AXName.insertionPointLineNumber) : nil))
        lastProbe = ProbeCache(element: element, probe: probe)
        return probe
    }

    // MARK: Select (requires a pass)

    /// Selects `backward` UTF-16 units before the collapsed caret and `forward` after it, then reads
    /// the selection back and checks it is `expected`. On any mismatch the caret is put back where it
    /// was. Used by write for me so a paste replaces the old text in one step.
    func selectAroundCaret(_ element: AXUIElement, field: FieldID, pass: SecureGatePass,
                           backward: Int, forward: Int, expected: String) -> Result<Void, CaretSelection.Failure> {
        guard pass.isValid(for: field), Int(bitPattern: UInt(CFHash(element))) == field.elementHash else {
            return .failure(.focusMoved)
        }
        guard let current = client.range(element, AXName.selectedTextRange), current.location >= 0 else {
            return .failure(.noRange)
        }
        guard current.length == 0 else { return .failure(.notCollapsed) }
        guard let target = CaretSelection.range(caret: current.location, backward: backward, forward: forward),
              let value = AXClient.rangeValue(location: target.location, length: target.length) else {
            return .failure(.outOfBounds)
        }
        func restore() {
            if let back = AXClient.rangeValue(location: current.location, length: 0) {
                client.set(element, AXName.selectedTextRange, back)
            }
        }
        guard client.set(element, AXName.selectedTextRange, value) else { return .failure(.setFailed) }
        guard let applied = client.range(element, AXName.selectedTextRange),
              applied.location == target.location, applied.length == target.length else {
            restore()
            return .failure(.notApplied)
        }
        guard let text = client.string(element, location: target.location, length: target.length)
                ?? client.string(element, AXName.selectedText) else {
            restore()
            return .failure(.unreadable)
        }
        guard CaretSelection.matches(text, expected: expected) else {
            restore()
            return .failure(.mismatch)
        }
        return .success(())
    }

    // MARK: Read (requires a pass)

    public func read(_ element: AXUIElement, field: FieldID, pass: SecureGatePass, limits: ContextLimits) throws -> TextContext {
        try read(element, field: field, pass: pass, limits: limits, app: appIdentity(for: field.pid))
    }

    func read(_ element: AXUIElement, field: FieldID, pass: SecureGatePass, limits: ContextLimits,
              app: AppIdentity) throws -> TextContext {
        guard pass.isValid(for: field) else { throw ContextReadError.passInvalid }

        // Inside a code editor: which of its fields this is. The integrated terminal is refused
        // before any text is read.
        let probe = cachedProbe(for: element)
        var ideSurface: IDESurface?
        if Seeds.codeEditors.contains(app.bundleID) {
            let surface = IDESurfaceClassifier.classify(role: probe?.role, description: probe?.title,
                                                        placeholder: probe?.placeholder,
                                                        roleDescription: probe?.roleDescription)
            if surface == .terminal { throw ContextReadError.unsupportedSurface }
            ideSurface = surface
        }

        // Editable web areas (Mail's compose body, other WebKit editors whose focused element is the
        // whole document) have no AXSelectedTextRange, only text markers: the caret offset is then
        // the length of the text before the caret marker.
        var markerRead: (before: String, selected: String, after: String)?
        let caret: Int
        let selLength: Int
        if let selection = client.range(element, AXName.selectedTextRange), selection.location >= 0 {
            caret = selection.location
            selLength = max(0, selection.length)
        } else if let marked = client.textAroundCaretViaMarkers(element),
                  marked.before.utf16.count + marked.selected.utf16.count + marked.after.utf16.count <= Self.webAreaReadLimit {
            markerRead = marked
            caret = marked.before.utf16.count
            selLength = marked.selected.utf16.count
        } else {
            throw ContextReadError.selectionUnavailable
        }
        switch TerminalHosts.profile(for: app.bundleID) {
        case .axScreen?:
            return try readTerminal(element, field: field, caret: caret, limits: limits, app: app)
        case .unsupported?:
            // FocusEngine blocks these before reading; their value is never parsed.
            throw ContextReadError.valueUnavailable
        case .axTextField?, nil:
            break
        }
        let total = client.int(element, AXName.numberOfCharacters)

        // Fetch either the whole value or a bounded window around the caret.
        // If the value changed between reads and the caret lies past the end, slicing clamps it.
        let text: String
        var windowStart = 0
        var endsAtDocumentEnd = true
        var localCaretOverride: Int?
        var selLengthOverride: Int?
        if let marked = markerRead {
            text = marked.before + marked.selected + marked.after
        } else if let total, total <= Self.markerReadLimit, let marked = client.textAroundCaretViaMarkers(element) {
            // Web hosts (Chromium/Electron, WebKit): AXValue can contain text the selection offsets
            // don't count (list markers such as "2. "), so value + offset lands mid-text. Text
            // markers give the field's own text before/after the caret consistently.
            text = marked.before + marked.selected + marked.after
            localCaretOverride = marked.before.utf16.count
            selLengthOverride = marked.selected.utf16.count
        } else if let total, total > Self.windowedReadThreshold,
           case let range = TextWindow.fetchRange(caretUTF16: caret, selectionUTF16: selLength, totalUTF16: total, limits: limits),
           let windowed = client.string(element, location: range.location, length: range.length) {
            text = windowed
            windowStart = range.location
            endsAtDocumentEnd = range.location + range.length >= total
        } else if let value = client.string(element, AXName.value) {
            text = value
        } else if let total, total >= 0, let all = client.string(element, location: 0, length: total) {
            text = all
        } else if total == 0 {
            // An empty field can report no AXValue and refuse a zero-length range (Messages' compose box).
            text = ""
        } else {
            throw ContextReadError.valueUnavailable
        }

        let localCaret = localCaretOverride ?? (caret - windowStart)
        let slice = TextWindow.slice(text, caretUTF16: localCaret, selectionUTF16: selLengthOverride ?? selLength,
                                     limits: limits,
                                     endsAtDocumentEnd: endsAtDocumentEnd,
                                     startsAtDocumentStart: windowStart == 0)
        let prevIsBreak = TextWindow.previousCharacterIsNewlineOrStart(text, caretUTF16: localCaret)
            && !(windowStart > 0 && localCaret == 0)

        let marked: Bool = {
            guard let r = client.range(element, AXName.markedTextRange) else { return false }
            return r.length > 0
        }()

        let role = probe?.role
        let subrole = probe?.subrole
        let surface = SurfaceClassifier.classify(bundleID: app.bundleID, role: role, subrole: subrole,
                                                 ideSurface: ideSurface)
        let metadata = FieldMetadata(
            role: role,
            subrole: subrole,
            placeholder: probe?.placeholder,
            label: probe?.title,
            isMultiline: role == AXName.textArea || slice.containsNewline,
            surface: surface,
            isAIChatInput: ideSurface == .aiChat)
        // Code: the caret in front of auto-closed closers counts as the end of its line (the
        // geometry keeps the raw answer; it places the caret from the next character).
        let caretAtLineEnd = slice.caretAtLineEnd
            || (surface == .code && CodeLineEnd.isEffectiveLineEnd(after: slice.after))

        lastRead = ReadSnapshot(field: field, element: element, caretUTF16: caret, selectionUTF16: selLength,
                                previousIsNewlineOrStart: prevIsBreak, nextIsNewlineOrEnd: slice.caretAtLineEnd,
                                bundleID: app.bundleID, nextScalar: slice.after.unicodeScalars.first?.value,
                                lineBefore: Self.lineBefore(slice.before),
                                lineStartUTF16: CaretMath.lineStartUTF16(
                                    before: slice.before, caretUTF16: caret,
                                    beforeReachesStart: windowStart == 0 && slice.before.utf16.count == localCaret))

        var context = TextContext(
            app: app,
            field: field,
            urlHost: hostCache?.field == field ? hostCache?.host : nil,
            before: slice.before,
            after: slice.after,
            selectionLength: slice.selectionLength,
            hasMarkedText: marked,
            caretAtLineEnd: caretAtLineEnd,
            metadata: metadata,
            contentSignature: ContentSignature.make(before: slice.before, after: slice.after,
                                                    selectionLength: slice.selectionLength),
            windowTitle: windowTitle(of: element, field: field),
            selectedText: slice.selected)
        context.beforeIsCut = slice.beforeIsCut
        context.afterIsCut = slice.afterIsCut
        return context
    }

    /// Terminals that expose their screen: only the user's input in an AI-agent prompt counts as
    /// the field; anything else on the screen throws `notAgentPrompt`, so no suggestion is shown
    /// there. A long screen (scrollback) is read in a window around the caret.
    private func readTerminal(_ element: AXUIElement, field: FieldID, caret: Int, limits: ContextLimits,
                              app: AppIdentity) throws -> TextContext {
        let total = client.int(element, AXName.numberOfCharacters)
        var screen: String
        var screenCaret = caret
        var caretLine: Int?
        var windowStart = 0
        if let total, let range = TerminalHosts.screenWindow(caretUTF16: caret, totalUTF16: total),
           let windowed = client.string(element, location: range.location, length: range.length) {
            // The host's line number counts from the top of the whole screen: unusable here.
            (screen, screenCaret) = TerminalHosts.wholeLines(windowed, windowStart: range.location, caretUTF16: caret)
            windowStart = caret - screenCaret
        } else {
            guard let value = client.string(element, AXName.value) else { throw ContextReadError.valueUnavailable }
            screen = value
            caretLine = client.int(element, AXName.insertionPointLineNumber)
        }
        terminalDump?.record(bundleID: app.bundleID, screen: screen, caretUTF16: screenCaret, caretLine: caretLine,
                             windowStart: windowStart, totalUTF16: total)
        let kind: TerminalTitleKind = switch shellCommandMode(app.bundleID) {
        case .always: .shell
        case .never: .agent
        case .automatic: terminalKind(of: element, field: field)
        }
        switch kind {
        case .shell:
            return try readShellPrompt(element, field: field, caret: caret, screen: screen, screenCaret: screenCaret,
                                       limits: limits, app: app)
        case .otherProgram: throw ContextReadError.otherTerminalProgram
        case .agent, .unknown: break
        }
        guard let prompt = TerminalPromptParser.parse(screen: screen, caretUTF16: screenCaret, caretLine: caretLine) else {
            // No title clue and no agent prompt box: a shell prompt at the caret, else nothing.
            if kind == .unknown {
                return try readShellPrompt(element, field: field, caret: caret, screen: screen,
                                           screenCaret: screenCaret, limits: limits, app: app)
            }
            throw ContextReadError.notAgentPrompt
        }
        let text = prompt.before + prompt.after
        let slice = TextWindow.slice(text, caretUTF16: prompt.before.utf16.count, selectionUTF16: 0, limits: limits)
        let ns = screen as NSString
        let pastLineEnd = screenCaret > ns.length
            || (screenCaret > 0 && screenCaret - 1 < ns.length && ns.character(at: screenCaret - 1) == 0x0A)
        let probe = cachedProbe(for: element)
        lastRead = ReadSnapshot(field: field, element: element, caretUTF16: caret, selectionUTF16: 0,
                                previousIsNewlineOrStart: false, nextIsNewlineOrEnd: true,
                                bundleID: app.bundleID, lineBefore: Self.lineBefore(slice.before),
                                pastLineEnd: pastLineEnd)
        return TextContext(
            app: app,
            field: field,
            before: slice.before,
            after: slice.after,
            selectionLength: 0,
            caretAtLineEnd: prompt.caretAtLineEnd,
            metadata: FieldMetadata(role: probe?.role, subrole: probe?.subrole, isMultiline: true,
                                    surface: .agentPrompt),
            contentSignature: ContentSignature.make(before: slice.before, after: slice.after, selectionLength: 0),
            windowTitle: windowTitle(of: element, field: field))
    }

    /// Shell-command mode: the field is the command typed at the shell prompt, with the screen lines
    /// above it as context (an error the next command answers). Agent prompts are not read here.
    private func readShellPrompt(_ element: AXUIElement, field: FieldID, caret: Int, screen: String, screenCaret: Int,
                                 limits: ContextLimits, app: AppIdentity) throws -> TextContext {
        guard let shell = ShellPromptParser.parse(screen: screen, caretUTF16: screenCaret) else {
            throw ContextReadError.notShellPrompt
        }
        let line = shell.prompt + " " + shell.command
        let text = (shell.above + [line]).joined(separator: "\n")
        let slice = TextWindow.slice(text, caretUTF16: text.utf16.count, selectionUTF16: 0, limits: limits)
        let ns = screen as NSString
        let pastLineEnd = screenCaret > ns.length
            || (screenCaret > 0 && screenCaret - 1 < ns.length && ns.character(at: screenCaret - 1) == 0x0A)
        let probe = cachedProbe(for: element)
        lastRead = ReadSnapshot(field: field, element: element, caretUTF16: caret, selectionUTF16: 0,
                                previousIsNewlineOrStart: false, nextIsNewlineOrEnd: true,
                                bundleID: app.bundleID, lineBefore: Self.lineBefore(slice.before),
                                pastLineEnd: pastLineEnd)
        return TextContext(
            app: app,
            field: field,
            before: slice.before,
            after: "",
            selectionLength: 0,
            caretAtLineEnd: true,
            metadata: FieldMetadata(role: probe?.role, subrole: probe?.subrole, isMultiline: true,
                                    surface: .shell, typedCommand: shell.command),
            contentSignature: ContentSignature.make(before: slice.before, after: "", selectionLength: 0),
            windowTitle: windowTitle(of: element, field: field))
    }

    /// The field's window title (AXWindow → AXTitle): metadata, bounded to 120 characters, with
    /// secrets redacted (`SecretSanitizer`) and other secret-looking tokens (long random strings)
    /// removed. Nil when absent.
    private func windowTitle(of element: AXUIElement, field: FieldID) -> String? {
        guard windowTitleEnabled() else {
            titleCache = nil
            return nil
        }
        let now = ContinuousClock.now
        if let cached = titleCache, cached.field == field, now - cached.at < .seconds(3) { return cached.title }
        var title: String?
        if let window = client.element(element, AXName.window), let raw = client.string(window, AXName.title) {
            var kept: [String] = []
            for token in SecretSanitizer.redact(raw).split(whereSeparator: { $0.isWhitespace }) {
                // Drop long tokens mixing letters and digits (session ids, keys) from the title.
                let word = String(token)
                let secretLike = word.count >= 16 && word.contains(where: { $0.isLetter })
                    && word.contains(where: { $0.isNumber })
                if !secretLike { kept.append(word) }
            }
            let joined = kept.joined(separator: " ")
            title = joined.isEmpty ? nil : String(joined.prefix(120))
        }
        titleCache = (field, title, now)
        return title
    }

    /// Automatic mode: what the terminal window's title says is in front. Read even when window
    /// titles are off as context; only the kind is kept, never the title.
    private func terminalKind(of element: AXUIElement, field: FieldID) -> TerminalTitleKind {
        let now = ContinuousClock.now
        if let cached = terminalKindCache, cached.field == field, now - cached.at < .seconds(1) { return cached.kind }
        let title = client.element(element, AXName.window).flatMap { client.string($0, AXName.title) }
        let kind = TerminalTitleClassifier.classify(title)
        terminalKindCache = (field, kind, now)
        return kind
    }

    // MARK: Caret geometry (requires a pass)

    public func caret(_ element: AXUIElement, field: FieldID, pass: SecureGatePass) -> CaretGeometry {
        caret(element, field: field, pass: pass, lineStart: false, estimatedOnly: false)
    }

    /// `lineStart`: also find where the caret's line starts (`CaretGeometry.lineStartX`), with an
    /// exact caret only. One more AX read, so only for apps that mirror.
    /// `estimatedOnly`: skip every text-bounds query (`AppPolicy.estimatedGeometryOnly`).
    func caret(_ element: AXUIElement, field: FieldID, pass: SecureGatePass, lineStart: Bool,
               estimatedOnly: Bool) -> CaretGeometry {
        let none = CaretGeometry(caretRect: .zero, quality: .none)
        // The pass must be for this field, and the field for this element.
        guard pass.isValid(for: field), Int(bitPattern: UInt(CFHash(element))) == field.elementHash else { return none }

        let snapshot: ReadSnapshot
        if let s = lastRead, s.field == field, CFEqual(s.element, element) {
            snapshot = s
        } else {
            guard let sel = client.range(element, AXName.selectedTextRange), sel.location >= 0 else { return none }
            snapshot = ReadSnapshot(field: field, element: element, caretUTF16: sel.location,
                                    selectionUTF16: max(0, sel.length), previousIsNewlineOrStart: false,
                                    nextIsNewlineOrEnd: false, bundleID: appIdentity(for: field.pid).bundleID)
        }

        let frame = client.frame(element)
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let flippedFrame = frame.map { CaretMath.flipToAppKit($0, primaryScreenHeight: screenHeight) }
        let font = fontHint(element, field: field, caret: snapshot.caretUTF16)

        func result(_ axRect: CGRect, _ quality: GeometryQuality) -> CaretGeometry {
            if quality == .exact { noteExactCaret(axRect, snapshot: snapshot, font: font) }
            // x is the same in AX and AppKit space; only y flips.
            var startX = lineStart && quality == .exact
                ? Self.lineStartX(element, client: client, lineStartUTF16: snapshot.lineStartUTF16,
                                  caretUTF16: snapshot.caretUTF16, caretRect: axRect, fieldFrame: frame)
                : nil
            // Hosts with text markers only (Chromium, Electron): with one character on the line, the
            // character before the caret is the line's first.
            if lineStart, quality == .exact, startX == nil, let start = snapshot.lineStartUTF16,
               start == snapshot.caretUTF16 - 1, snapshot.selectionUTF16 == 0,
               let r = client.previousCharacterMarkerBounds(element), r.width > 0, r.width <= r.height * 3 {
                startX = CaretMath.lineStartX(firstCharacter: r, caretRect: axRect, fieldFrame: frame)
            }
            return CaretGeometry(caretRect: CaretMath.flipToAppKit(axRect, primaryScreenHeight: screenHeight),
                                 fieldFrame: flippedFrame, font: font, quality: quality,
                                 widthScale: learnedWidthScale(pid: snapshot.field.pid, font: font),
                                 lineStartX: startX)
        }

        let loc = snapshot.caretUTF16
        let log = GeometryDebugLog.shared
        defer { log.flush() }
        log.begin(bundleID: snapshot.bundleID, caret: loc, frame: frame, font: font,
                  previousIsBreak: snapshot.previousIsNewlineOrStart, nextIsBreakOrEnd: snapshot.nextIsNewlineOrEnd,
                  nextScalar: snapshot.nextScalar)
        if snapshot.pastLineEnd, loc >= 2 {
            // 0. Terminal caret after a trimmed trailing space: one cell past the line's last character.
            let r = client.bounds(element, location: loc - 2, length: 1)
            let ok = r.map { CaretMath.isPlausible($0, fieldFrame: frame) && $0.width > 0 } ?? false
            log.step("pastLineEnd", r, ok)
            if let r, ok { return log.done(result(CaretMath.caretAfterCharacter(r).offsetBy(dx: r.width, dy: 0), .exact)) }
        }
        if !estimatedOnly {
            // 1. Right edge of the previous character (unless it is a line break). Preferred over the
            //    zero-length range: TextKit reports the end-of-document insertion rect a line too high.
            if loc > 0, !snapshot.previousIsNewlineOrStart {
                let r = client.bounds(element, location: loc - 1, length: 1)
                let ok = r.map { CaretMath.isPlausible($0, fieldFrame: frame) } ?? false
                log.step("prevChar", r, ok)
                if let r, ok { return log.done(result(CaretMath.caretAfterCharacter(r), .exact)) }
            }
            // 2. Zero-length range at the caret.
            let zero = client.bounds(element, location: loc, length: 0)
            let zeroOK = zero.map { CaretMath.isPlausible($0, fieldFrame: frame) } ?? false
            log.step("zeroLength", zero, zeroOK)
            if let zero, zeroOK { return log.done(result(CaretMath.caretFromInsertionBounds(zero), .exact)) }
            // 2b. Chromium/Electron text markers: bounds of the (collapsed) selected marker range.
            //     Chromium sometimes answers with the whole line or field box instead of a caret (seen
            //     in Claude desktop after a "/" command): anything much wider than a caret is rejected.
            let marker = client.selectedTextMarkerBounds(element)
            let markerOK = marker.map { CaretMath.isPlausible($0, fieldFrame: frame) && $0.width <= max(4, $0.height * 0.5) } ?? false
            log.step("textMarker", marker, markerOK)
            if let marker, markerOK { return log.done(result(CaretMath.caretFromInsertionBounds(marker), .exact)) }
            // 2c. Text markers again: right edge of the previous character.
            if loc > 0, !snapshot.previousIsNewlineOrStart {
                let r = client.previousCharacterMarkerBounds(element)
                let ok = r.map { CaretMath.isPlausible($0, fieldFrame: frame) && $0.width > 0 && $0.width <= $0.height * 3 } ?? false
                log.step("prevCharMarker", r, ok)
                if let r, ok { return log.done(result(CaretMath.caretAfterCharacter(r), .exact)) }
            }
            // 3. Left edge of the next character (unless it is a line break or the end).
            if !snapshot.nextIsNewlineOrEnd {
                let r = client.bounds(element, location: loc + snapshot.selectionUTF16, length: 1)
                let ok = r.map { CaretMath.isPlausible($0, fieldFrame: frame) } ?? false
                log.step("nextChar", r, ok)
                if let r, ok { return log.done(result(CaretMath.caretBeforeCharacter(r), .derived)) }
            }
        }
        // 3b. The host stopped reporting text bounds (Claude desktop after a "/" command answers
        //     every range with the whole field): continue from the last exact caret on this line by
        //     the width of the text typed since.
        if let r = extrapolatedCaret(snapshot: snapshot, font: font, frame: frame) {
            log.step("extrapolated", r, true)
            return log.done(result(r, .derived))
        }
        // 4. Estimate from the field frame.
        if let frame, frame.width > 0, frame.height > 0 {
            return log.done(result(CaretMath.estimatedCaret(fieldFrame: frame), .estimated))
        }
        return log.done(none)
    }

    /// x of the caret line's first character, from `AXBoundsForRange` on that one character (AX
    /// coordinates in and out; x needs no flip). Nil when the line start is unknown, or the bounds
    /// are implausible or not on the caret's row (`CaretMath.lineStartX`).
    static func lineStartX(_ element: AXUIElement, client: some TextBoundsReading, lineStartUTF16: Int?,
                           caretUTF16: Int, caretRect: CGRect, fieldFrame: CGRect?) -> CGFloat? {
        guard let start = lineStartUTF16, start >= 0, start < caretUTF16,
              let r = client.bounds(element, location: start, length: 1),
              CaretMath.isPlausible(r, fieldFrame: fieldFrame) else { return nil }
        return CaretMath.lineStartX(firstCharacter: r, caretRect: caretRect, fieldFrame: fieldFrame)
    }

    // MARK: Caret extrapolation

    static func lineBefore(_ before: String) -> String {
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? before
        return String(line.suffix(400))
    }

    /// Width of `text` in the font the overlay draws for `hint` (same choice as the presenter:
    /// the host's font by name, then family, then an installed stand-in for a web font, else the
    /// system face), at the reported size or 14.
    private static func textWidth(_ text: String, font hint: FontHint?) -> CGFloat {
        let size = (hint?.pointSize.flatMap { $0 > 0 ? $0 : nil } ?? 14) * (hint?.sizeFactor ?? 1)
        var font = NSFont.systemFont(ofSize: size)
        if let name = hint?.name, !name.hasPrefix("."), let f = NSFont(name: name, size: size) {
            font = f
        } else if let family = hint?.family, !family.hasPrefix("."),
                  let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            font = f
        } else if let stand = FontLookalike.standIn(for: hint),
                  let f = NSFontManager.shared.font(withFamily: stand, traits: [], weight: 5, size: size) {
            font = f
        } else if hint?.isMonospaced == true {
            font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Records an exact caret and, when it continues the anchor's line, refines the width scale.
    private func noteExactCaret(_ rect: CGRect, snapshot: ReadSnapshot, font: FontHint?) {
        guard let line = snapshot.lineBefore else { caretAnchor = nil; return }
        if let a = caretAnchor, a.field == snapshot.field, abs(a.rect.midY - rect.midY) < 2,
           line.count >= a.line.count + 3, line.hasPrefix(a.line) {
            let computed = Self.textWidth(String(line.dropFirst(a.line.count)), font: font)
            let measured = rect.minX - a.rect.minX
            if computed > 8, measured > 0 {
                let ratio = min(max(measured / computed, 0.7), 1.4)
                let key = Self.widthKey(pid: snapshot.field.pid, font: font)
                var state = widthStates[key] ?? (1, 0)
                // Plain average for the first samples, then a slow moving average.
                state.samples += 1
                let weight: CGFloat = state.samples <= 5 ? 1 / CGFloat(state.samples) : 0.15
                state.scale = state.scale * (1 - weight) + ratio * weight
                if widthStates.count > 64 { widthStates.removeAll() }
                widthStates[key] = state
            }
        }
        caretAnchor = CaretAnchor(field: snapshot.field, line: line, rect: rect)
    }

    /// Caret from the last exact reading on the same line plus the width of the text typed since.
    private func extrapolatedCaret(snapshot: ReadSnapshot, font: FontHint?, frame: CGRect?) -> CGRect? {
        guard let a = caretAnchor, a.field == snapshot.field, let line = snapshot.lineBefore,
              line.hasPrefix(a.line) else { return nil }
        let delta = String(line.dropFirst(a.line.count))
        let scale = widthStates[Self.widthKey(pid: snapshot.field.pid, font: font)]?.scale ?? 1
        let x = a.rect.minX + Self.textWidth(delta, font: font) * scale
        if let frame, x > frame.maxX { return nil }   // wrapped onto another line: unknown
        return CGRect(x: x, y: a.rect.minY, width: max(a.rect.width, 1), height: a.rect.height)
    }

    // MARK: Helpers used by the tracker

    /// Host of the enclosing web area's `AXURL`, cached per field. URL metadata, not field text;
    /// the tracker uses it to resolve domain policy before the element gate.
    func webHost(for element: AXUIElement, field: FieldID) -> String? {
        if let cached = hostCache, cached.field == field { return cached.host }
        var host: String?
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 32 {
            let role = client.string(node, AXName.role)
            if role == AXName.webArea {
                if let v = client.attribute(node, AXName.url) {
                    if CFGetTypeID(v) == CFURLGetTypeID() {
                        host = URLHostExtractor.host(from: (unsafeDowncast(v, to: CFURL.self) as URL).absoluteString)
                    } else if CFGetTypeID(v) == CFStringGetTypeID() {
                        host = URLHostExtractor.host(from: unsafeDowncast(v, to: CFString.self) as String)
                    }
                }
                break
            }
            if role == AXName.window || role == AXName.application || client.sawTimeout { break }
            current = client.element(node, AXName.parent)
            depth += 1
        }
        hostCache = (field, host)
        return host
    }

    func appIdentity(for pid: pid_t) -> AppIdentity {
        if let cached = appCache[pid] { return cached }
        let running = NSRunningApplication(processIdentifier: pid)
        let identity = AppIdentity(bundleID: running?.bundleIdentifier ?? "", pid: pid,
                                   localizedName: running?.localizedName)
        if appCache.count > 64 { appCache.removeAll() }
        appCache[pid] = identity
        return identity
    }

    /// Reported-to-screen font size factor for the app (`CatalystScale`), read once per pid.
    func catalystScale(pid: pid_t) -> CGFloat {
        if let known = catalystCache[pid] { return known }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL.flatMap { Bundle(url: $0) }
        let scale = CatalystScale.factor(
            deviceFamily: bundle?.object(forInfoDictionaryKey: "UIDeviceFamily"),
            macIdiom: bundle?.object(forInfoDictionaryKey: "UIUserInterfaceIdiomMac"))
        if catalystCache.count > 64 { catalystCache.removeAll() }
        catalystCache[pid] = scale
        return scale
    }

    /// Drops per-field caches (on focus change, pause, or app switch).
    func forgetField() {
        lastProbe = nil
        lastRead = nil
        hostCache = nil
        titleCache = nil
        terminalKindCache = nil
        fontCache = nil
        caretAnchor = nil
    }

    private func cachedProbe(for element: AXUIElement) -> ElementProbe? {
        guard let cache = lastProbe, CFEqual(cache.element, element) else { return nil }
        return cache.probe
    }

    private func fontHint(_ element: AXUIElement, field: FieldID, caret: Int) -> FontHint? {
        if let cached = fontCache, cached.field == field, cached.caret == caret { return cached.font }
        var hint: FontHint?
        // Terminals report no font: their own config comes first, matched on the measured cell
        // width. Terminal.app's answer is final, as before; other terminals without a usable
        // config fall through to accessibility.
        if let read = lastRead, read.field == field, let host = HostFontConfigs.source(for: read.bundleID),
           host.isTerminal {
            let cell = client.bounds(element, location: max(0, caret - (read.pastLineEnd ? 2 : 1)), length: 1)
            hint = HostFontConfigs.hint(host, cellWidth: cell?.width)
            if hint != nil || read.bundleID == HostFontConfigs.terminalBundleID {
                fontCache = (field, caret, hint)
                return hint
            }
        }
        let location = caret > 0 ? caret - 1 : caret
        let fontKey = NSAttributedString.Key(AXName.fontAttribute)
        let indexed = client.attributedString(element, location: location, length: 1)
        let hasFont = indexed.map { $0.length > 0 && $0.attribute(fontKey, at: 0, effectiveRange: nil) != nil } ?? false
        // Web areas without index ranges (Mail's compose body): ask through text markers instead.
        let source = hasFont ? indexed : (caret > 0 ? client.attributedCharacterBeforeCaretViaMarkers(element) : nil)
        if let attributed = source { hint = Self.fontHint(from: attributed) }
        // iPad-idiom Catalyst apps report their unscaled iPad size; the screen shows 77% of it.
        if let size = hint?.pointSize {
            let scale = catalystScale(pid: field.pid)
            if scale != 1 { hint?.pointSize = size * scale }
        }
        // Editors whose text carries no AXFont (VS Code forks): the font from their settings.
        if hint == nil, let host = HostFontConfigs.source(for: appIdentity(for: field.pid).bundleID), !host.isTerminal {
            hint = HostFontConfigs.hint(host, cellWidth: nil)
        }
        // The face and size decided from on-screen measurement for this app and size, so the width
        // learner, calibration and overlay all draw the same thing.
        hint = FaceChoiceBook.shared.apply(to: hint, bundleID: appIdentity(for: field.pid).bundleID)
        fontCache = (field, caret, hint)
        return hint
    }

    /// Font, text color, and background color of the first character of an AX attributed string.
    /// Nil without a font attribute.
    static func fontHint(from attributed: NSAttributedString) -> FontHint? {
        let fontKey = NSAttributedString.Key(AXName.fontAttribute)
        guard attributed.length > 0,
              let font = attributed.attribute(fontKey, at: 0, effectiveRange: nil) as? [String: Any] else { return nil }
        let colorKey = NSAttributedString.Key(AXName.foregroundColor)
        let color = attributed.attribute(colorKey, at: 0, effectiveRange: nil).flatMap(Self.rgba)
        let backgroundKey = NSAttributedString.Key(AXName.backgroundColor)
        let background = attributed.attribute(backgroundKey, at: 0, effectiveRange: nil).flatMap(Self.rgba)
        return FontHintParser.hint(family: font[AXName.fontFamily] as? String,
                                   name: font[AXName.fontName] as? String,
                                   size: (font[AXName.fontSize] as? NSNumber)?.doubleValue,
                                   textColor: color, backgroundColor: background)
    }

    /// `AXForegroundColor` and `AXBackgroundColor` arrive as CGColors; converts one to sRGB components.
    static func rgba(_ value: Any) -> RGBAColor? {
        let ref = value as AnyObject
        guard CFGetTypeID(ref) == CGColor.typeID else { return nil }
        let color = unsafeDowncast(ref, to: CGColor.self)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        return RGBAColor(red: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
    }
}

/// Wakes Chromium/Electron accessibility trees once per pid (policy-gated by `wakeChromiumAX`).
final class ChromiumWaker {
    private enum Woken { case manual, enhanced }
    private var woken: [pid_t: Woken] = [:]
    private var lastCheck: [pid_t: ContinuousClock.Instant] = [:]
    static let recheckInterval: Duration = .seconds(3)
    private var electron: [pid_t: Bool] = [:]
    private let client: AXClient

    init(client: AXClient) { self.client = client }

    /// Electron apps (Discord, Slack, Claude, ChatGPT, VS Code, ...) only build a full accessibility
    /// tree, with real text bounds, once asked to. Detected by any of: the bundled Electron framework
    /// (some apps rename it, e.g. ChatGPT's "Codex Framework"), the app's `app.asar` archive, or the
    /// `ElectronAsarIntegrity` Info.plist key.
    func isElectron(pid: pid_t) -> Bool {
        if let known = electron[pid] { return known }
        var found = false
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL {
            let fm = FileManager.default
            let contents = bundle.appendingPathComponent("Contents")
            found = fm.fileExists(atPath: contents.appendingPathComponent("Frameworks/Electron Framework.framework").path)
                || fm.fileExists(atPath: contents.appendingPathComponent("Resources/app.asar").path)
                || Bundle(url: bundle)?.object(forInfoDictionaryKey: "ElectronAsarIntegrity") != nil
        }
        if electron.count > 64 { electron.removeAll() }
        electron[pid] = found
        return found
    }

    /// Turns the app's accessibility tree on, and keeps it on: an app can drop the flag again
    /// (or ignore a set made while it was busy), so a woken app is re-checked at most every
    /// `recheckInterval` and woken again when the flag reads false. Only the attribute that worked
    /// is re-checked; the AXEnhancedUserInterface fallback is never set twice (it changes window
    /// behaviour), so apps that need it are woken once per launch.
    func wakeIfNeeded(pid: pid_t) {
        let now = ContinuousClock.now
        if let last = lastCheck[pid], now - last < Self.recheckInterval { return }
        if lastCheck.count > 64 { lastCheck.removeAll() }
        lastCheck[pid] = now
        let app = AXUIElementCreateApplication(pid)
        switch woken[pid] {
        case .enhanced?:
            return
        case .manual?:
            if client.bool(app, AXName.manualAccessibility) != false { return }
        case nil:
            break
        }
        if client.set(app, AXName.manualAccessibility, kCFBooleanTrue) {
            woken[pid] = .manual
        } else if client.set(app, AXName.enhancedUserInterface, kCFBooleanTrue) {
            woken[pid] = .enhanced
        }
        // Neither worked (app busy or not ready): left unmarked, so the next check tries again.
    }

    func forget(pid: pid_t) {
        woken[pid] = nil
        lastCheck[pid] = nil
    }
}
