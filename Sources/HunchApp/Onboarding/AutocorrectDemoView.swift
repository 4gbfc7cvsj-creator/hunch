import HunchCore
import Observation
import SwiftUI

/// The Autocorrect page's demo box: types a few sentences full of slips and shows what autocorrect
/// does to them under the current switches. Looks like `PracticeField` but takes no focus and no
/// clicks. A change of switches restarts the current sentence. With Reduce Motion it shows a static
/// before and after instead.
struct AutocorrectDemoView: View {
    let switches: AutocorrectDemo.Switches
    /// Show a fixed frame (sentence index, words typed so far) instead of running; for snapshots.
    var frozen: (sentence: Int, words: Int)?

    @State private var runner = AutocorrectDemoRunner()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion, frozen == nil { staticBody } else { animatedBody }
        }
        .frame(height: 84)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.2)))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let text = AutocorrectDemo.text(AutocorrectDemo.script[1], switches)
        return switches.suggestCorrections
            ? "Autocorrect demo: \u{201C}\(text.before)\u{201D} becomes \u{201C}\(text.after)\u{201D}."
            : "Autocorrect is off, so \u{201C}\(text.before)\u{201D} stays as typed."
    }

    // MARK: Animated

    private var animatedBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                ForEach(runner.words) { word in
                    DemoWordView(word: word, keyCapPressed: runner.keyPressed)
                }
                Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 19).padding(.leading, 1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 16))
            .lineLimit(1)
            .opacity(switches.suggestCorrections ? 1 : 0.55)
            Group {
                if switches.suggestCorrections {
                    Color.clear
                } else {
                    Label("Autocorrect is off, so everything stays as typed.", systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(height: 24, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: switches) {
            if let frozen {
                runner.freeze(sentence: frozen.sentence, words: frozen.words, switches: switches)
            } else {
                await runner.run(switches)
            }
        }
    }

    // MARK: Reduce Motion

    private var staticBody: some View {
        let text = AutocorrectDemo.text(AutocorrectDemo.script[1], switches)
        return VStack(alignment: .leading, spacing: 6) {
            Text(text.before).font(.system(size: 16))
                .foregroundStyle(switches.suggestCorrections ? .secondary : .primary)
                .lineLimit(1)
            if switches.suggestCorrections {
                Label(text.after, systemImage: "arrow.turn.down.right").font(.system(size: 16)).lineLimit(1)
            } else {
                Label("Autocorrect is off, so everything stays as typed.", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One word of the demo sentence on screen.
struct DemoWord: Identifiable, Equatable {
    enum State: Equatable {
        /// Typed as is (or still being typed).
        case plain
        /// Suggest mode: the typed word struck through, the fix after it, a Tab key cap below.
        case suggesting
        /// The fix is in. `underline`: the faint line that stays for a moment.
        case fixed(underline: Bool)
    }

    let id: Int
    var typed: String
    var fix: String
    var state: State = .plain
    /// The space after the word has been typed.
    var spaced = false
}

private struct DemoWordView: View {
    let word: DemoWord
    let keyCapPressed: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                switch word.state {
                case .plain:
                    Text(word.typed).fixedSize().transition(.opacity)
                case .suggesting:
                    HStack(spacing: 5) {
                        Text(word.typed).strikethrough().foregroundStyle(.secondary).fixedSize()
                        Text(word.fix).foregroundStyle(Color.accentColor).fixedSize()
                    }
                    .transition(.opacity)
                    .overlay(alignment: .bottomLeading) {
                        DemoKeyCap(pressed: keyCapPressed).offset(y: 30).fixedSize()
                    }
                case .fixed(let underline):
                    Text(word.fix).fixedSize()
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.accentColor.opacity(0.45)).frame(height: 1.5)
                                .offset(y: 2).opacity(underline ? 1 : 0)
                        }
                        .transition(.opacity)
                }
            }
            if word.spaced { Text(" ").fixedSize() }
        }
    }
}

/// The Tab key cap, same look as the practice box's.
private struct DemoKeyCap: View {
    let pressed: Bool

    var body: some View {
        Text("Tab \u{21E5}")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(pressed ? 0.3 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.5)))
            .scaleEffect(pressed ? 0.92 : 1)
    }
}

/// Plays the script. Cancelling its task (a change of switches, leaving the page) stops it at once.
@MainActor
@Observable
final class AutocorrectDemoRunner {
    private(set) var words: [DemoWord] = []
    private(set) var keyPressed = false
    @ObservationIgnored private var sentence = 0
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var fades: [Task<Void, Never>] = []

    /// The demo has to look like fast typing: 45 to 80 ms a key, uneven but the same on every loop.
    private static func keyDelay(_ i: Int) -> Duration { .milliseconds(45 + (i * 37) % 36) }

    func run(_ s: AutocorrectDemo.Switches) async {
        fades.forEach { $0.cancel() }
        fades = []
        words = []
        keyPressed = false
        do {
            while true {
                for (i, word) in AutocorrectDemo.script[sentence].enumerated() {
                    try await type(word, id: i, last: i == AutocorrectDemo.script[sentence].count - 1, s)
                }
                try await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeInOut(duration: 0.3)) { words = [] }
                try await Task.sleep(for: .milliseconds(400))
                sentence = (sentence + 1) % AutocorrectDemo.script.count
            }
        } catch {
            fades.forEach { $0.cancel() }
        }
    }

    private func type(_ word: AutocorrectDemo.Word, id: Int, last: Bool, _ s: AutocorrectDemo.Switches) async throws {
        words.append(DemoWord(id: nextID, typed: "", fix: word.fix ?? word.typed))
        nextID += 1
        let slot = words.count - 1
        for (k, ch) in word.typed.enumerated() {
            try await Task.sleep(for: Self.keyDelay(k + id))
            words[slot].typed.append(ch)
        }
        // The space after the word (or the end of the sentence) finishes it.
        try await Task.sleep(for: last ? .milliseconds(250) : Self.keyDelay(id))
        words[slot].spaced = !last
        // Fixes that were waiting for this word (a confused word needs the one after it), then its own.
        let sentence = AutocorrectDemo.script[sentence]
        for j in 0...id where AutocorrectDemo.landingIndex(of: j, in: sentence) == id
            && AutocorrectDemo.resolve(sentence[j], s).changed {
            try await land(slot: j, s)
        }
    }

    private func land(slot: Int, _ s: AutocorrectDemo.Switches) async throws {
        if s.applyAutomatically {
            try await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeInOut(duration: 0.25)) { words[slot].state = .fixed(underline: true) }
            let wordID = words[slot].id
            fades.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled, let self,
                      let at = self.words.firstIndex(where: { $0.id == wordID }) else { return }
                withAnimation(.easeOut(duration: 0.6)) { self.words[at].state = .fixed(underline: false) }
            })
            try await Task.sleep(for: .milliseconds(200))
        } else {
            try await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeInOut(duration: 0.25)) { words[slot].state = .suggesting }
            try await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeOut(duration: 0.1)) { keyPressed = true }
            try await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeInOut(duration: 0.25)) {
                words[slot].state = .fixed(underline: false)
                keyPressed = false
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// One still frame: the first `words` of a sentence, all done, the last one mid-fix.
    func freeze(sentence: Int, words count: Int, switches s: AutocorrectDemo.Switches) {
        let script = AutocorrectDemo.script[sentence]
        words = script.prefix(count).enumerated().map { i, word in
            var shown = DemoWord(id: i, typed: word.typed, fix: word.fix ?? word.typed)
            let r = AutocorrectDemo.resolve(word, s)
            shown.spaced = i < count - 1 || count < script.count
            // A fix lands once its landing word is finished; before that the word is still as typed.
            let landing = AutocorrectDemo.landingIndex(of: i, in: script)
            if r.changed, landing < count {
                shown.state = landing == count - 1 && !s.applyAutomatically ? .suggesting : .fixed(underline: landing >= count - 2)
            }
            return shown
        }
        keyPressed = false
    }
}
