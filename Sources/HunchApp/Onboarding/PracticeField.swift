import AppKit
import HunchCore
import HunchSession
import SwiftUI

/// The welcome tour's practice box: a fixed sentence with a fixed suggestion, so it works before any
/// model is ready. A key cap under the next word shows the user's accept shortcut; pressing it takes
/// that word in and the cap moves along. After the last word the next example comes up.
struct PracticeField: View {
    let bindings: AcceptBindings
    let wordOptions: WordUnitOptions

    private struct Example {
        let typed: String
        let suggestion: String
    }

    private static let examples = [
        Example(typed: "Thanks for the quick reply! I\u{2019}ll", suggestion: " send the updated slides before our meeting."),
        Example(typed: "Could we move our call to", suggestion: " Thursday afternoon instead?"),
        Example(typed: "The package should arrive", suggestion: " by the end of next week."),
    ]

    @State private var index = 0
    @State private var accepted = ""
    @State private var typedWidth: CGFloat = 0
    @State private var focused = false
    @State private var finished = false

    private var example: Example { Self.examples[index] }
    private var remaining: String { String(example.suggestion.dropFirst(accepted.count)) }
    private var font: Font { .system(size: 16) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            KeyCatcher(focused: $focused, onKey: handle)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text(example.typed + accepted)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { typedWidth = $0 }
                    Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 19)
                        .opacity(focused ? 1 : 0.35)
                    Text(remaining).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 0)
                }
                .font(font)
                .lineLimit(1)
                ZStack(alignment: .leading) {
                    if !remaining.isEmpty {
                        KeyCap(text: chordDescription(bindings.word))
                            .offset(x: typedWidth + 2)
                            .transition(.opacity)
                    } else {
                        Label("Nice. That\u{2019}s all it takes.", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
                .frame(height: 24, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .allowsHitTesting(false)
        }
        .frame(height: 84)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.2), lineWidth: focused ? 2 : 1))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Practice box: \(example.typed + accepted), suggestion \(remaining)")
        .accessibilityHint("Press \(chordDescription(bindings.word)) to accept the next word.")
    }

    /// Returns true when the key was used.
    private func handle(_ chord: KeyChord) -> Bool {
        guard !finished else { return true }
        if chord == bindings.word {
            take(WordUnits.next(in: remaining, options: wordOptions))
            return true
        }
        if chord == bindings.full {
            take(remaining)
            return true
        }
        return false
    }

    private func take(_ unit: String) {
        guard !unit.isEmpty else { return }
        withAnimation(.spring(duration: 0.25)) { accepted += unit }
        guard remaining.isEmpty else { return }
        finished = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeInOut(duration: 0.2)) {
                index = (index + 1) % Self.examples.count
                accepted = ""
                finished = false
            }
        }
    }
}

/// A key cap with the shortcut's symbols.
private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.5)))
    }
}

/// Takes keyboard focus (on appear and on click) and hands each key press over as a `KeyChord`.
private struct KeyCatcher: NSViewRepresentable {
    @Binding var focused: Bool
    let onKey: (KeyChord) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onKey = onKey
        view.onFocus = { focused = $0 }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onKey = onKey
        view.onFocus = { focused = $0 }
    }

    final class CatcherView: NSView {
        var onKey: (KeyChord) -> Bool = { _ in false }
        var onFocus: (Bool) -> Void = { _ in }

        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { onFocus(true); return true }
        override func resignFirstResponder() -> Bool { onFocus(false); return true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
            let chord = KeyChord(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue))
            if !onKey(chord) { super.keyDown(with: event) }
        }
    }
}
