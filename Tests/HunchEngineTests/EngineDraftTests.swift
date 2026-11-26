// Where the draft comes from: the previous continuation, adjusted for what the user typed since.
import Foundation
import HunchCore
import Testing
@testable import HunchEngine

private struct ByteVocabulary: VocabularyTable {
    var count: Int { 256 }
    func bytes(_ id: TokenID) -> ArraySlice<UInt8> { [UInt8(truncatingIfNeeded: id)][...] }
    func traits(_ id: TokenID) -> TokenTraits { [] }
    func admissible(forRequired required: ArraySlice<UInt8>) -> [TokenID] { [] }
}

private func ids(_ text: String) -> [TokenID] { text.utf8.map { TokenID($0) } }

@Suite struct EngineDraftTests {
    private func cache(prompt: String, continuation: String, before: String? = nil) -> SessionCache {
        let cache = SessionCache()
        cache.set(prompt: ids(prompt), continuation: ids(continuation), before: before ?? prompt, text: continuation)
        return cache
    }

    @Test func promptThatIsAPrefixOfTheCachedTokensDraftsTheRest() {
        let c = cache(prompt: "ab", continuation: "cdef")
        let v = ByteVocabulary()
        #expect(c.draft(for: ids("ab"), required: [], vocabulary: v, limit: 8) == ids("cdef"))
        #expect(c.draft(for: ids("abc"), required: [], vocabulary: v, limit: 8) == ids("def"))
        #expect(c.draft(for: ids("ab"), required: [], vocabulary: v, limit: 2) == ids("cd"))
        // Whole continuation typed, diverged, or shorter than the previous prompt: nothing to draft.
        #expect(c.draft(for: ids("abcdef"), required: [], vocabulary: v, limit: 8).isEmpty)
        #expect(c.draft(for: ids("abx"), required: [], vocabulary: v, limit: 8).isEmpty)
        #expect(c.draft(for: ids("a"), required: [], vocabulary: v, limit: 8).isEmpty)
        #expect(c.draft(for: ids("ab"), required: [], vocabulary: v, limit: 0).isEmpty)
    }

    @Test func draftMustBeAbleToStartWithTheRequiredPrefix() {
        let c = cache(prompt: "ab", continuation: "cdef")
        let v = ByteVocabulary()
        #expect(c.draft(for: ids("ab"), required: Array("c".utf8), vocabulary: v, limit: 8) == ids("cdef"))
        #expect(c.draft(for: ids("ab"), required: Array("cd".utf8), vocabulary: v, limit: 8) == ids("cdef"))
        #expect(c.draft(for: ids("ab"), required: Array("cx".utf8), vocabulary: v, limit: 8).isEmpty)
        // Required longer than the draft: the available bytes still have to agree.
        #expect(c.draft(for: ids("ab"), required: Array("cdefgh".utf8), vocabulary: v, limit: 8) == ids("cdef"))
    }

    @Test func textDraftFollowsWhatWasTypedFromThePreviousSuggestion() {
        let c = cache(prompt: "xx", continuation: " going to the", before: "I am")
        #expect(c.draftText(before: "I am", required: "") == " going to the")
        #expect(c.draftText(before: "I am go", required: " go") == " go" + "ing to the")
        #expect(c.draftText(before: "I am going to the", required: "") == nil)   // all typed
        #expect(c.draftText(before: "I am sitting", required: "") == nil)          // diverged
        #expect(c.draftText(before: "I a", required: "") == nil)                    // backspaced
        // Multi-byte text: typed one character of a CJK suggestion.
        let zh = cache(prompt: "xx", continuation: "玩吧！", before: "我们去公园")
        #expect(zh.draftText(before: "我们去公园玩", required: "") == "吧！")
    }

    @Test func failureOrReloadForgetsTheDraftSources() {
        let c = cache(prompt: "ab", continuation: "cd", before: "x")
        c.recordAfterFailure(session: FakeSession(), attempted: ids("ab"))
        #expect(c.draftText(before: "x", required: "") == nil)
        #expect(c.draft(for: ids("ab"), required: [], vocabulary: ByteVocabulary(), limit: 8).isEmpty)
    }
}
