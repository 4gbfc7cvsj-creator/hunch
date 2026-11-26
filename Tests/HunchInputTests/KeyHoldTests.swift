import Foundation
import HunchCore
import Testing
@testable import HunchInput

// Holding the user's keys while a fix goes in, and the catch-up shortcut's consume rule.

@Test func heldKeysComeBackInOrder() {
    var q = KeyHoldQueue<String>()
    let r1 = q.userKey("a")
    #expect(!r1)                      // idle: nothing held
    q.begin(now: 0)
    let r2 = q.userKey("a")
    #expect(r2)
    let r3 = q.userKey("b")
    #expect(r3)
    let out = q.release(now: 10)
    #expect(out.map(\.event) == ["a", "b"])
    #expect(q.mode == .draining(lastOrder: out.last!.order, since: 10))
    // Typed while the replays are on their way: held until the last one passed.
    let r4 = q.userKey("c")
    #expect(r4)
    let r5 = q.replayPassed(order: out[0].order, now: 11)
    #expect(r5.isEmpty)
    let next = q.replayPassed(order: out[1].order, now: 12)
    #expect(next.map(\.event) == ["c"])
    let r6 = q.replayPassed(order: next[0].order, now: 13)
    #expect(r6.isEmpty)
    #expect(q.mode == .idle)
}

@Test func releaseWithNothingHeldGoesIdle() {
    var q = KeyHoldQueue<String>()
    q.begin(now: 0)
    let r7 = q.release(now: 1)
    #expect(r7.isEmpty)
    #expect(q.mode == .idle)
    let r8 = q.release(now: 2)
    #expect(r8.isEmpty)            // releasing twice is harmless
}

@Test func holdNeverOutlastsItsLimit() {
    var q = KeyHoldQueue<String>()
    q.begin(now: 0, maxDuration: 10_000_000_000)  // asked for 10 s, capped
    _ = q.userKey("a")
    let r9 = q.tick(now: KeyHoldQueue<String>.maxHoldNanoseconds - 1)
    #expect(r9.isEmpty)
    let r10 = q.tick(now: KeyHoldQueue<String>.maxHoldNanoseconds)
    #expect(r10.map(\.event) == ["a"])
    // A replay that never comes back doesn't keep keys forever.
    _ = q.userKey("b")
    let r11 = q.tick(now: KeyHoldQueue<String>.maxHoldNanoseconds * 3)
    #expect(r11.map(\.event) == ["b"])
    #expect(q.mode == .idle)
}

@Test func aHoldStartedMidReplayKeepsTypingOrder() {
    var q = KeyHoldQueue<String>()
    q.begin(now: 0)
    _ = q.userKey("k")    // the catch-up key pressed again while the first fix ran
    _ = q.userKey("x")
    let out = q.release(now: 1)
    // The replayed "k" starts a new hold; "x" is still on its way and comes back held.
    q.begin(now: 2)
    let r12 = q.userKey("y")
    #expect(r12)
    let r13 = q.replayArrived(order: out[1].order, event: "x")
    #expect(r13)
    let r14 = q.release(now: 3)
    #expect(r14.map(\.event) == ["x", "y"])
}

@Test func catchUpKeyIsConsumedOnlyWhileAFixWaits() {
    let chord = KeyChord(keyCode: 3, modifiers: 0x100000 | 0x80000)
    var bindings = AcceptBindings()
    bindings.catchUp = chord
    #expect(ArbiterRules.shortcut(for: chord, bindings: bindings) == .catchUp)
    #expect(TapRules.globalShortcutChords(bindings).contains(chord))
    let waiting = TapRules.decide(ghostVisible: false, editableFocus: true, chord: chord, snapshot: nil,
                                  bindings: bindings, now: 0, maxAgeTicks: 1, catchUpWaiting: true)
    #expect(waiting == .shortcut(.catchUp))
    let idle = TapRules.decide(ghostVisible: false, editableFocus: true, chord: chord, snapshot: nil,
                               bindings: bindings, now: 0, maxAgeTicks: 1, catchUpWaiting: false)
    #expect(idle == .passThrough)  // nothing waiting: the key reaches the app
    #expect(TapRules.gate(waiting, catchUpWaiting: true) == .shortcut(.catchUp))
    #expect(TapRules.gate(waiting, catchUpWaiting: false) == .passThrough)
    #expect(TapRules.shortcutConsumed(.catchUp, editableFocus: true, catchUpWaiting: true))
    #expect(!TapRules.shortcutConsumed(.catchUp, editableFocus: true, catchUpWaiting: false))
    #expect(!TapRules.shortcutConsumed(.catchUp, editableFocus: false, catchUpWaiting: true))
}

@Test func catchUpIsUnsetByDefaultAndSurvivesSaving() throws {
    #expect(AcceptBindings().catchUp == nil)
    let old = try JSONDecoder().decode(AcceptBindings.self, from: Data(#"{"word":null}"#.utf8))
    #expect(old.catchUp == nil)
    var b = AcceptBindings()
    b.catchUp = KeyChord(keyCode: 3, modifiers: 0x100000)
    let back = try JSONDecoder().decode(AcceptBindings.self, from: JSONEncoder().encode(b))
    #expect(back.catchUp == b.catchUp)
}

@Test func revertKeyIsConsumedOnlyWhileAFixCanBePutBack() {
    let chord = KeyChord.controlShiftZ
    let bindings = AcceptBindings()
    #expect(bindings.revertFix == chord)  // bound by default
    #expect(ArbiterRules.shortcut(for: chord, bindings: bindings) == .revertFix)
    #expect(TapRules.globalShortcutChords(bindings).contains(chord))
    let waiting = TapRules.decide(ghostVisible: false, editableFocus: true, chord: chord, snapshot: nil,
                                  bindings: bindings, now: 0, maxAgeTicks: 1, revertWaiting: true)
    #expect(waiting == .shortcut(.revertFix))
    let idle = TapRules.decide(ghostVisible: false, editableFocus: true, chord: chord, snapshot: nil,
                               bindings: bindings, now: 0, maxAgeTicks: 1, catchUpWaiting: true, revertWaiting: false)
    #expect(idle == .passThrough)
    #expect(TapRules.gate(.shortcut(.revertFix), catchUpWaiting: false, revertWaiting: false) == .passThrough)
    #expect(!TapRules.shortcutConsumed(.revertFix, editableFocus: false, revertWaiting: true))
}

@Test func revertKeySurvivesSavingAndClearing() throws {
    var b = AcceptBindings()
    b.revertFix = nil
    let back = try JSONDecoder().decode(AcceptBindings.self, from: JSONEncoder().encode(b))
    #expect(back.revertFix == nil)  // cleared stays cleared
    let old = try JSONDecoder().decode(AcceptBindings.self, from: Data("{}".utf8))
    #expect(old.revertFix == .controlShiftZ)  // settings from before get the default
}
