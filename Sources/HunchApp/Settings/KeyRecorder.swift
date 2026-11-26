import AppKit
import HunchCore
import SwiftUI

/// Human-readable chord, e.g. "⌥⇧Tab".
func chordDescription(_ chord: KeyChord?) -> String {
    guard let chord else { return "Not set" }
    var out = ""
    if chord.modifiers & 0x40000 != 0 { out += "⌃" }
    if chord.modifiers & 0x80000 != 0 { out += "⌥" }
    if chord.modifiers & 0x20000 != 0 { out += "⇧" }
    if chord.modifiers & 0x100000 != 0 { out += "⌘" }
    return out + keyName(chord.keyCode)
}

private func keyName(_ code: UInt16) -> String {
    let names: [UInt16: String] = [
        48: "Tab", 53: "Esc", 49: "Space", 36: "Return", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
        7: "X", 16: "Y", 6: "Z", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
        25: "9", 29: "0", 50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",",
        47: ".", 44: "/",
    ]
    if let n = names[code] { return n }
    if (122...126).contains(code) || code == 120 || code == 99 { return "F\(code)" }
    return "Key \(code)"
}

/// Click, then press the shortcut. Esc cancels; Delete clears.
final class RecorderButton: NSButton {
    var chord: KeyChord? { didSet { refreshTitle() } }
    /// Shown with no chord set.
    var emptyTitle = "Not set" { didSet { refreshTitle() } }
    var onChange: ((KeyChord?) -> Void)?
    private var recording = false { didSet { refreshTitle() } }

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    private func refreshTitle() { title = recording ? "Press shortcut…" : chord.map(chordDescription) ?? emptyTitle }

    @objc private func begin() {
        recording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let mods = UInt64(event.modifierFlags.intersection([.shift, .control, .option, .command]).rawValue)
        let mask: UInt64 = 0x20000 | 0x40000 | 0x80000 | 0x100000
        if event.keyCode == 53 && mods == 0 { recording = false; return }
        if event.keyCode == 51 && mods == 0 {
            chord = nil
            onChange?(nil)
        } else {
            let new = KeyChord(keyCode: event.keyCode, modifiers: mods & mask)
            chord = new
            onChange?(new)
        }
        recording = false
    }
}

struct KeyRecorder: NSViewRepresentable {
    @Binding var chord: KeyChord?
    var emptyTitle = "Not set"

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton(frame: .zero)
        b.emptyTitle = emptyTitle
        b.chord = chord
        b.onChange = { new in chord = new }
        return b
    }

    func updateNSView(_ b: RecorderButton, context: Context) {
        b.emptyTitle = emptyTitle
        b.chord = chord
        b.onChange = { new in chord = new }
    }
}
