import Testing
@testable import HunchCore

@Suite struct LearnedBiasMidWordTests {
    let bias = LearnedBias(entries: [.init(text: "Microspikes", weight: 1), .init(text: " Riley", weight: 0.3)],
                           strength: 3, avoid: ["badword"], phrases: [.init(text: " tomorrow", weight: 1)], phraseStrength: 8)

    @Test func midWordKeepsOnlyTheWholeWordEntries() {
        let m = bias.midWordOnly(before: "I lent my micr")
        #expect(m.entries.map(\.text) == ["Microspikes"])
        #expect(m.avoid == ["badword"] && m.phrases == bias.phrases && m.strength == 3)
    }

    @Test func atAWordBoundaryNothingIsBoosted() {
        // At a boundary BiasBuilder writes context and global entries without a leading space.
        let boundary = LearnedBias(entries: [.init(text: "Riley", weight: 1)], strength: 3)
        #expect(boundary.midWordOnly(before: "sync with ").entries.isEmpty)
        #expect(boundary.midWordOnly(before: "").entries.isEmpty)
        #expect(bias.midWordOnly(before: "sync with,").entries.isEmpty)
    }
}
