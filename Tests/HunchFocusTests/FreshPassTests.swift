import Foundation
import HunchCore
import Testing
@testable import HunchFocus

// `currentPass` must never mint a pass when tracking isn't running or is paused, and must
// return promptly (no AX access is needed to refuse).

@Test func freshPassIsNilWhenNotStarted() async {
    let tracker = AXFocusTracker(secureInput: { SecureInputState(enabled: false) }, globallyEnabled: { true })
    let field = FieldID(pid: 1, elementHash: 1, generation: 1)
    let pass = await tracker.currentPass(for: field, timeout: .milliseconds(100))
    #expect(pass == nil)
}

@Test func freshPassIsNilWhenPaused() async {
    let tracker = AXFocusTracker(secureInput: { SecureInputState(enabled: false) }, globallyEnabled: { true })
    tracker.pause(.ownPanelOpen)
    let pass = await tracker.currentPass(for: FieldID(pid: 1, elementHash: 1, generation: 1))
    #expect(pass == nil)
    tracker.resume(.ownPanelOpen)
}
