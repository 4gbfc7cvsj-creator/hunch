import HunchCore
import Testing

@Suite struct KeyNamesTests {
    @Test func functionKeysUseTheirOwnNumbers() {
        let expected: [(UInt16, String)] = [
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"), (98, "F7"),
            (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
        ]
        for (code, name) in expected { #expect(KeyChord.keyName(code) == name) }
    }

    @Test func arrowsAreNotFunctionKeys() {
        #expect(KeyChord.keyName(123) == "←")
        #expect(KeyChord.keyName(126) == "↑")
    }

    @Test func unknownCodeFallsBack() {
        #expect(KeyChord.keyName(200) == "Key 200")
    }

    @Test func modifiersInMacOrder() {
        #expect(KeyChord.optionShiftTab.displayName == "⌥⇧Tab")
        #expect(KeyChord(keyCode: 96, modifiers: 0x40000 | 0x100000).displayName == "⌃⌘F5")
        #expect(KeyChord.controlShiftZ.displayName == "⌃⇧Z")
    }
}
