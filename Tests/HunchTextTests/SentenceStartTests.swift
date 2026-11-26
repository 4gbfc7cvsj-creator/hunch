import Testing
@testable import HunchText

/// Fix-as-you-type and the Strong pass agree with `CapitalFix` on where a sentence starts.
struct SentenceStartTests {
    @Test func finderSentenceStartSkipsAbbreviations() {
        #expect(CorrectionFinder.isSentenceStartCapital("Teh", before: ""))
        #expect(CorrectionFinder.isSentenceStartCapital("Teh", before: "Done. "))
        #expect(CorrectionFinder.isSentenceStartCapital("Teh", before: "Done\n"))
        #expect(!CorrectionFinder.isSentenceStartCapital("Kowalski", before: "Dr. "))
        #expect(!CorrectionFinder.isSentenceStartCapital("Teh", before: "e.g. "))
        #expect(!CorrectionFinder.isSentenceStartCapital("Teh", before: "wait... "))
        #expect(!CorrectionFinder.isSentenceStartCapital("Teh", before: "and "))
    }

    @Test func rewriteCapitalizesOnlyRealSentenceStarts() {
        var options = RewriteOptions()
        options.fixesCapitals = true
        func run(_ typed: String, _ revised: String) -> String {
            let target = RewriteTarget.find(before: typed, finished: true)!
            return FieldRewrite.apply(FieldRewrite.edits(target: target, revised: revised, options: options).edits, to: typed)
        }
        #expect(run("It works. teh end", "It works. the end") == "It works. The end")
        #expect(run("Ask Dr. teh vet", "Ask Dr. the vet") == "Ask Dr. the vet")
    }
}
