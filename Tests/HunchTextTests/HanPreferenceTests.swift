import XCTest
import HunchCore
@testable import HunchText

final class HanPreferenceTests: XCTestCase {
    private func run(_ before: String, _ raw: String, _ pref: HanVariant?, after: String = "") -> String {
        let out = DefaultPostProcessor().process(raw, meanLogProb: nil,
            context: PostContext(before: before, after: after, requiredPrefix: "", allowNewlines: false,
                                 maxWords: 20, preferredHanScript: pref))
        if case .show(let s) = out { return s }
        return "<suppressed>"
    }

    func testAmbiguousContextUsesPreferredTraditional() {
        XCTAssertEqual(run("但是就算在", "这样的情况下", .traditional), "這樣的情況下")
    }

    func testNilPreferenceUnchanged() {
        XCTAssertEqual(run("但是就算在", "这样的情况下", nil), "这样的情况下")
    }

    func testDecisiveSimplifiedContextWins() {
        XCTAssertEqual(run("我们今天在这里", "这样的情况下", .traditional), "这样的情况下")
    }

    func testDecisiveTraditionalContextWithSimplifiedPreference() {
        XCTAssertEqual(run("我們今天在這裡討論", "這樣的情況下", .simplified), "這樣的情況下")
    }

    func testPreferredSimplifiedConvertsAmbiguous() {
        XCTAssertEqual(run("但是就算在", "這樣的情況下", .simplified), "这样的情况下")
    }

    func testLanguageMapping() {
        XCTAssertEqual(HanPreference.variant(forLanguages: ["zh-Hant", "en"]), .traditional)
        XCTAssertEqual(HanPreference.variant(forLanguages: ["zh-TW"]), .traditional)
        XCTAssertEqual(HanPreference.variant(forLanguages: ["zh-HK"]), .traditional)
        XCTAssertEqual(HanPreference.variant(forLanguages: ["zh-Hans"]), .simplified)
        XCTAssertEqual(HanPreference.variant(forLanguages: ["zh-CN", "en"]), .simplified)
        XCTAssertNil(HanPreference.variant(forLanguages: ["zh-Hans", "zh-Hant"]))
        XCTAssertNil(HanPreference.variant(forLanguages: ["en", "ja"]))
    }
}
