import Foundation
import Testing
import HunchCore
@testable import HunchLlama

private func info(_ s: String, control: Bool = false, unused: Bool = false, byte: Bool = false, eog: Bool = false,
                  userDefined: Bool = false) -> RawTokenInfo {
    RawTokenInfo(bytes: Array(s.utf8), isControl: control, isUnused: unused, isByte: byte, isEOG: eog,
                 isUserDefined: userDefined)
}

private func makeTable() -> LlamaVocabularyTable {
    var infos = [
        info("<bos>", control: true),            // 0
        info("<eos>", control: true, eog: true), // 1
        info(" a"),                              // 2
        info(" am"),                             // 3
        info(" amazing"),                        // 4
        info(" "),                               // 5
        info("a"),                               // 6
        info(" b"),                              // 7
        info("."),                               // 8
        info(", "),                              // 9
        info("\n"),                              // 10
        info(""),                                // 11 (empty)
        info("<|channel>", userDefined: true),   // 12 marker-like user-defined
        info("<table>", userDefined: true),      // 13 ordinary user-defined
        info(" (see"),                           // 14
        info("!\""),                             // 15
        info("\u{2581}word"),                    // 16 raw SentencePiece space
    ]
    infos.append(RawTokenInfo(bytes: [0xE2], isControl: false, isUnused: false, isByte: true, isEOG: false)) // 17
    return LlamaVocabularyTable(infos)
}

@Suite struct VocabularyTableTests {
    let table = makeTable()

    @Test func bytesAndCount() {
        #expect(table.count == 18)
        #expect(Array(table.bytes(3)) == Array(" am".utf8))
        #expect(table.bytes(11).isEmpty)
        #expect(table.bytes(-1).isEmpty)
        #expect(table.bytes(99).isEmpty)
    }

    @Test func traits() {
        #expect(table.traits(0).contains(.control))
        #expect(table.traits(1).isSuperset(of: [.control, .endOfGeneration]))
        #expect(table.traits(3).isSuperset(of: [.leadingSpace, .wordStart]))
        #expect(!table.traits(5).contains(.wordStart))
        #expect(!table.traits(6).contains(.leadingSpace))
        #expect(table.traits(8).isSuperset(of: [.punctuation, .sentenceEnd]))
        #expect(table.traits(9).isSuperset(of: [.punctuation, .containsComma]))
        #expect(!table.traits(9).contains(.sentenceEnd))
        #expect(table.traits(10).contains(.containsNewline))
        #expect(table.traits(12).contains(.control))
        #expect(!table.traits(13).contains(.control))
        #expect(table.traits(14).contains(.wordStart))
        #expect(table.traits(15).isSuperset(of: [.punctuation]))
        #expect(table.traits(16).isSuperset(of: [.leadingSpace, .wordStart]))
        #expect(table.traits(17).isSuperset(of: [.byteFallback, .invalidUTF8Alone]))
        #expect(table.protectedMarkers == ["<|channel>"])
    }

    @Test func admissibleIsPrefixCompatible() {
        let got = Set(table.admissible(forRequired: Array(" am".utf8)[...]))
        // " " and " a" are prefixes of " am"; " am" equals it; " amazing" extends it.
        #expect(got == [5, 2, 3, 4])
        #expect(Set(table.admissible(forRequired: Array(" ".utf8)[...])) == [5, 2, 3, 4, 7, 14])
        #expect(Set(table.admissible(forRequired: Array(" amx".utf8)[...])) == [5, 2, 3])
        #expect(table.admissible(forRequired: Array("zzz".utf8)[...]).isEmpty)
        #expect(!table.admissible(forRequired: []).contains(11)) // empty tokens never admissible
    }

    @Test func admissibleMatchesBruteForce() {
        let requireds = [" a", " amaz", "a", ".", ", x", "<|", "\u{2581}", " (s"]
        for r in requireds {
            let req = Array(r.utf8)
            let expected = Set((0..<Int32(table.count)).filter { id in
                let b = Array(table.bytes(id))
                guard !b.isEmpty else { return false }
                let n = min(b.count, req.count)
                return Array(b.prefix(n)) == Array(req.prefix(n))
            })
            #expect(Set(table.admissible(forRequired: req[...])) == expected, "required \(r.debugDescription)")
        }
    }

    @Test func logSoftmaxIsNormalizedAndStable() throws {
        let logits: [Float] = [1000, 999, 998, -1e30]
        var out: [Float] = []
        var scratch: [Float] = []
        try logits.withUnsafeBufferPointer { try LlamaSession.logSoftmax($0, into: &out, scratch: &scratch) }
        let total = out.map { Double(expf($0)) }.reduce(0, +)
        #expect(abs(total - 1) < 1e-5)
        #expect(abs(out[0] - out[1] - 1) < 1e-4)
        #expect(out.allSatisfy { !$0.isNaN })
    }
}
