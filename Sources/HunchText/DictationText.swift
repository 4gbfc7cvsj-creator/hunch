import Foundation
import HunchCore

/// Text handling around dictation: what whisper hands back, what the cleanup model hands back, and
/// fitting the result into the field. Pure, so it is tested without audio or a model.
public enum DictationText {
    // MARK: Transcript

    /// Whisper's transcript without its non-speech markers ("[BLANK_AUDIO]", "(music)", "[Music]",
    /// "*laughs*") and the subtitle credits it invents on silence. Empty when nothing was said.
    public static func scrubTranscript(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\[[^\]]{1,40}\]"#, #"\((?:music|applause|laughter|laughs|silence|noise|inaudible|blank_audio)\)"#,
                        #"\*[^*\n]{1,30}\*"#, #"（[^）]{1,20}）"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isPhantom(collapsed) ? "" : collapsed
    }

    /// Lines whisper writes on silence, with case, spaces and punctuation taken out.
    static let phantomLines: Set<String> = [
        "thanksforwatching", "thankyouforwatching", "thankyousomuchforwatching", "thanksforwatchingeveryone",
        "pleasesubscribe", "likeandsubscribe", "pleaselikeandsubscribe", "pleasesubscribetomychannel",
    ]
    /// Subtitle credits whisper invents on silence: a line starting with one of these.
    static let phantomPrefixes = ["字幕由", "字幕by", "subtitlesby", "請不吝點贊", "请不吝点赞"]

    /// Every sentence is a phantom line or credit: a real sentence that merely holds the words
    /// ("Thanks for watching the kids", "我想訂閱這個頻道") stays.
    static func isPhantom(_ text: String) -> Bool {
        // A period ends a sentence only before a space or the end ("Amara.org" stays whole).
        let sentences = text.replacingOccurrences(of: #"[.!?](?=\s|$)|[。！？\n]"#, with: "\n",
                                                  options: .regularExpression)
            .split(separator: "\n")
            .map { line in
                String(String.UnicodeScalarView(line.lowercased().unicodeScalars.filter {
                    $0.properties.isAlphabetic || $0.properties.numericType != nil
                }))
            }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return false }
        return sentences.allSatisfy { line in
            phantomLines.contains(line) || phantomPrefixes.contains(where: { line.hasPrefix($0) })
        }
    }

    /// Nothing but filler or punctuation: nothing to insert.
    public static func isEmptySpeech(_ text: String) -> Bool {
        let fillers: Set<String> = ["um", "uh", "er", "erm", "hmm", "mm", "ah", "oh", "嗯", "呃", "啊", "欸"]
        return tokens(text).allSatisfy { fillers.contains($0) }
    }

    // MARK: Cleanup output

    public enum Rejection: String, Sendable, Equatable {
        case empty, doubled, copiedContext, tooLong, tooShort
    }

    public enum Verdict: Sendable, Equatable {
        case accept(String)
        case reject(Rejection)
    }

    /// Checks the cleanup's reply against the transcript; on any rejection the raw transcript goes in.
    /// - tooLong: it added a lot (an answer, an explanation, a continuation).
    /// - tooShort: it lost most of what was said (cut off, or it summarised).
    /// - doubled: the cleaned text twice in a row.
    /// - copiedContext: a run of the field's text that wasn't said.
    public static func check(_ reply: String, transcript: String, textBefore: String?) -> Verdict {
        let text = stripWrappers(reply)
        guard !text.isEmpty else { return .reject(.empty) }
        let said = tokens(transcript)
        let out = tokens(text)
        if isDoubled(out, said: said) { return .reject(.doubled) }
        if let before = textBefore, copiesContext(out, context: tokens(before), said: said) {
            return .reject(.copiedContext)
        }
        if Double(out.count) > Double(said.count) * 1.6 + 8 { return .reject(.tooLong) }
        if said.count >= 12, Double(out.count) < Double(said.count) * 0.35 { return .reject(.tooShort) }
        return .accept(text)
    }

    /// Removes tags and labels a model may wrap its reply in.
    public static func stripWrappers(_ reply: String) -> String {
        var text = reply.replacingOccurrences(of: "</?transcript>", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = ["cleaned transcript:", "cleaned text:", "written:", "output:", "cleaned:"]
        if let label = labels.first(where: { text.lowercased().hasPrefix($0) }) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// The same run of at least six words twice, back to back, that wasn't said twice.
    static func isDoubled(_ out: [String], said: [String]) -> Bool {
        guard out.count >= 12, out.count % 2 == 0 else { return false }
        let half = out.count / 2
        guard Array(out[..<half]) == Array(out[half...]) else { return false }
        // Said twice for real: the transcript holds (nearly) every word of the half twice.
        var counts: [String: Int] = [:]
        for t in said { counts[t, default: 0] += 1 }
        let twice = out[..<half].filter { (counts[$0] ?? 0) >= 2 }.count
        return Double(twice) < Double(half) * 0.8
    }

    /// Eight or more words in a row from the field's text that the transcript doesn't have.
    static func copiesContext(_ out: [String], context: [String], said: [String], run: Int = 8) -> Bool {
        guard out.count >= run, context.count >= run else { return false }
        func grams(_ t: [String]) -> Set<[String]> {
            guard t.count >= run else { return [] }
            return Set((0...(t.count - run)).map { Array(t[$0..<($0 + run)]) })
        }
        let fromContext = grams(context).subtracting(grams(said))
        guard !fromContext.isEmpty else { return false }
        return !grams(out).isDisjoint(with: fromContext)
    }

    /// Lowercased words for comparing texts; Chinese and Japanese split into words by the system.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        folded.enumerateSubstrings(in: folded.startIndex..., options: [.byWords, .localized]) { word, _, _, _ in
            // With `.localized` the system also hands back the spaces between Chinese words.
            if let word, word.contains(where: { $0.isLetter || $0.isNumber }) {
                out.append(word.replacingOccurrences(of: "'", with: ""))
            }
        }
        return out
    }

    // MARK: Fitting into the field

    /// `text` as it should go in after `before`: a space in front when both sides are words written
    /// with spaces (not Chinese or Japanese, not after a space, a line break or an opening bracket).
    public static func fitted(_ text: String, after before: String) -> String {
        guard let last = before.last, let first = text.first else { return text }
        if last.isWhitespace || "([{“‘\"'/-".contains(last) { return text }
        if isCJK(last) || isCJK(first) { return text }
        if first.isLetter || first.isNumber || "(“\"'".contains(first) { return " " + text }
        return text
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains {
            switch $0.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                true
            default: false
            }
        }
    }

    // MARK: Names from the screen and the window title

    /// Words that look like names or terms, most frequent first: capitalized words that don't start
    /// a sentence (and runs of them, "Alex Morgan"), words with inner capitals or digits ("iOS",
    /// "GPT-5", "McKinsey"). Chinese has no capitals to go by, so none is taken from it.
    public static func names(in text: String, limit: Int = 30) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        func add(_ name: String) {
            guard name.count >= 2, name.count <= 40 else { return }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let pattern = #"[\p{L}\p{N}][\p{L}\p{N}'’._\-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var run: [String] = []
        var previousEnd = 0
        func flush() {
            if !run.isEmpty { add(run.joined(separator: " ")) }
            run = []
        }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var word = ns.substring(with: match.range)
            while let tail = word.last, ".-_'’".contains(tail) { word.removeLast() }
            let gap = ns.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
            let isFirst = previousEnd == 0
            previousEnd = match.range.location + match.range.length
            let sentenceStart = isFirst || gap.contains(where: { ".!?。！？\n:|•·—–".contains($0) })
            // A run of capitalized words continues only across plain spaces.
            if !gap.allSatisfy({ $0 == " " }) { flush() }
            guard isNameLike(word, sentenceStart: sentenceStart) else { flush(); continue }
            if run.count < 3 { run.append(word) } else { flush(); run = [word] }
        }
        flush()
        // Most frequent first; ties keep the order they appeared in.
        return order.enumerated().sorted { a, b in
            let (ca, cb) = (counts[a.element]!, counts[b.element]!)
            return ca != cb ? ca > cb : a.offset < b.offset
        }.prefix(limit).map(\.element)
    }

    static func isNameLike(_ word: String, sentenceStart: Bool) -> Bool {
        guard let first = word.first, first.isLetter, !word.contains(where: isCJK) else { return false }
        if commonCapitalized.contains(word.lowercased()) { return false }
        let rest = word.dropFirst()
        // "Hunch", "McKinsey", and "iOS", "eBay".
        let innerCapital = rest.contains { $0.isUppercase } && (first.isLowercase || rest.contains { $0.isLowercase })
        let lettersAndDigits = word.contains { $0.isNumber }
        if innerCapital || lettersAndDigits { return true }
        if word.count >= 2, word.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "-" }) { return true }  // NASA
        return first.isUppercase && !sentenceStart
    }

    /// Capitalized for grammar, not because they name anything.
    static let commonCapitalized: Set<String> = [
        "i", "i'm", "i've", "i'll", "i'd", "the", "a", "an", "and", "or", "but", "if", "this", "that", "it", "we",
        "you", "he", "she", "they", "my", "our", "your", "ok", "okay", "yes", "no", "hi", "hello", "thanks",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "re", "fw", "fwd", "new", "edit", "view", "file", "window", "help", "untitled", "inbox", "draft",
    ]
}
