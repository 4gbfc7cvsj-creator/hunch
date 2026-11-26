// Detects a suggestion that repeats (or translates) the framer's own header text. Pure.
import Foundation
import HunchCore

/// The document framer's preface can leak into the output on very short prompts, sometimes translated
/// into the writer's language. HunchText does not depend on HunchPrompt, so this holds its own copy of the
/// current header wording (a list that must be kept in step when a framer wording changes) and accepts
/// extra phrases through `DefaultPostProcessor.prefaceTexts`.
enum PrefaceEcho {
    /// Header and label wording of the document framer (v1 and v2) at the time of writing.
    static let builtInPhrases: [String] = [
        "A personal piece of writing, reproduced exactly as its author typed it.",
        "Written by one person in their own words, exactly as they typed it.",
        "Notes on the writer and their style",
        "The author's own notes on how they write, which this text follows",
        "Material the author had open nearby (not part of this text)",
        "Nearby text visible alongside this piece (reference)",
        "Conversation visible alongside this piece, oldest first; lines marked Me are the writer's (reference)",
        "The conversation the author had open, oldest first; lines marked Me are the author's (not part of this text)",
        "Text that already follows this passage (reference)",
        "Text that comes later in this piece (not to be repeated here)",
        "Passage the writer recently copied (reference)",
        "Languages the writer uses",
        "Place of writing",
        "Where this piece was typed",
        "Notes on this piece",
        "The author writes in",
        "The author's notes for this piece, which it follows",
        "Excerpt the author copied earlier (not part of this text)",
        "Earlier sentences by the same writer (for tone and word choice only)",
        "Earlier lines by this author, showing how they phrase things (not part of this text)",
        "A source file, reproduced exactly as its author typed it.",
        "Source code written by one person, exactly as they typed it.",
    ]

    /// Chinese renderings of the header idea. A hit needs a term from two different groups, so ordinary
    /// sentences that merely mention an author or writing do not trip it.
    static let chineseGroups: [[String]] = [
        ["个人写作", "个人文章", "一篇个人", "一段个人", "个人的文字", "一个人写的", "一个人的文字", "自己的话"],
        ["作者", "笔者", "写作者"],
        ["原样", "原封不动", "逐字", "如实", "完全按照", "一字不差", "照原样", "键入的", "打出来的"],
    ]

    /// Lowercased text reduced to letters and digits per word, joined by single spaces.
    static func normalized(_ text: String) -> String {
        TextMeasure.normalizedWords(text).joined(separator: " ")
    }

    static func echoes(_ suggestion: String, phrases: [String]) -> Bool {
        let words = TextMeasure.normalizedWords(suggestion)
        if words.count >= 4 {
            for phrase in builtInPhrases + phrases where sharesRun(words, TextMeasure.normalizedWords(phrase)) {
                return true
            }
        }
        return chineseHit(suggestion)
    }

    /// Three or more consecutive words of the suggestion appear consecutively in the phrase
    /// (a phrase shorter than three words must match entirely).
    private static func sharesRun(_ words: [String], _ phrase: [String]) -> Bool {
        let run = min(3, phrase.count)
        guard run >= 2, words.count >= run else { return false }
        for start in 0...(words.count - run) {
            let slice = Array(words[start..<(start + run)])
            if phrase.count >= run, (0...(phrase.count - run)).contains(where: { Array(phrase[$0..<($0 + run)]) == slice }) {
                return true
            }
        }
        return false
    }

    private static func chineseHit(_ text: String) -> Bool {
        guard text.unicodeScalars.contains(where: TextMeasure.isCJK) else { return false }
        let text = HanScript.simplified(text)   // keyword groups are simplified
        let hits = chineseGroups.filter { group in group.contains(where: { text.contains($0) }) }.count
        return hits >= 2
    }
}
