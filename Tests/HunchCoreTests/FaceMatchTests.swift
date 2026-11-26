import CoreGraphics
import Testing
@testable import HunchCore

@Suite struct FaceMatchTests {
    // x-heights at 16 pt, roughly: system 8.4, Avenir Next 7.5, Helvetica Neue 8.3.
    private let faces: [String: CGFloat] = ["System": 8.4, "Avenir Next": 7.5, "Helvetica Neue": 8.3]

    @Test func discordShortLettersPickAvenirNext() {
        // Discord reports no font name; its gg sans measures about 7.5 pt at 16 pt.
        #expect(FaceMatch.pickFace(host: 7.55, xHeights: faces) == "Avenir Next")
    }

    @Test func systemFaceKeptWhenItMatches() {
        #expect(FaceMatch.pickFace(host: 8.3, xHeights: faces) == nil)
        #expect(FaceMatch.pickFace(host: 8.15, xHeights: faces) == nil)   // within 0.3 pt
    }

    @Test func anotherFaceMustBeClearlyBetter() {
        // System is 0.35 off, Avenir 0.2 off: not 0.2 pt better, so the system face stays.
        #expect(FaceMatch.pickFace(host: 7.7, xHeights: ["System": 8.05, "Avenir Next": 7.5]) == nil)
    }

    @Test func noPickWithoutTheSystemMeasurement() {
        #expect(FaceMatch.pickFace(host: 7.5, xHeights: ["Avenir Next": 7.5]) == nil)
    }

    @Test func smallSizeGapsAreLeftAlone() {
        #expect(FaceMatch.suggestedSizeFactor(host: 8.3, drawn: 8.0) == nil)    // 0.3 pt
        #expect(FaceMatch.suggestedSizeFactor(host: 15.6, drawn: 15.0) == nil)  // 0.6 pt but 4%
    }

    @Test func largeSizeGapsSuggestACorrectionWithinTenPercent() {
        let up = FaceMatch.suggestedSizeFactor(host: 8.6, drawn: 8.0)
        #expect(up != nil && abs(up! - 1.075) < 0.001)
        #expect(FaceMatch.suggestedSizeFactor(host: 12, drawn: 8) == 1.1)
        #expect(FaceMatch.suggestedSizeFactor(host: 4, drawn: 8) == 0.9)
    }

    @Test func oneMismatchIsNotEnough() {
        #expect(FaceMatch.nextSizeFactor(current: 1, previousSuggestion: nil, suggestion: 1.08) == 1)
    }

    @Test func twoAgreeingMismatchesConfirm() {
        let f = FaceMatch.nextSizeFactor(current: 1, previousSuggestion: 1.07, suggestion: 1.09)
        #expect(abs(f - 1.08) < 0.0001)
        // Opposite directions or too far apart don't confirm.
        #expect(FaceMatch.confirm(1.06, 0.94) == nil)
        #expect(FaceMatch.confirm(1.02, 1.08) == nil)
    }

    @Test func agreementClearsACorrection() {
        #expect(FaceMatch.nextSizeFactor(current: 1.08, previousSuggestion: 1.08, suggestion: nil) == 1)
        // A lone new mismatch keeps the correction in force.
        #expect(FaceMatch.nextSizeFactor(current: 1.08, previousSuggestion: nil, suggestion: 0.93) == 1.08)
    }

    @Test func bookAppliesTheChoiceToHintsOfThatAppAndSize() {
        let book = FaceChoiceBook()
        book.set(FaceChoice(family: "Avenir Next"), for: .init(bundleID: "com.hnc.Discord", pointSize: 16))
        // Discord's current report: a size, no name.
        let applied = book.apply(to: FontHint(pointSize: 16), bundleID: "com.hnc.Discord")
        #expect(applied?.measuredFamily == "Avenir Next")
        #expect(FontLookalike.standIn(for: applied) == "Avenir Next")
        // Another app or size is untouched.
        #expect(book.apply(to: FontHint(pointSize: 16), bundleID: "com.apple.mail")?.measuredFamily == nil)
        #expect(book.apply(to: FontHint(pointSize: 13), bundleID: "com.hnc.Discord")?.measuredFamily == nil)
        #expect(book.apply(to: nil, bundleID: "com.apple.mail") == nil)
    }

    @Test func clearedChoiceRemovesAStaleFace() {
        let book = FaceChoiceBook()
        var stale = FontHint(pointSize: 16)
        stale.measuredFamily = "Avenir Next"
        stale.sizeFactor = 1.05
        let out = book.apply(to: stale, bundleID: "com.hnc.Discord")
        #expect(out?.measuredFamily == nil)
        #expect(out?.sizeFactor == 1)
    }

    @Test func reportedNameStillWinsOverMeasurement() {
        var hint = FontHint(family: "gg sans", pointSize: 16)
        hint.measuredFamily = "Helvetica Neue"
        #expect(FontLookalike.standIn(for: hint) == "Avenir Next")
    }
}

@Suite struct FaceChoiceFontKeyTests {
    @Test func tagIsStableAndDiffersPerFont() {
        #expect(FaceChoiceBook.fontTag(FontHint(name: "ArialMT")) == FaceChoiceBook.fontTag(FontHint(name: "ArialMT")))
        #expect(FaceChoiceBook.fontTag(FontHint(name: "ArialMT")) != FaceChoiceBook.fontTag(FontHint(name: "Georgia")))
        #expect(FaceChoiceBook.fontTag(FontHint(family: "Georgia")) != FaceChoiceBook.fontTag(FontHint(name: "ArialMT")))
        #expect(FaceChoiceBook.fontTag(nil) == "-")
        // A fixed value, so saved keys survive relaunches.
        #expect(FaceChoiceBook.fontTag(FontHint(name: "a")) == "e40c292c")
    }

    @Test func choiceForOneFontIsNotAppliedToAnother() {
        let book = FaceChoiceBook()
        let web = FontHint(name: "CustomWebFont", pointSize: 16)
        var chosen = FaceChoice(family: "Avenir Next")
        chosen.sizeFactor = 0.93
        book.set(chosen, for: .init(bundleID: "com.google.Chrome", pointSize: 16, fontTag: FaceChoiceBook.fontTag(web)))
        #expect(book.apply(to: web, bundleID: "com.google.Chrome")?.sizeFactor == 0.93)
        let arial = book.apply(to: FontHint(name: "ArialMT", pointSize: 16), bundleID: "com.google.Chrome")
        #expect(arial?.sizeFactor == 1)
        #expect(arial?.measuredFamily == nil)
    }
}
