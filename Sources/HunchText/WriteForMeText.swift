import Foundation
import HunchCore

// Pure text logic for "write for me": which text the shortcut works on, whether it reads as an
// instruction or a finished message, the draft's shape, cleanup of model output, and the words a
// polish changed.

/// The part of the field a write-for-me draft replaces: the selection, or else the paragraph the
/// caret is in (back to the previous blank line, on to the next one).
public struct WriteRange: Sendable, Equatable {
    /// The text that gets replaced, as it is in the field.
    public var source: String
    /// Characters to delete before the caret (Backspace presses).
    public var deleteBackward: Int
    /// Characters to delete after the caret (Forward Delete presses).
    public var deleteForward: Int
    /// The selection is the range: typing or pasting replaces it, nothing is deleted first.
    public var replacesSelection: Bool
    /// The field's text before and after the range (reference for the model, never replaced).
    public var textBefore: String
    public var textAfter: String

    public init(source: String, deleteBackward: Int, deleteForward: Int, replacesSelection: Bool,
                textBefore: String, textAfter: String) {
        self.source = source
        self.deleteBackward = deleteBackward
        self.deleteForward = deleteForward
        self.replacesSelection = replacesSelection
        self.textBefore = textBefore
        self.textAfter = textAfter
    }

    /// Longest range the shortcut works on, in characters.
    public static let maxCharacters = 6000

    /// What a lookup found: a range, nothing to work on, or a paragraph that runs past the edge of
    /// the text that was read (the read window cut it), so the field must be read wider first.
    public enum Lookup: Sendable, Equatable {
        case found(WriteRange)
        case nothing
        case needsWiderRead
    }

    /// How far a wider read reaches on each side: enough to tell whether a paragraph fits in
    /// `maxCharacters`.
    public static let widerReadLimits = ContextLimits(beforeChars: maxCharacters + 1, afterChars: maxCharacters + 1)

    /// The range for a read of the field (see `find`), or `.needsWiderRead` when the paragraph
    /// reaches a side the read cut short. With `dictated`, the paragraphs a dictation touched.
    public static func lookup(_ context: TextContext, dictated: String? = nil) -> Lookup {
        if let dictated {
            return lookup(before: context.before, after: context.after, selected: context.selectedText,
                          dictated: dictated, beforeIsCut: context.beforeIsCut, afterIsCut: context.afterIsCut)
        }
        return lookup(before: context.before, after: context.after, selected: context.selectedText,
                      beforeIsCut: context.beforeIsCut, afterIsCut: context.afterIsCut)
    }

    /// The range for the field's text around the caret, or nil when there is nothing to work on
    /// (only whitespace, or more than `maxCharacters`) or the paragraph runs into a cut side.
    public static func find(before: String, after: String, selected: String,
                            beforeIsCut: Bool = false, afterIsCut: Bool = false) -> WriteRange? {
        lookup(before: before, after: after, selected: selected, beforeIsCut: beforeIsCut,
               afterIsCut: afterIsCut).range
    }

    /// The paragraphs a dictation touched: from the start of the paragraph the dictated text begins in
    /// to the end of the paragraph the caret is in, with the text already there included.
    /// `dictated` is the text that went in, ending at the caret. Nil like `find`.
    public static func find(before: String, after: String, selected: String, dictated: String,
                            beforeIsCut: Bool = false, afterIsCut: Bool = false) -> WriteRange? {
        lookup(before: before, after: after, selected: selected, dictated: dictated, beforeIsCut: beforeIsCut,
               afterIsCut: afterIsCut).range
    }

    static func lookup(before: String, after: String, selected: String,
                       beforeIsCut: Bool, afterIsCut: Bool) -> Lookup {
        if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard selected.count <= maxCharacters else { return .nothing }
            return .found(WriteRange(source: selected, deleteBackward: 0, deleteForward: 0, replacesSelection: true,
                                     textBefore: before, textAfter: after))
        }
        // Start: just after the last blank line before the caret.
        return paragraphs(before: before, after: after, from: lastBlankLine(in: before) ?? before.startIndex,
                          beforeIsCut: beforeIsCut, afterIsCut: afterIsCut)
    }

    static func lookup(before: String, after: String, selected: String, dictated: String,
                       beforeIsCut: Bool, afterIsCut: Bool) -> Lookup {
        if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lookup(before: before, after: after, selected: selected, beforeIsCut: beforeIsCut,
                          afterIsCut: afterIsCut)
        }
        let body = String(dictated.drop(while: \.isWhitespace))
        func n(_ s: String) -> String { s.replacingOccurrences(of: "\u{00A0}", with: " ") }
        let start: String.Index
        if !body.isEmpty, n(before).hasSuffix(n(body)) {
            // The dictated text is still right before the caret: its paragraph starts after the last
            // blank line before it.
            let cut = before.index(before.endIndex, offsetBy: -body.count)
            start = before[..<cut].ranges(of: blankLine).last?.upperBound ?? before.startIndex
        } else {
            // The host changed it on the way in (spaces, line ends): go back one paragraph per
            // paragraph break it has.
            let breaks = body.ranges(of: blankLine).count
            let blanks = before.ranges(of: blankLine).map(\.upperBound)
            let index = blanks.count - 1 - breaks
            start = index >= 0 ? blanks[index] : before.startIndex
        }
        return paragraphs(before: before, after: after, from: start, beforeIsCut: beforeIsCut, afterIsCut: afterIsCut)
    }

    /// The range from `start` in `before` to the end of the caret's paragraph in `after`. A range that
    /// starts at the start of a cut `before`, or runs to the end of a cut `after`, would end in the
    /// middle of the field's text: `.needsWiderRead` (or `.nothing` once it is too long anyway).
    private static func paragraphs(before: String, after: String, from start: String.Index,
                                   beforeIsCut: Bool, afterIsCut: Bool) -> Lookup {
        let startIsCut = beforeIsCut && start == before.startIndex
        // Skip the whitespace that opens the paragraph (it stays in the field).
        var start = start
        while start < before.endIndex, before[start].isWhitespace { start = before.index(after: start) }
        let head = before[start...]
        // End: just before the next blank line after the caret, leaving trailing whitespace alone.
        var end = after.endIndex
        var endIsCut = afterIsCut
        if let blank = firstBlankLine(in: after) {
            end = blank
            endIsCut = false
        }
        var tailEnd = end
        while tailEnd > after.startIndex, after[after.index(before: tailEnd)].isWhitespace {
            tailEnd = after.index(before: tailEnd)
        }
        // The caret itself may sit in trailing whitespace past the paragraph's text.
        let tail = tailEnd > after.startIndex ? after[..<tailEnd] : ""
        let source = String(head) + tail
        if source.count > maxCharacters { return .nothing }
        if startIsCut || endIsCut { return .needsWiderRead }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        return .found(WriteRange(source: source, deleteBackward: head.count, deleteForward: tail.count,
                                 replacesSelection: false, textBefore: String(before[..<start]),
                                 textAfter: String(after[tail.endIndex...])))
    }

    /// An empty range at the caret: a draft written from a spoken description goes in there and
    /// replaces nothing. `before` and `after` are the field's text around the caret (reference).
    public static func atCaret(before: String, after: String) -> WriteRange {
        WriteRange(source: "", deleteBackward: 0, deleteForward: 0, replacesSelection: false,
                   textBefore: before, textAfter: after)
    }

    /// Nothing is replaced: the draft goes in at the caret (`atCaret`).
    public var isAtCaret: Bool { source.isEmpty && !replacesSelection }

    /// The text that goes into the field for `draft`: the draft without its outer whitespace, and for
    /// a selection, wrapped in the whitespace the selection began and ended with (a triple-click
    /// selects the paragraph's newline, a selected list item its indent), since the paste replaces
    /// all of it.
    public func insertion(for draft: String) -> String {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAtCaret, !body.isEmpty { return VoiceInstruction.separator(before: textBefore, draft: body) + body }
        guard replacesSelection, !body.isEmpty else { return body }
        let leading = source.prefix(while: \.isWhitespace)
        let trailing = source.reversed().prefix(while: \.isWhitespace).reversed()
        guard leading.count < source.count else { return body }
        return String(leading) + body + String(trailing)
    }

    /// The field still has this range where it was, as read again before inserting: the selection
    /// is the same text, or the text around the caret still ends and starts with the parts of the
    /// range on each side. Non-breaking spaces count as spaces (web editors report a trailing space
    /// either way). A side the read cut short (`beforeIsCut`, `afterIsCut`) may hold only the part of
    /// the range next to the caret: a range found by a wider read is longer than the usual window.
    public func stillHolds(before: String, after: String, selected: String, selectionLength: Int,
                           markedText: Bool, beforeIsCut: Bool = false, afterIsCut: Bool = false) -> Bool {
        func n(_ s: String) -> String { s.replacingOccurrences(of: "\u{00A0}", with: " ") }
        if replacesSelection { return n(selected) == n(source) }
        guard selectionLength == 0, !markedText else { return false }
        if isAtCaret {
            // Nothing to find in the field: the caret must still sit between the same texts.
            let b = Self.loose(before), a = Self.loose(after)
            let tb = Self.loose(textBefore), ta = Self.loose(textAfter)
            return b.hasSuffix(String(tb.suffix(40))) && a.hasPrefix(String(ta.prefix(40)))
        }
        let head = n(String(source.prefix(deleteBackward)))
        let tail = n(String(source.suffix(deleteForward)))
        let b = n(before), a = n(after)
        let headHolds = b.hasSuffix(head) || (beforeIsCut && !b.isEmpty && head.hasSuffix(b))
        let tailHolds = a.hasPrefix(tail) || (afterIsCut && !a.isEmpty && tail.hasPrefix(a))
        return headHolds && tailHolds
    }

    /// The range's own text is gone from the field (the deletes have landed): what was around it now
    /// meets at the caret. Whitespace runs count as one space and the ends are trimmed (an emptied web
    /// editor reports a leftover newline or non-breaking space); only the last and first `probe`
    /// characters are compared when the text around is longer, as a long field's read is windowed.
    public func isCleared(before: String, after: String, probe: Int = 40) -> Bool {
        if replacesSelection { return true }
        let b = Self.loose(before), a = Self.loose(after), tb = Self.loose(textBefore), ta = Self.loose(textAfter)
        let beforeOK = tb.count <= probe ? b == tb : b.hasSuffix(String(tb.suffix(probe)))
        let afterOK = ta.count <= probe ? a == ta : a.hasPrefix(String(ta.prefix(probe)))
        return beforeOK && afterOK
    }

    /// The range's own text no longer touches the caret on either side: neither the end of the part
    /// before the caret nor the start of the part after it is there. Weaker than `isCleared`; used
    /// once the field has stopped changing.
    public func isGoneFromCaret(before: String, after: String, probe: Int = 12) -> Bool {
        if replacesSelection { return true }
        let head = Self.loose(String(source.prefix(deleteBackward)))
        let tail = Self.loose(String(source.suffix(deleteForward)))
        let b = Self.loose(before), a = Self.loose(after)
        let headGone = head.isEmpty || !b.hasSuffix(String(head.suffix(probe)))
        let tailGone = tail.isEmpty || !a.hasPrefix(String(tail.prefix(probe)))
        return headGone && tailGone
    }

    /// Non-breaking spaces as spaces, whitespace runs as one space, ends trimmed.
    static func loose(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The draft has landed: the text before the caret ends with it. Whitespace runs count as one
    /// space (hosts turn pasted newlines into paragraphs or spaces), and only its last `probe`
    /// characters are compared.
    public static func showsDraft(_ draft: String, before: String, probe: Int = 40) -> Bool {
        let want = loose(draft)
        guard !want.isEmpty else { return true }
        return loose(before).hasSuffix(String(want.suffix(probe)))
    }

    /// Index just past the last blank line (a newline, optional spaces or tabs, a newline).
    static func lastBlankLine(in text: String) -> String.Index? {
        text.ranges(of: blankLine).last?.upperBound
    }

    /// Index of the newline that starts the first blank line.
    static func firstBlankLine(in text: String) -> String.Index? {
        text.firstRange(of: blankLine)?.lowerBound
    }

    nonisolated(unsafe) private static let blankLine = /\n[ \t]*\n/
}

extension WriteRange.Lookup {
    /// The range, if one was found.
    public var range: WriteRange? {
        if case .found(let range) = self { return range }
        return nil
    }
}

/// Han ideographs (CJK unified, extension A and B+, compatibility).
func isHanScalar(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
    default: false
    }
}

/// Write or polish: the panel's preset for the toggle. Short or command-like text is an
/// instruction; several sentences or a message to someone reads as finished text.
public enum WriteModeGuess {
    /// Openings that make text an instruction ("tell him…", "ask about…", "agree to…").
    static let commandWords: Set<String> = [
        "write", "draft", "reply", "respond", "answer", "tell", "ask", "say", "let", "agree", "accept", "decline",
        "refuse", "thank", "thanks", "confirm", "explain", "remind", "follow", "schedule", "invite", "apologize",
        "apologise", "request", "propose", "suggest", "summarize", "summarise", "describe", "announce", "inform",
        "congratulate", "welcome", "introduce", "cancel", "reschedule", "push", "offer", "mention", "make",
        "compose", "send", "give", "list", "note", "check", "politely", "nicely", "briefly", "quickly", "formally",
        "casually", "pls", "please",
    ]
    /// Greetings that open a message written to someone.
    static let greetings: [String] = ["hi", "hello", "hey", "dear", "good morning", "good afternoon", "good evening",
                                      "greetings", "hiya", "yo"]
    /// Instruction openings in Chinese (traditional and simplified).
    static let hanCommands: [String] = ["幫我", "帮我", "寫", "写", "回覆", "回复", "告訴", "告诉", "問", "问", "請", "请",
                                        "跟他說", "跟他说", "跟她說", "跟她说", "同意", "拒絕", "拒绝", "感謝", "感谢", "提醒",
                                        "確認", "确认", "解釋", "解释", "安排", "通知", "說", "说"]

    public static func guess(_ text: String) -> WriteMode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .write }
        let han = trimmed.unicodeScalars.filter { isHanScalar($0) }.count
        if han * 2 >= trimmed.unicodeScalars.filter({ !$0.properties.isWhitespace }).count {
            if hanCommands.contains(where: { trimmed.hasPrefix($0) }) && han < 80 { return .write }
            return han >= 40 || sentenceCount(trimmed) >= 3 ? .polish : .write
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        let first = words.first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        let lower = trimmed.lowercased()
        let opensWithGreeting = greetings.contains { g in
            lower.hasPrefix(g) && (lower.count == g.count || !lower[lower.index(lower.startIndex, offsetBy: g.count)].isLetter)
        }
        let sentences = sentenceCount(trimmed)
        let lines = trimmed.split(whereSeparator: \.isNewline).count
        if opensWithGreeting && (words.count >= 8 || lines >= 2) { return .polish }
        if commandWords.contains(first) && words.count < 60 && sentences <= 3 { return .write }
        if words.count >= 40 || sentences >= 3 || lines >= 3 { return .polish }
        return .write
    }

    /// Sentence ends followed by a space, newline or the end (". ", "!", "?", "。").
    static func sentenceCount(_ text: String) -> Int {
        var count = 0
        var previousWasEnd = false
        for c in text {
            let isEnd = c == "." || c == "!" || c == "?" || c == "。" || c == "！" || c == "？"
            if isEnd { previousWasEnd = true; continue }
            if previousWasEnd, c.isWhitespace || isHanScalar(c.unicodeScalars.first!) { count += 1 }
            previousWasEnd = false
        }
        if previousWasEnd { count += 1 }
        return count
    }
}

/// The draft shape for a field when the setting is `adaptive`.
public enum WriteShapeResolver {
    /// Web mail and chat sites, matched on the host's registrable part.
    static let mailHosts = ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
                            "mail.yahoo.com", "app.fastmail.com", "mail.proton.me", "mail.zoho.com", "www.icloud.com"]
    static let chatHosts = ["app.slack.com", "discord.com", "web.whatsapp.com", "www.messenger.com",
                            "messenger.com", "teams.microsoft.com", "web.telegram.org", "chat.google.com",
                            "www.linkedin.com", "x.com", "twitter.com", "www.instagram.com"]
    /// AI chat sites: what is typed there is a prompt.
    static let aiHosts = ["claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "aistudio.google.com",
                          "perplexity.ai", "copilot.microsoft.com", "chat.deepseek.com", "chat.mistral.ai",
                          "grok.com", "poe.com", "chat.qwen.ai", "kimi.com", "v0.dev", "bolt.new", "lovable.dev"]
    /// AI chat and agent apps (the current ChatGPT app is `com.openai.codex`; older ones `com.openai.chat`).
    static let aiApps: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
                                      "ai.perplexity.mac"]

    /// - Parameters:
    ///   - bundleID: the app the field is in.
    ///   - isAIChatInput: a code editor's AI chat or composer box.
    public static func resolve(_ setting: WriteShape, surface: SurfaceKind, urlHost: String?, bundleID: String = "",
                               isAIChatInput: Bool = false) -> WriteShape {
        guard setting == .adaptive else { return setting }
        func matches(_ host: String, _ list: [String]) -> Bool {
            list.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        }
        if let host = urlHost?.lowercased() {
            if matches(host, aiHosts) { return .aiPrompt }
            if matches(host, mailHosts) { return .email }
            if matches(host, chatHosts) { return .message }
        }
        if isAIChatInput || aiApps.contains(bundleID) { return .aiPrompt }
        switch surface {
        case .email: return .email
        case .agentPrompt: return .aiPrompt
        case .chat: return .message
        default: return .paragraph
        }
    }
}

/// The shape and wording a write-for-me request uses here, from the app's policy and the user's
/// shape library. A custom shape writes as a plain `paragraph` with its own text; on a polish it
/// is ignored (the text keeps its own shape) and the preset underneath decides.
public enum WriteShapeChoice {
    public static func resolve(policy: AppPolicy, library: WriteShapeLibrary, mode: WriteMode, surface: SurfaceKind,
                               urlHost: String?, bundleID: String = "",
                               isAIChatInput: Bool = false) -> (shape: WriteShape, text: String?) {
        if mode == .write, let custom = library.custom(policy.writeCustomShapeID) {
            return (.paragraph, custom.text)
        }
        let shape = WriteShapeResolver.resolve(policy.writeShape, surface: surface, urlHost: urlHost,
                                               bundleID: bundleID, isAIChatInput: isAIChatInput)
        return (shape, library.editedText(shape))
    }
}

/// The note a prompt-aware polish may end with ("Missing: which file the error is in"): shown in
/// the panel, never inserted.
public enum DraftGaps {
    static let marker = "missing:"

    /// The draft without its gap note, and the note's text (nil when there is none). A last line
    /// that is only the start of the marker (mid-stream) is dropped.
    public static func split(_ text: String) -> (draft: String, gaps: String?) {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last else { return (text, nil) }
        let line = last.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        func rest() -> String { lines.dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        if lower.hasPrefix(marker) {
            let note = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return (rest(), note.isEmpty ? nil : note)
        }
        if lines.count > 1, line.count >= 3, marker.hasPrefix(lower) { return (rest(), nil) }
        return (text, nil)
    }
}

/// Tidies model output into text that can go straight into the field.
public enum DraftCleanup {
    public static func clean(_ raw: String, mode: WriteMode, shape: WriteShape) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A Markdown fence around the whole draft.
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A preface line such as "Here's a draft:" or "Sure! Here is the polished text:".
        if let firstBreak = text.firstIndex(of: "\n") {
            let first = text[..<firstBreak].trimmingCharacters(in: .whitespaces)
            let lower = first.lowercased()
            let preface = ["here's", "here is", "sure", "certainly", "of course", "okay", "ok,"]
            if first.hasSuffix(":"), preface.contains(where: { lower.hasPrefix($0) }) {
                text = String(text[firstBreak...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // A subject line at the top of an email body.
        if mode == .write, shape == .email, let firstBreak = text.firstIndex(of: "\n") {
            let first = text[..<firstBreak].trimmingCharacters(in: .whitespaces).lowercased()
            if first.hasPrefix("subject:") {
                text = String(text[firstBreak...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Quotation marks around the whole draft.
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("「", "」")]
        for (open, close) in pairs where text.count > 2 && text.first == open && text.last == close {
            let inner = text.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) { text = String(inner) }
        }
        // Markdown bold markers the field would show literally.
        text = text.replacingOccurrences(of: "**", with: "")
        // At most one blank line between paragraphs, no trailing spaces.
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            while let last = l.last, last == " " || last == "\t" { l.removeLast() }
            return l
        }
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty == true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Word-level difference between a text and its polished version: the parts of the new text that
/// are not in the old one, for highlighting.
public enum WordDiff {
    /// One piece of text: a word (letters, digits, apostrophes), one Han character, a run of
    /// whitespace, or one other character.
    struct Token: Equatable {
        var text: Substring
        var isSpace: Bool
    }

    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            var j = text.index(after: i)
            if c.isWhitespace {
                while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
                out.append(Token(text: text[i..<j], isSpace: true))
            } else if let s = c.unicodeScalars.first, isHanScalar(s) {
                out.append(Token(text: text[i..<j], isSpace: false))
            } else if c.isLetter || c.isNumber {
                while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "'" || text[j] == "\u{2019}",
                      !(text[j].unicodeScalars.first.map(isHanScalar) ?? false) {
                    j = text.index(after: j)
                }
                out.append(Token(text: text[i..<j], isSpace: false))
            } else {
                out.append(Token(text: text[i..<j], isSpace: false))
            }
            i = j
        }
        return out
    }

    /// Ranges of `revised` (in `revised`'s own indices) holding words that `original` doesn't have
    /// at that point. Whitespace never counts; adjacent changed words merge into one range.
    public static func changedRanges(original: String, revised: String) -> [Range<String.Index>] {
        let a = tokens(original).filter { !$0.isSpace }
        let b = tokens(revised).enumerated().filter { !$0.element.isSpace }
        let n = a.count, m = b.count
        guard m > 0 else { return [] }
        guard n > 0, n * m <= 4_000_000 else {
            return [revised.startIndex..<revised.endIndex]
        }
        // Longest common subsequence over word tokens.
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i].text == b[j].element.text
                    ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var changed = [Bool](repeating: false, count: m)
        var i = 0, j = 0
        while j < m {
            if i < n, a[i].text == b[j].element.text {
                i += 1; j += 1
            } else if i < n, table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                changed[j] = true
                j += 1
            }
        }
        // Merge runs of changed tokens (with the whitespace between them) into ranges.
        var ranges: [Range<String.Index>] = []
        var runStart: String.Index?
        var runEnd: String.Index?
        for (k, entry) in b.enumerated() {
            let token = entry.element
            if changed[k] {
                if runStart == nil { runStart = token.text.startIndex }
                runEnd = token.text.endIndex
            } else if let s = runStart, let e = runEnd {
                ranges.append(s..<e)
                runStart = nil
                runEnd = nil
            }
        }
        if let s = runStart, let e = runEnd { ranges.append(s..<e) }
        return ranges
    }
}
