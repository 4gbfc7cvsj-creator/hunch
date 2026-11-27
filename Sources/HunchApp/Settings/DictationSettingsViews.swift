import AppKit
import HunchCore
import Observation
import SwiftUI

// Dictation is part of Hunch like autocomplete: its settings sit in General, Shortcuts,
// Personalization and Model rather than a pane of their own.

/// What dictation's settings show that isn't a setting.
@MainActor
@Observable
final class DictationPaneState {
    static let shared = DictationPaneState()
    /// The system refused the shortcut (another app holds those keys).
    var shortcutRefused = false
    /// EXPERIMENTAL: why the voice instruction shortcut isn't registered, if it isn't.
    var voiceShortcutProblem: String?
    /// Fixes learned from the user correcting dictated text, as the store has them.
    private(set) var fixes: [DictationFix] = []
    private(set) var store: DictationFixStore?

    func attach(_ store: DictationFixStore) {
        self.store = store
        fixes = store.fixes
        store.onChange = { [weak self, weak store] in self?.fixes = store?.fixes ?? [] }
    }
}

/// General → Dictation: dictation on or off, and (only while on) its cleanup.
struct DictationGeneralRows: View {
    let model: SettingsModel

    var body: some View {
        Toggle(isOn: model.bind(\.dictation.enabled)) {
            SettingLabel("Dictation", info: "Press the dictation shortcut (\(SettingsLinks.md("Shortcuts", "shortcuts.dictation"))) and speak; the text goes in where you\u{2019}re typing. "
                 + "Tap to start and again to stop, or hold while you speak. Esc cancels.")
        }
        .searchAnchor("general.dictation")
        if model.settings.dictation.enabled {
            Toggle(isOn: model.bind(\.dictation.cleanupEnabled)) {
                SettingLabel("AI cleanup", info: "Removes filler and false starts, applies corrections like \u{201C}no wait\u{201D}, adds punctuation, "
                     + "and fits the text to the app: email, chat or an AI prompt.")
            }
            .searchAnchor("general.cleanupOn")
            StopSlider(title: "Cleanup", detail: presetHelp, count: DictationPreset.allCases.count,
                       index: Binding(
                           get: { DictationPreset.allCases.firstIndex(of: model.settings.dictation.preset) ?? 1 },
                           set: { model.set(\.dictation.preset, to: DictationPreset.allCases[$0]) }),
                       value: presetName)
            .searchAnchor("general.cleanupLevel")
            .disabled(!model.settings.dictation.cleanupEnabled)
            Toggle(isOn: model.bind(\.dictation.boostAfterDictation)) {
                SettingLabel("Offer Polish", info: "For a few seconds after the text goes in, the pill shows a blue ghost with sparkles. Click it, or press "
                     + "the \(SettingsLinks.md("Write for me shortcut", "shortcuts.writeForMe")), to polish the paragraphs you dictated into.")
            }
            .searchAnchor("general.offerPolish")
        }
    }

    private var presetName: String {
        switch model.settings.dictation.preset {
        case .light: "Light"
        case .standard: "Standard"
        case .polished: "Polished"
        }
    }

    private var presetHelp: String {
        switch model.settings.dictation.preset {
        case .light: "Adds punctuation and capitals and removes filler words. Your wording stays as you said it."
        case .standard: "Adds punctuation, removes filler, and fixes grammar and run-on sentences."
        case .polished: "Fixes punctuation, filler and grammar, and smooths clumsy phrasing while keeping your meaning and voice."
        }
    }
}

/// Shortcuts: the dictation shortcut, with a warning when the system refused it.
struct DictationShortcutRow: View {
    let model: SettingsModel
    private let state = DictationPaneState.shared

    var body: some View {
        LabeledContent("Dictation") {
            KeyRecorder(chord: model.bind(\.dictation.shortcut)).frame(width: 150, height: 24)
        }
        ShortcutConflictWarning(settings: model.settings, keyPath: \.dictation.shortcut)
        if state.shortcutRefused {
            Label("macOS or another app already uses the dictation shortcut. Pick another one.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

/// EXPERIMENTAL: the voice instruction shortcut, shown while the feature is on.
struct VoiceInstructionShortcutRow: View {
    let model: SettingsModel
    private let state = DictationPaneState.shared

    var body: some View {
        if model.settings.experimentalVoiceInstructions {
            LabeledContent("Voice instruction (experimental)") {
                KeyRecorder(chord: model.bind(\.voiceInstruction.shortcut)).frame(width: 150, height: 24)
            }
            ShortcutConflictWarning(settings: model.settings, keyPath: \.voiceInstruction.shortcut)
            if let problem = state.voiceShortcutProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// Personalization: learning from dictation fixes, then TESTING (remove when the defaults are decided,
/// see TODO.md): one switch per context source the cleanup gets.
struct DictationContextSection: View {
    let model: SettingsModel

    var body: some View {
        Section {
            Toggle(isOn: model.bind(\.dictation.learnFromFixes)) {
                SettingLabel("Learn from fixes", info: "When you correct a word Hunch dictated, it fixes that mishearing in later dictations, and with \(SettingsLinks.md("Learn words and phrases", "personalization.learnWords")) on, adds the word to your learned words. Never in code editors or apps where learning is off.")
            }
            .searchAnchor("personalization.learnFromFixes")
            toggle("Learned words", "Your learned and added words, as spellings for Whisper and the cleanup.",
                   \.dictation.context.learnedWords)
            toggle("Window title names", "Names and terms from the email subject or document name.",
                   \.dictation.context.titleNames)
            toggle("Names on screen", "Names and terms from the text on screen. Needs \(SettingsLinks.md("Screen Awareness", "personalization.screenAwareness")) on.",
                   \.dictation.context.screenNames)
            toggle("Text before cursor", "So the cleanup fits the sentence it continues.",
                   \.dictation.context.textBefore)
            toggle("App & field type", "Chat, email, code\u{2026}, and the app's name.", \.dictation.context.appType)
            toggle("Languages", "Your languages, and Traditional characters when that's what you type.",
                   \.dictation.context.languages)
            toggle("About me", "A trimmed About me (only with \u{201C}\(SettingsLinks.md("Personal info", "personalization.personalInfo"))\u{201D} on).",
                   \.dictation.context.aboutMe)
        } header: {
            SettingLabel("Dictation Cleanup Context",
                         info: "For testing: turn sources on or off to compare quality and speed.")
                .searchAnchor("personalization.dictationContext")
        } footer: {
            FooterText("Tips: Timings and the log are in "
                       + SettingsLinks.md("Privacy & Data \u{2192} Diagnostics", "privacy.debugLogging") + ".")
        }
    }

    private func toggle(_ title: String, _ detail: String, _ keyPath: WritableKeyPath<HunchSettings, Bool> & Sendable)
        -> some View {
        Toggle(isOn: model.bind(keyPath)) {
            SettingLabel(title, info: detail)
        }
    }
}

/// Privacy & Data → Diagnostics: TESTING (remove later, see TODO.md): dictation timings. (The
/// dictation log follows Debug logging and is in Saved logs.)
struct DictationDiagnosticsRows: View {
    let model: SettingsModel

    var body: some View {
        Toggle("Show timings after each dictation", isOn: model.bind(\.dictation.showTimings))
        .searchAnchor("privacy.dictationTimings")
    }
}

/// The learned-words sheet: fixes learned from dictation. Heard → written (editable), on/off, how
/// often, when, delete.
struct DictationFixesEditor: View {
    private let state = DictationPaneState.shared
    @State private var confirmDeleteAll = false

    private var shown: [DictationFix] { state.fixes.sorted { $0.lastFixed > $1.lastFixed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(shown) {
                TableColumn("On") { fix in
                    Toggle("", isOn: Binding(get: { fix.enabled }, set: { on in
                        var changed = fix
                        changed.enabled = on
                        state.store?.update(changed)
                    }))
                    .labelsHidden().toggleStyle(.checkbox)
                }.width(30)
                TableColumn("Heard") { fix in Text(fix.heard).foregroundStyle(.secondary) }
                TableColumn("Written") { fix in WrittenCell(fix: fix, store: state.store) }
                TableColumn("Fixed") { fix in Text(fix.count == 1 ? "once" : "\(fix.count)×") }.width(50)
                TableColumn("Last fixed") { fix in
                    Text(fix.lastFixed, format: .relative(presentation: .named))
                }.width(110)
                TableColumn("") { fix in
                    Button(role: .destructive) { state.store?.remove(id: fix.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }.width(30)
            }
            .frame(height: 200)
            HStack {
                Button("Delete All\u{2026}", role: .destructive) { confirmDeleteAll = true }
                    .disabled(state.fixes.isEmpty)
                    .confirmationDialog("Delete all learned dictation fixes?", isPresented: $confirmDeleteAll) {
                        Button("Delete All", role: .destructive) { state.store?.removeAll() }
                    } message: {
                        Text("The words stay in Learned words. This can't be undone.")
                    }
            }
            Text("When you correct a word Hunch dictated, the mishearing is fixed in later dictations. Turn a fix "
                 + "off to keep it without using it; edit what's written by clicking it. The right word is also in "
                 + "Learned words.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// An editable "written" cell; saves on Return.
private struct WrittenCell: View {
    let fix: DictationFix
    let store: DictationFixStore?
    @State private var written = ""

    var body: some View {
        TextField("Written", text: $written)
            .textFieldStyle(.plain)
            .onSubmit(save)
            .onAppear { written = fix.written }
            .onChange(of: fix.written) { _, new in written = new }
    }

    private func save() {
        let text = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != fix.written else { written = fix.written; return }
        var changed = fix
        changed.written = text
        store?.update(changed)
    }
}
