import CoreGraphics
import Foundation
import HunchCore

/// Who wrote each screen line in a list chat (Discord), where everyone's messages sit on the left
/// under a header row: avatar, name, badges, time. Pure, from line rects plus avatar fingerprints.
///
/// A header starts a group; the lines under it, up to the next header, are that sender's. A group is
/// - the writer's (`Me`) when it holds a message they sent through Hunch (`sent`); its avatar is
///   then learned (`ListOutcome.learned`) to be remembered;
/// - the writer's when its avatar matches one learned before (`mine`), unless the header shows a
///   readable name never seen beside that avatar (someone else with the same default avatar);
/// - the other side's (`Them`) when its avatar clearly differs from every learned one, or (no avatar
///   found) its readable name is none of the writer's;
/// - unlabeled otherwise, and so is everything when nothing about the writer is known yet.
/// Names aren't used as labels: decorated display names read differently on every capture.
/// Reply previews (`@name quoted…` just above a header), reaction counts and date dividers are never
/// labeled; labeled groups' header rows are dropped from the text.
extension ChatSides {
    static let listChatApps: Set<String> = ["com.hnc.Discord"]
    static let listChatHosts: Set<String> = ["discord.com"]

    /// Discord, the app or the site.
    public static func isListChat(bundleID: String, urlHost: String? = nil) -> Bool {
        listChatApps.contains(bundleID) || (urlHost.map(listChatHosts.contains) ?? false)
    }

    public struct ListOutcome: Sendable {
        public var assignments: [Assignment]
        /// Avatars of groups confirmed by a sent message, with the header name ("" unread).
        public var learned: [MyAvatar]
        /// Groups labeled by avatar (`Me` by a match, `Them` by a clear miss), for the logs.
        public var avatarMe = 0
        public var avatarThem = 0
        /// Per group: header top, nearest learned avatar's distance, side (debug logging; no text).
        public var notes: [String] = []
    }

    /// Avatar distance (`AvatarPrint.distance`) up to which a header's avatar is the writer's.
    static let avatarMatch = 16.0
    /// Avatar distance from which a header's avatar is clearly someone else's; in between, unknown.
    static let avatarMiss = 30.0
    /// The avatar patch, in message-text line heights: from this far left of the group's text edge…
    static let avatarPatchLeft: CGFloat = 4.6
    /// …to this far left of it (the gap between avatar and text)…
    static let avatarPatchRight: CGFloat = 0.15
    /// …and from this far above the header's top to this far below it.
    static let avatarPatchUp: CGFloat = 0.9
    static let avatarPatchDown: CGFloat = 3.2
    /// The avatar's side, in message-text line heights.
    static let avatarMinSide: CGFloat = 1.4
    static let avatarMaxSide: CGFloat = 3.8
    /// Lines of one message (wrapped) sit this close, in line heights; separate messages of one
    /// group sit further apart (Discord: 0.1 to 0.3 vs about 0.45).
    static let listLineGap: CGFloat = 0.35
    /// A group's lines start at most this many line heights left of its header (a header whose name
    /// wasn't read starts at its time, right of the text edge).
    static let maxIndentLeft: CGFloat = 4
    /// Name letters needed for a name to count as read (a one-letter name is often missed or misread).
    static let minNameLetters = 3

    /// - Parameters:
    ///   - lines: screen lines in reading order, rects top-left origin.
    ///   - avatar: reads the avatar fingerprint in a screen rect, sized within `minSide...maxSide`.
    ///   - mine: the writer's avatars learned before for this app.
    ///   - above: the message box's top: the avatar patch stops there (the box is a big shape too).
    /// - Returns: nil when no header is found or nothing could be labeled.
    public static func assignList(_ lines: [(text: String, rect: CGRect)], spread: [Bool] = [], sent: [String] = [],
                                  mine: [MyAvatar] = [], above: CGFloat? = nil,
                                  avatar: ((_ patch: CGRect, _ minSide: CGFloat, _ maxSide: CGFloat) -> AvatarPrint?)? = nil)
        -> ListOutcome? {
        guard lines.count >= 2 else { return nil }
        // A header row may be spread: OCR skips a badge ("APP") and leaves a wide gap before the time.
        let headerNames: [String??] = lines.indices.map { listHeader(lines[$0].text) }
        let headers = lines.indices.filter { headerNames[$0] != nil }
        guard !headers.isEmpty else { return nil }

        // Lines never labeled: chrome around messages, and reply previews sitting just above a header.
        let heights = lines.map(\.rect.height).sorted()
        let h = max(1, heights[heights.count / 2])
        var skip = Set<Int>()
        for i in lines.indices where headerNames[i] == nil {
            let t = lines[i].text
            if isUnlabeled(t) || isReactionRow(t) || isDateDivider(t) || t.hasPrefix("Message #")
                || (spread.indices.contains(i) && spread[i]) {
                skip.insert(i)
                continue
            }
            if isReplyPreview(t), let next = headers.first(where: { $0 > i }),
               lines[next].rect.minY - lines[i].rect.maxY <= h * 1.5 {
                skip.insert(i)
            }
        }

        // Groups: a header and the lines under it.
        struct Group { var header: Int; var lines: [Int] }
        var groups: [Group] = []
        var groupOf = [Int?](repeating: nil, count: lines.count)
        for i in lines.indices {
            if headerNames[i] != nil {
                groups.append(Group(header: i, lines: []))
                groupOf[i] = groups.count - 1
            } else if !skip.contains(i), let g = groups.indices.last,
                      lines[i].rect.minX >= lines[groups[g].header].rect.minX - h * maxIndentLeft {
                // Only lines in the group's text column: not a sidebar or server list let in beside it.
                groups[g].lines.append(i)
                groupOf[i] = g
            }
        }

        // The usual message line height, for the avatar patch.
        let textHeights = groups.flatMap { $0.lines.map { lines[$0].rect.height } }.sorted()
        let textH = textHeights.isEmpty ? h : textHeights[textHeights.count / 2]

        func avatarOf(_ g: Group) -> AvatarPrint? {
            guard let avatar else { return nil }
            let header = lines[g.header].rect
            let left = ([header.minX] + g.lines.map { lines[$0].rect.minX }).min()!
            let top = header.minY - textH * avatarPatchUp
            let bottom = min(header.minY + textH * avatarPatchDown, above ?? .infinity)
            guard bottom - top > textH * avatarMinSide else { return nil }
            let patch = CGRect(x: left - textH * avatarPatchLeft, y: top,
                               width: textH * (avatarPatchLeft - avatarPatchRight), height: bottom - top)
            return avatar(patch, textH * avatarMinSide, textH * avatarMaxSide)
        }
        let prints = groups.map(avatarOf)
        let names = groups.map { g -> String in readName(headerNames[g.header] ?? nil) }

        // Sent messages: groups holding one are the writer's, and teach their avatar.
        let sentKeys = sent.map(matchKey).filter { $0.count >= minMatchCharacters }
        var confirmed = Set<Int>()
        for (k, g) in groups.enumerated() where !sentKeys.isEmpty && holdsSent(g.lines.map { lines[$0].text }, sentKeys) {
            confirmed.insert(k)
        }
        var known = mine
        var learned: [MyAvatar] = []
        for k in confirmed.sorted() {
            guard let p = prints[k] else { continue }
            let entry = MyAvatar(print: p, names: [names[k]])
            learned = merged(learned, entry)
            known = merged(known, entry)
        }
        let knownNames = Set(known.flatMap(\.names))

        enum Side { case me, them }
        var sides = [Side?](repeating: nil, count: groups.count)
        var avatarMe = 0, avatarThem = 0
        for k in groups.indices {
            if confirmed.contains(k) { sides[k] = .me; continue }
            guard !known.isEmpty else { continue }
            let name = names[k]
            if let p = prints[k] {
                let nearest = known.min { $0.print.distance(to: p) < $1.print.distance(to: p) }!
                let d = nearest.print.distance(to: p)
                if d <= avatarMatch {
                    // Same avatar, but a readable name never seen with it: someone else's default avatar.
                    if name.isEmpty || nearest.names.contains(where: { similarName($0, name) }) {
                        sides[k] = .me
                        avatarMe += 1
                    }
                } else if d >= avatarMiss {
                    sides[k] = .them
                    avatarThem += 1
                }
            } else if !name.isEmpty, !knownNames.contains(where: { similarName($0, name) }) {
                sides[k] = .them
            }
        }
        let notes = groups.indices.map { k -> String in
            let d = prints[k].flatMap { p in known.map { $0.print.distance(to: p) }.min() }
            return "group y=\(Int(lines[groups[k].header].rect.minY)) lines=\(groups[k].lines.count) "
                + "nameRead=\(!names[k].isEmpty) avatar=\(prints[k] != nil) nearest=\(d.map { String(format: "%.0f", $0) } ?? "-") "
                + "sent=\(confirmed.contains(k)) side=\(sides[k].map { $0 == .me ? "me" : "them" } ?? "-")"
        }
        guard sides.contains(where: { $0 != nil }) else { return nil }

        // Assignments: a labeled group's header is hidden; its lines are blocks of close lines.
        var assignments = lines.indices.map { Assignment(block: -1 - $0, speaker: nil) }
        var block = 0
        for (k, g) in groups.enumerated() {
            block += 1
            guard let side = sides[k] else { continue }
            assignments[g.header] = Assignment(block: block, speaker: nil, isNameLine: true)
            var prev: Int?
            for i in g.lines {
                if let p = prev, lines[i].rect.minY - lines[p].rect.maxY > h * listLineGap
                    || abs(lines[i].rect.minX - lines[p].rect.minX) > h * blockAlign { block += 1 }
                var a = Assignment(block: block, speaker: side == .me ? meLabel : themLabel)
                a.confirmedBySent = confirmed.contains(k)
                assignments[i] = a
                prev = i
            }
        }
        return ListOutcome(assignments: assignments, learned: learned, avatarMe: avatarMe, avatarThem: avatarThem,
                           notes: notes)
    }

    /// Adds `entry` to `list`, joining an entry with the same avatar (names merged).
    static func merged(_ list: [MyAvatar], _ entry: MyAvatar) -> [MyAvatar] {
        var list = list
        if let i = list.firstIndex(where: { $0.print.distance(to: entry.print) <= avatarMatch }) {
            for n in entry.names where !list[i].names.contains(n) { list[i].names.append(n) }
        } else {
            list.append(entry)
        }
        return list
    }

    /// A group's lines hold a sent message: one to four consecutive lines match it (`matches`).
    static func holdsSent(_ texts: [String], _ sentKeys: [String]) -> Bool {
        for start in texts.indices {
            for end in start..<min(texts.count, start + 4) {
                if matches(matchKey(texts[start...end].joined(separator: " ")), sentKeys) { return true }
            }
        }
        return false
    }

    // MARK: Header rows

    /// A list chat's header row: a time at the end (`ChatHeader.timePattern`), after a short run of
    /// name, badges and emoji read as symbols ("nora * MOD # 11/14/26, 12:12 PM", "Sam & MOD -
    /// 9:07 AM", a bare "11/20/26, 10:56AM" when the name wasn't read). Returns the text before the
    /// time (possibly empty), or nil when the line isn't a header.
    static func listHeader(_ line: String) -> String?? {
        var t = line.trimmingCharacters(in: .whitespaces)
        // A stray mark OCR reads after the time ("12:27 PM|", "8:36 PMł"): up to two characters that
        // aren't plain letters or digits.
        for _ in 0..<2 where t.last.map({ !($0.isASCII && ($0.isLetter || $0.isNumber)) }) ?? false {
            t.removeLast()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        guard let m = t.firstMatch(of: ChatHeader.timePattern), m.range.upperBound == t.endIndex else { return nil }
        var before = String(t[..<m.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        // A date read without its space ("10/6/26,3:42 PM").
        if let d = before.firstMatch(of: /\d{1,2}\/\d{1,2}\/\d{2,4},?$/) { before = String(before[..<d.range.lowerBound]) }
        before = before.trimmingCharacters(in: .whitespaces)
        if before.isEmpty || !before.contains(where: \.isLetter) { return .some(nil) }
        let tokens = before.split(whereSeparator: \.isWhitespace)
        guard before.count <= 48, tokens.count <= 8 else { return nil }
        if before.contains(where: { "?!".contains($0) }) { return nil }
        let words = tokens.map { $0.lowercased().filter(\.isLetter) }
        if let last = words.last(where: { !$0.isEmpty }), ChatHeader.notNameEndings.contains(last) { return nil }
        // A sentence ending in a time has several lowercase words; a header has a name and badges.
        if words.filter({ $0.count >= 2 }).count > 5 { return nil }
        return .some(before)
    }

    /// The name part of a header's text, letters and digits lowercased; "" when too little was read.
    public static func readName(_ before: String?) -> String {
        guard let before else { return "" }
        var words: [String] = []
        for token in before.split(whereSeparator: \.isWhitespace) {
            let core = token.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            // Decoration before the name is skipped; once the name started, a badge or symbol ends it.
            if core.count != token.count || core.isEmpty {
                if words.isEmpty { continue } else { break }
            }
            // An all-capitals badge after the name ("MOD", "APP").
            if !words.isEmpty, core.count >= 2, core.allSatisfy({ $0.isUppercase || $0.isNumber }) { break }
            words.append(String(core))
            if words.count == 3 { break }
        }
        // A one-letter word after the name is an emoji or badge read as a letter ("Rosa Lee X MOD").
        while words.count > 1, words.last!.count == 1 { words.removeLast() }
        let name = words.joined(separator: " ").lowercased()
        return name.filter(\.isLetter).count >= minNameLetters ? name : ""
    }

    /// Two read names are the same person's: equal, one containing the other, or a few letters apart.
    static func similarName(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        if a.contains(b) || b.contains(a) { return true }
        return editDistance(a, b) <= max(1, min(a.count, b.count) / 4)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(1, b.count) where !b.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    // MARK: Chrome

    /// `@name quoted text…`: the preview of the message a reply answers. The replied-to sender's icon
    /// and badge may come first, read as symbols and capitals (`' APP @Nao Cake donuts…`).
    static func isReplyPreview(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let at = t.firstIndex(of: "@") else { return false }
        let before = t[..<at]
        return before.count <= 3 || (before.count <= 10 && !before.contains(where: \.isLowercase))
    }

    /// A reaction under a message: an emoji (read as a short word or symbols) and a count ("9 1",
    /// "wow 1", "38, 1").
    static func isReactionRow(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\S{0,8},?\s*\d{1,3}/) != nil
    }

    /// A day divider ("November 22, 2026", "Today").
    static func isDateDivider(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.wholeMatch(of: /(?i)(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.? \d{1,2},? \d{4}[^\p{L}\p{N}]*/) != nil
            || t.wholeMatch(of: /\d{4}年\d{1,2}月\d{1,2}日/) != nil
    }
}
