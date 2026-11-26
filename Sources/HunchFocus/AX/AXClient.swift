import ApplicationServices
import Foundation
import os

/// Attribute names used by HunchFocus (string literals, to avoid depending on CFSTR macro imports).
enum AXName {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let roleDescription = "AXRoleDescription"
    static let identifier = "AXIdentifier"
    static let title = "AXTitle"
    static let description = "AXDescription"
    static let placeholder = "AXPlaceholderValue"
    static let protectedContent = "AXProtectedContent"
    static let value = "AXValue"
    static let selectedTextRange = "AXSelectedTextRange"
    static let selectedText = "AXSelectedText"
    static let numberOfCharacters = "AXNumberOfCharacters"
    static let insertionPointLineNumber = "AXInsertionPointLineNumber"
    static let markedTextRange = "AXMarkedTextRange"
    static let previousTextMarkerForTextMarker = "AXPreviousTextMarkerForTextMarker"
    static let nextTextMarkerForTextMarker = "AXNextTextMarkerForTextMarker"
    static let indexForTextMarker = "AXIndexForTextMarker"
    static let textMarkerForIndex = "AXTextMarkerForIndex"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let parent = "AXParent"
    static let url = "AXURL"
    static let focusedUIElement = "AXFocusedUIElement"
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"
    static let focused = "AXFocused"
    static let children = "AXChildren"
    static let manualAccessibility = "AXManualAccessibility"
    static let enhancedUserInterface = "AXEnhancedUserInterface"
    // Parameterized
    static let boundsForRange = "AXBoundsForRange"
    static let stringForRange = "AXStringForRange"
    static let attributedStringForRange = "AXAttributedStringForRange"
    // Roles
    static let webArea = "AXWebArea"
    static let window = "AXWindow"
    static let application = "AXApplication"
    static let textArea = "AXTextArea"
    // Notifications
    static let focusedUIElementChanged = "AXFocusedUIElementChanged"
    static let valueChanged = "AXValueChanged"
    static let selectedTextChanged = "AXSelectedTextChanged"
    // Font attribute keys inside attributed strings
    static let fontAttribute = "AXFont"
    static let fontFamily = "AXFontFamily"
    static let fontName = "AXFontName"
    static let fontSize = "AXFontSize"
    static let foregroundColor = "AXForegroundColor"
    static let selectedTextMarkerRange = "AXSelectedTextMarkerRange"
    static let boundsForTextMarkerRange = "AXBoundsForTextMarkerRange"
    static let textMarkerRangeForUIElement = "AXTextMarkerRangeForUIElement"
    static let textMarkerRangeForUnorderedTextMarkers = "AXTextMarkerRangeForUnorderedTextMarkers"
    static let stringForTextMarkerRange = "AXStringForTextMarkerRange"
    static let lineTextMarkerRangeForTextMarker = "AXLineTextMarkerRangeForTextMarker"
    static let attributedStringForTextMarkerRange = "AXAttributedStringForTextMarkerRange"
    static let backgroundColor = "AXBackgroundColor"
}

/// The one `AXClient` read the line-start lookup needs, so tests can stand in for the host.
protocol TextBoundsReading {
    func bounds(_ element: AXUIElement, location: Int, length: Int) -> CGRect?
}

extension AXClient: TextBoundsReading {}

/// Thin, synchronous AX accessor. Confined to the AX thread. Every queried element gets the
/// messaging timeout first, and timeouts are recorded so the tracker can back off a hung app.
final class AXClient {
    let timeout: Float
    private(set) var sawTimeout = false

    init(timeout: Float = 0.1) { self.timeout = timeout }

    func resetTimeoutFlag() { sawTimeout = false }

    private func note(_ error: AXError) {
        if error == .cannotComplete { sawTimeout = true }
    }

    func prepare(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, timeout)
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        prepare(element)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        note(err)
        return err == .success ? value : nil
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        prepare(element)
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value)
        note(err)
        return err == .success ? value : nil
    }

    func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        prepare(element)
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        note(err)
        return err == .success && settable.boolValue
    }

    @discardableResult
    func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        prepare(element)
        let err = AXUIElementSetAttributeValue(element, name as CFString, value)
        note(err)
        return err == .success
    }

    func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }

    // MARK: Typed reads

    func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let v = attribute(element, name), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return unsafeDowncast(v, to: CFString.self) as String
    }

    func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let v = attribute(element, name) else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return CFBooleanGetValue(unsafeDowncast(v, to: CFBoolean.self)) }
        if CFGetTypeID(v) == CFNumberGetTypeID() { return (unsafeDowncast(v, to: CFNumber.self) as NSNumber).boolValue }
        return nil
    }

    func int(_ element: AXUIElement, _ name: String) -> Int? {
        guard let v = attribute(element, name), CFGetTypeID(v) == CFNumberGetTypeID() else { return nil }
        return (unsafeDowncast(v, to: CFNumber.self) as NSNumber).intValue
    }

    func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(element, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(v, to: AXUIElement.self)
    }

    func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let v = attribute(element, AXName.children), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (unsafeDowncast(v, to: CFArray.self) as [AnyObject]).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
        }
    }

    func range(_ element: AXUIElement, _ name: String) -> CFRange? {
        attribute(element, name).flatMap(Self.range(from:))
    }

    func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, AXName.position).flatMap(Self.point(from:)),
              let s = attribute(element, AXName.size).flatMap(Self.size(from:)) else { return nil }
        return CGRect(origin: p, size: s)
    }

    func bounds(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        guard location >= 0, length >= 0, let param = Self.rangeValue(location: location, length: length) else { return nil }
        return parameterized(element, AXName.boundsForRange, param).flatMap(Self.rect(from:))
    }

    /// The field's text before, inside, and after the selection, read through text markers scoped
    /// to `element` (its own start/end, not the whole web page). Nil when the host has no markers.
    func textAroundCaretViaMarkers(_ element: AXUIElement) -> (before: String, selected: String, after: String)? {
        guard let selection = attribute(element, AXName.selectedTextMarkerRange),
              CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID(),
              let whole = parameterized(element, AXName.textMarkerRangeForUIElement, element),
              CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return nil }
        let sel = unsafeDowncast(selection, to: AXTextMarkerRange.self)
        let all = unsafeDowncast(whole, to: AXTextMarkerRange.self)
        let start = AXTextMarkerRangeCopyStartMarker(all), end = AXTextMarkerRangeCopyEndMarker(all)
        let caretStart = AXTextMarkerRangeCopyStartMarker(sel), caretEnd = AXTextMarkerRangeCopyEndMarker(sel)
        func text(_ a: AXTextMarker, _ b: AXTextMarker) -> String? {
            guard let range = parameterized(element, AXName.textMarkerRangeForUnorderedTextMarkers, [a, b] as CFArray),
                  let value = parameterized(element, AXName.stringForTextMarkerRange, range),
                  CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
            return unsafeDowncast(value, to: CFString.self) as String
        }
        guard let before = text(start, caretStart), let after = text(caretEnd, end) else { return nil }
        let selected = CFEqual(caretStart, caretEnd) ? "" : (text(caretStart, caretEnd) ?? "")
        // Chromium runs paragraphs together in marker text; AXValue keeps the breaks.
        guard let value = string(element, AXName.value), value.contains(where: \.isNewline) || !before.isEmpty else {
            return (before, selected, after)
        }
        var caretLine: ParagraphBreaks.CaretLine?
        if let line = parameterized(element, AXName.lineTextMarkerRangeForTextMarker, caretStart),
           CFGetTypeID(line) == AXTextMarkerRangeGetTypeID() {
            let lineRange = unsafeDowncast(line, to: AXTextMarkerRange.self)
            let lineText = parameterized(element, AXName.stringForTextMarkerRange, lineRange)
                .flatMap { CFGetTypeID($0) == CFStringGetTypeID() ? unsafeDowncast($0, to: CFString.self) as String : nil }
            if let lineText, let toCaret = text(AXTextMarkerRangeCopyStartMarker(lineRange), caretStart) {
                caretLine = .init(atLineStart: toCaret.isEmpty,
                                  emptyLine: lineText.allSatisfy { $0.isNewline || $0 == "\u{200B}" })
            }
        }
        return ParagraphBreaks.restore(before: before, selected: selected, after: after, value: value,
                                       caretLine: caretLine) ?? (before, selected, after)
    }

    /// Chromium's text-marker route to the caret: `AXSelectedTextMarkerRange` → `AXBoundsForTextMarkerRange`.
    func selectedTextMarkerBounds(_ element: AXUIElement) -> CGRect? {
        guard let range = attribute(element, AXName.selectedTextMarkerRange) else { return nil }
        return parameterized(element, AXName.boundsForTextMarkerRange, range).flatMap(Self.rect(from:))
    }

    /// Bounds of the character just before the caret, through text markers (Chromium). Used when
    /// the collapsed caret range comes back as the whole line or field box.
    func previousCharacterMarkerBounds(_ element: AXUIElement) -> CGRect? {
        guard let selection = attribute(element, AXName.selectedTextMarkerRange),
              CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() else { return nil }
        let caret = AXTextMarkerRangeCopyStartMarker(unsafeDowncast(selection, to: AXTextMarkerRange.self))
        guard let previous = parameterized(element, AXName.previousTextMarkerForTextMarker, caret),
              CFGetTypeID(previous) == AXTextMarkerGetTypeID(),
              let range = parameterized(element, AXName.textMarkerRangeForUnorderedTextMarkers,
                                        [previous, caret] as CFArray) else { return nil }
        return parameterized(element, AXName.boundsForTextMarkerRange, range).flatMap(Self.rect(from:))
    }

    /// Bounds of `word`, which starts `textToCaret` before the collapsed caret, through text markers
    /// (Chromium, Electron: their index ranges answer with the whole field). The marker range is
    /// checked to read as `textToCaret`, then as `word`, before its bounds are used. Tries the
    /// marker index first, then walks markers one character at a time (short spans only).
    func markerBoundsBehindCaret(_ element: AXUIElement, textToCaret: String, word: String) -> CGRect? {
        guard !word.isEmpty, textToCaret.hasPrefix(word),
              let selection = attribute(element, AXName.selectedTextMarkerRange),
              CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() else { return nil }
        let caret = AXTextMarkerRangeCopyStartMarker(unsafeDowncast(selection, to: AXTextMarkerRange.self))
        func range(_ a: AXTextMarker, _ b: AXTextMarker) -> CFTypeRef? {
            parameterized(element, AXName.textMarkerRangeForUnorderedTextMarkers, [a, b] as CFArray)
        }
        func text(_ r: CFTypeRef) -> String? {
            guard let v = parameterized(element, AXName.stringForTextMarkerRange, r),
                  CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
            return unsafeDowncast(v, to: CFString.self) as String
        }
        func marker(_ v: CFTypeRef?) -> AXTextMarker? {
            guard let v, CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
            return unsafeDowncast(v, to: AXTextMarker.self)
        }
        func wordBounds(start: AXTextMarker, end: AXTextMarker) -> CGRect? {
            guard let toCaret = range(start, caret), let read = text(toCaret),
                  Self.sameText(read, textToCaret),
                  let wordRange = range(start, end), let readWord = text(wordRange), Self.sameText(readWord, word)
            else { return nil }
            return parameterized(element, AXName.boundsForTextMarkerRange, wordRange).flatMap(Self.rect(from:))
        }
        // 1. Marker index (UTF-16 offsets in the host's text).
        if let indexValue = parameterized(element, AXName.indexForTextMarker, caret),
           CFGetTypeID(indexValue) == CFNumberGetTypeID() {
            let index = (indexValue as! NSNumber).intValue
            let startIndex = index - textToCaret.utf16.count
            if startIndex >= 0,
               let start = marker(parameterized(element, AXName.textMarkerForIndex, NSNumber(value: startIndex))),
               let end = marker(parameterized(element, AXName.textMarkerForIndex,
                                              NSNumber(value: startIndex + word.utf16.count))),
               let rect = wordBounds(start: start, end: end) {
                return rect
            }
        }
        // 2. Walk back one character at a time.
        guard textToCaret.count <= Self.maxMarkerWalk else { return nil }
        var start = caret
        for _ in 0..<textToCaret.count {
            guard let previous = marker(parameterized(element, AXName.previousTextMarkerForTextMarker, start)) else { return nil }
            start = previous
        }
        var end = start
        for _ in 0..<word.count {
            guard let next = marker(parameterized(element, AXName.nextTextMarkerForTextMarker, end)) else { return nil }
            end = next
        }
        return wordBounds(start: start, end: end)
    }

    /// Most characters walked marker by marker for a word's bounds.
    static let maxMarkerWalk = 160

    private static func sameText(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            // Line breaks dropped: marker text runs paragraphs together (`ParagraphBreaks`).
            String(s.replacingOccurrences(of: "\u{00A0}", with: " ").filter { !$0.isNewline })
        }
        return norm(a) == norm(b)
    }

    func string(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard location >= 0, length >= 0, let param = Self.rangeValue(location: location, length: length),
              let v = parameterized(element, AXName.stringForRange, param),
              CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return unsafeDowncast(v, to: CFString.self) as String
    }

    func attributedString(_ element: AXUIElement, location: Int, length: Int) -> NSAttributedString? {
        guard location >= 0, length > 0, let param = Self.rangeValue(location: location, length: length),
              let v = parameterized(element, AXName.attributedStringForRange, param),
              CFGetTypeID(v) == CFAttributedStringGetTypeID() else { return nil }
        return unsafeDowncast(v, to: CFAttributedString.self) as NSAttributedString
    }

    /// The character just before the caret with its attributes, through text markers: the route
    /// for editable web areas (Mail's compose body), which don't answer index-based ranges.
    func attributedCharacterBeforeCaretViaMarkers(_ element: AXUIElement) -> NSAttributedString? {
        guard let selection = attribute(element, AXName.selectedTextMarkerRange),
              CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() else { return nil }
        let caret = AXTextMarkerRangeCopyStartMarker(unsafeDowncast(selection, to: AXTextMarkerRange.self))
        guard let previous = parameterized(element, AXName.previousTextMarkerForTextMarker, caret),
              CFGetTypeID(previous) == AXTextMarkerGetTypeID(),
              let range = parameterized(element, AXName.textMarkerRangeForUnorderedTextMarkers, [previous, caret] as CFArray),
              let v = parameterized(element, AXName.attributedStringForTextMarkerRange, range),
              CFGetTypeID(v) == CFAttributedStringGetTypeID() else { return nil }
        return unsafeDowncast(v, to: CFAttributedString.self) as NSAttributedString
    }

    // MARK: AXValue conversion

    static func rangeValue(location: Int, length: Int) -> AXValue? {
        var r = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &r)
    }

    private static func axValue(_ v: CFTypeRef, _ type: AXValueType) -> AXValue? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = unsafeDowncast(v, to: AXValue.self)
        return AXValueGetType(ax) == type ? ax : nil
    }

    static func range(from v: CFTypeRef) -> CFRange? {
        guard let ax = axValue(v, .cfRange) else { return nil }
        var r = CFRange()
        return AXValueGetValue(ax, .cfRange, &r) ? r : nil
    }

    static func rect(from v: CFTypeRef) -> CGRect? {
        guard let ax = axValue(v, .cgRect) else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(ax, .cgRect, &r) ? r : nil
    }

    static func point(from v: CFTypeRef) -> CGPoint? {
        guard let ax = axValue(v, .cgPoint) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ax, .cgPoint, &p) ? p : nil
    }

    static func size(from v: CFTypeRef) -> CGSize? {
        guard let ax = axValue(v, .cgSize) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ax, .cgSize, &s) ? s : nil
    }
}

/// Debug-only logging. Callers pass roles, qualities, reasons, and timings only, never field
/// text, titles, identifiers, placeholders, or URLs.
struct FocusLog: Sendable {
    let enabled: @Sendable () -> Bool
    private let logger = Logger(subsystem: "Hunch", category: "focus")

    init(enabled: @escaping @Sendable () -> Bool) { self.enabled = enabled }

    func debug(_ message: @autoclosure () -> String) {
        guard enabled() else { return }
        let text = message()
        logger.debug("\(text, privacy: .private)")
    }
}
