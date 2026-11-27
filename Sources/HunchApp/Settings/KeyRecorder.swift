import AppKit
import HunchCore
import SwiftUI

/// Human-readable chord, e.g. "⌥⇧Tab".
func chordDescription(_ chord: KeyChord?) -> String {
    chord?.displayName ?? "Not set"
}

/// Click, then press the shortcut. Esc cancels; Delete clears. A key that types text needs ⌃, ⌥ or ⌘.
final class RecorderButton: NSButton {
    var chord: KeyChord? { didSet { refreshTitle() } }
    /// Shown with no chord set.
    var emptyTitle = "Not set" { didSet { refreshTitle() } }
    var onChange: ((KeyChord?) -> Void)?
    private var recording = false { didSet { hint = nil; refreshTitle() } }
    /// Shown instead of "Press shortcut…" after a key that would swallow typing.
    private var hint: String? { didSet { refreshTitle() } }

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    private func refreshTitle() {
        title = recording ? hint ?? "Press shortcut…" : chord.map(chordDescription) ?? emptyTitle
    }

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
            if new.typesText {  // a bare "A" would swallow every "a": keep recording
                hint = "Add ⌃, ⌥ or ⌘"
                NSSound.beep()
                return
            }
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

/// Orange warning under a shortcut row when another listed shortcut uses the same keys.
struct ShortcutConflictWarning: View {
    let settings: HunchSettings
    let keyPath: KeyPath<HunchSettings, KeyChord?>

    var body: some View {
        let others = settings.shortcutConflicts(for: keyPath)
        if !others.isEmpty {
            Label("\(others.joined(separator: " and ")) also uses this shortcut. Pick another one.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
