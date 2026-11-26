import CoreGraphics
import Foundation
import HunchCore

public struct ScreenPipelineResult: Sendable, Equatable {
    public var text: String
    public var signature: UInt64
    /// Reply-preview lines (`@name quoted text…`) dropped because their message is also on screen.
    public var previewsDropped = 0
    /// Reply-preview-shaped lines kept (their message is off screen, or the match failed).
    public var previewsKept = 0
    /// Lines in the returned text.
    public var lineCount = 0
    /// Interface lines next to the field (status boxes, toolbars) dropped (`InterfaceLines`).
    public var interfaceDropped = 0
    /// Lines labeled with a speaker (`ChatSides`); 0 when the layout was not two-sided or labels were off.
    public var sideLabeled = 0
    /// Lines dropped for being outside the field's column (sidebars, conversation lists).
    public var outsideColumn = 0
    /// Chat places only: lines dropped for sitting entirely below the text box (model pickers,
    /// disclaimers, usage notes): neither side wrote them.
    public var belowField = 0
    /// Message blocks labeled "Me" because they match a sent message, and blocks that lost a "Me"
    /// label below the newest match (`ChatSides.assign`'s `sent`).
    public var sentConfirmed = 0
    public var sentVetoed = 0
    /// List chats (Discord): the writer's avatars learned on this read (`ChatSides.ListOutcome`), and
    /// groups labeled by avatar.
    public var learnedAvatars: [MyAvatar] = []
    public var avatarMe = 0
    public var avatarThem = 0
    /// Debug notes per group (`ChatSides.ListOutcome.notes`).
    public var avatarNotes: [String] = []
}

/// Pure post-OCR pipeline: hygiene, dedupe, secret and web-address filtering, column filter, proximity selection,
/// capping.
public enum ScreenTextPipeline {
    public static let minConfidence: Float = 0.4
    /// A line is in the field's column when at least this share of its width lies within the
    /// field's horizontal span (sidebars and channel lists beside the conversation are not).
    public static let columnOverlap: CGFloat = 0.5
    /// Added to the distance of lines below the field (toolbars, model pickers): every line above
    /// it is chosen first, nearest first, and lines below only fill what budget is left.
    static let belowFieldOffset: CGFloat = 1_000_000
    public static let minLineHeight: CGFloat = 6
    public static let minLineCharacters = 2

    /// - Parameters:
    ///   - caret: caret position in the same coordinate space as `lines` (origin top-left).
    ///   - field: the text field's frame, same space. When given, only lines in its column are kept
    ///     and distance is measured from the field's edges (text just above it first).
    ///   - fieldBefore/fieldAfter: text already in the field; lines present there are dropped.
    /// The run of interface lines next to the field is dropped first (`InterfaceLines`).
    /// Selection is nearest first until `maxCharacters` is reached (whole lines only); the kept
    /// lines are then emitted in reading order. Returns nil if nothing useful remains.
    ///   - chatSides: in a chat place (`ChatSides.applies`), label who wrote each message when the
    ///     layout is clearly two-sided ("Me: …", "Them: …", or the sender's name).
    ///   - bubbleApp: a bubble app (`ChatSides.isBubbleApp`): a screen of only the other side's messages
    ///     is labeled too.
    ///   - sentMessages: the writer's messages sent from this app (`SentMessages`), speaker evidence.
    ///   - listChat: a list chat (`ChatSides.isListChat`, Discord): sides come from header groups and
    ///     avatars (`ChatSides.assignList`) instead of left/right layout.
    ///   - myAvatars: the writer's avatars learned before in this app.
    ///   - avatarAt: reads an avatar fingerprint from the capture (`ImageAvatarSource`).
    public static func process(lines: [OCRLine], caret: CGPoint, field: CGRect? = nil, fieldBefore: String = "",
                               fieldAfter: String = "", maxCharacters: Int,
                               chatSides: Bool = false, bubbleApp: Bool = false,
                               sentMessages: [String] = [], senderNames: Bool = true,
                               listChat: Bool = false, myAvatars: [MyAvatar] = [],
                               avatarAt: ((CGRect, CGFloat, CGFloat) -> AvatarPrint?)? = nil) -> ScreenPipelineResult? {
        guard maxCharacters > 0 else { return nil }
        let fieldNorm = normalize(fieldBefore + " " + fieldAfter)

        struct Item {
            var text: String; var rect: CGRect; var distance: CGFloat; var side: ChatSides.Assignment? = nil
            /// Joined from fragments with a wide gap between them (`mergingRows`): a toolbar or status row.
            var spread = false
        }
        var items: [Item] = []
        var outsideColumn = 0
        var belowField = 0
        for line in lines {
            guard line.confidence >= minConfidence, line.rect.height >= minLineHeight else { continue }
            let collapsed = collapseWhitespace(line.text)
            guard collapsed.count >= minLineCharacters, hasLetterOrDigit(collapsed) else { continue }
            // Outside the field's column (sidebars), or inside the field itself (its placeholder;
            // typed text is in the prompt already).
            if let field, !inColumn(line.rect, of: field) {
                outsideColumn += 1
                continue
            }
            if let field, field.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)) { continue }
            // In a chat, messages are above the text box; what sits under it is the app's.
            if chatSides, let field, line.rect.minY >= field.maxY {
                belowField += 1
                continue
            }
            if let key = Optional(normalize(collapsed)), key.count >= 3, fieldNorm.contains(key) { continue }
            guard let sanitized = SecretFilter.sanitize(collapsed) else { continue }
            // Web addresses on screen (address bars, links) only teach the model to suggest them.
            let clean = URLShape.removingURLs(sanitized)
            guard clean.count >= minLineCharacters, hasLetterOrDigit(clean) else { continue }
            let d = field.map { distance(fromField: $0, to: line.rect) } ?? distance(from: caret, to: line.rect)
            items.append(Item(text: clean, rect: line.rect, distance: d))
        }
        guard !items.isEmpty else { return nil }
        items = mergingRows(items.map { ($0.text, $0.rect, $0.distance) }).map {
            Item(text: $0.text, rect: $0.rect, distance: $0.distance, spread: $0.spread)
        }
        let beforePreviews = items.count
        items = droppingReplyPreviews(items, text: \.text)
        let previewsDropped = beforePreviews - items.count
        // Interface text right next to the field (status boxes, toolbars, model pickers): scanned
        // outward from the field, above and below separately, up to the first line of writing.
        func isBelow(_ item: Item) -> Bool {
            field != nil ? item.distance >= belowFieldOffset : item.rect.midY > caret.y
        }
        var interfaceRun = Set<Int>()
        for below in [false, true] {
            let side = items.indices.filter { isBelow(items[$0]) == below }.sorted { items[$0].distance < items[$1].distance }
            // In a list chat a header row ("Sam MOD 11:01 AM") is the start of a message, not chrome:
            // the run stops there.
            let stop = listChat ? side.firstIndex { ChatSides.listHeader(items[$0].text) != nil } ?? side.count : side.count
            for i in InterfaceLines.run(side.prefix(stop).map { items[$0].text }) { interfaceRun.insert(side[i]) }
        }
        items = items.indices.filter { !interfaceRun.contains($0) }.map { items[$0] }

        let rowTolerance: CGFloat = 4
        func readingOrder(_ a: Item, _ b: Item) -> Bool {
            if abs(a.rect.midY - b.rect.midY) > rowTolerance { return a.rect.midY < b.rect.midY }
            return a.rect.minX < b.rect.minX
        }
        // Speakers, from the whole column before duplicates go (a sender's name line repeats).
        var listOutcome: ChatSides.ListOutcome?
        if chatSides && listChat {
            items.sort(by: readingOrder)
            listOutcome = ChatSides.assignList(items.map { ($0.text, $0.rect) }, spread: items.map(\.spread),
                                               sent: sentMessages, mine: myAvatars, above: field?.minY,
                                               avatar: avatarAt)
            if let sides = listOutcome?.assignments {
                for i in items.indices { items[i].side = sides[i] }
            }
        } else if chatSides {
            items.sort(by: readingOrder)
            if let sides = ChatSides.assign(items.map { ($0.text, $0.rect) }, spread: items.map(\.spread),
                                            bubbleApp: bubbleApp, sent: sentMessages,
                                            senderNames: senderNames) {
                for i in items.indices { items[i].side = sides[i] }
            }
        }

        // Drop exact duplicate lines (repeated UI chrome), keeping the nearest. Chat sender headers
        // ("Nora 10:14 AM", a bare "10:14 AM") repeat for real and mark where messages start, so they stay.
        var seen = Set<String>()
        let nearestFirst = items.sorted { $0.distance < $1.distance }.filter {
            ChatHeader.isHeader($0.text) || seen.insert(normalize($0.text)).inserted
        }

        var chosen: [Item] = []
        var used = 0
        for item in nearestFirst {
            let cost = item.text.count + (chosen.isEmpty ? 0 : 1)
            if used + cost > maxCharacters {
                if chosen.isEmpty { continue }  // first line alone too long: try shorter ones
                break
            }
            chosen.append(item)
            used += cost
        }
        guard !chosen.isEmpty else { return nil }

        chosen.sort(by: readingOrder)
        // A labeled message's lines become one line after its speaker; name lines become the label.
        var out: [String] = []
        var lastBlock: Int?
        var labeled = 0
        for item in chosen {
            guard let side = item.side else { out.append(item.text); lastBlock = nil; continue }
            if side.isNameLine { continue }
            guard let speaker = side.speaker else { out.append(item.text); lastBlock = nil; continue }
            labeled += 1
            if lastBlock == side.block, !out.isEmpty {
                out[out.count - 1] += " " + item.text
            } else {
                out.append(speaker + ": " + item.text)
                lastBlock = side.block
            }
        }
        guard !out.isEmpty else { return nil }
        let text = out.joined(separator: "\n")
        var result = ScreenPipelineResult(text: text, signature: signature(of: nearestFirst.map(\.text)))
        result.previewsDropped = previewsDropped
        result.interfaceDropped = interfaceRun.count
        result.previewsKept = chosen.filter { !replyPreviewBodies($0.text).isEmpty }.count
        result.lineCount = out.count
        result.sideLabeled = labeled
        let sides = items.compactMap(\.side)
        result.sentConfirmed = Set(sides.filter(\.confirmedBySent).map(\.block)).count
        result.sentVetoed = Set(sides.filter(\.vetoedBySent).map(\.block)).count
        result.outsideColumn = outsideColumn
        result.belowField = belowField
        result.learnedAvatars = listOutcome?.learned ?? []
        result.avatarMe = listOutcome?.avatarMe ?? 0
        result.avatarThem = listOutcome?.avatarThem ?? 0
        result.avatarNotes = listOutcome?.notes ?? []
        return result
    }

    /// Fragments OCR reads apart on one row are joined, left to right, when the gap between them is at
    /// most this many line heights. Chat apps put badges and emoji between a sender's name and the time,
    /// or between a reply preview's `@name` and its text, and OCR splits the row there.
    static let rowJoinGap: CGFloat = 10

    /// A row joined across a gap wider than this many line heights is `spread`: separate controls on
    /// one row (a status bar, a toolbar, a row of buttons), not one run of writing. An emoji OCR skips
    /// inside a message leaves a gap of about one line height.
    static let spreadGap: CGFloat = 3

    /// Joins fragments on the same row (vertical centers within half a line height, horizontal gap
    /// within `rowJoinGap` heights) into one line, keeping the nearest distance. `spread` marks a row
    /// joined across a gap wider than `spreadGap` heights.
    static func mergingRows(_ items: [(text: String, rect: CGRect, distance: CGFloat)])
        -> [(text: String, rect: CGRect, distance: CGFloat, spread: Bool)] {
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }
        var rows: [(text: String, rect: CGRect, distance: CGFloat, spread: Bool)] = []
        for item in sorted {
            if let i = rows.lastIndex(where: { row in
                let h = min(row.rect.height, item.rect.height)
                return abs(row.rect.midY - item.rect.midY) <= h / 2
                    && item.rect.minX - row.rect.maxX <= h * rowJoinGap
                    && item.rect.minX >= row.rect.maxX - h / 2
            }) {
                let h = min(rows[i].rect.height, item.rect.height)
                let spread = rows[i].spread || item.rect.minX - rows[i].rect.maxX > h * spreadGap
                rows[i] = (rows[i].text + " " + item.text, rows[i].rect.union(item.rect),
                           min(rows[i].distance, item.distance), spread)
            } else {
                rows.append((item.text, item.rect, item.distance, false))
            }
        }
        return rows
    }

    /// Minimum characters of preview text to match against another line; shorter ones are too ambiguous.
    static let minReplyPreviewCharacters = 8

    /// Chat apps (Discord) show a one-line `@name quoted text...` preview above a reply. When the quoted
    /// message is also on screen (the preview is a prefix of, or contained in, another line, or the
    /// original wraps and its first line is a prefix of the preview), the preview only doubles text, so
    /// it is dropped. A preview whose original is off screen stays as is.
    static func droppingReplyPreviews<T>(_ items: [T], text: KeyPath<T, String>) -> [T] {
        return items.enumerated().filter { index, item in
            let candidates = replyPreviewBodies(item[keyPath: text])
            guard !candidates.isEmpty else { return true }
            let own = normalize(item[keyPath: text])
            for (otherIndex, other) in items.enumerated() where otherIndex != index {
                let o = normalize(other[keyPath: text])
                if o == own || o.count < minReplyPreviewCharacters { continue }
                for body in candidates where body.count >= minReplyPreviewCharacters {
                    if o.contains(body) || body.hasPrefix(o) { return false }
                }
            }
            return true
        }.map(\.element)
    }

    /// Normalized text after a leading `@name ` marker (name of 1-3 words, an avatar glyph may precede
    /// the `@`), one candidate per possible name length, truncation ellipsis removed.
    static func replyPreviewBodies(_ line: String) -> [String] {
        let collapsed = collapseWhitespace(line)
        guard let at = collapsed.firstIndex(of: "@"), collapsed.distance(from: collapsed.startIndex, to: at) <= 3
        else { return [] }
        let words = collapsed[collapsed.index(after: at)...].split(separator: " ").map(String.init)
        guard words.count >= 2 else { return [] }
        var bodies: [String] = []
        for nameLength in 1...min(3, words.count - 1) {
            var body = normalize(words[nameLength...].joined(separator: " "))
            while body.hasSuffix(".") || body.hasSuffix("…") || body.hasSuffix(" ") { body.removeLast() }
            bodies.append(body)
        }
        return bodies
    }

    /// Order-independent hash of the visible lines (stable across runs, unlike `Hasher`).
    public static func signature(of lines: [String]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for key in lines.map(normalize).sorted() {
            for byte in key.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
            hash ^= 0x0a
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    public static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func normalize(_ s: String) -> String { collapseWhitespace(s).lowercased() }

    private static func hasLetterOrDigit(_ s: String) -> Bool {
        s.contains { $0.isLetter || $0.isNumber }
    }

    static func inColumn(_ line: CGRect, of field: CGRect) -> Bool {
        guard line.width > 0 else { return false }
        let overlap = min(line.maxX, field.maxX) - max(line.minX, field.minX)
        return overlap >= line.width * columnOverlap
    }

    /// Distance from the field's top edge for lines above it (the newest chat message is nearest),
    /// after every line above for lines below it; zero for lines level with it.
    static func distance(fromField field: CGRect, to r: CGRect) -> CGFloat {
        if r.maxY <= field.minY { return field.minY - r.maxY }
        if r.minY >= field.maxY { return belowFieldOffset + r.minY - field.maxY }
        return 0
    }

    /// Vertical distance dominates (lines near the caret's row); horizontal adds a small weight.
    static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dy = p.y < r.minY ? r.minY - p.y : (p.y > r.maxY ? p.y - r.maxY : 0)
        let dx = p.x < r.minX ? r.minX - p.x : (p.x > r.maxX ? p.x - r.maxX : 0)
        return dy + dx * 0.25
    }
}
