import Testing
@testable import HunchCore

@Suite struct PromptDebugLogTests {
    @Test func lineHasCountsAndBlocksButNoText() {
        let line = PromptDebugLog.line(promptTokens: 2_100, budget: 7_680, decoded: 40, reused: 2_060,
                                       syncMilliseconds: 31.24, framingMilliseconds: 2.5, prewarm: false,
                                       blocks: [("instruction: Below is", 12), ("screen: On screen", 1_500), ("text", 588)])
        #expect(line == "tokens=2100/7680 decoded=40 reused=2060 syncMs=31.2 framingMs=2.5 blocks: "
                + "instruction: Below is=12 | screen: On screen=1500 | text=588")
        #expect(PromptDebugLog.line(promptTokens: 1, budget: 2, decoded: 1, reused: 0, syncMilliseconds: 0,
                                    framingMilliseconds: 0, prewarm: true, blocks: []).hasPrefix("prewarm "))
    }
}
