import Foundation

/// Sender header lines in chat apps (Discord, Slack): a line ending in the time, after the sender's
/// name or alone when OCR missed a short or styled name (`Nora 10:14 AM`, `Yesterday at 4:06 PM`).
/// They repeat for real, so screen cleanup keeps them instead of dropping them as duplicate chrome.
/// Pure.
enum ChatHeader {
    /// Longest name accepted in a header line, in characters.
    static let nameLimit = 32

    /// "10:14 AM", "10:14", "Today at 9:41 PM", "Yesterday at 10:02 AM", "11/02/2026 10:14 AM".
    nonisolated(unsafe) static let timePattern =
        /(?i)(?:(?:today|yesterday) at |\d{1,2}\/\d{1,2}\/\d{2,4},? )?\d{1,2}:\d{2}(?: ?[ap]\.?m\.?)?/

    /// Words a sentence ending in a time often ends with ("see you at 10:30 AM"): not a name.
    static let notNameEndings: Set<String> = ["at", "by", "until", "till", "before", "after", "around", "from",
                                              "to", "for", "since", "about", "is", "was", "the", "@"]

    /// True for a header line: a time at the end, with nothing before it or a plausible name.
    static func isHeader(_ line: String) -> Bool {
        guard let m = line.firstMatch(of: timePattern), m.range.upperBound == line.endIndex else { return false }
        let before = String(line[..<m.range.lowerBound])
        if !before.contains(where: { $0.isLetter || $0.isNumber }) { return true }
        return name(before) != nil
    }

    /// A plausible display name: short, no sentence punctuation, not ending like a sentence.
    /// Decoration before the name is skipped; a badge after it (`>w<`, `*`, one character) ends it.
    static func name(_ raw: String) -> String? {
        func isNameCharacter(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "." || c == "'" || c == "-"
        }
        var words: [String] = []
        for token in raw.split(whereSeparator: \.isWhitespace) {
            var word = Substring(token)
            while let last = word.last, !(isNameCharacter(last) || last == ")") { word.removeLast() }
            while let first = word.first, !(first.isLetter || first.isNumber || first == "_") { word.removeFirst() }
            if word.isEmpty && words.isEmpty { continue }
            if word.isEmpty || (!words.isEmpty && (word.count != token.count || word.count == 1)) { break }
            if word.contains(where: { !(isNameCharacter($0) || $0 == "(" || $0 == ")") }) { break }
            words.append(String(word))
        }
        let name = words.joined(separator: " ")
        guard !name.isEmpty, name.count <= nameLimit, words.count <= 4 else { return nil }
        if name.contains(where: { "?!,;:".contains($0) }) { return nil }
        // After a badge ends the name, only decoration may follow, not more words of a sentence.
        let tokens = raw.split(whereSeparator: \.isWhitespace)
        let leading = tokens.prefix { !$0.contains(where: { $0.isLetter || $0.isNumber }) }.count
        if tokens.dropFirst(leading + words.count).contains(where: { $0.filter(\.isLetter).count >= 3 }) { return nil }
        if let lastWord = words.last, notNameEndings.contains(lastWord.lowercased()) { return nil }
        return name
    }
}
