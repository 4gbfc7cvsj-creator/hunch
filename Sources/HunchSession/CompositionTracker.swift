import HunchCore

/// Guesses whether the user is in the middle of an input-method composition (Zhuyin, Pinyin, ...)
/// in hosts that expose the uncommitted characters in their text without marking them. Pure: fed
/// with key-downs, mouse-downs, field text and the input-method flag. While the flag is off it never
/// reports a composition.
public struct CompositionTracker: Sendable {
    public private(set) var composing = false
    /// Field text before the caret at the moment the composition began.
    public private(set) var startBefore = ""
    public private(set) var field: FieldID?

    private var kind = InputMethodKind.plainLayout
    private var latest: (field: FieldID, before: String)?
    /// The field text has differed from `startBefore` since the composition began; an equal text
    /// before that is just a context read older than the first key.
    private var grew = false

    public init() {}

    /// Text typed since the composition began, empty when not composing or the field moved on.
    public var composedText: String {
        guard composing, field == latest?.field, let before = latest?.before,
              before.hasPrefix(startBefore) else { return "" }
        return String(before.dropFirst(startBefore.count))
    }

    /// True once the composition holds Bopomofo letters or tone marks: a syllable not yet chosen.
    public var hasPhoneticSymbols: Bool { Self.hasPhoneticSymbols(composedText) }

    /// True when the composed text holds characters an input method actually composes (Chinese
    /// characters, Zhuyin, kana, Hangul, full-width punctuation). Latin letters typed while an
    /// input method is selected (its English mode) are final as typed: no composition to cancel.
    public var holdsComposedScript: Bool { Self.holdsComposedScript(composedText) }

    /// True when Tab-accept must first finish the composition (Escape), because the input method
    /// may still be holding the composed characters. A buffering input method (Zhuyin) holds
    /// everything since the composition began. One that commits as it goes (Pinyin, Cangjie,
    /// Korean) has already handed its characters to the app, so an Escape would reach the app
    /// itself (alert sound, a cancelled edit, a closed dialog); only a trailing Hangul syllable can
    /// still be in the making.
    public var needsFinishBeforeAccept: Bool {
        guard composing else { return false }
        switch kind {
        case .plainLayout: return false
        case .buffering: return holdsComposedScript
        case .commitsAsTyped: return composedText.last.map(Self.isHangul) ?? false
        }
    }

    static func isHangul(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF: true
            default: false
            }
        }
    }

    public static func holdsComposedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x312F, 0x3130...0x318F, 0x31A0...0x31BF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0x1100...0x11FF, 0xF900...0xFAFF,
                 0xFF00...0xFFEF, 0x20000...0x2FFFF, 0x02CA, 0x02C7, 0x02CB, 0x02D9: true
            default: false
            }
        }
    }

    public static func hasPhoneticSymbols(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3100...0x312F, 0x31A0...0x31BF, 0x02CA, 0x02C7, 0x02CB, 0x02D9: true
            default: false
            }
        }
    }

    public mutating func setInputMethod(_ kind: InputMethodKind) {
        self.kind = kind
        if !kind.isInputMethod { end() }
    }

    /// Shorthand for tests and callers that only know on/off: on counts as a buffering input method.
    public mutating func setInputMethodActive(_ active: Bool) {
        setInputMethod(active ? .buffering : .plainLayout)
    }

    public mutating func keyDown(_ chord: KeyChord, isCharacter: Bool) {
        if composing {
            if chord.keyCode == 36 || chord.keyCode == 76 || chord.keyCode == 53 { end() }
            return
        }
        guard kind.isInputMethod, isCharacter, chord.modifiers & (0x100000 | 0x40000) == 0,
              let latest else { return }
        composing = true
        startBefore = latest.before
        field = latest.field
        grew = false
    }

    public mutating func mouseDown() { end() }

    public mutating func focusLost() {
        latest = nil
        end()
    }

    public mutating func context(field newField: FieldID, before: String) {
        latest = (newField, before)
        guard composing else { return }
        if newField != field || !before.hasPrefix(startBefore) {
            end()
        } else if before == startBefore {
            if grew { end() }
        } else {
            grew = true
        }
    }

    public mutating func end() {
        composing = false
        startBefore = ""
        field = nil
        grew = false
    }
}
