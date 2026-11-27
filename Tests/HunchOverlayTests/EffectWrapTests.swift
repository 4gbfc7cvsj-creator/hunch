import AppKit
import HunchCore
import Testing
@testable import HunchOverlay

@Suite struct EffectWrapTests {
    /// Every character is 1 point wide.
    let measure: (String) -> CGFloat = { CGFloat($0.count) }

    @Test func shortTextStaysOnTheCaretLine() {
        #expect(EffectWrap.lines(" see you soon", firstWidth: 40, width: 60, measure: measure) == [" see you soon"])
    }

    @Test func wrapsAtSpacesFirstLineShorter() {
        let lines = EffectWrap.lines("one two three four", firstWidth: 8, width: 10, measure: measure)
        #expect(lines == ["one two", "three four"])
    }

    @Test func firstWordTooWideForTheCaretGoesToTheNextLine() {
        let lines = EffectWrap.lines("hello there", firstWidth: 3, width: 20, measure: measure)
        #expect(lines == ["", "hello there"])
    }

    @Test func wordWiderThanALineBreaksAnywhere() {
        let lines = EffectWrap.lines("abcdefghij", firstWidth: 4, width: 4, measure: measure)
        #expect(lines == ["abcd", "efgh", "ij"])
    }

    @Test func traditionalChineseWrapsByCharacter() {
        let lines = EffectWrap.lines("我們明天見面吧", firstWidth: 3, width: 4, measure: measure)
        #expect(lines == ["我們明", "天見面吧"])
    }

    @Test func lineBreaksStartNewLinesAndKeepBlankOnes() {
        let lines = EffectWrap.lines("Hi Alex,\n\nThanks", firstWidth: 50, width: 50, measure: measure)
        #expect(lines == ["Hi Alex,", "", "Thanks"])
    }

    @Test func wholeLineEffectsStartTogether() {
        var fade = PopInRecipe()
        fade.fadeOn = true
        #expect(EffectWrap.lineDelays(fade, counts: [10, 10, 10]) == [0, 0, 0])
    }

    @Test func sweepingEffectsCrossLineByLineWithinTheCap() {
        var type = PopInRecipe()
        type.typewriterOn = true
        type.typewriterMsPerCharacter = 10
        type.typewriterMaxMs = 10_000
        let delays = EffectWrap.lineDelays(type, counts: [10, 10, 10])
        #expect(abs(delays[1] - 0.1) < 1e-9 && abs(delays[2] - 0.2) < 1e-9)
        let capped = EffectWrap.lineDelays(type, counts: Array(repeating: 100, count: 10), maxStagger: 1.2)
        #expect(abs(capped.last! - 1.2) < 1e-9)
    }

    @Test func streamedLinesWaitForTheLineBefore() {
        var type = PopInRecipe()
        type.typewriterOn = true
        type.typewriterMsPerCharacter = 10
        type.typewriterMaxMs = 10_000
        #expect(abs(EffectWrap.streamGap(type, characters: 10) - 0.1) < 1e-9)
        var fade = PopInRecipe()
        fade.fadeOn = true
        // A whole-line effect still hands over only once the line has settled, never at once.
        #expect(EffectWrap.streamGap(fade, characters: 10) == PopIn.totalDuration(fade, characters: 10))
        #expect(EffectWrap.streamGap(fade, characters: 10) > 0)
        #expect(EffectWrap.streamGap(PopInRecipe(), characters: 10) == 0)
    }

    @Test func noneSettlesAtOnce() {
        #expect(EffectWrap.settleTime(PopInRecipe(), counts: [5], delays: [0]) == 0)
    }

    @Test func streamingWaitsForTheWordBeingWritten() {
        #expect(EffectWrap.readyEnd("Thanks for the upd" as NSString, from: 0, finished: false) == 15)
        #expect(EffectWrap.readyEnd("Thanks for the upd" as NSString, from: 15, finished: false) == 15)
        #expect(EffectWrap.readyEnd("Thanks for the upd" as NSString, from: 15, finished: true) == 18)
        #expect(EffectWrap.readyEnd("謝謝你的" as NSString, from: 0, finished: false) == 4)
    }
}
