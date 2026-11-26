import CoreGraphics
import Foundation
import HunchCore
import Testing
@testable import HunchScreen

// A Discord-like list chat: message text starts at x 72, headers above each group, 16 pt lines.

private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> AvatarPrint {
    AvatarPrint(cells: (0..<(AvatarPrint.side * AvatarPrint.side)).flatMap { _ in [r, g, b] })
}

private let alexAvatar = solid(200, 60, 60)
private let samAvatar = solid(60, 160, 220)
private let rosaAvatar = solid(90, 200, 90)

/// A list chat screen built top to bottom: a header, then the group's message lines.
private struct ListScreen {
    var lines: [(text: String, rect: CGRect)] = []
    var avatars: [(y: CGFloat, print: AvatarPrint?)] = []
    var y: CGFloat = 40

    mutating func group(_ header: String, avatar: AvatarPrint?, _ messages: [String], preview: String? = nil) {
        if let preview {
            lines.append((preview, CGRect(x: 90, y: y, width: CGFloat(preview.count) * 7, height: 14)))
            y += 20
        }
        lines.append((header, CGRect(x: 72, y: y, width: CGFloat(header.count) * 7, height: 16)))
        avatars.append((y, avatar))
        y += 22
        for m in messages {
            lines.append((m, CGRect(x: 72, y: y, width: CGFloat(m.count) * 7, height: 16)))
            y += 24
        }
        y += 16
    }

    func assign(sent: [String] = [], mine: [MyAvatar] = []) -> ChatSides.ListOutcome? {
        ChatSides.assignList(lines, sent: sent, mine: mine) { patch, _, _ in
            avatars.first { $0.y > patch.minY && $0.y < patch.maxY }?.print
        }
    }

    /// "speaker: text" per labeled line, "text" for unlabeled ones, nothing for hidden headers.
    func labeled(_ out: ChatSides.ListOutcome) -> [String] {
        lines.indices.compactMap { i in
            let a = out.assignments[i]
            if a.isNameLine { return nil }
            return a.speaker.map { "\($0): \(lines[i].text)" } ?? lines[i].text
        }
    }
}

@Suite struct ChatSidesListTests {
    @Test func headers() {
        #expect(ChatSides.listHeader("Sam & MOD - 11/21/26, 8:36 PM") == .some("Sam & MOD -"))
        #expect(ChatSides.listHeader("11/20/26, 10:56AM") == .some(nil))
        #expect(ChatSides.listHeader("j 11/2/26, 12:27 PM|") != nil)
        #expect(ChatSides.listHeader("Sam A MOD - 11/21/26, 8:36 PMł") != nil)
        #expect(ChatSides.listHeader("Yesterday at 11:03 PM") == .some(nil))
        #expect(ChatSides.listHeader("Remi v APP 10/6/26,3:42 PM") != nil)
        #expect(ChatSides.listHeader("see you at 10:30 AM") == nil)
        #expect(ChatSides.listHeader("are we still on for 10:30?") == nil)
        #expect(ChatSides.listHeader("i think we should all meet up tomorrow morning around 10:30") == nil)
        #expect(ChatSides.listHeader("Star fox remake is awesome") == nil)
    }

    @Test func names() {
        #expect(ChatSides.readName("Sam & MOD -") == "sam")
        #expect(ChatSides.readName("Rosa Lee X MOD") == "rosa lee")
        #expect(ChatSides.readName("•DO+ Jo Ann + 0.") == "jo ann")
        #expect(ChatSides.readName("j") == "")
        #expect(ChatSides.readName(nil) == "")
        #expect(ChatSides.similarName("rosa lee", "rosa le"))
        #expect(ChatSides.similarName("alex", "alex be"))
        #expect(!ChatSides.similarName("sam", "rosa"))
        #expect(!ChatSides.similarName("", "sam"))
    }

    @Test func chrome() {
        #expect(ChatSides.isReactionRow("wow 1"))
        #expect(ChatSides.isReactionRow("38, 1"))
        #expect(!ChatSides.isReactionRow("Bring snacks"))
        #expect(ChatSides.isDateDivider("November 22, 2026"))
        #expect(ChatSides.isReplyPreview("@Sam MOD Click to see attachment"))
        #expect(ChatSides.isReplyPreview("' APP @Remi The ferry leaves at noon"))
        #expect(!ChatSides.isReplyPreview("ask me @ noon"))
    }

    @Test func nothingKnownStaysUnlabeled() {
        var s = ListScreen()
        s.group("Sam & MOD 9:07 AM", avatar: samAvatar, ["The ferry leaves at noon tomorrow"])
        s.group("11:03 PM", avatar: alexAvatar, ["nice one"])
        #expect(s.assign() == nil)
    }

    @Test func sentMessageMakesItsGroupMineAndTeachesTheAvatar() throws {
        var s = ListScreen()
        s.group("Sam & MOD 9:07 AM", avatar: samAvatar, ["The ferry leaves at noon tomorrow"])
        s.group("11:03 PM", avatar: alexAvatar, ["nice", "almost finished packing the tent"])
        s.group("Sam & MOD 9:12 AM", avatar: samAvatar, ["Bring snacks"])
        let out = try #require(s.assign(sent: ["almost finished packing the tent"]))
        #expect(s.labeled(out) == ["Them: The ferry leaves at noon tomorrow", "Me: nice",
                                  "Me: almost finished packing the tent", "Them: Bring snacks"])
        #expect(out.learned == [MyAvatar(print: alexAvatar, names: [""], learnedAt: out.learned[0].learnedAt)])
    }

    @Test func learnedAvatarFindsTheWriter() throws {
        var s = ListScreen()
        s.group("Rosa Lee 10:12 AM", avatar: rosaAvatar, ["Passed my driving test!"])
        s.group("10:56 AM", avatar: alexAvatar, ["congrats!!"], preview: "@Rosa Lee Passed my driving test!")
        s.group("Sam & MOD 11:01 AM", avatar: samAvatar, ["Congrats"], preview: "@Rosa Lee Passed my driving test!")
        let out = try #require(s.assign(mine: [MyAvatar(print: alexAvatar, names: [""])]))
        #expect(s.labeled(out) == ["Them: Passed my driving test!", "@Rosa Lee Passed my driving test!",
                                  "Me: congrats!!", "@Rosa Lee Passed my driving test!", "Them: Congrats"])
        #expect(out.avatarMe == 1 && out.avatarThem == 2)
    }

    @Test func sameAvatarWithAnotherReadableNameIsNotMe() throws {
        // Two people with the same default avatar: the writer's name was never read (one letter), Sam's is.
        var s = ListScreen()
        s.group("10:56 AM", avatar: alexAvatar, ["congrats!!"])
        s.group("Sam 11:01 AM", avatar: alexAvatar, ["Congrats"])
        let out = try #require(s.assign(mine: [MyAvatar(print: alexAvatar, names: [""])]))
        #expect(s.labeled(out) == ["Me: congrats!!", "Sam 11:01 AM", "Congrats"])
    }

    @Test func noAvatarFallsBackOnTheName() throws {
        var s = ListScreen()
        s.group("Alex 10:56 AM", avatar: nil, ["congrats!!"])
        s.group("Sam 11:01 AM", avatar: nil, ["Congrats"])
        s.group("11:05 AM", avatar: nil, ["see you all there"])
        let out = try #require(s.assign(mine: [MyAvatar(print: alexAvatar, names: ["alex"])]))
        // A name that isn't the writer's is Them; the writer's own name alone, or none, stays unlabeled
        // (with its header kept).
        #expect(s.labeled(out) == ["Alex 10:56 AM", "congrats!!", "Them: Congrats", "11:05 AM", "see you all there"])
    }

    @Test func linesAboveTheFirstHeaderStayUnlabeled() throws {
        var s = ListScreen()
        s.lines.append(("which is why the road was closed", CGRect(x: 72, y: 10, width: 200, height: 16)))
        s.group("Sam 11:01 AM", avatar: samAvatar, ["Congrats"])
        let out = try #require(s.assign(mine: [MyAvatar(print: alexAvatar, names: [""])]))
        #expect(s.labeled(out) == ["which is why the road was closed", "Them: Congrats"])
    }

    @Test func separateMessagesOfOneGroupAreSeparateBlocks() throws {
        var s = ListScreen()
        s.group("Sam 11:01 AM", avatar: samAvatar, ["The bakery opens at seven", "Cash only though"])
        let out = try #require(s.assign(mine: [MyAvatar(print: alexAvatar, names: [""])]))
        #expect(out.assignments[1].block != out.assignments[2].block)
    }

    @Test func pipelineEmitsMeAndThem() throws {
        var s = ListScreen()
        s.group("Sam & MOD 9:07 AM", avatar: samAvatar, ["The ferry leaves at noon tomorrow"])
        s.group("11:03 PM", avatar: alexAvatar, ["perfect, I will bring the map"])
        let lines = s.lines.map { OCRLine(text: $0.text, confidence: 1, rect: $0.rect) }
        let field = CGRect(x: 40, y: s.y + 20, width: 600, height: 40)
        let avatars = s.avatars
        let out = try #require(ScreenTextPipeline.process(
            lines: lines, caret: CGPoint(x: 60, y: field.midY), field: field, maxCharacters: 4000,
            chatSides: true, listChat: true, myAvatars: [MyAvatar(print: alexAvatar, names: [""])],
            avatarAt: { patch, _, _ in avatars.first { $0.y > patch.minY && $0.y < patch.maxY }?.print }))
        #expect(out.text == "Them: The ferry leaves at noon tomorrow\nMe: perfect, I will bring the map")
        #expect(out.avatarMe == 1 && out.avatarThem == 1)
    }
}

@Suite struct AvatarFinderTests {
    /// A dark patch with a filled circle at (cx, cy), a thin connector line above it and some
    /// small text to its right.
    private func patch(width: Int = 120, height: Int = 130, bg: (UInt8, UInt8, UInt8) = (20, 20, 24),
                       color: (Int, Int) -> (UInt8, UInt8, UInt8), cx: Int = 45, cy: Int = 60, r: Int = 30,
                       litRows: Range<Int>? = nil) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var c = bg
                // A message lit up under the mouse: its rows' background is lighter, avatar side included.
                if let litRows, litRows.contains(y) { c = (52, 54, 62) }
                if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r { c = color(x, y) }
                if y == 15 && x > 40 && x < 110 { c = (150, 150, 150) }  // reply connector
                if x == 41 && y > 15 && y < 28 { c = (150, 150, 150) }
                if x > 95 && x < 101 && y > 40 && y < 50 { c = (230, 230, 230) }  // a short name
                let p = (y * width + x) * 4
                px[p] = c.0; px[p + 1] = c.1; px[p + 2] = c.2; px[p + 3] = 255
            }
        }
        return px
    }

    private func face(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        y < 60 ? (210, 170, 140) : (60, 90, 200)
    }

    @Test func findsTheCircleAndIgnoresLinesAndText() throws {
        let a = try #require(AvatarFinder.print(rgba: patch(color: face), width: 120, height: 130, minSide: 30, maxSide: 90))
        // The same avatar further left, on a highlighted background.
        let b = try #require(AvatarFinder.print(rgba: patch(bg: (60, 50, 20), color: face, cx: 38), width: 120, height: 130,
                                                minSide: 30, maxSide: 90))
        #expect(a.distance(to: b) < ChatSides.avatarMatch)
        let other = try #require(AvatarFinder.print(rgba: patch(color: { _, _ in (240, 90, 160) }), width: 120, height: 130,
                                                    minSide: 30, maxSide: 90))
        #expect(a.distance(to: other) > ChatSides.avatarMiss)
    }

    @Test func aLitUpRowDoesNotMoveTheAvatar() throws {
        let plain = try #require(AvatarFinder.print(rgba: patch(color: face), width: 120, height: 130, minSide: 30, maxSide: 90))
        for lit in [40..<130, 0..<75, 20..<100] {
            let hovered = try #require(AvatarFinder.print(rgba: patch(color: face, litRows: lit), width: 120, height: 130,
                                                          minSide: 30, maxSide: 90))
            #expect(plain.distance(to: hovered) < ChatSides.avatarMatch / 2, "\(lit)")
        }
    }

    @Test func tooSmallOrMissingIsNil() {
        #expect(AvatarFinder.print(rgba: patch(color: face, r: 8), width: 120, height: 130, minSide: 30, maxSide: 90) == nil)
        let empty = [UInt8](repeating: 20, count: 120 * 130 * 4)
        #expect(AvatarFinder.print(rgba: empty, width: 120, height: 130, minSide: 30, maxSide: 90) == nil)
    }
}

@Suite struct MyAvatarStoreTests {
    @Test func learnsMergesAndForgets() {
        let store = MyAvatarStore(fileURL: nil)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.learn([MyAvatar(print: alexAvatar, names: [""])], app: "discord", now: t0)
        store.learn([MyAvatar(print: alexAvatar, names: ["alex"])], app: "discord", now: t0)
        #expect(store.avatars(app: "discord", now: t0).map(\.names) == [["", "alex"]])
        #expect(store.avatars(app: "other", now: t0).isEmpty)
        // `perApp` more avatars, each clearly different (one channel bright per quarter of the range).
        let others = (0..<MyAvatarStore.perApp).map { i in
            solid(UInt8((i & 1) * 240), UInt8(((i >> 1) & 1) * 240), UInt8(((i >> 2) & 1) * 240 + 10))
        }
        for (i, p) in others.enumerated() {
            store.learn([MyAvatar(print: p, names: [])], app: "discord", now: t0 + Double(i + 1))
        }
        #expect(store.avatars(app: "discord", now: t0 + 10).count == MyAvatarStore.perApp)
        #expect(!store.avatars(app: "discord", now: t0 + 10).contains { $0.print == alexAvatar })
        #expect(store.avatars(app: "discord", now: t0 + MyAvatarStore.maxAge + 100).isEmpty)
    }

    @Test func savesAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("my-avatars-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        MyAvatarStore(fileURL: url).learn([MyAvatar(print: alexAvatar, names: [""])], app: "discord")
        #expect(MyAvatarStore(fileURL: url).avatars(app: "discord").count == 1)
    }
}

@Suite struct MyAvatarStoreEditingTests {
    @Test func listsAndDeletes() {
        let store = MyAvatarStore(fileURL: nil)
        var changes = 0
        store.onChange = { changes += 1 }
        let t0 = Date()
        store.learn([MyAvatar(print: alexAvatar, names: [""])], app: "discord", now: t0)
        store.learn([MyAvatar(print: samAvatar, names: ["alex"])], app: "discord", now: t0 + 1)
        #expect(store.all(now: t0 + 2).map(\.avatar.print) == [samAvatar, alexAvatar])
        store.delete(app: "discord", print: samAvatar)
        #expect(store.avatars(app: "discord", now: t0 + 2).map(\.print) == [alexAvatar])
        store.clear()
        #expect(store.all(now: t0 + 2).isEmpty)
        #expect(changes == 4)
        store.clear()
        #expect(changes == 4)
    }
}
