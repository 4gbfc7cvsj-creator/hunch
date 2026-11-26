// Script matching for Chinese suggestions: convert simplified output to traditional only on clear evidence,
// and avoid the well-known one-to-many mis-conversions. Pure.
import Foundation
import HunchCore

enum HanConversion {
    /// Hiragana, Katakana, their extensions, and halfwidth Katakana.
    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: true
        default: false
        }
    }

    static func containsKana(_ text: String) -> Bool { text.unicodeScalars.contains(where: isKana) }

    private static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    /// Number of characters (with repeats) that exist only in the traditional script.
    static func traditionalOnlyCount(_ text: String) -> Int {
        var verdict: [Unicode.Scalar: Bool] = [:]
        var count = 0
        for scalar in text.unicodeScalars where isHan(scalar) {
            let isTraditional: Bool
            if let known = verdict[scalar] {
                isTraditional = known
            } else {
                let s = String(Character(scalar))
                isTraditional = HanScript.simplified(s) != s
                verdict[scalar] = isTraditional
            }
            if isTraditional { count += 1 }
        }
        return count
    }

    /// Whether a suggestion should be converted to traditional script, given the text before the caret.
    ///
    /// Requires at least 2 traditional-only characters in the recent text and no simplified-only
    /// ones; never when kana are around (Japanese uses shinjitai kanji that look "simplified");
    /// a writer who lists Japanese needs 4 such characters.
    static func shouldConvertToTraditional(text: String, recent: String, languages: [String]) -> Bool {
        if containsKana(recent) || containsKana(text) { return false }
        guard HanScript.usesSimplified(text) else { return false }
        let japanese = languages.contains { $0.lowercased().hasPrefix("ja") }
        guard traditionalOnlyCount(recent) >= (japanese ? 4 : 2) else { return false }
        return !HanScript.usesSimplified(recent)
    }

    /// Simplified phrase -> traditional phrase (same number of characters). Covers the one-to-many
    /// characters that single-character conversion tends to get wrong, and queen/hair-style words.
    static let phrases: [String: String] = [
        "头发": "頭髮", "理发": "理髮", "白发": "白髮", "金发": "金髮", "假发": "假髮", "毛发": "毛髮", "发型": "髮型",
        "发现": "發現", "发展": "發展", "发生": "發生", "出发": "出發", "开发": "開發", "发表": "發表",
        "皇后": "皇后", "王后": "王后", "太后": "太后", "皇太后": "皇太后",
        "以后": "以後", "之后": "之後", "然后": "然後", "后来": "後來", "后面": "後面", "最后": "最後",
        "面条": "麵條", "面包": "麵包", "方便面": "方便麵", "面粉": "麵粉", "面前": "面前",
        "一只": "一隻", "两只": "兩隻", "三只": "三隻", "只有": "只有", "只是": "只是", "只要": "只要", "只能": "只能",
        "里面": "裡面", "这里": "這裡", "那里": "那裡", "哪里": "哪裡", "公里": "公里", "千里": "千里", "万里": "萬里",
        "时钟": "時鐘", "钟情": "鍾情", "闹钟": "鬧鐘",
        "制度": "制度", "制定": "制定", "制作": "製作", "制造": "製造", "控制": "控制", "限制": "限制", "体制": "體制",
        "斗争": "鬥爭", "战斗": "戰鬥", "北斗": "北斗", "斗篷": "斗篷", "斗胆": "斗膽",
        "干净": "乾淨", "干部": "幹部", "干杯": "乾杯", "干嘛": "幹嘛", "干活": "幹活", "干涉": "干涉", "相干": "相干",
        "台湾": "台灣", "平台": "平臺", "舞台": "舞臺", "阳台": "陽臺", "台风": "颱風",
    ]

    /// Characters whose conversion depends on the word they sit in.
    private static let ambiguous: Set<Unicode.Scalar> = Set("发后干斗钟只里制面台".unicodeScalars)
    /// Ambiguous characters whose dictionary default is right far more often than not.
    private static let defaultSafe: Set<Unicode.Scalar> = Set("发后钟".unicodeScalars)

    static func toTraditional(_ text: String) -> String {
        let icu = HanScript.traditional(text)
        let source = Array(text.unicodeScalars)
        let converted = Array(icu.unicodeScalars)
        guard source.count == converted.count else {
            // Not a one-to-one conversion: only convert when no ambiguous character is involved.
            return source.contains(where: ambiguous.contains) ? text : icu
        }
        var out = converted
        var covered = [Bool](repeating: false, count: source.count)

        // Known phrases win (longest first at each position).
        let keys = phrases.keys.map { Array($0.unicodeScalars) }.sorted { $0.count > $1.count }
        var i = 0
        while i < source.count {
            var matched = false
            for key in keys where i + key.count <= source.count && Array(source[i..<(i + key.count)]) == key {
                let value = Array(phrases[String(String.UnicodeScalarView(key))]!.unicodeScalars)
                if value.count == key.count {
                    for k in 0..<key.count { out[i + k] = value[k]; covered[i + k] = true }
                    i += key.count
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }

        // Uncovered ambiguous characters: trust the converter's own word context; otherwise leave
        // the character alone rather than guess.
        for index in source.indices where !covered[index] && ambiguous.contains(source[index]) {
            if defaultSafe.contains(source[index]) { continue }
            let alone = HanScript.traditional(String(Character(source[index]))).unicodeScalars.first
            if converted[index] == alone { out[index] = source[index] }
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: out)
        return String(view)
    }
}
