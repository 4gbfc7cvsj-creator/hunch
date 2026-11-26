import Foundation

/// The message a reply answers, read from screen text whose chat lines say who wrote them
/// ("Me: …", "Them: …" or a sender's name, from `ChatSides`), and how alike two such messages are.
/// Learned replies (`LearnedReplies`) match only this, never anything else on screen, so a question
/// answered further up can never bring back its answers.
public enum ReplyQuestion {
    /// Their lines after my last one: their newest message, kept to the last `maxLines` (an AI's
    /// answer spans several paragraphs, and the question is often not the last one). Nil when my
    /// own message is the newest, or nothing is labeled theirs. List items and status rows
    /// (`isListOrStatus`) are skipped: an app's checklist is not part of their message.
    public static func theirNewest(screen: String?, maxLines: Int = 6) -> [String]? {
        guard let screen else { return nil }
        var run: [String] = [], lastIsMine = false, sawTheirs = false
        for line in screen.split(separator: "\n") {
            guard let (label, text) = labeled(line) else { continue }
            if label == meLabel {
                run = []
                lastIsMine = true
            } else if label.first?.isUppercase == true, !isListOrStatus(text) {
                run.append(text)
                lastIsMine = false
                sawTheirs = true
            }
        }
        guard sawTheirs, !lastIsMine, !run.isEmpty else { return nil }
        return Array(run.suffix(maxLines))
    }

    /// "Me" (`ChatSides.meLabel`, HunchScreen).
    static let meLabel = "Me"

    /// A line's speaker label and its text, when it has one.
    static func labeled(_ line: Substring) -> (label: Substring, text: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = line[..<colon], text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 30, !label.contains(where: \.isNumber), !text.isEmpty else { return nil }
        return (label, text)
    }

    /// The sentences of their message that ask for my answer: ones ending in a question mark,
    /// offering two or more quoted options ('Reply "Done testing" or "Skip testing"'), or starting
    /// with "Reply". None when nothing asks (a plain statement gets all kinds of answers, so there is
    /// no habit to learn). At most `maxKeys`, newest last, each at most 200 characters.
    public static func keySentences(_ lines: [String], maxKeys: Int = 4) -> [String] {
        lines.flatMap(Self.sentences).filter(isAsking).suffix(maxKeys).map { String($0.prefix(200)) }
    }

    static func isAsking(_ sentence: String) -> Bool {
        if looksLikeCode(sentence) { return false }
        if sentence.hasSuffix("?") || sentence.hasSuffix("？") { return true }
        if quoted(sentence).count >= 2 { return true }
        return sentence.lowercased().hasPrefix("reply ")
    }

    /// A line split after sentence ends (". ", "? ", "! " and the CJK marks), trimmed, non-empty.
    static func sentences(_ line: String) -> [String] {
        var out: [String] = [], current = ""
        let chars = Array(line)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if "。？！".contains(c) || (".?!".contains(c) && next.isWhitespace) {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// A command, path or tool-output row rather than words to answer ("> Ran grep -c "a" ~/x || …"):
    /// its quoted strings are arguments, not options, and a "?" in it asks nothing.
    static func looksLikeCode(_ sentence: String) -> Bool {
        let marks = ["~/", ">_", "&&", "||", "$(", "`", " | ", " --", "==", "->", "::"]
        if marks.contains(where: sentence.contains) { return true }
        return sentence.split(separator: " ").contains { w in w.filter { $0 == "/" }.count >= 2 }
    }

    /// Phrases in quotes, lowercased: the options a message offers. A quote opens with a double quote
    /// (straight or curly) or a single one after a space, and closes with either kind, so a mistyped
    /// pair ("Done testing') still counts; an apostrophe inside a word ("you've") never closes one.
    static func quoted(_ sentence: String) -> Set<String> {
        let doubles: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
        let singles: Set<Character> = ["'", "\u{2018}", "\u{2019}"]
        let chars = Array(sentence)
        var out: Set<String> = [], current: String?
        for (i, c) in chars.enumerated() {
            let prev = i > 0 ? chars[i - 1] : " ", next = i + 1 < chars.count ? chars[i + 1] : " "
            if let open = current {
                let closes = doubles.contains(c) || (singles.contains(c) && !(next.isLetter || next.isNumber))
                if closes {
                    let t = open.trimmingCharacters(in: .whitespaces).lowercased()
                    if !t.isEmpty, t.count <= 40 { out.insert(t) }
                    current = nil
                } else {
                    current?.append(c)
                }
            } else if doubles.contains(c) || (singles.contains(c) && !(prev.isLetter || prev.isNumber) && next.isLetter) {
                current = ""
            }
        }
        return out
    }

    /// Words that say nothing about which question it is.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "so", "to", "of", "in", "on", "at", "for", "with",
        "is", "are", "was", "be", "it", "its", "this", "that", "these", "those", "i", "you", "your", "me", "my",
        "we", "our", "do", "does", "did", "can", "could", "would", "will", "should", "any", "some", "when",
        "what", "how", "there", "here", "now", "just", "all", "from", "as", "by", "not", "no", "yes",
    ]

    /// Content words, lowercased; each Han character counts as a word.
    static func words(_ text: String) -> Set<String> {
        var out: Set<String> = []
        var word = ""
        func flush() {
            word = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !word.isEmpty, !stopwords.contains(word) { out.insert(word) }
            word = ""
        }
        for c in text.lowercased() {
            if c.unicodeScalars.first.map(HanScript.isHan) == true {
                flush()
                out.insert(String(c))
            } else if c.isLetter || c.isNumber || c == "'" {
                word.append(c)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// How alike two sentences are, 0...1: the share of their content words in common, or 1 when
    /// both offer at least two of the same quoted options, however the rest is worded ('Reply "Done
    /// testing" when you've checked the labels, or "Skip testing"' is the same question every time).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let qa = quoted(a), qb = quoted(b)
        if qa.intersection(qb).count >= 2 { return 1 }
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
    }

    /// The best match between any key sentence of one message and any of another.
    public static func similarity(_ a: [String], _ b: [String]) -> Double {
        var best = 0.0
        for x in a { for y in b { best = max(best, similarity(x, y)) } }
        return best
    }

    /// Marks that start a list item or a status row (OCR reads checkboxes and spinners as these).
    public static let listMarks: Set<Character> = ["•", "◦", "○", "●", "◌", "▪", "✓", "✔", "☐", "☑", "*", "©", "·", "›", "»"]

    /// A list item or a status row rather than a message: it starts with a list or status mark, or it
    /// is a few words without sentence punctuation that end in a chevron or hold a duration ("Ran 2
    /// commands ›", "Thinking 41s", "2m 13s • 3.1K tokens"). Chat messages rarely start with a bullet.
    public static func isListOrStatus(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return true }
        if listMarks.contains(first) { return true }
        if t.hasPrefix("- ") || t.hasPrefix("– ") { return true }
        let words = t.split(separator: " ")
        let sentenceEnd = t.range(of: #"[.?!](\s|$)|[。？！]"#, options: .regularExpression) != nil
        guard words.count <= 6, !sentenceEnd else { return false }
        if let last = t.last, "›»>".contains(last) { return true }
        return t.range(of: #"\b\d+(\.\d+)?\s?(s|m|ms|min|sec)\b"#, options: .regularExpression) != nil
    }
}
