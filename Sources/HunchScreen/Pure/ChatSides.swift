import CoreGraphics
import Foundation
import HunchCore

/// Who wrote each screen line in a two-sided chat: in Messages, WhatsApp, Signal, Telegram, LINE,
/// Teams 1:1 and AI chat apps the writer's own messages sit right-aligned in the conversation column
/// and the other side's start at its left edge. Pure, from line rects only.
///
/// Lines are grouped into message blocks (lines of one bubble: same left edge, similar height,
/// stacked closely). A block is
/// - the writer's (`Me`) when it ends at the column's right edge and starts clearly indented;
/// - the other side's (`Them`, or the sender's name) when it starts at the column's left edge (it
///   may run the full width, as an AI's reply does);
/// - unlabeled otherwise (centered dates, titles).
/// Times, delivery status and tapback lines are never labeled, nor rows of separate controls (a
/// status bar or toolbar above the text box, joined from fragments far apart). The layout only counts as two-sided
/// when both sides have a message and few blocks fit neither; otherwise nothing is labeled, since a
/// wrong label is worse than none. The one exception is a bubble app (`isBubbleApp`), where the
/// writer's messages always sit indented on the right: a screen of only left-aligned messages with
/// ragged right ends (the writer's own scrolled off) is all the other side's.
///
/// Messages the writer sent through Hunch (`sent`) are evidence beyond layout: a block matching
/// one is the writer's (confirmed), and below the newest matched block, a block that only looks like
/// the writer's but matches nothing sent loses its label (vetoed: Hunch saw everything typed in
/// that box since, so it is chrome such as a status bar). Left-aligned lists with name headers (Slack, Discord) have no
/// right side and stay unlabeled.
public enum ChatSides {
    public static let meLabel = "Me"
    public static let themLabel = "Them"

    /// What `assign` decided for one line.
    public struct Assignment: Sendable, Equatable {
        /// Index of the line's message block (lines of one bubble share it).
        public var block: Int
        /// "Me", "Them" or a sender name; nil for lines left unlabeled.
        public var speaker: String?
        /// A sender-name line above the other side's bubble (group chats): its name labels the
        /// following messages, so the line itself is not emitted.
        public var isNameLine = false
        /// The block matches a message the writer sent (`sent`), so it is "Me" whatever its layout.
        public var confirmedBySent = false
        /// The block looked like the writer's but sits below their newest matched message and matches
        /// nothing they sent, so it is left unlabeled.
        public var vetoedBySent = false
    }

    /// A block starts at the left edge when its left side is within this many line heights of it.
    static let edgeTolerance: CGFloat = 1.5
    /// A block ends at the right edge within this many line heights: looser, since an emoji ending
    /// the writer's message is often not read and the line then stops short.
    static let rightEdgeTolerance: CGFloat = 2.5
    /// A right-side block must start at least this far in from the left edge: this many line heights,
    /// and this share of the column width.
    static let minIndentHeights: CGFloat = 3
    static let minIndentShare: CGFloat = 0.12
    /// Lines join one block when the gap between them is at most this many line heights.
    static let blockGap: CGFloat = 0.6
    /// Lines join one block when their left edges are within this many line heights.
    static let blockAlign: CGFloat = 0.75
    /// A sender-name line is at most this share of the height of the message under it.
    static let nameHeightRatio: CGFloat = 0.85
    /// The layout is not two-sided when more than this share of message blocks fit neither side.
    /// Only blocks with some writing count: text read off a photo or a file card is short.
    static let maxUnsidedShare = 0.34
    /// Words (with letters) from which a block counts as writing for `maxUnsidedShare`; Chinese and
    /// Japanese text counts from this many characters times two.
    static let writingWords = 3

    /// Chat apps the surface classifier does not mark as chat: LINE and AI chat apps (Claude, ChatGPT, LM Studio).
    /// ChatGPT now ships as `com.openai.codex` (the Codex app's ID); `com.openai.chat` is the older ChatGPT app.
    static let extraChatApps: Set<String> = ["jp.naver.line.mac", "com.anthropic.claudefordesktop", "com.openai.chat",
                                             "com.openai.codex", "ai.elementlabs.lmstudio"]
    /// Chat websites (web versions of the apps above, AI chats).
    static let chatHosts: Set<String> = ["web.whatsapp.com", "web.telegram.org", "messages.google.com",
                                         "claude.ai", "chatgpt.com", "gemini.google.com"]

    /// Apps and sites that always show the writer's messages indented on the right (`assign`'s
    /// one-sided case). Slack, Discord and other list-style chats are not: the writer's messages sit
    /// on the left there too.
    static let bubbleApps: Set<String> = ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
                                          "org.whispersystems.signal-desktop", "ru.keepcoder.Telegram",
                                          "org.telegram.desktop", "jp.naver.line.mac",
                                          "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
                                          "ai.elementlabs.lmstudio"]

    /// AI chat apps and sites: one assistant answers, so there are no sender names, and a bold heading
    /// in its reply ("Where it went") must not be taken for one.
    static let aiChatApps: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
                                          "ai.elementlabs.lmstudio"]
    static let aiChatHosts: Set<String> = ["claude.ai", "chatgpt.com", "gemini.google.com"]

    /// Whether sender names are looked for (`assign`'s `senderNames`): chats between people, not AI
    /// chats or agent prompts.
    public static func hasSenderNames(surface: SurfaceKind, bundleID: String, urlHost: String? = nil) -> Bool {
        surface != .agentPrompt && !aiChatApps.contains(bundleID) && !(urlHost.map(aiChatHosts.contains) ?? false)
    }

    public static func isBubbleApp(bundleID: String, urlHost: String? = nil) -> Bool {
        bubbleApps.contains(bundleID) || (urlHost.map(chatHosts.contains) ?? false)
    }

    /// Sides are looked for only in chat places: chat apps, chat websites and AI chat fields.
    public static func applies(surface: SurfaceKind, bundleID: String, urlHost: String? = nil) -> Bool {
        if surface == .chat || surface == .agentPrompt || extraChatApps.contains(bundleID) { return true }
        return urlHost.map(chatHosts.contains) ?? false
    }

    /// - Parameters:
    ///   - lines: screen lines in reading order (top to bottom), rects top-left origin.
    ///   - spread: per line, whether it was joined from fragments far apart on one row (never labeled).
    ///   - bubbleApp: the screen is a bubble app (`isBubbleApp`): a screen of only the other side's
    ///     messages is labeled too.
    ///   - sent: messages the writer sent from this app through Hunch (`SentMessages`).
    ///   - senderNames: look for sender names above the other side's messages (`hasSenderNames`).
    /// - Returns: one assignment per line, or nil when the layout is not clearly two-sided.
    public static func assign(_ lines: [(text: String, rect: CGRect)], spread: [Bool] = [],
                              bubbleApp: Bool = false, sent: [String] = [], senderNames: Bool = true) -> [Assignment]? {
        guard lines.count >= 2 else { return nil }
        let heights = lines.map(\.rect.height).sorted()
        let h = max(1, heights[heights.count / 2])
        // The usual height of message text, without name lines (in a busy group chat a third of the lines).
        let textHeights = lines.filter { senderName($0.text) == nil }.map(\.rect.height).sorted()
        let textHeight = textHeights.isEmpty ? h : max(h, textHeights[textHeights.count / 2])

        // Blocks: consecutive content lines with the same left edge and height, stacked closely.
        var blockOf = [Int?](repeating: nil, count: lines.count)
        var blocks: [(lines: [Int], rect: CGRect)] = []
        for (i, line) in lines.enumerated() where !isUnlabeled(line.text) && !(spread.indices.contains(i) && spread[i]) {
            if let last = blocks.indices.last, let prev = blocks[last].lines.last {
                let p = lines[prev].rect, r = line.rect
                // OCR line heights vary with the letters, so height only keeps a smaller sender-name
                // line apart from the bubble under it (against the screen's usual line height too:
                // a bubble of only short letters, "ah", reads as small as the name above it).
                let nameAbove = senderNames && blocks[last].lines.count == 1 && p.height <= max(r.height, textHeight) * nameHeightRatio
                    && senderName(lines[prev].text) != nil
                if prev == i - 1 || blockOf[i - 1] == nil, !nameAbove,
                   abs(r.minX - p.minX) <= h * blockAlign, r.minY - p.maxY <= h * blockGap,
                   r.minY >= p.midY {
                    blocks[last].lines.append(i)
                    blocks[last].rect = blocks[last].rect.union(r)
                    blockOf[i] = last
                    continue
                }
            }
            blocks.append(([i], line.rect))
            blockOf[i] = blocks.count - 1
        }
        guard blocks.count >= 2 else { return nil }

        let left = blocks.map(\.rect.minX).min()!, right = blocks.map(\.rect.maxX).max()!
        let width = right - left
        guard width > h * 4 else { return nil }
        let indent = max(h * minIndentHeights, width * minIndentShare)
        enum Side { case me, them }
        var sides: [Side?] = blocks.map { b in
            if b.rect.maxX >= right - h * rightEdgeTolerance, b.rect.minX >= left + indent { return .me }
            if b.rect.minX <= left + h * edgeTolerance { return .them }
            return nil
        }
        // Sent messages: confirm matches, veto unmatched "Me" blocks below the newest match. A match
        // at the left edge outside bubble apps stays as layout says (list chats aren't labeled).
        var confirmed = Set<Int>(), vetoed = Set<Int>()
        let sentKeys = sent.map(matchKey).filter { $0.count >= minMatchCharacters }
        if !sentKeys.isEmpty {
            let matched = blocks.indices.filter { k in
                matches(matchKey(blocks[k].lines.map { lines[$0].text }.joined(separator: " ")), sentKeys)
            }
            for k in matched where sides[k] != .them || bubbleApp {
                sides[k] = .me
                confirmed.insert(k)
            }
            if let newest = confirmed.max() {
                for k in blocks.indices where k > newest && sides[k] == .me && !confirmed.contains(k) {
                    sides[k] = nil
                    vetoed.insert(k)
                }
            }
        }
        let mine = sides.filter { $0 == .me }.count, theirs = sides.filter { $0 == .them }.count
        let writing = blocks.indices.filter { isWriting(blocks[$0].lines.map { lines[$0].text }.joined(separator: " ")) }
        let unsided = writing.filter { sides[$0] == nil }.count
        guard theirs >= 1, Double(unsided) <= Double(writing.count) * maxUnsidedShare else { return nil }
        if mine == 0 {
            // One-sided: only in a bubble app, with some message ending well short of the right edge
            // (left-aligned messages of the other side, not right-aligned ones of the writer that
            // happen to share a left edge).
            guard bubbleApp, !writing.isEmpty,
                  blocks.contains(where: { $0.rect.maxX <= right - indent }) else { return nil }
        }

        // Sender names (group chats): a one-line block in smaller type just above the other side's
        // message names it and the messages after it, until the writer's next message.
        let nameBlocks = senderNames ? senderNameBlocks(blocks, lines: lines, sides: sides.map { $0 == .them }, h: textHeight) : []
        var names = [String?](repeating: nil, count: blocks.count)
        var current: String?
        for k in blocks.indices {
            switch sides[k] {
            case .me: current = nil
            case nil: continue
            case .them:
                if nameBlocks.contains(k) {
                    current = senderName(lines[blocks[k].lines[0]].text)
                    continue
                }
                names[k] = current
            }
        }

        return lines.indices.map { i in
            guard let k = blockOf[i] else { return Assignment(block: -1 - i, speaker: nil) }
            if nameBlocks.contains(k) { return Assignment(block: k, speaker: nil, isNameLine: true) }
            var a: Assignment
            switch sides[k] {
            case .me: a = Assignment(block: k, speaker: meLabel)
            case .them: a = Assignment(block: k, speaker: names[k] ?? themLabel)
            case nil: a = Assignment(block: k, speaker: nil)
            }
            a.confirmedBySent = confirmed.contains(k)
            a.vetoedBySent = vetoed.contains(k)
            return a
        }
    }

    // MARK: Sender names

    /// A name read as tall as the bubble under it still counts when it sits this much closer to the
    /// bubble than any two bubbles on the screen sit to each other (a share of that smallest gap).
    static let nameGapShare: CGFloat = 0.8

    /// The other side's one-line blocks that are sender names above their bubbles (group chats), not
    /// messages. OCR heights vary with the letters ("Avery" can read 13 pt over a 12 pt "Oh no";
    /// "Robin" and "ah" both read 10 pt), so besides smaller type, a name counts when:
    /// - it is small next to the screen's usual line height, not only the bubble under it;
    /// - its text is a name already found on this screen;
    /// - in a group chat (names found), it sits clearly closer to the bubble under it than bubbles sit
    ///   to each other, and starts with a capital;
    /// - its bubble has no readable text (a sticker, photo or emoji): then the next block is another
    ///   name or not theirs, and the name must be one already found on this screen.
    static func senderNameBlocks(_ blocks: [(lines: [Int], rect: CGRect)], lines: [(text: String, rect: CGRect)],
                                 sides isThem: [Bool], h: CGFloat) -> Set<Int> {
        let count = blocks.count
        guard count >= 2 else { return [] }
        func name(_ k: Int) -> String? {
            guard isThem[k], blocks[k].lines.count == 1 else { return nil }
            return senderName(lines[blocks[k].lines[0]].text)
        }
        func gap(after k: Int) -> CGFloat? {
            k + 1 < count ? blocks[k + 1].rect.minY - blocks[k].rect.maxY : nil
        }
        /// The next block is theirs and starts close under `k`.
        func bubbleBelow(_ k: Int) -> Bool {
            guard k + 1 < count, isThem[k + 1], let g = gap(after: k) else { return false }
            return g <= h * edgeTolerance
        }
        var found = Set<Int>()
        for k in 0..<count where name(k) != nil && bubbleBelow(k) {
            let below = lines[blocks[k + 1].lines[0]].rect.height
            if blocks[k].rect.height <= max(below, h) * nameHeightRatio { found.insert(k) }
        }
        let known = Set(found.compactMap(name))
        guard !known.isEmpty else { return found }
        // Known names over their bubble, whatever their read height.
        for k in 0..<count where !found.contains(k) && bubbleBelow(k) {
            if let n = name(k), known.contains(n) { found.insert(k) }
        }
        // Closer to the bubble under it than bubbles are to each other: gaps under blocks that can't be
        // names, to the next block that isn't a found name.
        let bubbleGaps = (0..<max(0, count - 1)).compactMap { k -> CGFloat? in
            guard name(k) == nil, !found.contains(k + 1) else { return nil }
            return gap(after: k).flatMap { $0 > 0 ? $0 : nil }
        }
        if let smallest = bubbleGaps.min() {
            for k in 0..<count where !found.contains(k) && bubbleBelow(k) {
                guard let n = name(k), n.first?.isUppercase == true, let g = gap(after: k) else { continue }
                let below = lines[blocks[k + 1].lines[0]].rect.height
                if g < smallest * nameGapShare, blocks[k].rect.height <= below * 1.2 { found.insert(k) }
            }
        }
        // A known name whose bubble OCR could not read: the next block is another name or not theirs.
        for k in 0..<count where !found.contains(k) {
            guard let n = name(k), known.contains(n) else { continue }
            if k + 1 == count || !isThem[k + 1] || found.contains(k + 1) { found.insert(k) }
        }
        return found
    }

    // MARK: Matching sent messages

    /// Shortest text (letters and digits) that can match: shorter text ("ok") matches too much.
    static let minMatchCharacters = 12
    /// The shorter of block and sent message must be at least this share of the longer: a block is a
    /// whole bubble, so a word or a short quote of the message is not a match.
    static let minMatchShare = 0.5
    /// Share of a block's words that must appear in a sent message when the text isn't contained
    /// outright (OCR misreads a letter here and there).
    static let minWordOverlap = 0.8

    /// Lowercased letters, digits and CJK, words separated by single spaces.
    static func matchKey(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// A block's text matches a sent message: one contains the other (a wrapped or cut-off read), or
    /// most of the block's words are in it, and the two are of comparable length.
    static func matches(_ block: String, _ sent: [String]) -> Bool {
        guard block.count >= minMatchCharacters else { return false }
        let words = block.split(separator: " ")
        for s in sent where s.count >= minMatchCharacters {
            guard Double(min(block.count, s.count)) >= Double(max(block.count, s.count)) * minMatchShare else { continue }
            if s.contains(block) || block.contains(s) { return true }
            guard words.count >= 3 else { continue }
            let sentWords = Set(s.split(separator: " "))
            let shared = words.filter { sentWords.contains($0) }.count
            if Double(shared) >= Double(words.count) * minWordOverlap { return true }
        }
        return false
    }

    /// A short name line: one to three words, no sentence punctuation (`ChatHeader.name`).
    static func senderName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.split(separator: " ").count <= 3, let name = ChatHeader.name(trimmed), name == trimmed
        else { return nil }
        return name
    }

    static func isWriting(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }.count
        return words >= writingWords || text.filter(InterfaceLines.isCJKCharacter).count >= writingWords * 2
    }

    // MARK: Lines that never get a speaker

    /// Delivery status words that start a status line ("Delivered", "Read 9:41 AM", "已讀 6").
    static let statusWords: Set<String> = ["delivered", "read", "seen", "sent", "sending", "not delivered",
                                           "已送達", "已讀", "已傳送", "已读", "已送达", "已发送", "既読"]
    /// Tapback lines in Messages ("Loved “guilty”"): someone's reaction, not a message.
    static let tapbackStarts = ["loved ", "liked ", "disliked ", "laughed at ", "emphasized ", "questioned ",
                                "reacted ", "已將", "已将"]

    /// Bullets that separate the parts of a status row ("Opus 5.5 • Medium • Auto").
    static let rowSeparators: Set<Character> = ["•", "·"]
    /// A status row with two or more separators ends in a part of at most this many words.
    static let maxLastPartWords = 3

    /// A status row of bullet-separated parts: a model picker or usage bar ("1/3 • Task Opus 5.5 •
    /// Medium • Auto", two or more separators), or a timer ("1m 26s • 2.8K tokens", one separator
    /// between parts that are at least half numbers). Its parts may sit close enough to be read as one
    /// line, so `spread` does not always catch it. A bullet starting a line (a list item) is not a
    /// separator.
    static func isStatusRow(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        var separators = 0, last = 0
        for (k, token) in tokens.enumerated() where k > 0 && k < tokens.count - 1 {
            guard token.allSatisfy(rowSeparators.contains) else { continue }
            if !tokens[k - 1].allSatisfy(rowSeparators.contains) { separators += 1; last = k }
        }
        // A message quoting a status row goes on after it; the row itself ends in a short part.
        if separators >= 2 { return tokens.count - 1 - last <= maxLastPartWords }
        guard separators == 1 else { return false }
        let parts = tokens.filter { !$0.allSatisfy(rowSeparators.contains) }
        return parts.filter { $0.contains(where: \.isNumber) }.count * 2 >= parts.count
    }

    /// Times and dates, delivery status and tapbacks: chrome around messages, not messages.
    static func isUnlabeled(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return true }
        if ChatHeader.isHeader(t) { return true }
        let lower = t.lowercased()
        if tapbackStarts.contains(where: { lower.hasPrefix($0) }) { return true }
        // Thread counts under a message ("4 Replies", "1 reply").
        if lower.wholeMatch(of: /\d+ repl(?:y|ies)/) != nil { return true }
        if isStatusRow(t) { return true }
        for word in statusWords where lower.hasPrefix(word) {
            let rest = lower.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || ChatHeader.isHeader(rest) || rest.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}
