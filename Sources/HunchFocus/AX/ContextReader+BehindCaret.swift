import AppKit
import ApplicationServices
import Foundation
import HunchCore
import HunchPolicy

/// Autocorrect catch-up through Accessibility: select a word some way before the caret, after
/// checking the host holds exactly the expected text from that word up to the caret, and put the
/// caret back afterwards. Nothing here types; selecting and moving the caret never changes text.
extension ContextReader {
    /// Checks that the `expectedSpan.utf16.count` units before the collapsed caret read as
    /// `expectedSpan`, then selects its first `wordUTF16` units and checks the selection reads as
    /// `expectedWord`. Returns the caret's offset from before. On any mismatch the caret is put back.
    func selectBehindCaret(_ element: AXUIElement, field: FieldID, pass: SecureGatePass,
                           expectedSpan: String, expectedWord: String) -> Result<Int, CaretSelection.Failure> {
        guard pass.isValid(for: field), Int(bitPattern: UInt(CFHash(element))) == field.elementHash else {
            return .failure(.focusMoved)
        }
        guard let current = client.range(element, AXName.selectedTextRange), current.location >= 0 else {
            return .failure(.noRange)
        }
        guard current.length == 0 else { return .failure(.notCollapsed) }
        let caret = current.location
        let spanUTF16 = expectedSpan.utf16.count, wordUTF16 = expectedWord.utf16.count
        guard let word = BehindCaret.wordRange(caret: caret, span: spanUTF16, word: wordUTF16),
              let value = AXClient.rangeValue(location: word.location, length: word.length) else {
            return .failure(.outOfBounds)
        }
        // The text from the word to the caret must be exactly what was typed since the fix was shown.
        guard let span = client.string(element, location: caret - spanUTF16, length: spanUTF16) else {
            return .failure(.unreadable)
        }
        guard CaretSelection.matches(span, expected: expectedSpan) else { return .failure(.mismatch) }
        func restore() {
            if let back = AXClient.rangeValue(location: caret, length: 0) {
                client.set(element, AXName.selectedTextRange, back)
            }
        }
        guard client.set(element, AXName.selectedTextRange, value) else {
            restore()
            return .failure(.setFailed)
        }
        guard let applied = client.range(element, AXName.selectedTextRange),
              applied.location == word.location, applied.length == word.length else {
            restore()
            return .failure(.notApplied)
        }
        guard let selected = client.string(element, location: word.location, length: word.length)
                ?? client.string(element, AXName.selectedText) else {
            restore()
            return .failure(.unreadable)
        }
        guard CaretSelection.matches(selected, expected: expectedWord) else {
            restore()
            return .failure(.mismatch)
        }
        return .success(caret)
    }

    /// Collapses the caret at `location` and checks the `expectedBefore.utf16.count` units before it
    /// read as `expectedBefore`. On success returns the bounds of the last `highlightUTF16` units of
    /// `expectedBefore`'s first part (the replaced word), in AppKit coordinates, when the host gives
    /// usable ones.
    func placeCaret(_ element: AXUIElement, field: FieldID, pass: SecureGatePass, location: Int,
                    expectedBefore: String, highlightStartBack: Int, highlightUTF16: Int)
        -> Result<CGRect?, CaretSelection.Failure> {
        guard pass.isValid(for: field), Int(bitPattern: UInt(CFHash(element))) == field.elementHash else {
            return .failure(.focusMoved)
        }
        guard location >= 0, let value = AXClient.rangeValue(location: location, length: 0) else {
            return .failure(.outOfBounds)
        }
        if let current = client.range(element, AXName.selectedTextRange),
           current.location != location || current.length != 0 {
            guard client.set(element, AXName.selectedTextRange, value) else { return .failure(.setFailed) }
        }
        guard let applied = client.range(element, AXName.selectedTextRange),
              applied.location == location, applied.length == 0 else { return .failure(.notApplied) }
        let count = expectedBefore.utf16.count
        guard let text = client.string(element, location: location - count, length: count) else {
            return .failure(.unreadable)
        }
        guard CaretSelection.matches(text, expected: expectedBefore) else { return .failure(.mismatch) }
        return .success(wordRect(element, location: location - highlightStartBack, length: highlightUTF16))
    }

    /// Moves the collapsed caret `forward` UTF-16 units on (over text the host already holds) and
    /// checks the text before it then reads as `expectedBefore`. Undoing a fix after the user clicked
    /// into it: the caret goes back to the end of what was typed first.
    func moveCaretForward(_ element: AXUIElement, field: FieldID, pass: SecureGatePass, forward: Int,
                          expectedBefore: String) -> Result<Void, CaretSelection.Failure> {
        guard pass.isValid(for: field), Int(bitPattern: UInt(CFHash(element))) == field.elementHash else {
            return .failure(.focusMoved)
        }
        guard let current = client.range(element, AXName.selectedTextRange), current.location >= 0 else {
            return .failure(.noRange)
        }
        guard current.length == 0 else { return .failure(.notCollapsed) }
        return placeCaret(element, field: field, pass: pass, location: current.location + forward,
                          expectedBefore: expectedBefore, highlightStartBack: 0, highlightUTF16: 0).map { _ in () }
    }

    /// Bounds of `length` units starting `back` units before the collapsed caret, for highlighting
    /// a word just changed at the caret. Nil when the host gives none worth drawing.
    /// Bounds of `word`, which starts `textToCaret` before the collapsed caret: the index range
    /// first (rejected when much wider than the word: hosts answering with the line or field box),
    /// then Chromium text markers, checked to read as the expected text.
    func wordBoundsBehindCaret(_ element: AXUIElement, field: FieldID, pass: SecureGatePass,
                               textToCaret: String, word: String) -> Result<CGRect, BehindCaret.BoundsMiss> {
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        switch boundsBehindCaret(element, field: field, pass: pass, back: textToCaret.utf16.count,
                                 length: word.utf16.count) {
        case .success(let rect) where BehindCaret.fitsWord(rect, characters: word.count):
            return .success(rect)
        case .failure(.focusMoved):
            return .failure(.focusMoved)
        case .failure(.notCollapsed):
            return .failure(.notCollapsed)
        default:
            guard let raw = client.markerBoundsBehindCaret(element, textToCaret: textToCaret, word: word) else {
                return .failure(.noBounds)
            }
            guard let usable = BehindCaret.usableWordRect(raw), BehindCaret.fitsWord(usable, characters: word.count)
            else { return .failure(.unusable) }
            return .success(CaretMath.flipToAppKit(usable, primaryScreenHeight: screenHeight))
        }
    }

    func boundsBehindCaret(_ element: AXUIElement, field: FieldID, pass: SecureGatePass,
                           back: Int, length: Int) -> Result<CGRect, BehindCaret.BoundsMiss> {
        guard pass.isValid(for: field), Int(bitPattern: UInt(CFHash(element))) == field.elementHash else {
            return .failure(.focusMoved)
        }
        guard let current = client.range(element, AXName.selectedTextRange) else { return .failure(.noCaret) }
        guard current.length == 0 else { return .failure(.notCollapsed) }
        let location = current.location - back
        guard location >= 0, length > 0,
              let raw = client.bounds(element, location: location, length: length) else { return .failure(.noBounds) }
        guard let usable = BehindCaret.usableWordRect(raw) else { return .failure(.unusable) }
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        return .success(CaretMath.flipToAppKit(usable, primaryScreenHeight: screenHeight))
    }

    private func wordRect(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        guard location >= 0, length > 0,
              let raw = BehindCaret.usableWordRect(client.bounds(element, location: location, length: length))
        else { return nil }
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CaretMath.flipToAppKit(raw, primaryScreenHeight: screenHeight)
    }
}
