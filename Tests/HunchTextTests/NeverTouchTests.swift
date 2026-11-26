import Foundation
import Testing
@testable import HunchText

/// One check for text autocorrect never changes (links, paths, identifiers, code...), used by every
/// fix path. Names and addresses are made up.

private struct Suggester: CorrectionSuggesting {
    let table: [String: CorrectionOptions] = [
        "teh": CorrectionOptions(confident: "the", guesses: ["the"]),
        "therea": CorrectionOptions(confident: "there", guesses: ["theres", "there"]),
    ]
    func correction(for word: String, context: String, languages: [String]) -> String? { table[word]?.confident }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        table[word] ?? CorrectionOptions(confident: nil, guesses: [])
    }
    func completions(forPrefix prefix: String, languages: [String]) -> [String] { [] }
}

private let dictionary = FakeSpell([
    "the", "and", "there", "theres", "are", "still", "res", "till", "i", "think", "now", "rest", "ill", "a", "as",
    "here", "re", "do", "should", "some", "so", "me", "when", "their", "they're", "over", "see", "this", "dont",
    "we", "end", "next", "word", "alex", "morgan",
])
private let everyday: Set<String> = ["the", "and", "there", "are", "still", "i", "think", "now", "till", "rest", "ill",
                                     "a", "as", "here", "do", "should", "some", "so", "me", "when", "see", "this", "we"]

private func finder() -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: dictionary, suggester: Suggester(), languages: ["en"], knownWords: [],
                             guesser: StubGuesser([:], default: ("en", 0.9)),
                             isCommonWord: { everyday.contains($0) || $0 == "their" || $0 == "over" },
                             isEverydayWord: { everyday.contains($0) })
    f.fixesPunctuation = true
    f.doubleSpace = .period
    f.fixesCapitals = true
    f.fixesConfusedWords = true
    f.textReplacements = TextReplacements(["omw": "on my way"])
    f.appliesReplacements = true
    return f
}

/// What the finder does with `text` in both modes, as a short label.
private func outcome(_ text: String) -> [String] {
    [false, true].map { auto in
        switch finder().finding(before: text, deferAmbiguous: auto) {
        case .fix(let p)?: "fix:" + p.replacement
        case .ambiguous(let t)?: "ambiguous:" + t.misspelled
        case nil: "none"
        }
    }
}

private func untouched(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(outcome(text) == ["none", "none"], "\(text)", sourceLocation: sourceLocation)
}

struct NeverTouchKindTests {
    @Test(arguments: [
        ("https://example.com/a", NeverTouch.Kind.url), ("www.example.com", .url), ("example.com/path?q=1", .url),
        ("example.com", .url), ("(https://example.com)", .url),
        ("alex@example.com", .email), ("alex.morgan@mail.example.org,", .email),
        ("@alexmorgan", .mention), ("(@alex)", .mention), ("#launch2026", .hashtag),
        ("~/Documents/notes", .path), ("/usr/local/bin", .path), ("./run", .path), ("../up", .path),
        ("C:\\Users\\alex", .path), ("D:/data", .path), ("src/main/app", .path), ("a\\b", .path),
        ("fooBar", .identifier), ("FooBar", .identifier), ("iPhone", .identifier), ("snake_case", .identifier),
        ("__init__", .identifier), ("my_var.", .identifier),
        ("`code`", .code), ("`x", .code),
        ("API", .abbreviation), ("NASA,", .abbreviation), ("APIs", .abbreviation), ("COVID-19", .abbreviation),
        ("v1.2", .number), ("3.5", .number), ("v2", .number), ("1.2.3", .number), ("$3.50", .number),
        ("e.g", .dotted), ("U.S", .dotted), ("file.txt", .dotted), ("node.js", .dotted),
    ])
    func recognizes(chunk: String, kind: NeverTouch.Kind) {
        #expect(NeverTouch.kind(of: chunk) == kind)
    }

    @Test(arguments: ["the", "The", "teh", "THe", "tHIS", "I", "and/or", "don't", "well-known", "_italic_", "word,",
                      "Hello", "x", "(word)", "A", "end.", "2026", "3pm", "whe4n", "\u{4F60}\u{597D}"])
    func ordinaryWordsAreNot(_ chunk: String) {
        #expect(NeverTouch.kind(of: chunk) == nil, "\(chunk)")
    }

    @Test func capsLockSlipsStayFixable() {
        #expect(NeverTouch.kind(of: "tHIS") == nil)
        #expect(NeverTouch.kind(of: "THe") == nil)
    }

    @Test func spacingFixesMayActOnAbbreviationsAndPlainDots() {
        #expect(NeverTouch.kind(of: "NASA", forSpacing: true) == nil)
        #expect(NeverTouch.kind(of: "end.Next", forSpacing: true) == nil)
        #expect(NeverTouch.kind(of: "file.txt", forSpacing: true) == nil)
        #expect(NeverTouch.kind(of: "v1.2", forSpacing: true) == .number)
        #expect(NeverTouch.kind(of: "https://example.com", forSpacing: true) == .url)
        #expect(NeverTouch.kind(of: "fooBar", forSpacing: true) == .identifier)
    }

    @Test func insideCodeInlineAndFenced() {
        #expect(NeverTouch.insideCode("run `git st"))
        #expect(!NeverTouch.insideCode("run `git st` now"))
        #expect(NeverTouch.insideCode("```\nlet x = 1\nsee"))
        #expect(!NeverTouch.insideCode("```\nlet x = 1\n```\nsee"))
        #expect(!NeverTouch.insideCode("no code here"))
    }

    @Test func lastWordIsJudgedByItsWholeChunk() {
        #expect(NeverTouch.protectsLastWord(in: "see ~/Documents/teh"))
        #expect(NeverTouch.protectsLastWord(in: "mail alex@example.com"))
        #expect(!NeverTouch.protectsLastWord(in: "mail me. see teh"))
        #expect(NeverTouch.protectsLastWord(in: "```\nsee teh"))
    }
}

struct NeverTouchPathTests {
    // Controls: each path does fix the plain word, so the "untouched" checks below mean something.
    @Test func controls() {
        #expect(outcome("see teh ") == ["fix:the", "fix:the"])
        #expect(outcome("see THe ") == ["fix:The", "fix:The"])
        #expect(outcome("see tHIS ") == ["fix:This", "fix:This"])
        #expect(outcome("we dont ") == ["fix:don't", "fix:don't"])
        #expect(outcome("ask whe4n ")[1] == "ambiguous:whe4n")
        #expect(outcome("over their ")[1] == "ambiguous:their")
        #expect(outcome("see a s ")[1] == "ambiguous:a s")
        #expect(outcome("i think therea res till ")[1].hasPrefix("ambiguous:"))
        #expect(outcome("see omw ")[1] == "fix:on my way")
        #expect(outcome("we end . ") == ["fix:end. ", "fix:end. "])
        #expect(outcome("we end  ") == ["fix:end. ", "fix:end. "])
        #expect(outcome("the end.Next ") == ["fix:end. Next ", "fix:end. Next "])
    }

    @Test(arguments: [
        "~/Documents/", "~/", "/usr/", "./", "../", "C:\\Users\\", "#", "@", "foo_", "fooBar", "my_",
        "https://example.com/", "www.", "alex@", "`",
    ])
    func singleWordPaths(prefix: String) {
        // Spelling, capitals, apostrophes, symbol slips, confused words and text replacements.
        for word in ["teh", "THe", "tHIS", "dont", "whe4n", "their", "omw", "i"] {
            untouched("see \(prefix)\(word) ")
        }
    }

    @Test func wordsInsideAddressesAndPaths() {
        untouched("go to example.com/teh ")
        untouched("write to alex@teh.example.com ")
        untouched("open ~/Projects/teh ")
        untouched("run teh_script ")
        untouched("call fooTeh ")
        untouched("see (@teh) ")
    }

    @Test func codeInlineAndFenced() {
        untouched("run `see teh ")
        untouched("run `git teh ")
        untouched("```\nsee teh ")
        untouched("```swift\nlet x = i ")
        untouched("run `ask whe4n ")
        #expect(outcome("```\nlet x\n```\nsee teh ") == ["fix:the", "fix:the"])
        #expect(outcome("run `ls` and teh ") == ["fix:the", "fix:the"])
    }

    @Test func stretchPairAndResegmentPaths() {
        untouched("`see a s ")
        untouched("```\nsee a s ")
        untouched("`i think therea res till ")
        // A link or path next to the words is no neighbour to fix them with.
        untouched("foo_bar therea res till ")
        untouched("https://example.com/x therea res till ")
        untouched("~/notes therea res till ")
    }

    @Test func punctuationPaths() {
        untouched("see example.com . ")
        untouched("see https://example.com/a  ")
        untouched("see ~/notes . ")
        untouched("see fooBar . ")
        untouched("see snake_case  ")
        untouched("we ship v1.2 . ")
        untouched("it costs 3.5  ")
        untouched("`we end . ")
        untouched("```\nwe end  ")
        untouched("see alex@example.com . ")
        untouched("ask @alex  ")
        untouched("see #launch . ")
        // Abbreviations and plain words still get their spacing fixed.
        #expect(outcome("we use NASA . ") == ["fix:NASA. ", "fix:NASA. "])
    }

    @Test func abbreviationsAreNotTouchedButCapsLockSlipsAre() {
        untouched("see API ")
        untouched("see NASA ")
        #expect(outcome("see tHIS ") == ["fix:This", "fix:This"])
    }
}
