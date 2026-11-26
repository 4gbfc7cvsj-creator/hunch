import Foundation
import HunchCore
import Testing
@testable import HunchInput

@MainActor
private final class FakePoster: KeyEventPosting {
    var unicode: [[UInt16]] = []
    var pastes: [Bool] = []
    var failUnicodeAfter: Int?
    var pasteWorks = true
    func postUnicode(_ units: [UInt16]) -> Bool {
        if let limit = failUnicodeAfter, unicode.count >= limit { return false }
        unicode.append(units)
        return true
    }
    func postPaste(matchStyle: Bool) -> Bool {
        pastes.append(matchStyle)
        return pasteWorks
    }
    var keys: [UInt16] = []
    func postKey(keyCode: UInt16) -> Bool {
        keys.append(keyCode)
        return true
    }
    var deletes = 0
    func postDeleteBackward() -> Bool {
        deletes += 1
        return true
    }
}

@MainActor
private final class FakePasteboard: PasteboardAccess {
    var changeCount = 0
    var contents = PasteboardSnapshot(items: [[.init(type: "public.utf8-plain-text", data: Data("mine".utf8))],
                                              [.init(type: "public.png", data: Data([1, 2, 3]))]])
    var writeWorks = true
    func snapshot() -> PasteboardSnapshot { contents }
    func writeTransient(_ text: String) -> Int? {
        guard writeWorks else { return nil }
        contents = PasteboardSnapshot(items: [[.init(type: "public.utf8-plain-text", data: Data(text.utf8))]])
        changeCount += 1
        return changeCount
    }
    func restore(_ snapshot: PasteboardSnapshot) {
        contents = snapshot
        changeCount += 1
    }
    func userCopies(_ text: String) {
        contents = PasteboardSnapshot(items: [[.init(type: "public.utf8-plain-text", data: Data(text.utf8))]])
        changeCount += 1
    }
}

private let app = AppIdentity(bundleID: "com.example.editor", pid: 99, localizedName: nil)

@MainActor
private func makeInserter(poster: FakePoster, board: FakePasteboard, secure: Bool = false, frontmost: pid_t = 99) -> UnicodeEventInserter {
    UnicodeEventInserter(poster: poster, pasteboard: board,
                         environment: InsertionEnvironment(secureInputEnabled: { secure }, frontmostPID: { frontmost }),
                         interChunkDelay: .zero, pasteRestoreDelay: .seconds(3600))
}

@MainActor @Test func unicodeInsertionPostsChunks() async {
    let poster = FakePoster(), board = FakePasteboard()
    let outcome = await makeInserter(poster: poster, board: board).insert("hello world, 你好世界", into: app, mode: .unicodeEvents, chunkSize: 8)
    #expect(outcome == .inserted)
    #expect(String(decoding: poster.unicode.joined(), as: UTF16.self) == "hello world, 你好世界")
    #expect(poster.unicode.allSatisfy { $0.count <= 8 })
}

@MainActor @Test func secureInputBlocksInsertion() async {
    let poster = FakePoster()
    let outcome = await makeInserter(poster: poster, board: FakePasteboard(), secure: true).insert("x", into: app, mode: .unicodeEvents, chunkSize: 16)
    guard case .failed = outcome else { Issue.record("expected failure"); return }
    #expect(poster.unicode.isEmpty)
}

@MainActor @Test func wrongFrontmostAppBlocksInsertion() async {
    let poster = FakePoster()
    let outcome = await makeInserter(poster: poster, board: FakePasteboard(), frontmost: 1).insert("x", into: app, mode: .paste, chunkSize: 16)
    guard case .failed = outcome else { Issue.record("expected failure"); return }
    #expect(poster.pastes.isEmpty)
}

@MainActor @Test func unicodeFailureFallsBackToPasteForRemainder() async {
    let poster = FakePoster(), board = FakePasteboard()
    poster.failUnicodeAfter = 1
    let outcome = await makeInserter(poster: poster, board: board).insert("abcdefgh", into: app, mode: .unicodeEvents, chunkSize: 4)
    #expect(outcome == .fellBack(.paste))
    #expect(String(decoding: poster.unicode.joined(), as: UTF16.self) == "abcd")
    #expect(board.contents.items.first?.first?.data == Data("efgh".utf8))
}

@MainActor @Test func pasteMatchStyleUsesStyleChord() async {
    let poster = FakePoster(), board = FakePasteboard()
    let outcome = await makeInserter(poster: poster, board: board).insert("hi", into: app, mode: .pasteMatchStyle, chunkSize: 16)
    #expect(outcome == .inserted)
    #expect(poster.pastes == [true])
}

@MainActor @Test func pasteWriteFailureFallsBackToUnicode() async {
    let poster = FakePoster(), board = FakePasteboard()
    board.writeWorks = false
    let original = board.contents
    let outcome = await makeInserter(poster: poster, board: board).insert("hi", into: app, mode: .paste, chunkSize: 16)
    #expect(outcome == .fellBack(.unicodeEvents))
    #expect(board.contents == original)
}

@MainActor @Test func clipboardRestoredWhenUntouched() {
    let board = FakePasteboard()
    let original = board.contents
    let swap = ClipboardSwap(board: board)
    #expect(swap.stage("ghost"))
    swap.restoreNow()
    #expect(board.contents == original)
    #expect(!swap.hasPendingRestore)
}

@MainActor @Test func clipboardNotRestoredAfterUserCopy() {
    let board = FakePasteboard()
    let swap = ClipboardSwap(board: board)
    #expect(swap.stage("ghost"))
    board.userCopies("new user copy")
    swap.restoreNow()
    #expect(board.contents.items.first?.first?.data == Data("new user copy".utf8))
}

@MainActor @Test func backToBackPastesRestoreTheUsersOriginal() {
    let board = FakePasteboard()
    let original = board.contents
    let swap = ClipboardSwap(board: board)
    #expect(swap.stage("one"))
    #expect(swap.stage("two"))
    swap.restoreNow()
    #expect(board.contents == original)
}

@MainActor @Test func replaceDeletesTriggerThenInserts() async {
    let poster = FakePoster(), board = FakePasteboard()
    let outcome = await makeInserter(poster: poster, board: board)
        .replace(deletingBackward: 4, with: "😄", into: app, mode: .unicodeEvents, chunkSize: 16)
    #expect(outcome == .inserted)
    #expect(poster.deletes == 4)
    #expect(String(decoding: poster.unicode.joined(), as: UTF16.self) == "😄")
}

@MainActor @Test func replaceIsBlockedUnderSecureInput() async {
    let poster = FakePoster(), board = FakePasteboard()
    let outcome = await makeInserter(poster: poster, board: board, secure: true)
        .replace(deletingBackward: 3, with: "🙂", into: app, mode: .unicodeEvents, chunkSize: 16)
    #expect(poster.deletes == 0)
    if case .failed = outcome {} else { Issue.record("expected failure") }
}

@MainActor @Test func restorePendingClipboardPutsBackUserContentsNow() async {
    let poster = FakePoster(), board = FakePasteboard()
    let original = board.contents
    let inserter = makeInserter(poster: poster, board: board)
    _ = await inserter.insert("hi", into: app, mode: .paste, chunkSize: 16)
    #expect(board.contents != original)
    inserter.restorePendingClipboard()
    #expect(board.contents == original)
}

@MainActor @Test func restorePendingClipboardLeavesUserCopyAlone() async {
    let poster = FakePoster(), board = FakePasteboard()
    let inserter = makeInserter(poster: poster, board: board)
    _ = await inserter.insert("hi", into: app, mode: .paste, chunkSize: 16)
    board.userCopies("newer")
    let count = board.changeCount
    inserter.restorePendingClipboard()
    #expect(board.changeCount == count)
}

@MainActor @Test func pressKeyPostsOnlyWhenSafe() {
    let poster = FakePoster()
    #expect(makeInserter(poster: poster, board: FakePasteboard()).pressKey(53, into: app))
    #expect(poster.keys == [53])
    #expect(!makeInserter(poster: poster, board: FakePasteboard(), secure: true).pressKey(53, into: app))
    #expect(!makeInserter(poster: poster, board: FakePasteboard(), frontmost: 1).pressKey(53, into: app))
    #expect(poster.keys == [53])
}

// MARK: Insertion workarounds

private let nbsp: UInt16 = 0x00A0
private func units(_ s: String) -> [UInt16] { Array(s.utf16) }

@Test func transformWithoutWorkaroundsIsPlainChunking() {
    let text = "hello world, 你好世界 👩‍💻 done"
    #expect(InsertionTextTransform.runs(text, workarounds: .init(), chunkSize: 8)
            == TextChunker.chunks(text, chunkSize: 8).map(InsertionTextTransform.Run.unicode))
}

@Test func transformSubstitutesEveryNonBreakingSpace() {
    let runs = InsertionTextTransform.runs(" a  b ", workarounds: .init(nonBreakingSpaces: true))
    #expect(runs == [.unicode([nbsp] + units("a") + [nbsp, nbsp] + units("b") + [nbsp])])
}

@Test func transformSplitsSpacesIntoKeyPresses() {
    typealias Run = InsertionTextTransform.Run
    let on = InsertionWorkarounds(spaceAsKeyEvent: true)
    #expect(InsertionTextTransform.runs(" world", workarounds: on) == [.key(keyCode: 49), .unicode(units("world"))])
    #expect(InsertionTextTransform.runs("a  b ", workarounds: on)
            == [.unicode(units("a")), .key(keyCode: 49), .key(keyCode: 49), .unicode(units("b")), .key(keyCode: 49)])
    // Each Unicode run is still chunked.
    #expect(InsertionTextTransform.runs("abcdef gh", workarounds: on, chunkSize: 4)
            == [.unicode(units("abcd")), .unicode(units("ef")), .key(keyCode: 49), .unicode(units("gh"))])
    #expect(InsertionTextTransform.text(of: InsertionTextTransform.runs("a  b ", workarounds: on)) == "a  b ")
}

@Test func nonBreakingSpacesWinOverSpaceKey() {
    let both = InsertionWorkarounds(nonBreakingSpaces: true, spaceAsKeyEvent: true)
    #expect(InsertionTextTransform.runs(" hi there", workarounds: both) == [.unicode([nbsp] + units("hi") + [nbsp] + units("there"))])
}

@MainActor @Test func defaultWorkaroundsPostExactlyAsBefore() async {
    let text = "hello world, 你好世界 👩‍💻 done"
    let plain = FakePoster(), explicit = FakePoster()
    #expect(await makeInserter(poster: plain, board: FakePasteboard())
        .insert(text, into: app, mode: .unicodeEvents, chunkSize: 8) == .inserted)
    #expect(await makeInserter(poster: explicit, board: FakePasteboard())
        .insert(text, into: app, mode: .unicodeEvents, chunkSize: 8, workarounds: InsertionWorkarounds()) == .inserted)
    #expect(explicit.unicode == TextChunker.chunks(text, chunkSize: 8))
    #expect(explicit.unicode == plain.unicode)
    #expect(explicit.keys.isEmpty && explicit.deletes == 0 && explicit.pastes.isEmpty)

    let pasted = FakePoster()
    #expect(await makeInserter(poster: pasted, board: FakePasteboard())
        .insert(text, into: app, mode: .paste, chunkSize: 8, workarounds: InsertionWorkarounds()) == .inserted)
    #expect(pasted.pastes == [false] && pasted.deletes == 0 && pasted.unicode.isEmpty && pasted.keys.isEmpty)
}

@MainActor @Test func nonBreakingSpacesArePostedForEverySpace() async {
    let poster = FakePoster()
    let outcome = await makeInserter(poster: poster, board: FakePasteboard())
        .insert(" hello big world", into: app, mode: .unicodeEvents, chunkSize: 16,
                workarounds: .init(nonBreakingSpaces: true))
    #expect(outcome == .inserted)
    let posted = poster.unicode.joined()
    #expect(!posted.contains(0x20))
    #expect(String(decoding: posted, as: UTF16.self) == "\u{A0}hello\u{A0}big\u{A0}world")
    #expect(poster.keys.isEmpty)
}

@MainActor @Test func spaceKeyRunsArePostedInOrder() async {
    // Records unicode and key posts in one sequence.
    @MainActor final class Recorder: KeyEventPosting {
        var events: [String] = []
        func postUnicode(_ units: [UInt16]) -> Bool { events.append(String(decoding: units, as: UTF16.self)); return true }
        func postPaste(matchStyle: Bool) -> Bool { events.append("paste"); return true }
        func postDeleteBackward() -> Bool { events.append("delete"); return true }
        func postKey(keyCode: UInt16) -> Bool { events.append("key\(keyCode)"); return true }
    }
    let recorder = Recorder()
    let inserter = UnicodeEventInserter(
        poster: recorder, pasteboard: FakePasteboard(),
        environment: InsertionEnvironment(secureInputEnabled: { false }, frontmostPID: { 99 }), interChunkDelay: .zero)
    let outcome = await inserter.insert(" world", into: app, mode: .unicodeEvents, chunkSize: 16,
                                        workarounds: .init(spaceAsKeyEvent: true))
    #expect(outcome == .inserted)
    #expect(recorder.events == ["key49", "world"])
}

@MainActor @Test func bothFlagsPressNoSpaceKey() async {
    let poster = FakePoster()
    _ = await makeInserter(poster: poster, board: FakePasteboard())
        .insert("a b", into: app, mode: .unicodeEvents, chunkSize: 16,
                workarounds: .init(nonBreakingSpaces: true, spaceAsKeyEvent: true))
    #expect(poster.keys.isEmpty)
    #expect(poster.unicode == [units("a") + [nbsp] + units("b")])
}

@MainActor @Test func backspaceFollowsOnlyASuccessfulPaste() async {
    let on = InsertionWorkarounds(backspaceAfterPaste: true)
    let ok = FakePoster()
    #expect(await makeInserter(poster: ok, board: FakePasteboard())
        .insert("hi there", into: app, mode: .pasteMatchStyle, chunkSize: 16, workarounds: on) == .inserted)
    #expect(ok.pastes == [true] && ok.deletes == 1)

    // Cmd+V could not be posted: falls back to typing, no Backspace.
    let refused = FakePoster()
    refused.pasteWorks = false
    #expect(await makeInserter(poster: refused, board: FakePasteboard())
        .insert("hi there", into: app, mode: .paste, chunkSize: 16, workarounds: on) == .fellBack(.unicodeEvents))
    #expect(refused.deletes == 0)

    // The clipboard could not be written: same.
    let unwritable = FakePoster(), board = FakePasteboard()
    board.writeWorks = false
    #expect(await makeInserter(poster: unwritable, board: board)
        .insert("hi there", into: app, mode: .paste, chunkSize: 16, workarounds: on) == .fellBack(.unicodeEvents))
    #expect(unwritable.pastes.isEmpty && unwritable.deletes == 0)

    // The Unicode path never presses Backspace, even when it falls back to pasting the rest.
    let typed = FakePoster()
    typed.failUnicodeAfter = 1
    #expect(await makeInserter(poster: typed, board: FakePasteboard())
        .insert("abcdefgh", into: app, mode: .unicodeEvents, chunkSize: 4, workarounds: on) == .fellBack(.paste))
    #expect(typed.pastes == [false] && typed.deletes == 0)
}

@MainActor @Test func workaroundFallbacksStillWork() async {
    // Typing fails part-way: what's left (Space presses as spaces) is pasted.
    let poster = FakePoster(), board = FakePasteboard()
    poster.failUnicodeAfter = 1
    let outcome = await makeInserter(poster: poster, board: board)
        .insert("ab cd ef", into: app, mode: .unicodeEvents, chunkSize: 16, workarounds: .init(spaceAsKeyEvent: true))
    #expect(outcome == .fellBack(.paste))
    #expect(poster.unicode == [units("ab")] && poster.keys == [49])
    #expect(board.contents.items.first?.first?.data == Data("cd ef".utf8))

    // Paste fails: typing applies the workarounds.
    let typing = FakePoster(), unwritable = FakePasteboard()
    unwritable.writeWorks = false
    #expect(await makeInserter(poster: typing, board: unwritable)
        .insert("a b", into: app, mode: .paste, chunkSize: 16,
                workarounds: .init(nonBreakingSpaces: true)) == .fellBack(.unicodeEvents))
    #expect(typing.unicode == [units("a") + [nbsp] + units("b")])
}

@MainActor @Test func replaceAppliesWorkaroundsToTheReplacement() async {
    let poster = FakePoster()
    let outcome = await makeInserter(poster: poster, board: FakePasteboard())
        .replace(deletingBackward: 3, with: "the ", into: app, mode: .unicodeEvents, chunkSize: 16,
                 workarounds: .init(spaceAsKeyEvent: true))
    #expect(outcome == .inserted)
    #expect(poster.deletes == 3 && poster.unicode == [units("the")] && poster.keys == [49])
}

@MainActor @Test func heldPasteKeepsTheDraftUntilReleased() async throws {
    let poster = FakePoster(), board = FakePasteboard()
    let original = board.contents
    // A restore delay that would long have run out: holding ignores it.
    let inserter = UnicodeEventInserter(poster: poster, pasteboard: board,
                                        environment: InsertionEnvironment(secureInputEnabled: { false }, frontmostPID: { 99 }),
                                        interChunkDelay: .zero, pasteRestoreDelay: .milliseconds(1))
    let outcome = await inserter.insertHoldingClipboard("draft", into: app, mode: .paste, chunkSize: 16,
                                                        workarounds: InsertionWorkarounds())
    #expect(outcome == .inserted)
    try await Task.sleep(for: .milliseconds(50))
    #expect(board.contents != original)
    inserter.releaseClipboard(restore: true)
    #expect(board.contents == original)
}

@MainActor @Test func releasingWithoutRestoreLeavesTheDraft() async {
    let poster = FakePoster(), board = FakePasteboard()
    let original = board.contents
    let inserter = makeInserter(poster: poster, board: board)
    _ = await inserter.insertHoldingClipboard("draft", into: app, mode: .paste, chunkSize: 16,
                                              workarounds: InsertionWorkarounds())
    let draft = board.contents
    inserter.releaseClipboard(restore: false)
    inserter.restorePendingClipboard()
    #expect(board.contents == draft)
    #expect(board.contents != original)
}
