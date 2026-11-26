import HunchCore
import Testing
@testable import HunchSession

@Suite struct CompositionTrackerTests {
    static let field = Fixture.fieldA
    static let letter = KeyChord(keyCode: 0)

    private func started(_ before: String = "Hello ") -> CompositionTracker {
        var t = CompositionTracker()
        t.setInputMethodActive(true)
        t.context(field: Self.field, before: before)
        t.keyDown(Self.letter, isCharacter: true)
        return t
    }

    @Test func startsOnCharacterKeyWithPriorText() {
        let t = started()
        #expect(t.composing)
        #expect(t.startBefore == "Hello ")
    }

    @Test func neverComposesWithoutInputMethod() {
        var t = CompositionTracker()
        t.context(field: Self.field, before: "Hello ")
        t.keyDown(Self.letter, isCharacter: true)
        #expect(!t.composing)
        t.setInputMethodActive(true)
        t.setInputMethodActive(false)
        t.keyDown(Self.letter, isCharacter: true)
        #expect(!t.composing)
    }

    @Test func commandAndControlAndNonCharactersDoNotStart() {
        var t = CompositionTracker()
        t.setInputMethodActive(true)
        t.context(field: Self.field, before: "Hi")
        t.keyDown(KeyChord(keyCode: 8, modifiers: 0x100000), isCharacter: true)
        t.keyDown(KeyChord(keyCode: 8, modifiers: 0x40000), isCharacter: true)
        t.keyDown(KeyChord(keyCode: 123), isCharacter: false)
        #expect(!t.composing)
    }

    @Test func composedTextIsWhatFollowsStart() {
        var t = started()
        t.context(field: Self.field, before: "Hello nihao")
        #expect(t.composedText == "nihao")
        #expect(!t.hasPhoneticSymbols)
    }

    @Test func phoneticSymbolsDetected() {
        var t = started("")
        t.context(field: Self.field, before: "ㄋㄧˇ")
        #expect(t.hasPhoneticSymbols)
        #expect(CompositionTracker.hasPhoneticSymbols("ㄅˊ"))
        #expect(CompositionTracker.hasPhoneticSymbols("ˇ"))
        #expect(!CompositionTracker.hasPhoneticSymbols("你好 hello"))
    }

    @Test func endsOnReturnEscapeAndMouse() {
        for end in 0..<4 {
            var t = started()
            t.context(field: Self.field, before: "Hello ni")
            switch end {
            case 0: t.keyDown(KeyChord(keyCode: 36), isCharacter: false)
            case 1: t.keyDown(KeyChord(keyCode: 76), isCharacter: false)
            case 2: t.keyDown(KeyChord(keyCode: 53), isCharacter: false)
            default: t.mouseDown()
            }
            #expect(!t.composing)
            #expect(t.composedText.isEmpty)
        }
    }

    @Test func endsOnFieldChangeFocusLossAndImeOff() {
        var a = started()
        a.context(field: Fixture.fieldB, before: "Hello ")
        #expect(!a.composing)
        var b = started()
        b.focusLost()
        #expect(!b.composing)
        var c = started()
        c.setInputMethodActive(false)
        #expect(!c.composing)
    }

    @Test func endsWhenTextNoLongerExtendsStart() {
        var t = started()
        t.context(field: Self.field, before: "Hello ni")
        t.context(field: Self.field, before: "Help")
        #expect(!t.composing)
    }

    @Test func endsWhenCompositionDeleted() {
        var t = started()
        t.context(field: Self.field, before: "Hello ni")
        t.context(field: Self.field, before: "Hello ")
        #expect(!t.composing)
    }

    @Test func staleContextEqualToStartDoesNotEndIt() {
        var t = started()
        t.context(field: Self.field, before: "Hello ")
        #expect(t.composing)
        t.context(field: Self.field, before: "Hello n")
        #expect(t.composedText == "n")
    }

    @Test func returnThenNewCharacterStartsFreshComposition() {
        var t = started()
        t.context(field: Self.field, before: "Hello ni")
        t.keyDown(KeyChord(keyCode: 36), isCharacter: false)
        t.keyDown(Self.letter, isCharacter: true)
        #expect(t.composing)
        #expect(t.startBefore == "Hello ni")
    }
}

@Test func latinTypedWithAnInputMethodSelectedIsNotAComposition() {
    #expect(!CompositionTracker.holdsComposedScript("suggestion"))
    #expect(CompositionTracker.holdsComposedScript("這是一個"))
    #expect(CompositionTracker.holdsComposedScript("ㄓㄜˋ"))
    #expect(CompositionTracker.holdsComposedScript("好，"))
}

@Suite struct InputMethodKindTests {
    static let field = Fixture.fieldA

    private func typed(_ kind: InputMethodKind, start: String, then text: String) -> CompositionTracker {
        var t = CompositionTracker()
        t.setInputMethod(kind)
        t.context(field: Self.field, before: start)
        t.keyDown(KeyChord(keyCode: 0), isCharacter: true)
        t.context(field: Self.field, before: start + text)
        return t
    }

    @Test func classifiesSourcesByID() {
        let mode = "TISTypeKeyboardInputMode"
        #expect(InputMethodKind.classify(id: "com.apple.keylayout.US", type: "TISTypeKeyboardLayout") == .plainLayout)
        #expect(InputMethodKind.classify(id: nil, type: nil) == .plainLayout)
        for id in ["com.apple.inputmethod.TCIM.Zhuyin", "com.apple.inputmethod.TCIM.ZhuyinEten",
                   "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "com.example.UnknownIME"] {
            #expect(InputMethodKind.classify(id: id, type: mode) == .buffering, "\(id)")
        }
        for id in ["com.apple.inputmethod.SCIM.ITABC", "com.apple.inputmethod.TCIM.Pinyin",
                   "com.apple.inputmethod.TCIM.Cangjie", "com.apple.inputmethod.TCIM.Jianyi",
                   "com.apple.inputmethod.SCIM.WBX", "com.apple.inputmethod.TCIM.Shuangpin",
                   "com.apple.inputmethod.Korean.2SetKorean"] {
            #expect(InputMethodKind.classify(id: id, type: mode) == .commitsAsTyped, "\(id)")
        }
        // A prefix must end at a dot: "TCIM.PinyinX" is not Pinyin.
        #expect(InputMethodKind.classify(id: "com.apple.inputmethod.TCIM.PinyinX", type: mode) == .buffering)
    }

    /// Zhuyin keeps chosen characters in its buffer: Tab must still finish it with Escape.
    @Test func zhuyinTraditionalCharactersStillNeedFinishing() {
        #expect(typed(.buffering, start: "我說", then: "這個問題").needsFinishBeforeAccept)
        #expect(typed(.buffering, start: "", then: "臺灣，").needsFinishBeforeAccept)
        #expect(typed(.buffering, start: "Hi ", then: "ㄓㄜˋ").needsFinishBeforeAccept)
        #expect(!typed(.buffering, start: "Hi ", then: "there").needsFinishBeforeAccept)
    }

    /// Pinyin / Cangjie already handed these to the app: an Escape would reach the app itself.
    @Test func committedPinyinAndCangjieTextNeedsNoEscape() {
        #expect(!typed(.commitsAsTyped, start: "", then: "你好").needsFinishBeforeAccept)
        #expect(!typed(.commitsAsTyped, start: "我說", then: "這個問題").needsFinishBeforeAccept)
        #expect(!typed(.commitsAsTyped, start: "", then: "臺灣，").needsFinishBeforeAccept)
        #expect(!typed(.commitsAsTyped, start: "", then: "nihao").needsFinishBeforeAccept)
    }

    /// Korean: only the last syllable can still be in the making.
    @Test func hangulOnlyWhenLastSyllableMayBePending() {
        #expect(typed(.commitsAsTyped, start: "", then: "안녕").needsFinishBeforeAccept)
        #expect(typed(.commitsAsTyped, start: "", then: "ㅎ").needsFinishBeforeAccept)
        #expect(!typed(.commitsAsTyped, start: "", then: "안녕 ").needsFinishBeforeAccept)
        #expect(!typed(.commitsAsTyped, start: "", then: "안녕.").needsFinishBeforeAccept)
    }

    @Test func plainLayoutNeverNeedsFinishing() {
        #expect(!typed(.plainLayout, start: "", then: "這個").needsFinishBeforeAccept)
    }
}
