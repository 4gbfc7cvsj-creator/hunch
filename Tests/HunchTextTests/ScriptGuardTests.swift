import XCTest
import HunchCore
@testable import HunchText

final class ScriptGuardTests: XCTestCase {
    private let mine: Set<String> = ["latin", "han", "bopomofo"]

    private func run(_ before: String, _ raw: String, allowed: Set<String>?, after: String = "") -> PostOutcome {
        DefaultPostProcessor().process(raw, meanLogProb: nil,
            context: PostContext(before: before, after: after, requiredPrefix: "", allowNewlines: false,
                                 maxWords: 8, allowedScripts: allowed))
    }

    func testClassifierRanges() {
        func s(_ c: Unicode.Scalar) -> ScriptGuard.Script? { ScriptGuard.script(of: c) }
        XCTAssertEqual(s("a"), .latin)
        XCTAssertEqual(s("é"), .latin)
        XCTAssertEqual(s("ž"), .latin)
        XCTAssertEqual(s("н"), .cyrillic)
        XCTAssertEqual(s("α"), .greek)
        XCTAssertEqual(s("你"), .han)
        XCTAssertEqual(s("ㄅ"), .bopomofo)
        XCTAssertEqual(s("あ"), .kana)
        XCTAssertEqual(s("カ"), .kana)
        XCTAssertEqual(s("한"), .hangul)
        XCTAssertEqual(s("ع"), .arabic)
        XCTAssertEqual(s("ש"), .hebrew)
        XCTAssertEqual(s("ก"), .thai)
        XCTAssertEqual(s("अ"), .devanagari)
        XCTAssertNil(s("1"))
        XCTAssertNil(s(" "))
        XCTAssertNil(s("!"))
        XCTAssertNil(s("😀"))
    }

    func testLanguageMapping() {
        XCTAssertEqual(ScriptGuard.scripts(forLanguage: "en"), ["latin"])
        XCTAssertEqual(ScriptGuard.scripts(forLanguage: "zh-Hant"), ["han", "bopomofo"])
        XCTAssertEqual(ScriptGuard.scripts(forLanguage: "zh-TW"), ["han", "bopomofo"])
        XCTAssertEqual(ScriptGuard.scripts(forLanguage: "zh-Hans"), ["han"])
        XCTAssertEqual(ScriptGuard.scripts(forLanguage: "ja"), ["han", "kana"])
        XCTAssertEqual(ScriptGuard.scripts(forLanguage: "ko"), ["hangul", "han"])
        XCTAssertEqual(ScriptGuard.scripts(forLanguage: "ru"), ["cyrillic"])
        XCTAssertEqual(ScriptGuard.scripts(forLanguages: ["en", "zh-Hant"]), ["latin", "han", "bopomofo"])
    }

    func testRussianAfterEnglishSuppressed() {
        XCTAssertEqual(run("Some settings ", "настроить", allowed: mine), .suppress(.foreignScript))
    }

    func testCutsAtForeignWord() {
        XCTAssertEqual(run("Say ", "hello мир", allowed: mine), .show("hello"))
        XCTAssertEqual(run("Say ", "hello, мир", allowed: mine), .show("hello"))
    }

    func testCyrillicAllowedWhenAlreadyPresent() {
        XCTAssertEqual(run("Привет, как ", "дела", allowed: mine), .show("дела"))
        XCTAssertEqual(run("Hi ", "мир", allowed: mine, after: " друг"), .show("мир"))
    }

    func testChineseAllowedKanaSuppressed() {
        XCTAssertEqual(run("我想", "你好", allowed: mine), .show("你好"))
        XCTAssertEqual(run("Next ", "ありがとう", allowed: mine), .suppress(.foreignScript))
    }

    func testNilGuardUnchanged() {
        XCTAssertEqual(run("Some settings ", "настроить", allowed: nil), .show("настроить"))
    }

    func testNumbersAndEmojiAllowed() {
        XCTAssertEqual(run("Call ", "me at 5 😀", allowed: mine), .show("me at 5 😀"))
    }
}
