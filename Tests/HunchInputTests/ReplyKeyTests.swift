import HunchCore
import Testing
@testable import HunchInput

@Suite struct ReplyKeyTests {
    private let tab = KeyChord(keyCode: 48)
    private let ret = KeyChord(keyCode: 36)
    private let enter = KeyChord(keyCode: 76)
    private let esc = KeyChord(keyCode: 53)

    @Test func nothingIsTakenWhileTheBubbleIsHidden() {
        for chord in [tab, ret, esc] {
            #expect(ReplyKeyRules.decide(chord, shown: false, highlighted: true) == nil)
        }
    }

    @Test func tabAndEscapeWhileShown() {
        #expect(ReplyKeyRules.decide(tab, shown: true, highlighted: false) == .next)
        #expect(ReplyKeyRules.decide(tab, shown: true, highlighted: true) == .next)
        #expect(ReplyKeyRules.decide(esc, shown: true, highlighted: false) == .dismiss)
    }

    @Test func returnInsertsOnlyAfterTab() {
        #expect(ReplyKeyRules.decide(ret, shown: true, highlighted: false) == nil)
        #expect(ReplyKeyRules.decide(ret, shown: true, highlighted: true) == .insert)
        #expect(ReplyKeyRules.decide(enter, shown: true, highlighted: true) == .insert)
    }

    @Test func modifiedAndOtherKeysPassThrough() {
        #expect(ReplyKeyRules.decide(KeyChord(keyCode: 48, modifiers: 0x20000), shown: true, highlighted: true) == nil)
        #expect(ReplyKeyRules.decide(KeyChord(keyCode: 36, modifiers: 0x20000), shown: true, highlighted: true) == nil)
        #expect(ReplyKeyRules.decide(KeyChord(keyCode: 0), shown: true, highlighted: true) == nil)
    }

    @Test func arrowsStepOnlyAlongTheLayoutOnceHighlighted() {
        let up = KeyChord(keyCode: 126, modifiers: 0), down = KeyChord(keyCode: 125, modifiers: 0)
        let left = KeyChord(keyCode: 123, modifiers: 0), right = KeyChord(keyCode: 124, modifiers: 0)
        // Before Tab picks a reply, arrows are the app's.
        #expect(ReplyKeyRules.decide(down, shown: true, highlighted: false, arrows: [.vertical, .horizontal]) == nil)
        #expect(ReplyKeyRules.decide(down, shown: true, highlighted: true, arrows: .vertical) == .step(forward: true))
        #expect(ReplyKeyRules.decide(up, shown: true, highlighted: true, arrows: .vertical) == .step(forward: false))
        #expect(ReplyKeyRules.decide(left, shown: true, highlighted: true, arrows: .vertical) == nil)
        #expect(ReplyKeyRules.decide(right, shown: true, highlighted: true, arrows: .horizontal) == .step(forward: true))
        #expect(ReplyKeyRules.decide(left, shown: true, highlighted: true, arrows: .horizontal) == .step(forward: false))
        #expect(ReplyKeyRules.decide(up, shown: true, highlighted: true, arrows: .horizontal) == nil)
        // Arrow keys carry the Fn and numeric-pad flags; those don't count as modifiers.
        #expect(ReplyKeyRules.decide(KeyChord(keyCode: 125, modifiers: 0xA00000), shown: true, highlighted: true,
                                     arrows: .vertical) == .step(forward: true))
        #expect(ReplyKeyRules.decide(KeyChord(keyCode: 125, modifiers: 0x20000), shown: true, highlighted: true,
                                     arrows: .vertical) == nil)
    }
}
