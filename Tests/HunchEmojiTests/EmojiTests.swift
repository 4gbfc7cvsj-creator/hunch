import Foundation
import Testing
@testable import HunchEmoji

private func top(_ term: String, _ n: Int = 6, _ prefs: EmojiPreferences = .default) -> [String] {
    EmojiSearch.query(term, limit: n, preferences: prefs).map(\.emoji)
}

@Suite struct EmojiTriggerTests {
    @Test func shortcodePositive() {
        let t = EmojiTrigger.detect(before: "hello :smi")
        #expect(t?.triggerText == ":smi")
        #expect(t?.utf16Length == 4)
        #expect(t?.kind == .shortcode(query: "smi"))
        #expect(EmojiTrigger.detect(before: ":fir") != nil)
        #expect(EmojiTrigger.detect(before: "(:fire") != nil)
        #expect(EmojiTrigger.detect(before: "ok\n:thu") != nil)
        #expect(EmojiTrigger.detect(before: "x :+1") != nil)
    }

    @Test func shortcodeNegatives() {
        #expect(EmojiTrigger.detect(before: "see https://example.com") == nil)
        #expect(EmojiTrigger.detect(before: "https:") == nil)
        #expect(EmojiTrigger.detect(before: "at 10:30") == nil)
        #expect(EmojiTrigger.detect(before: "word:word") == nil)
        #expect(EmojiTrigger.detect(before: "hello :s") == nil)
        #expect(EmojiTrigger.detect(before: "hello :") == nil)
        #expect(EmojiTrigger.detect(before: "hello :smile ") == nil)
        #expect(EmojiTrigger.detect(before: "a ::fire") == nil)
        #expect(EmojiTrigger.detect(before: "ratio 3:12") == nil)
        #expect(EmojiTrigger.detect(before: "") == nil)
        #expect(EmojiTrigger.detect(before: "hello :zzzzqqq") == nil)
    }

    @Test func emoticons() {
        #expect(EmojiTrigger.detect(before: "hi :)")?.candidates.first?.emoji == "🙂")
        #expect(EmojiTrigger.detect(before: ":-)")?.candidates.first?.emoji == "🙂")
        #expect(EmojiTrigger.detect(before: "no :(")?.candidates.first?.emoji == "🙁")
        #expect(EmojiTrigger.detect(before: "yes :D")?.candidates.first?.emoji == "😃")
        #expect(EmojiTrigger.detect(before: "ok ;)")?.candidates.first?.emoji == "😉")
        #expect(EmojiTrigger.detect(before: "I <3")?.candidates.first?.emoji == "❤️")
        #expect(EmojiTrigger.detect(before: "a :P")?.candidates.first?.emoji == "😛")
        #expect(EmojiTrigger.detect(before: "a :O")?.candidates.first?.emoji == "😮")
        #expect(EmojiTrigger.detect(before: "a :'(")?.candidates.first?.emoji == "😢")
        #expect(EmojiTrigger.detect(before: "lol XD")?.candidates.first?.emoji == "😆")
        let t = EmojiTrigger.detect(before: "hi :)")
        #expect(t?.kind == .emoticon && t?.triggerText == ":)")
        // must start a token
        #expect(EmojiTrigger.detect(before: "foo:)") == nil)
        #expect(EmojiTrigger.detect(before: "http:/") == nil)
        #expect(EmojiTrigger.detect(before: "a :) b") == nil)
    }
}

@Suite struct EmojiKindFilterTests {
    // Per-app switches: emoticons and ":" search are filtered separately.
    @Test func emoticonAndSearchAreSwitchedSeparately() throws {
        let emoticon = try #require(EmojiTrigger.detect(before: "hi :)")).kind
        let search = try #require(EmojiTrigger.detect(before: "hi :smile")).kind
        #expect(emoticon.isAllowed(emoticons: true, search: true) && search.isAllowed(emoticons: true, search: true))
        #expect(!emoticon.isAllowed(emoticons: false, search: true))
        #expect(search.isAllowed(emoticons: false, search: true))
        #expect(emoticon.isAllowed(emoticons: true, search: false))
        #expect(!search.isAllowed(emoticons: true, search: false))
        #expect(!emoticon.isAllowed(emoticons: false, search: false) && !search.isAllowed(emoticons: false, search: false))
    }
}

@Suite struct EmojiSearchTests {
    @Test func ranking() {
        let smi = top(":smi")
        #expect(smi.first == "😄")
        #expect(Set(smi.prefix(6)).isSuperset(of: ["😄", "🙂", "😃"]))
        #expect(top("thu").first == "👍")
        #expect(top("fir").first == "🔥")
        #expect(top("hea").first == "❤️")
        #expect(top("joy").first == "😂")
        #expect(top("rocket").first == "🚀")
        #expect(top("+1").first == "👍")
        #expect(top("100").first == "💯")
        #expect(top("THUMBS_UP").first == "👍")
    }

    @Test func nameWordsAndSubstring() {
        #expect(top("grinning_face", 10).contains("😀"))
        #expect(top("eyes", 40).contains("😍") || top("eyes", 40).contains("👀"))
        #expect(top("zzzzqqq").isEmpty)
        #expect(top("", 5).isEmpty)
        #expect(EmojiSearch.query("fire", limit: 0).isEmpty)
        #expect(top("flag_us", 3).first == "🇺🇸")
        #expect(top("keycap_1", 3).first == "1\u{FE0F}\u{20E3}")
    }

    @Test func skinTone() {
        let p = EmojiPreferences(skinTone: .medium)
        #expect(top("thumbsup", 1, p) == ["👍🏽"])
        // Heart and fire are not modifier bases.
        #expect(top("fire", 1, p) == ["🔥"])
        #expect(top("hea", 1, p) == ["❤️"])
        // Text-default base drops FE0F before the modifier.
        #expect(top("peace", 1, p).first == "✌🏽")
    }

    @Test func includeNeutralOrdering() {
        let p = EmojiPreferences(skinTone: .dark, includeNeutral: true)
        #expect(top("thumbsup", 1, p) == ["👍🏿", "👍"])
        #expect(top("fire", 1, p) == ["🔥"])
        let none = EmojiPreferences(skinTone: .none, includeNeutral: true)
        #expect(top("thumbsup", 1, none) == ["👍"])
    }

    @Test func gender() {
        let f = EmojiPreferences(skinTone: .light, gender: .female)
        #expect(top("shrug", 1, f) == ["🤷🏻\u{200D}♀\u{FE0F}"])
        let m = EmojiPreferences(gender: .male)
        #expect(top("shrug", 1, m) == ["🤷\u{200D}♂\u{FE0F}"])
        // Non-person emoji untouched.
        #expect(top("fire", 1, m) == ["🔥"])
        // Text-default base keeps FE0F when untoned.
        #expect(top("golfer", 1, m).first == "🏌\u{FE0F}\u{200D}♂\u{FE0F}")
    }

    @Test func triggerAppliesPreferences() {
        let p = EmojiPreferences(skinTone: .light)
        #expect(EmojiTrigger.detect(before: "x :thumbsup", preferences: p)?.candidates.first?.emoji == "👍🏻")
    }

    @Test func performance() {
        let t0 = Date()
        let n = EmojiIndex.shared.entries.count
        let build = Date().timeIntervalSince(t0)
        #expect(n > 1000)
        #expect(build < 0.5)  // spec target 100 ms; generous for debug builds
        let t1 = Date()
        for term in ["smi", "thu", "fir", "hea", "face", "a", "zzq"] { _ = EmojiSearch.query(term, limit: 8) }
        let per = Date().timeIntervalSince(t1) / 7
        #expect(per < 0.01)  // 1 ms target in release; debug is slower
        print("emoji entries=\(n) build=\(Int(build * 1000))ms perQuery=\(Int(per * 1_000_000))us")
    }
}

// MARK: - OS emoji names (sequences, gender forms, other languages)

import CoreText

private let system = SystemEmojiNames.load(preferredLanguages: ["en-US", "zh-Hant-US"])
private let zhIndex = EmojiIndex(system: system)
private func zh(_ term: String, _ n: Int = 6, _ prefs: EmojiPreferences = .default) -> [String] {
    EmojiSearch.query(term, limit: n, preferences: prefs, index: zhIndex).map(\.emoji)
}

/// True when Apple Color Emoji draws `s` as one emoji (a valid, supported sequence). Width,
/// not glyph count: couples and handshakes are drawn as two overlapping glyphs.
private func drawsAsOneEmoji(_ s: String) -> Bool {
    let font = CTFontCreateWithName("Apple Color Emoji" as CFString, 20, nil)
    func width(_ t: String) -> Double {
        let attr = NSAttributedString(string: t, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil)
    }
    return width(s) < width("😀") * 1.2
}

@Suite struct SystemEmojiNameTests {
    @Test func tablesLoad() {
        #expect(system.english.count > 1500)
        #expect(system.languages == ["zh_TW"])
        #expect(system.english[SystemEmojiNames.key("👩‍💻")]?.name == "woman technologist")
    }

    @Test func languageMapping() {
        let avail: Set<String> = ["zh_TW", "zh_HK", "zh_CN", "de", "pt_BR", "pt_PT", "fr_CA", "fr", "ja"]
        #expect(SystemEmojiNames.lprojNames(for: ["en-US", "zh-Hant-US"], available: avail) == ["zh_TW"])
        #expect(SystemEmojiNames.lprojNames(for: ["zh-Hant-HK"], available: avail) == ["zh_HK"])
        #expect(SystemEmojiNames.lprojNames(for: ["zh-Hans-CN"], available: avail) == ["zh_CN"])
        #expect(SystemEmojiNames.lprojNames(for: ["de-DE", "pt-BR", "fr-FR", "ja"], available: avail) == ["de", "pt_BR", "fr", "ja"])
        #expect(SystemEmojiNames.lprojNames(for: ["xx-YY"], available: avail).isEmpty)
    }

    @Test func missingTablesFallBack() {
        let none = SystemEmojiNames.load(from: URL(fileURLWithPath: "/nonexistent"))
        #expect(none.english.isEmpty)
        let idx = EmojiIndex(system: none)
        #expect(idx.entries.count > 1000)
        #expect(EmojiSearch.query("shrug", limit: 1, preferences: EmojiPreferences(gender: .male), index: idx).first?.emoji
                == "🤷\u{200D}♂\u{FE0F}")
    }

    @Test func zwjSequencesSearchable() {
        #expect(zh("technologist", 3).contains("🧑‍💻"))
        #expect(zh("woman_tech", 3).first == "👩‍💻")
        #expect(zh("astronaut", 3).first == "🧑‍🚀")
        #expect(zh("family", 60).contains("👨‍👩‍👧"))
        #expect(zh("rainbow_flag", 3).first == "🏳️‍🌈")
        #expect(zh("broken_chain", 3).first == "⛓️‍💥")
        #expect(zh("black_cat", 3).first == "🐈‍⬛")
        // A ZWJ sequence starting with a popular scalar doesn't inherit its aliases.
        #expect(zh("heart", 1).first == "❤️")
    }

    @Test func genderFromOSNames() {
        let f = EmojiPreferences(gender: .female)
        let m = EmojiPreferences(gender: .male)
        #expect(zh("astronaut", 1, f) == ["👩‍🚀"])
        #expect(zh("astronaut", 1, m) == ["👨‍🚀"])
        #expect(zh("shrug", 1, f) == ["🤷‍♀️"])
        #expect(zh("golfer", 1, m).first == "🏌️‍♂️")
        #expect(zh("fire", 1, f) == ["🔥"])
        // Neutral listed first and not repeated by the gendered entries.
        let all = zh("mechanic", 3)
        #expect(all.first == "🧑‍🔧")
        #expect(Set(all).count == all.count)
        // Families aren't gendered or toned.
        let fam = EmojiPreferences(skinTone: .dark, gender: .female)
        #expect(zh("family_adult_adult_child", 1, fam).first == "🧑‍🧑‍🧒")
    }

    @Test func tonesOnSequences() {
        let p = EmojiPreferences(skinTone: .medium)
        #expect(zh("astronaut", 1, p) == ["🧑🏽‍🚀"])
        let pf = EmojiPreferences(skinTone: .light, gender: .female)
        #expect(zh("astronaut", 1, pf) == ["👩🏻‍🚀"])
        #expect(zh("shrug", 1, pf) == ["🤷🏻‍♀️"])
        let d = EmojiPreferences(skinTone: .dark)
        #expect(zh("two_women_with_heart", 1, d) == ["👩🏿‍❤️‍👩🏿"])
        #expect(zh("handshake", 3, d).contains("🫱🏿‍🫲🏿") || zh("handshake", 3, d).contains("🤝🏿"))
        #expect(zh("people_holding_hands", 1, d) == ["🧑🏿‍🤝‍🧑🏿"])
    }

    /// Every variant the app can insert is one the system font draws as a single emoji.
    @Test func allVariantsAreRealSequences() {
        var bad: [String] = []
        var checked = 0
        for tone in EmojiSkinTone.allCases {
            for g in EmojiGender.allCases {
                let p = EmojiPreferences(skinTone: tone, gender: g)
                for e in zhIndex.entries {
                    for v in EmojiVariants.variants(of: e.emoji, prefs: p, genderForms: zhIndex.genderForms) {
                        checked += 1
                        if !drawsAsOneEmoji(v) { bad.append(v) }
                    }
                }
            }
        }
        let uniqueBad = Array(Set(bad)).sorted()
        print("checked \(checked) variants, \(uniqueBad.count) not single glyphs: \(uniqueBad.prefix(40))")
        #expect(uniqueBad.isEmpty)
    }

    @Test func traditionalChineseNames() {
        #expect(zh("火焰", 3).contains("🔥"))
        #expect(zh("火", 6).contains("🔥"))
        #expect(zh("技術人員", 4).contains("👩‍💻"))
        #expect(zh("彩虹旗", 2).first == "🏳️‍🌈")
    }

    @Test func fullWidthColonAndCJKTrigger() {
        let t = EmojiTrigger.detect(before: "好熱 ：火", index: zhIndex)
        #expect(t?.triggerText == "：火")
        #expect(t?.candidates.contains(where: { $0.emoji == "🔥" }) == true)
        #expect(EmojiTrigger.detect(before: ":火焰", index: zhIndex)?.triggerText == ":火焰")
        // A colon right after a word ("地點:台北", "如下：首先") is punctuation, not a trigger.
        #expect(EmojiTrigger.detect(before: "地點:台北", index: zhIndex) == nil)
        #expect(EmojiTrigger.detect(before: "如下：首先", index: zhIndex) == nil)
        // One Latin letter still isn't enough.
        #expect(EmojiTrigger.detect(before: "hello :s", index: zhIndex) == nil)
        // Zhuyin still composing: no match.
        #expect(EmojiTrigger.detect(before: "：ㄏㄨㄛˇ", index: zhIndex) == nil)
    }
}

// MARK: - OS emoji picker keywords

private let noKeywords = EmojiIndex(keywords: .empty)
private func names(_ term: String, _ n: Int = 6) -> [String] {
    EmojiSearch.query(term, limit: n, index: noKeywords).map(\.emoji)
}

@Suite struct SystemEmojiKeywordTests {
    @Test func indexLoads() {
        let k = SystemEmojiKeywords.load()
        #expect(k.terms.count > 3000)
        #expect(k.terms["yay"]?.first?.key == SystemEmojiNames.key("😁"))
        #expect(k.terms["bonfire"]?.contains(where: { $0.key == "🔥" }) == true)
    }

    @Test func keywordsFindEmojiNamesMiss() {
        #expect(names("yay").isEmpty && names("bonfire").isEmpty)
        #expect(top("yay").first == "😁")
        #expect(top("yay").contains("🎉"))
        #expect(top("bonfire").first == "🔥")
        #expect(top("hashtag").first == "#️⃣")
        #expect(EmojiTrigger.detect(before: "we won :yay")?.candidates.first?.emoji == "😁")
    }

    @Test func namesStayFirst() {
        for term in ["cat", "fire", "smi", "thu", "hea", "joy", "rocket", "heart", "face", "party", "lol", "sad"] {
            let before = names(term, 30)
            let now = top(term, 30)
            #expect(Array(now.prefix(before.count)) == before, "\(term)")
        }
    }

    @Test func prefixNeedsThreeLetters() {
        #expect(!top("ya", 30).contains("😁"))
        #expect(top("bonf").first == "🔥")
        #expect(top("hasht").first == "#️⃣")
    }

    @Test func preferencesApply() {
        let p = EmojiPreferences(skinTone: .medium)
        // 🙌 is a keyword hit for "woop"; toned like any other result.
        #expect(top("woop", 3, p).contains("🙌🏽"))
    }

    @Test func missingIndexFallsBack() {
        #expect(SystemEmojiKeywords.load(from: URL(fileURLWithPath: "/nonexistent")).terms.isEmpty)
        #expect(SystemEmojiKeywords.load(emojiForToken: { _ in nil }).terms.isEmpty)
        #expect(names("fire").first == "🔥")
        #expect(names("yay").isEmpty)
    }
}
