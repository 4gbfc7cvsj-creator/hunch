import HunchCore
import Testing
@testable import HunchInput

private let field = FieldID(pid: 42, elementHash: 7, generation: 1)
private let identity = MachTimebase(numer: 1, denom: 1)

/// The shortcuts as bound before the retired ones were unset (2026-11-26): their logic is still tested.
let legacyBindings = AcceptBindings(forceActivate: .controlTab, nextAlternative: .optionDown, previousAlternative: .optionUp,
                                    revertFix: .controlShiftZ)

private func arbiter(_ snapshot: ArbiterSnapshot?, bindings: AcceptBindings = legacyBindings) -> DefaultAcceptanceArbiter {
    let a = DefaultAcceptanceArbiter(bindings: bindings, maxAgeNanoseconds: 1_500, timebase: identity)
    a.publish(snapshot)
    return a
}

private func snap(ghost: Bool = true, at: UInt64 = 1_000, tab: Bool = true) -> ArbiterSnapshot {
    ArbiterSnapshot(field: field, hasGhost: ghost, publishedAt: at, tabAllowed: tab)
}

@Test func tabAcceptsWordAndOptionTabAcceptsFull() {
    let a = arbiter(snap())
    #expect(a.verdict(for: .tab, now: 1_100) == .consume(.word))
    #expect(a.verdict(for: .optionTab, now: 1_100) == .consume(.full))
}

@Test func noSnapshotPassesThrough() {
    #expect(arbiter(nil).verdict(for: .tab, now: 0) == .passThrough)
}

@Test func noGhostPassesThrough() {
    #expect(arbiter(snap(ghost: false)).verdict(for: .tab, now: 1_100) == .passThrough)
    #expect(arbiter(snap(ghost: false)).inputVerdict(for: .escape, now: 1_100) == .passThrough)
}

@Test func staleSnapshotPassesThrough() {
    let a = arbiter(snap(at: 1_000))
    #expect(a.verdict(for: .tab, now: 2_500) == .consume(.word))
    #expect(a.verdict(for: .tab, now: 2_501) == .passThrough)
}

@Test func tabNotAllowedPassesTabChordsOnly() {
    var bindings = AcceptBindings()
    bindings.full = KeyChord(keyCode: 124, modifiers: ChordMatcher.option) // Option+Right arrow
    let a = arbiter(snap(tab: false), bindings: bindings)
    #expect(a.verdict(for: .tab, now: 1_000) == .passThrough)
    #expect(a.verdict(for: KeyChord(keyCode: 124, modifiers: ChordMatcher.option), now: 1_000) == .consume(.full))
}

@Test func tabOffKeepsTheModifiedFullChord() {
    // Code editors: plain Tab indents (passes through); the default full chord Option+Tab still
    // accepts, standing in for the word chord.
    let a = arbiter(snap(tab: false))
    #expect(a.verdict(for: .tab, now: 1_000) == .passThrough)
    #expect(a.verdict(for: .optionTab, now: 1_000) == .consume(.full))
    #expect(a.inputVerdict(for: .escape, now: 1_000) == .dismiss)
    // A word binding on a modified Tab chord is not plain Tab either.
    var bindings = AcceptBindings()
    bindings.word = .controlTab
    bindings.forceActivate = nil
    let b = arbiter(snap(tab: false), bindings: bindings)
    #expect(b.verdict(for: .controlTab, now: 1_000) == .consume(.word))
    #expect(b.verdict(for: .tab, now: 1_000) == .passThrough)
}

@Test func unrelatedKeysPassThrough() {
    let a = arbiter(snap())
    #expect(a.verdict(for: KeyChord(keyCode: 0), now: 1_000) == .passThrough)
    #expect(a.verdict(for: KeyChord(keyCode: 48, modifiers: ChordMatcher.shift), now: 1_000) == .passThrough)
}

@Test func escapeDismissesOnlyWithLiveGhost() {
    #expect(arbiter(snap()).inputVerdict(for: .escape, now: 1_000) == .dismiss)
    #expect(arbiter(snap()).verdict(for: .escape, now: 1_000) == .passThrough) // not an accept
    #expect(arbiter(nil).inputVerdict(for: .escape, now: 1_000) == .passThrough)
    #expect(arbiter(snap()).inputVerdict(for: KeyChord(keyCode: 53, modifiers: ChordMatcher.command), now: 1_000) == .passThrough)
}

@Test func globalShortcutsRecognizedWithoutGhost() {
    var bindings = legacyBindings
    bindings.toggleGlobal = KeyChord(keyCode: 5, modifiers: ChordMatcher.control | ChordMatcher.option)
    let a = arbiter(nil, bindings: bindings)
    #expect(a.inputVerdict(for: .controlTab, now: 0) == .shortcut(.forceActivate))
    #expect(a.inputVerdict(for: .optionShiftTab, now: 0) == .shortcut(.writeForMe))
    #expect(a.inputVerdict(for: KeyChord(keyCode: 5, modifiers: ChordMatcher.control | ChordMatcher.option), now: 0) == .shortcut(.toggleGlobal))
    #expect(a.verdict(for: .controlTab, now: 0) == .passThrough)
}

@Test func setBindingsTakesEffect() {
    let a = arbiter(snap())
    var bindings = AcceptBindings()
    bindings.word = KeyChord(keyCode: 124, modifiers: ChordMatcher.control)
    bindings.full = nil
    a.setBindings(bindings)
    #expect(a.verdict(for: .tab, now: 1_000) == .passThrough)
    #expect(a.verdict(for: .optionTab, now: 1_000) == .passThrough)
    #expect(a.verdict(for: KeyChord(keyCode: 124, modifiers: ChordMatcher.control), now: 1_000) == .consume(.word))
}

@Test func publishingNilClearsGhost() {
    let a = arbiter(snap())
    a.publish(nil)
    #expect(a.verdict(for: .tab, now: 1_000) == .passThrough)
}

@Test func arbiterIsSafeUnderConcurrentAccess() async {
    let a = arbiter(snap())
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<8 {
            group.addTask {
                for j in 0..<500 {
                    if i % 2 == 0 { a.publish(snap(ghost: j % 2 == 0)) } else { _ = a.verdict(for: .tab, now: 1_000) }
                }
            }
        }
    }
    a.publish(snap())
    #expect(a.verdict(for: .tab, now: 1_000) == .consume(.word))
}

// MARK: Consuming tap without a visible ghost

private func noGhostDecision(_ chord: KeyChord, bindings: AcceptBindings = legacyBindings,
                             snapshot: ArbiterSnapshot? = nil, focus: Bool = true) -> InputVerdict {
    TapRules.decide(ghostVisible: false, editableFocus: focus, chord: chord, snapshot: snapshot, bindings: bindings, now: 1_000, maxAgeTicks: 1_500)
}

@Test func noGhostBoundControlTabIsConsumedAsForceActivate() {
    let verdict = noGhostDecision(.controlTab)
    #expect(verdict == .shortcut(.forceActivate))
    #expect(verdict.consumes)
}

@Test func noGhostBoundOptionShiftTabIsConsumedAsWriteForMe() {
    #expect(noGhostDecision(.optionShiftTab) == .shortcut(.writeForMe))
}

@Test func toggleAppIsUnboundByDefaultAndWorksWhenRecorded() {
    #expect(AcceptBindings().toggleCurrentApp == nil)
    var b = AcceptBindings()
    b.toggleCurrentApp = KeyChord(keyCode: 48, modifiers: ChordMatcher.control | ChordMatcher.option)
    #expect(noGhostDecision(b.toggleCurrentApp!, bindings: b) == .shortcut(.toggleCurrentApp))
}

@Test func writeForMeWithGhostVisibleIsNotAnAccept() {
    // Option+Tab accepts the whole suggestion; Shift+Option+Tab writes for me even then.
    let live = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 1_000, tabAllowed: true)
    let decide = { (chord: KeyChord) in
        TapRules.decide(ghostVisible: true, editableFocus: true, chord: chord, snapshot: live,
                        bindings: legacyBindings, now: 1_000, maxAgeTicks: 1_500)
    }
    #expect(decide(.optionTab) == .accept(.full))
    #expect(decide(.optionShiftTab) == .shortcut(.writeForMe))
}

@Test func noGhostTabOptionTabAndEscapePass() {
    // Even if a stale snapshot still claims a ghost, the ghost signal wins.
    let stale = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 1_000, tabAllowed: true)
    #expect(noGhostDecision(.tab, snapshot: stale) == .passThrough)
    #expect(noGhostDecision(.optionTab, snapshot: stale) == .passThrough)
    #expect(noGhostDecision(.escape, snapshot: stale) == .passThrough)
}

@Test func noGhostUnboundControlTabPasses() {
    var bindings = AcceptBindings()
    bindings.forceActivate = nil
    #expect(noGhostDecision(.controlTab, bindings: bindings) == .passThrough)
}

@Test func noGhostShortcutNeedsExactModifiers() {
    let controlShiftTab = KeyChord(keyCode: 48, modifiers: ChordMatcher.control | ChordMatcher.shift)
    #expect(noGhostDecision(controlShiftTab) == .passThrough)
}

@Test func ghostVisibleKeepsAcceptBehaviorAndShortcuts() {
    let live = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 1_000, tabAllowed: true)
    func decide(_ chord: KeyChord) -> InputVerdict {
        TapRules.decide(ghostVisible: true, editableFocus: false, chord: chord, snapshot: live, bindings: legacyBindings, now: 1_000, maxAgeTicks: 1_500)
    }
    #expect(decide(.tab) == .accept(.word))
    #expect(decide(.escape) == .dismiss)
    #expect(decide(.controlTab) == .shortcut(.forceActivate))
}

@Test func noGhostShortcutNeedsEditableFocus() {
    #expect(noGhostDecision(.controlTab, focus: true) == .shortcut(.forceActivate))
    #expect(noGhostDecision(.controlTab, focus: false) == .passThrough)
    #expect(noGhostDecision(.optionShiftTab, focus: false) == .passThrough)
}

@Test func toggleGlobalConsumedWithoutFocus() {
    var b = AcceptBindings()
    b.toggleGlobal = KeyChord(keyCode: 40, modifiers: ChordMatcher.control | ChordMatcher.option)
    #expect(noGhostDecision(b.toggleGlobal!, bindings: b, focus: false) == .shortcut(.toggleGlobal))
}

@Test func tapRunsWhenGhostOrFocusedShortcutsOrToggleGlobal() {
    let none = AcceptBindings(forceActivate: nil, toggleCurrentApp: nil, toggleGlobal: nil, writeForMe: nil, revertFix: nil)
    #expect(!TapRules.tapShouldRun(ghostVisible: false, editableFocus: true, bindings: none))
    #expect(TapRules.tapShouldRun(ghostVisible: true, editableFocus: false, bindings: none))
    #expect(!TapRules.tapShouldRun(ghostVisible: false, editableFocus: false, bindings: AcceptBindings()))
    #expect(TapRules.tapShouldRun(ghostVisible: false, editableFocus: true, bindings: AcceptBindings()))
    var g = none
    g.toggleGlobal = .controlTab
    #expect(TapRules.tapShouldRun(ghostVisible: false, editableFocus: false, bindings: g))
    #expect(TapRules.globalShortcutChords(AcceptBindings()) == [.optionShiftTab])
}

@Test func arbiterReportsBoundShortcutChords() {
    let a = arbiter(nil)
    #expect(a.globalShortcutChords.count == 3)
    a.setBindings(AcceptBindings(forceActivate: nil, toggleCurrentApp: nil, writeForMe: nil, revertFix: nil))
    #expect(a.globalShortcutChords.isEmpty)
}

@Suite struct HoldOnlySnapshotTests {
    private let field = FieldID(pid: 1, elementHash: 1, generation: 1)

    @Test func holdOwnsTabButNotEscapeAndExpiresSooner() {
        let max: UInt64 = 1_500
        let hold = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 0, tabAllowed: true, holdOnly: true)
        let bindings = AcceptBindings()
        #expect(ArbiterRules.decide(chord: .tab, snapshot: hold, bindings: bindings, now: 900, maxAgeTicks: max)
            == .accept(.word))
        #expect(ArbiterRules.decide(chord: .escape, snapshot: hold, bindings: bindings, now: 10, maxAgeTicks: max)
            == .passThrough)
        #expect(ArbiterRules.decide(chord: .tab, snapshot: hold, bindings: bindings, now: 1_100, maxAgeTicks: max)
            == .passThrough)
    }
}

// MARK: Alternative cycling

@Test func optionDownUpCycleOnlyWithLiveGhost() {
    let a = arbiter(snap())
    #expect(a.inputVerdict(for: .optionDown, now: 1_100) == .cycleAlternative(forward: true))
    #expect(a.inputVerdict(for: .optionUp, now: 1_100) == .cycleAlternative(forward: false))
    #expect(a.inputVerdict(for: .optionDown, now: 1_100).consumes)
    #expect(a.verdict(for: .optionDown, now: 1_100) == .passThrough)
    // Stale, no ghost, no snapshot.
    #expect(a.inputVerdict(for: .optionDown, now: 9_000) == .passThrough)
    #expect(arbiter(snap(ghost: false)).inputVerdict(for: .optionDown, now: 1_100) == .passThrough)
    #expect(arbiter(nil).inputVerdict(for: .optionUp, now: 1_100) == .passThrough)
}

@Test func cycleIgnoredDuringHoldOnlySnapshot() {
    let hold = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 1_000, tabAllowed: true, holdOnly: true)
    #expect(arbiter(hold).inputVerdict(for: .optionDown, now: 1_100) == .passThrough)
}

@Test func unboundCycleChordsDoNothing() {
    var b = AcceptBindings()
    b.nextAlternative = nil
    b.previousAlternative = nil
    let a = arbiter(snap(), bindings: b)
    #expect(a.inputVerdict(for: .optionDown, now: 1_100) == .passThrough)
    #expect(a.inputVerdict(for: .optionUp, now: 1_100) == .passThrough)
}

@Test func tapRulesCycleNeedsVisibleGhost() {
    let live = snap()
    let on = TapRules.decide(ghostVisible: true, editableFocus: true, chord: .optionDown, snapshot: live,
                             bindings: legacyBindings, now: 1_000, maxAgeTicks: 1_500)
    #expect(on == .cycleAlternative(forward: true))
    let off = TapRules.decide(ghostVisible: false, editableFocus: true, chord: .optionDown, snapshot: live,
                              bindings: legacyBindings, now: 1_000, maxAgeTicks: 1_500)
    #expect(off == .passThrough)
}

@Test func alternativeKeysConsumedOnlyWhenAlternativesAvailable() {
    func verdict(_ chord: KeyChord, available: Bool) -> InputVerdict {
        let snap = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 1_000, tabAllowed: true,
                                   alternativesAvailable: available)
        return ArbiterRules.decide(chord: chord, snapshot: snap, bindings: legacyBindings, now: 1_000, maxAgeTicks: 1_500)
    }
    #expect(verdict(.optionDown, available: true) == .cycleAlternative(forward: true))
    #expect(verdict(.optionUp, available: true) == .cycleAlternative(forward: false))
    #expect(verdict(.optionDown, available: false) == .passThrough)
    #expect(verdict(.optionUp, available: false) == .passThrough)
    // Accept and Escape are unaffected.
    #expect(verdict(.tab, available: false) == .accept(.word))
    #expect(verdict(.escape, available: false) == .dismiss)
}

@Test func replacementGhostKeepsTabAndEscapeButReleasesAlternativeKeys() {
    let replacement = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 1_000, tabAllowed: true,
                                      alternativesAvailable: false)
    let hold = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 1_000, tabAllowed: true, holdOnly: true)
    func decide(_ chord: KeyChord, _ s: ArbiterSnapshot) -> InputVerdict {
        ArbiterRules.decide(chord: chord, snapshot: s, bindings: legacyBindings, now: 1_000, maxAgeTicks: 1_500)
    }
    #expect(decide(.tab, replacement) == .accept(.word))
    #expect(decide(.escape, replacement) == .dismiss)
    #expect(decide(.optionDown, replacement) == .passThrough)
    // A fast Tab right after a fix is still owned by the hold; Escape and alternatives are not.
    #expect(decide(.tab, hold) == .accept(.word))
    #expect(decide(.escape, hold) == .passThrough)
    #expect(decide(.optionUp, hold) == .passThrough)
}

// MARK: Shell prompt keys

@Test func shellPromptAcceptsWithRightArrowNotTab() {
    func decide(_ chord: KeyChord, shell: Bool, tabAllowed: Bool) -> InputVerdict {
        let snap = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 1_000, tabAllowed: tabAllowed,
                                   shellKeys: shell)
        return ArbiterRules.decide(chord: chord, snapshot: snap, bindings: legacyBindings, now: 1_000, maxAgeTicks: 1_500)
    }
    #expect(decide(.rightArrow, shell: true, tabAllowed: false) == .accept(.word))
    #expect(decide(.optionRight, shell: true, tabAllowed: false) == .accept(.full))
    #expect(decide(.optionTab, shell: true, tabAllowed: false) == .accept(.full))
    #expect(decide(.tab, shell: true, tabAllowed: false) == .passThrough)   // Tab completes in the shell
    // Elsewhere Right arrow just moves the caret.
    #expect(decide(.rightArrow, shell: false, tabAllowed: true) == .passThrough)
    #expect(decide(.optionRight, shell: false, tabAllowed: true) == .passThrough)
}

// MARK: Per-app accept keys

@Test func perAppAcceptKeysReplaceTheShortcuts() {
    func decide(_ chord: KeyChord, word: AcceptKey, full: AcceptKey = .shortcuts, tab: Bool = true) -> InputVerdict {
        let snap = ArbiterSnapshot(field: field, hasGhost: true, publishedAt: 1_000, tabAllowed: tab,
                                   wordKey: word, fullKey: full)
        return ArbiterRules.decide(chord: chord, snapshot: snap, bindings: legacyBindings, now: 1_000, maxAgeTicks: 1_500)
    }
    // Code editors: Right arrow for the next word, Tab stays with the editor, Option+Tab still accepts all.
    #expect(decide(.rightArrow, word: .chord(.rightArrow)) == .accept(.word))
    #expect(decide(.tab, word: .chord(.rightArrow)) == .passThrough)
    #expect(decide(.optionTab, word: .chord(.rightArrow)) == .accept(.full))
    // None: that accept has no key here.
    #expect(decide(.tab, word: .off) == .passThrough)
    #expect(decide(.optionTab, word: .shortcuts, full: .off) == .passThrough)
    let ctrlSpace = KeyChord(keyCode: 49, modifiers: 0x40000)
    #expect(decide(ctrlSpace, word: .shortcuts, full: .chord(ctrlSpace)) == .accept(.full))
    #expect(decide(.tab, word: .shortcuts, full: .chord(ctrlSpace)) == .accept(.word))
    // A recorded plain Tab still goes to an input method that is composing.
    #expect(decide(.tab, word: .chord(.tab), tab: false) == .passThrough)
}
