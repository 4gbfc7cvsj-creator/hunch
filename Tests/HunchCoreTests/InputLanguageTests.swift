import Testing
@testable import HunchCore

private let mine = ["en-US", "zh-Hant-US"]

@Test func englishKeyboardNamesEnglishOnly() {
    #expect(InputLanguage.promptLanguages(inputSource: "en", preferred: mine) == ["en-US"])
}

@Test func zhuyinNamesTraditionalChineseOnly() {
    #expect(InputLanguage.promptLanguages(inputSource: "zh-Hant", preferred: mine) == ["zh-Hant-US"])
}

@Test func otherScriptDoesNotMatch() {
    // Pinyin (Simplified) with only a Traditional preference: nothing matches, so all are kept.
    #expect(InputLanguage.promptLanguages(inputSource: "zh-Hans", preferred: mine) == mine)
}

@Test func unknownOrMissingInputLanguageKeepsAll() {
    #expect(InputLanguage.promptLanguages(inputSource: nil, preferred: mine) == mine)
    #expect(InputLanguage.promptLanguages(inputSource: "ja", preferred: mine) == mine)
    #expect(InputLanguage.promptLanguages(inputSource: "", preferred: mine) == mine)
}

@Test func severalRegionalFormsAreAllKept() {
    #expect(InputLanguage.promptLanguages(inputSource: "en", preferred: ["en-GB", "zh-Hant", "en-US"])
        == ["en-GB", "en-US"])
    #expect(InputLanguage.promptLanguages(inputSource: "zh_Hant", preferred: ["zh-TW", "en"]) == ["zh-TW"])
}
