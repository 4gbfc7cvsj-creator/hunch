import Foundation
import HunchCore
import Testing
@testable import HunchInput

private let field = FieldID(pid: 42, elementHash: 7, generation: 1)
private let identity = MachTimebase(numer: 1, denom: 1)

private func verdict(_ chord: KeyChord, next: Bool, previous: Bool, ghost: Bool = true) -> InputVerdict {
    var snapshot = ArbiterSnapshot(field: field, hasGhost: ghost, publishedAt: 1_000, tabAllowed: true)
    snapshot.styleNextAvailable = next
    snapshot.stylePreviousAvailable = previous
    let a = DefaultAcceptanceArbiter(bindings: AcceptBindings(), maxAgeNanoseconds: 1_500, timebase: identity)
    a.publish(snapshot)
    return a.inputVerdict(for: chord, now: 1_100)
}

@Test func styleKeysDefaultToOptionShiftLeftRight() {
    let b = AcceptBindings()
    #expect(b.styleNext == .optionShiftRight)
    #expect(b.stylePrevious == .optionShiftLeft)
    // Plain Option+arrows stay with alternatives.
    #expect(b.nextAlternative == .optionDown)
}

@Test func styleKeysSwitchOnlyWhenAvailable() {
    #expect(verdict(.optionShiftRight, next: true, previous: false) == .switchStyle(forward: true))
    #expect(verdict(.optionShiftLeft, next: true, previous: false) == .passThrough)
    #expect(verdict(.optionShiftLeft, next: false, previous: true) == .switchStyle(forward: false))
    #expect(verdict(.optionShiftRight, next: false, previous: false) == .passThrough)
    // No ghost: the app keeps its selection keys.
    #expect(verdict(.optionShiftRight, next: true, previous: true, ghost: false) == .passThrough)
    // Alternatives are untouched.
    #expect(verdict(.optionDown, next: true, previous: true) == .cycleAlternative(forward: true))
}

@Test func oldSettingsFilesGetTheDefaultStyleKeys() throws {
    let data = Data(#"{"word":{"keyCode":48,"modifiers":0}}"#.utf8)
    let b = try JSONDecoder().decode(AcceptBindings.self, from: data)
    #expect(b.styleNext == .optionShiftRight)
    let cleared = try JSONDecoder().decode(AcceptBindings.self, from: Data(#"{"stylePrevious":null}"#.utf8))
    #expect(cleared.stylePrevious == nil)
}
