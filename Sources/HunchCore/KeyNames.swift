extension KeyChord {
    /// Human-readable chord, e.g. "⌥⇧Tab" or "⌃F5".
    public var displayName: String {
        var out = ""
        if modifiers & 0x40000 != 0 { out += "⌃" }
        if modifiers & 0x80000 != 0 { out += "⌥" }
        if modifiers & 0x20000 != 0 { out += "⇧" }
        if modifiers & 0x100000 != 0 { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    /// Name of a macOS virtual key code (ANSI layout); "Key N" for codes without one.
    public static func keyName(_ code: UInt16) -> String {
        keyNames[code] ?? "Key \(code)"
    }

    private static let keyNames: [UInt16: String] = [
        48: "Tab", 53: "Esc", 49: "Space", 36: "Return", 76: "Enter", 51: "Delete", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
        7: "X", 16: "Y", 6: "Z", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
        25: "9", 29: "0", 50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",",
        47: ".", 44: "/",
        // Function keys: macOS key codes aren't in order.
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]
}
