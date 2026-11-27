import HunchCore
import Testing

@Suite struct ShortcutChecksTests {
    @Test func bareTypingKeysAreRejected() {
        #expect(KeyChord(keyCode: 0).typesText)                       // A
        #expect(KeyChord(keyCode: 0, modifiers: 0x20000).typesText)   // ⇧A
        #expect(KeyChord(keyCode: 49).typesText)                      // Space
        #expect(KeyChord(keyCode: 36).typesText)                      // Return
        #expect(KeyChord(keyCode: 18).typesText)                      // 1
    }

    @Test func modifiedOrNonTypingKeysAreAllowed() {
        #expect(!KeyChord.tab.typesText)
        #expect(!KeyChord(keyCode: 48, modifiers: 0x20000).typesText) // ⇧Tab
        #expect(!KeyChord(keyCode: 122).typesText)                    // F1
        #expect(!KeyChord.rightArrow.typesText)
        #expect(!KeyChord(keyCode: 0, modifiers: 0x80000).typesText)  // ⌥A
        #expect(!KeyChord.controlShiftZ.typesText)
    }

    @Test func defaultsHaveNoConflicts() {
        let s = HunchSettings()
        for entry in HunchSettings.namedShortcuts { #expect(s.shortcutConflicts(for: entry.keyPath).isEmpty) }
    }

    @Test func duplicateIsReportedOnBothSides() {
        var s = HunchSettings()
        s.bindings.writeForMe = .optionTab
        #expect(s.shortcutConflicts(for: \.bindings.writeForMe) == ["Accept whole suggestion"])
        #expect(s.shortcutConflicts(for: \.bindings.full) == ["Write for me"])
    }

    @Test func voiceInstructionCountsOnlyWhileOn() {
        var s = HunchSettings()
        s.voiceInstruction.shortcut = .tab
        #expect(s.shortcutConflicts(for: \.bindings.word).isEmpty)
        s.experimentalVoiceInstructions = true
        #expect(s.shortcutConflicts(for: \.bindings.word) == ["Voice instruction"])
    }

    @Test func unsetHasNoConflicts() {
        var s = HunchSettings()
        s.bindings.word = nil
        s.bindings.full = nil
        #expect(s.shortcutConflicts(for: \.bindings.word).isEmpty)
    }
}
