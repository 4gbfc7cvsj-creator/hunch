import HunchCore
import Testing
@testable import HunchText

private let dictionary = FakeSpell(["the", "return", "value", "hello", "world", "let", "const"])

private func run(_ raw: String, before: String, after: String = "", surface: SurfaceKind = .code, maxWords: Int = 4,
                 allowNewlines: Bool = false, checker: (any SpellChecking)? = dictionary) -> PostOutcome {
    DefaultPostProcessor(spellChecker: checker, prefaceTexts: [])
        .process(raw, meanLogProb: nil,
                 context: PostContext(before: before, after: after, requiredPrefix: "", allowNewlines: allowNewlines,
                                      maxWords: maxWords, preferredHanScript: .traditional, surface: surface))
}

// MARK: - Rules skipped in code

@Suite struct CodeProfileSkipsProseRules {
    @Test func identifiersAreNotTypos() {
        // Prose: "strncpy" after the caret word is a misspelling; code: shown as written.
        #expect(run(" the value", before: "int n = strncpy", surface: .unknown) == .suppress(.likelyTypo))
        #expect(run(" the value", before: "int n = strncpy") == .show(" the value"))
        #expect(run("State(0)", before: "const [x, setX] = use") == .show("State(0)"))
    }

    @Test func quotesAreLeftAsWritten() {
        // A curly quote earlier in the field would turn straight quotes curly in prose.
        #expect(run(" \"world\"", before: "She said \u{201C}hi\u{201D}. Then", surface: .unknown)
                == .show(" \u{201C}world\u{201D}"))
        #expect(run(" \"world\"", before: "// She said \u{201C}hi\u{201D}\nlet s =") == .show(" \"world\""))
    }

    @Test func hanScriptIsNotConverted() {
        // Preferred traditional script converts a simplified prose suggestion, not a string literal.
        #expect(run("谢谢你", before: "let s = \"") == .show("谢谢你"))
    }
}

// MARK: - Rules kept in code

@Suite struct CodeProfileKeepsChatterRules {
    @Test func aiVoiceAndMetaRepliesStillSuppress() {
        #expect(run(" language model trained by Google", before: "// I am an AI") == .suppress(.aiVoice))
        #expect(run(" Sure, here is the code", before: "// Write a sort function.") == .suppress(.metaReply))
    }

    @Test func markupAndEmptyStillSuppress() {
        #expect(run("<|im_end|>", before: "return x") == .suppress(.markupLeak))
        #expect(run("   ", before: "return x") == .suppress(.empty))
        #expect(run(");", before: "foo(x") == .suppress(.punctuationOnly))
    }
}

// MARK: - Clamp

@Suite struct CodeClampTests {
    @Test func budgetIsCharactersNotProseWords() {
        #expect(CodePostProfile.characterBudget(maxWords: 4) == 40)
        #expect(CodePostProfile.characterBudget(maxWords: 0) == nil)
        // 6 "words" in prose terms, 31 characters: fits a 4-word code budget.
        let text = " items.filter { $0.isEnabled }"
        #expect(CodePostProfile.clamp(text, maxWords: 4) == text)
    }

    @Test func cutsAtATokenBoundaryNeverInsideAnIdentifier() {
        let long = " configuration.applyDefaults(forUser: currentUser, options: options)"
        let clamped = CodePostProfile.clamp(long, maxWords: 2)
        #expect(clamped.count <= 20)
        #expect(clamped == " configuration.")
        let oneIdentifier = "aVeryLongIdentifierNameThatGoesOnAndOn"
        #expect(CodePostProfile.clamp(oneIdentifier, maxWords: 1) == oneIdentifier)
        #expect(CodePostProfile.clamp(" return someValue + another", maxWords: 1) == " return")
    }

    @Test func processorUsesTheCodeClamp() {
        let long = " configuration.applyDefaults(forUser: currentUser, options: options)"
        #expect(run(long, before: "let x =", maxWords: 2) == .show(" configuration."))
        // Prose counts whitespace-separated words (punctuation never ends one), however long.
        #expect(run(long, before: "let x =", surface: .unknown, maxWords: 2)
                == .show(" configuration.applyDefaults(forUser: currentUser,"))
    }
}

// MARK: - Trailing newline

@Suite struct CodeNewlineTests {
    @Test func statementEnders() {
        #expect(CodePostProfile.endsStatement("foo();"))
        #expect(CodePostProfile.endsStatement("if x {"))
        #expect(CodePostProfile.endsStatement("}"))
        #expect(CodePostProfile.endsStatement("print(x)  "))
        #expect(CodePostProfile.endsStatement("else:"))
        #expect(!CodePostProfile.endsStatement("let x ="))
        #expect(!CodePostProfile.endsStatement("foo"))
        #expect(!CodePostProfile.endsStatement(""))
    }

    @Test func singleNewlineOnlyWhenTheLineEndsAStatementAndTheModelWentOn() {
        #expect(run("x + 1)\n    return y", before: "    print(") == .show("x + 1)\n"))
        #expect(run("x + 1", before: "    print(") == .show("x + 1"))
        #expect(run("x + 1\n    return y", before: "    print(") == .show("x + 1"))
        #expect(run("x + 1)", before: "    print(") == .show("x + 1)"))
        // Only ever one newline, and never after a clamp.
        #expect(run("x);\n\n\nfoo()", before: "    print(") == .show("x);\n"))
        #expect(run(" configuration.applyDefaults(forUser: user);\nnext()", before: "let x =", maxWords: 2) == .show(" configuration."))
    }

    @Test func allowNewlinesKeepsTheProseBehaviour() {
        #expect(run("x);\nfoo()", before: "    print(", allowNewlines: true) == .show("x);\nfoo()"))
    }
}
