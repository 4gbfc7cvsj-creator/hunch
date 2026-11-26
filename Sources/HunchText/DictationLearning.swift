import Foundation
import HunchCore

// Dictation's chat style, learned fixes, and finding the fixes the user makes to dictated text.
// Pure, so it is tested without a field or a model.

extension DictationText {
    // MARK: Chat style

    /// Chat messages are written the casual way: all lowercase, and only commas and question marks.
    /// Periods, colons, semicolons and exclamation marks stay only when the transcript shows the
    /// user said them ("period", 句號); capitals stay when they said "capital" or "caps". Applied after
    /// the cleanup too, since a small model doesn't always follow the prompt.
    public static func chatStyle(_ text: String, transcript: String) -> String {
        let said = transcript.lowercased()
        func spoke(_ words: [String]) -> Bool { words.contains { said.contains($0) } }
        var out = text
        if !spoke(["capital", "caps", "大寫", "大写"]) { out = out.lowercased() }
        if !spoke(["period", "full stop", "句號", "句号"]) {
            // A sentence-ending period (not a decimal point, "...", "e.g." or a domain).
            out = out.replacingOccurrences(of: #"(?<![.\s\d])(?<!\b\p{L}\.\p{L})\.(?=\s|$)"#, with: "",
                                           options: .regularExpression)
            out = out.replacingOccurrences(of: "。", with: " ")
        }
        if !spoke(["exclamation", "驚嘆號", "感嘆號", "惊叹号", "感叹号"]) {
            out = out.replacingOccurrences(of: #"[!！]+"#, with: "", options: .regularExpression)
        }
        if !spoke(["semicolon", "分號", "分号"]) {
            out = out.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "；", with: "，")
        }
        if !spoke(["colon", "冒號", "冒号"]) {
            // Not in a time (3:30) or a link (https://).
            out = out.replacingOccurrences(of: #"(?<!\d):(?!\d|//)"#, with: "", options: .regularExpression)
            out = out.replacingOccurrences(of: "：", with: " ")
        }
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+([,，?？])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // A full-width ？ after English is the ASCII one.
        out = out.replacingOccurrences(of: #"(?<=[A-Za-z0-9'’])？"#, with: "?", options: .regularExpression)
        // The transcript ended on a question, or a Chinese line ends in 嗎, and the mark is missing.
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = out.last, !"?？".contains(last),
           heard.last.map({ "?？".contains($0) }) == true || "嗎吗".contains(last) {
            out += isCJK(last) ? "？" : "?"
        }
        return out
    }

    // MARK: Learned fixes

    /// `text` with each enabled fix applied: whole words, any case; where two overlap, the longer
    /// mishearing wins, and nothing a fix wrote is changed again. Returns the fixes that applied.
    public static func applyFixes(_ fixes: [DictationFix], to text: String) -> (text: String, applied: [DictationFix]) {
        let ns = text as NSString
        var taken: [(range: NSRange, fix: DictationFix)] = []
        for fix in fixes.filter(\.enabled).sorted(by: { $0.heard.count > $1.heard.count }) {
            let heard = fix.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, heard != fix.written else { continue }
            let pattern: String
            if heard.contains(where: isCJK) {
                pattern = NSRegularExpression.escapedPattern(for: heard)
            } else {
                let words = heard.split(whereSeparator: \.isWhitespace)
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where !taken.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
                if ns.substring(with: match.range) != fix.written { taken.append((match.range, fix)) }
            }
        }
        var out = text
        for item in taken.sorted(by: { $0.range.location > $1.range.location }) {
            out = (out as NSString).replacingCharacters(in: item.range, with: item.fix.written)
        }
        var applied: [DictationFix] = []
        for item in taken where !applied.contains(where: { $0.id == item.fix.id }) { applied.append(item.fix) }
        return (out, applied)
    }

    // MARK: Finding the user's fixes

    /// One fix the user made to dictated text.
    public struct Correction: Sendable, Equatable {
        /// What the user wrote, for the learned-words list.
        public var word: String
        /// The replace rule: what was there and what to write instead. With a neighbouring word
        /// when the misheard word is a real word ("clock code" → "Claude Code", so "clock" alone
        /// stays); nil when there was no neighbour to take.
        public var rule: (heard: String, written: String)?

        public init(word: String, rule: (heard: String, written: String)?) {
            self.word = word
            self.rule = rule
        }

        public static func == (x: Correction, y: Correction) -> Bool {
            x.word == y.word && x.rule?.heard == y.rule?.heard && x.rule?.written == y.rule?.written
        }
    }

    public enum EditCheck: Sendable, Equatable {
        /// The dictated text is no longer in the field (sent, deleted or rewritten).
        case gone
        /// Still there; these are the fixes made inside it so far (none when untouched).
        case present([Correction])
    }

    /// Compares the dictated text with the field's text now. Only swaps inside the dictated text
    /// count: text typed before or after it, added or deleted words, and edits that change more than
    /// half of it (a rewrite) are not fixes. A fix needs a real word on the written side (not a
    /// common word, at least three letters or two Chinese characters) that resembles what it
    /// replaced. `chat`: capitals are not fixes there (the chat style lowercases them).
    /// `isKnownWord`: a correctly spelled dictionary word (its rule then takes a neighbour).
    public static func corrections(inserted: String, field: String, chat: Bool,
                                   isKnownWord: (String) -> Bool = { _ in false }) -> EditCheck {
        let a = wordTokens(inserted)
        let b = wordTokens(field)
        guard !a.isEmpty, a.count <= 400, b.count <= 6000 else { return .gone }
        let ops = align(a.map(\.folded), b.map(\.folded))
        let matched = ops.filter { if case .match = $0 { true } else { false } }.count
        guard Double(matched) >= Double(a.count) * 0.5 else { return .gone }

        // Runs of edits between matched words.
        var blocks: [(old: [Int], new: [Int])] = []
        var current: (old: [Int], new: [Int]) = ([], [])
        var caseOnly: [(Int, Int)] = []
        for op in ops {
            switch op {
            case .match(let i, let j):
                if !current.old.isEmpty || !current.new.isEmpty { blocks.append(current) }
                current = ([], [])
                if a[i].text != b[j].text { caseOnly.append((i, j)) }
            case .substitute(let i, let j):
                current.old.append(i)
                current.new.append(j)
            case .delete(let i): current.old.append(i)
            case .insert(let j): current.new.append(j)
            }
        }
        if !current.old.isEmpty || !current.new.isEmpty { blocks.append(current) }
        // Words typed before or after the dictated text are not edits of it.
        let editedOld = blocks.reduce(0) { $0 + $1.old.count }
        guard Double(editedOld) <= Double(a.count) * 0.5 else { return .present([]) }

        var found: [Correction] = []
        var seen: Set<String> = []
        func add(_ word: String, rule: (heard: String, written: String)?) {
            guard seen.insert(DictationFix.key(word)).inserted else { return }
            found.append(Correction(word: word, rule: rule))
        }
        // Matched pairs by position, to take a neighbour for a rule.
        var partner: [Int: Int] = [:]
        for op in ops { if case .match(let i, let j) = op { partner[i] = j } }
        func rule(_ old: [Int], _ new: [Int]) -> (heard: String, written: String)? {
            let heard = span(inserted, old.map { a[$0] })
            let written = span(field, new.map { b[$0] })
            guard old.count == 1, !a[old[0]].isHan, isKnownWord(a[old[0]].text) else { return (heard, written) }
            if let i = old.last.map({ $0 + 1 }), let j = partner[i], j == (new.last ?? -2) + 1 {
                return (span(inserted, [a[old[0]], a[i]]), span(field, [b[new[0]], b[j]]))
            }
            if let i = old.first.map({ $0 - 1 }), let j = partner[i], j == (new.first ?? -2) - 1 {
                return (span(inserted, [a[i], a[old[0]]]), span(field, [b[j], b[new.last!]]))
            }
            return nil
        }
        for block in blocks where !block.old.isEmpty && !block.new.isEmpty {
            let oldWords = block.old.map { a[$0] }
            let newWords = block.new.map { b[$0] }
            let han = newWords.contains(where: \.isHan)
            guard han == oldWords.contains(where: \.isHan),
                  oldWords.count <= (han ? 4 : 3), newWords.count <= (han ? 4 : 3) else { continue }
            let heard = span(inserted, oldWords)
            let written = span(field, newWords)
            guard isWorthLearning(heard: heard, written: written, words: newWords, han: han) else { continue }
            add(written, rule: rule(block.old, block.new))
        }
        // "iphone" → "iPhone", "alex" → "Alex" mid-sentence (not in chat).
        if !chat {
            for (i, j) in caseOnly {
                let written = b[j].text
                let rest = written.dropFirst()
                let innerCapital = rest.contains { $0.isUppercase }
                let namedMidSentence = written.first?.isUppercase == true && !startsSentence(a[i], in: inserted)
                guard innerCapital || namedMidSentence, written.count >= 3,
                      !commonWords.contains(b[j].folded) else { continue }
                add(written, rule: (a[i].text, written))
            }
        }
        return .present(found)
    }

    static func isWorthLearning(heard: String, written: String, words: [WordToken], han: Bool) -> Bool {
        guard DictationFix.key(heard) != DictationFix.key(written) else { return false }
        if han {
            // Homophones share no letters to compare: same length, and a real word.
            return written.count >= 2 && written.count == heard.count
        }
        guard written.filter(\.isLetter).count >= 3, !words.allSatisfy({ commonWords.contains($0.folded) })
        else { return false }
        let x = Array(heard.lowercased()), y = Array(written.lowercased())
        return Double(editDistance(x, y)) / Double(max(x.count, y.count)) <= 0.7
    }

    /// The original text from the first to the last of `words`.
    static func span(_ text: String, _ words: [WordToken]) -> String {
        guard let first = words.first, let last = words.last else { return "" }
        return String(text[first.range.lowerBound..<last.range.upperBound])
    }

    static func startsSentence(_ word: WordToken, in text: String) -> Bool {
        let before = text[..<word.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = before.last else { return true }
        return ".!?。！？\n".contains(last)
    }

    // MARK: Words and alignment

    struct WordToken: Equatable {
        var text: String
        var folded: String
        var range: Range<String.Index>
        var isHan: Bool
    }

    /// Words with spaces between them as words; Chinese and Japanese one character at a time.
    static func wordTokens(_ text: String) -> [WordToken] {
        var out: [WordToken] = []
        var start: String.Index?
        func flush(_ end: String.Index) {
            guard let s = start else { return }
            var e = end
            // Keep "v1.2" and "don't", not a trailing period or quote.
            while e > s, let c = text[text.index(before: e)...].first, !(c.isLetter || c.isNumber) {
                e = text.index(before: e)
            }
            if e > s {
                let word = String(text[s..<e])
                out.append(WordToken(text: word, folded: word.lowercased().replacingOccurrences(of: "’", with: "'"),
                                     range: s..<e, isHan: false))
            }
            start = nil
        }
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if isCJK(c), c.isLetter {
                flush(i)
                let next = text.index(after: i)
                out.append(WordToken(text: String(c), folded: String(c), range: i..<next, isHan: true))
            } else if c.isLetter || c.isNumber {
                if start == nil { start = i }
            } else if start != nil, "'’-_.".contains(c) {
                // Inside a word.
            } else {
                flush(i)
            }
            i = text.index(after: i)
        }
        flush(text.endIndex)
        return out
    }

    enum AlignOp: Equatable {
        case match(Int, Int), substitute(Int, Int), delete(Int), insert(Int)
    }

    /// Aligns all of `a` against the best-matching stretch of `b` (words of `b` before and after it
    /// are free), by edit distance on words.
    static func align(_ a: [String], _ b: [String]) -> [AlignOp] {
        let n = a.count, m = b.count
        let width = m + 1
        var d = [Int32](repeating: 0, count: (n + 1) * width)
        for i in 0...n { d[i * width] = Int32(i) }
        for i in stride(from: 1, through: n, by: 1) {
            for j in stride(from: 1, through: m, by: 1) {
                let sub = d[(i - 1) * width + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                let del = d[(i - 1) * width + j] + 1
                let ins = d[i * width + j - 1] + 1
                d[i * width + j] = min(sub, del, ins)
            }
        }
        // The cheapest end in `b`; on a tie, the latest (text typed after is the usual case).
        var j = 0
        for k in 0...m where d[n * width + k] <= d[n * width + j] { j = k }
        var i = n
        var ops: [AlignOp] = []
        while i > 0 {
            let here = d[i * width + j]
            if j > 0, here == d[(i - 1) * width + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                ops.append(a[i - 1] == b[j - 1] ? .match(i - 1, j - 1) : .substitute(i - 1, j - 1))
                i -= 1
                j -= 1
            } else if here == d[(i - 1) * width + j] + 1 {
                ops.append(.delete(i - 1))
                i -= 1
            } else {
                ops.append(.insert(j - 1))
                j -= 1
            }
        }
        return ops.reversed()
    }

    static func editDistance(_ x: [Character], _ y: [Character]) -> Int {
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var previous = row[0]
            row[0] = i
            for j in 1...y.count {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = saved
            }
        }
        return row[y.count]
    }

    /// Everyday words: swapping one for another is an edit of what was said, not a word to learn.
    static let commonWords: Set<String> = Set("""
        the and for not with you this but his her from they say she will one all would there their what out \
        about who get which when make can like time just him know take into year your good some could them see \
        other than then now look only come over think also back after use two how our work first well way even \
        new want because any these give day most are was were been has had did does said went made got came \
        took saw knew thought where why here very much many still too again off down never every own same \
        another both each few more less last next while before through under between should might must being \
        have that its yes okay sure thanks thank please sorry maybe really right left today tomorrow tonight \
        week month send sent call meet meeting let lets let's i'm i'll i've i'd don't can't won't it's that's \
        going doing done need needs great nice fine cool yeah nope
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}
