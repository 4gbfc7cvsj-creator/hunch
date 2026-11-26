import HunchCore
import Testing
@testable import HunchSession

@Suite struct TypedWordsTests {
    @Test func countsWordsOnTheCaretLineOnly() {
        #expect(TypedWords.onCurrentLine("") == 0)
        #expect(TypedWords.onCurrentLine("Hello") == 1)
        #expect(TypedWords.onCurrentLine("This i") == 2)
        #expect(TypedWords.onCurrentLine("Long paragraph here.\n") == 0)
        #expect(TypedWords.onCurrentLine("Long paragraph here.\nNew start") == 2)
        #expect(TypedWords.onCurrentLine("- ") == 0)
        #expect(TypedWords.onCurrentLine("2. ok") == 2)
    }

    @Test func unspacedScriptsCountPerTwoCharacters() {
        #expect(TypedWords.onCurrentLine("我") == 0)
        #expect(TypedWords.onCurrentLine("我今天") == 1)
        #expect(TypedWords.onCurrentLine("我今天想") == 2)
    }
}

@Suite struct MinWordsGateTests {
    private func context(_ before: String, minWords: Int) -> SessionEvent {
        .context(Fixture.context(before), Fixture.geometry, midLineEnabled: false, minWords: minWords)
    }

    @Test func noRequestUntilEnoughWords() {
        var d = Driver()
        #expect(d.send(context("", minWords: 2)).requests.isEmpty)
        #expect(d.send(context("Hello", minWords: 2)).requests.isEmpty)
        #expect(d.send(context("Hello the", minWords: 2)).requests.count == 1)
    }

    @Test func deletingBackBelowTheMinimumHidesTheGhost() {
        var d = Driver()
        d.send(context("Hello the", minWords: 2))
        d.answer("re friend")
        #expect(d.session.visibleGhost != nil)
        let back = d.send(context("Hello", minWords: 2))
        #expect(back.hides)
        #expect(d.session.visibleGhost == nil)
    }

    @Test func zeroDisablesTheGate() {
        var d = Driver()
        #expect(d.send(context("", minWords: 0)).requests.count == 1)
    }
}

@Suite struct CodeFloorTests {
    @Test func codeUnitsCountTokensOrCharacters() {
        #expect(TypedWords.codeUnitsOnCurrentLine("") == 0)
        #expect(TypedWords.codeUnitsOnCurrentLine("(") == 1)
        #expect(TypedWords.codeUnitsOnCurrentLine("x") == 1)
        #expect(TypedWords.codeUnitsOnCurrentLine("ab") == 1)
        #expect(TypedWords.codeUnitsOnCurrentLine("return") == 2)
        #expect(TypedWords.codeUnitsOnCurrentLine("x =") == 2)
        #expect(TypedWords.codeUnitsOnCurrentLine("if (") == 2)
        #expect(TypedWords.codeUnitsOnCurrentLine("foo.bar(") == 4)
        #expect(TypedWords.codeUnitsOnCurrentLine("let x = ") == 3)
        // Only the caret's line counts; indentation does not.
        #expect(TypedWords.codeUnitsOnCurrentLine("func f() {\n    ") == 0)
        #expect(TypedWords.codeUnitsOnCurrentLine("func f() {\n    return") == 2)
    }

    @Test func surfacePicksTheUnit() {
        #expect(TypedWords.onCurrentLine("return", surface: .code) == 2)
        #expect(TypedWords.onCurrentLine("return", surface: .unknown) == 1)
        #expect(TypedWords.onCurrentLine("x =", surface: .email) == 1)
    }

    private func context(_ before: String, after: String = "", surface: SurfaceKind, lineEnd: Bool = true) -> SessionEvent {
        .context(Fixture.context(before, after: after, lineEnd: lineEnd, surface: surface), Fixture.geometry,
                 midLineEnabled: false, minWords: 2)
    }

    @Test func returnAloneIsEnoughContextInCode() {
        var d = Driver()
        #expect(d.send(context("    return", surface: .unknown)).requests.isEmpty)
        #expect(d.send(context("    return", surface: .code)).requests.count == 1)
        var e = Driver()
        #expect(e.send(context("x", surface: .code)).requests.isEmpty)
        #expect(e.send(context("x =", surface: .code)).requests.count == 1)
    }

    @Test func caretBeforeAnAutoClosedCloserPassesTheMidLineGate() {
        // HunchFocus reports the caret in front of ")" as a line end in code (CodeLineEnd); the
        // session then requests with mid-line off. A real mid-line caret is still refused.
        var d = Driver()
        #expect(d.send(context("    print(x", after: ")", surface: .code, lineEnd: true)).requests.count == 1)
        var e = Driver()
        #expect(e.send(context("    print(x", after: ", y)", surface: .code, lineEnd: false)).requests.isEmpty)
    }
}
