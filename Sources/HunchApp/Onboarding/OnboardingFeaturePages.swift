import AppKit
import HunchCore
import SwiftUI

// MARK: Suggestions

/// A scripted practice box (works before any model is ready) and the accept-next-word shortcut.
struct SuggestionsPage: View {
    let model: OnboardingModel

    private var settings: HunchSettings { model.settings.settings }

    var body: some View {
        VStack(spacing: 18) {
            PageHeader(
                art: .symbol("text.cursor"), title: "Suggestions as you type",
                message: "Press the shortcut to take the next word. Try it below.")
            PracticeField(bindings: settings.bindings, wordOptions: settings.wordUnits)
            TourCard {
                ShortcutRow(title: "Accept next word", chord: model.settings.bind(\.bindings.word))
            }
            Text("More shortcuts, like accepting the whole suggestion, are in Settings \u{2192} Shortcuts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Quick replies

/// The Quick replies switch and layout (the same settings as Settings → General) with a live demo
/// above them that plays in the layout picked.
struct QuickRepliesPage: View {
    let settings: SettingsModel
    /// A fixed demo frame instead of the running loop (snapshots only).
    var frozen: (conversation: Int, phase: QuickRepliesDemo.Phase)?

    private var s: HunchSettings { settings.settings }

    var body: some View {
        VStack(spacing: 12) {
            PageHeader(
                art: .symbol("bubble.left.and.text.bubble.right"), title: "Quick replies",
                message: "In an empty message box, Hunch offers ways to answer the message.")
            QuickRepliesDemoView(layout: s.suggestedRepliesLayout, enabled: s.suggestedRepliesEnabled, frozen: frozen)
            // Fixed height, so the demo above stays put when the rows below come and go.
            VStack(spacing: 8) {
                TourCard {
                    HStack {
                        SettingLabel("Quick replies", info: GeneralPane.quickRepliesInfo)
                        Spacer()
                        Toggle("Quick replies", isOn: settings.bind(\.suggestedRepliesEnabled))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    if s.suggestedRepliesEnabled {
                        Divider().padding(.horizontal, 14)
                        HStack {
                            SettingLabel("Layout", info: GeneralPane.quickRepliesLayoutInfo)
                            Spacer()
                            Picker("Layout", selection: settings.bind(\.suggestedRepliesLayout)) {
                                ForEach(SuggestedRepliesLayout.allCases, id: \.self) { layout in
                                    Text(Self.label(layout)).tag(layout)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 300)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                    }
                }
                if s.suggestedRepliesEnabled, let reason = SuggestedRepliesStatus.shared.blockedReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 112)
            .animation(.easeInOut(duration: 0.2), value: s.suggestedRepliesEnabled)
        }
    }

    static func label(_ layout: SuggestedRepliesLayout) -> String {
        switch layout {
        case .verticalStack: "Stacked"
        case .rowAboveField: "Row above"
        case .inlineAtCaret: "Inline"
        }
    }
}

// MARK: Write for me

struct WriteForMePage: View {
    let settings: SettingsModel

    private static let instruction = "email the team that friday\u{2019}s launch moves to next tuesday, "
        + "ask for updated slides by monday"
    private static let draft = """
        Hi team,

        A quick update: we\u{2019}re moving Friday\u{2019}s launch to next Tuesday to leave time for final \
        testing. Could everyone send me their updated slides by the end of Monday?

        Thanks,
        Alex
        """

    var body: some View {
        VStack(spacing: 14) {
            PageHeader(
                art: .symbol("wand.and.stars"), title: "Write for me",
                message: "Say what you want, or select your own text, then press the shortcut.")
            // The arrow from the instruction to the draft runs through the shortcut that makes it.
            VStack(spacing: 0) {
                ExampleBubble(label: "You type", text: Self.instruction)
                connector(height: 10)
                // Styled like the boxes around it, as wide as the recorder, centered on the arrow.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Then press").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    KeyRecorder(chord: settings.bind(\.bindings.writeForMe)).frame(width: 150, height: 24)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .bubbleBackground()
                connector(height: 8)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .padding(.bottom, 3)
                ExampleBubble(label: "Hunch writes", text: Self.draft, highlighted: true)
            }
        }
    }
}

private func connector(height: CGFloat) -> some View {
    Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1.5, height: height)
}

private struct ExampleBubble: View {
    let label: String
    let text: String
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .bubbleBackground(highlighted: highlighted)
    }
}

private extension View {
    /// The Write for me example boxes' fill and border.
    func bubbleBackground(highlighted: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: 10)
            .fill(highlighted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: Dictation

struct DictationPage: View {
    let model: OnboardingModel

    private var micGranted: Bool { model.permissions.isGranted(.microphone) }

    var body: some View {
        VStack(spacing: 18) {
            PageHeader(
                art: .symbol("waveform"), title: "Dictation",
                message: "Press the shortcut and speak; press it again when you\u{2019}re done, or hold it while you "
                    + "talk. Hunch writes down what you said, tidies it up and puts it at the cursor.")
            TourCard {
                ShortcutRow(title: "Start or stop dictation", chord: model.settings.bind(\.dictation.shortcut))
                Divider().padding(.leading, 14)
                statusRow(
                    done: micGranted, title: "Microphone",
                    detail: micGranted ? "Allowed." : "Needed to hear you. macOS asks once.") {
                    Button("Allow\u{2026}") { model.permissions.request(.microphone) }
                }
                Divider().padding(.leading, 14)
                statusRow(done: speechReady, title: "Speech model", detail: speechDetail) { EmptyView() }
            }
            if DictationPaneState.shared.shortcutRefused {
                Label("macOS or another app already uses this shortcut. Pick another one.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var speechReady: Bool { model.models.effectiveSpeechModel != nil }

    private var speechDetail: String {
        if let id = model.models.effectiveSpeechModel {
            return (model.speechRows.first { $0.id == id }?.name ?? id) + " is ready."
        }
        if let row = model.speechRows.first(where: { $0.id == model.speechPick }),
           case .downloading(let fraction, _) = row.state {
            return "\(row.name) is downloading (\(Int((fraction * 100).rounded()))%)."
        }
        return "None yet. Pick one on the first page or later in Settings \u{2192} Model."
    }

    private func statusRow<Action: View>(done: Bool, title: String, detail: String,
                                         @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16))
                .foregroundStyle(done ? Color.green : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { action() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: Appearance

/// The Appearance pane's preview and effects, as a grid of chips.
struct AppearancePage: View {
    let settings: SettingsModel
    @State private var replay = 0

    private var appearance: AppearanceSettings { settings.settings.appearance }
    private static let effects = AppearancePane.effects.filter { $0 != .custom }

    var body: some View {
        VStack(spacing: 14) {
            PageHeader(
                art: .symbol("sparkles"), title: "Make it yours",
                message: "Pick your vibe.")
            AppearancePreview(appearance: appearance, replay: replay)
                .onTapGesture { replay += 1 }
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Self.effects, id: \.self) { style in chip(style) }
            }
            Picker("Color", selection: settings.bind(\.appearance.color)) {
                Text("Follow effect").tag(SuggestionColorChoice.followEffect)
                Text("Match text").tag(SuggestionColorChoice.matchText)
                Text("Grey").tag(SuggestionColorChoice.grey)
                Text("Accent").tag(SuggestionColorChoice.accent)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            .onChange(of: appearance.color) { replay += 1 }
        }
    }

    private func chip(_ style: PopInAnimation) -> some View {
        let selected = appearance.animation == style
        return Button {
            settings.set(\.appearance.animation, to: style)
            replay += 1
        } label: {
            Text(AppearancePane.name(style))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AppearancePane.blurb(style))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Personalization

struct PersonalizePage: View {
    let settings: SettingsModel

    var body: some View {
        VStack(spacing: 14) {
            PageHeader(
                art: .symbol("person.text.rectangle"), title: "Sound like you",
                message: "Optional: a few lines about you and how you write help suggestions and drafts fit. "
                    + "It stays on this Mac. Leave them empty to skip.")
            field("About me", \.aboutMe, PersonalizationPane.aboutMePlaceholder)
            field("How I write", \.customInstructions, PersonalizationPane.howIWritePlaceholder)
        }
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<HunchSettings, String> & Sendable,
                       _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).padding(.horizontal, 4)
            TextEditor(text: settings.bind(keyPath))
                .settingsTextBox(minHeight: 92)
                .settingsPlaceholder(placeholder, shown: settings.settings[keyPath: keyPath].isEmpty)
                .frame(height: 92)
        }
    }
}

// MARK: Done

struct DonePage: View {
    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 22) {
            PageHeader(
                art: .symbol("checkmark.circle"), title: "You\u{2019}re all set",
                message: "Start typing in any app. Hunch\u{2019}s menu bar icon has a quick on/off switch, and "
                    + "everything here can be changed in Settings.")
            Button("Open Settings") { model.openSettings() }
            if let download = model.downloadSummary, !download.failed {
                Text("Your models keep downloading after you close this window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Autocorrect

/// The Autocorrect switches (the same ones as Settings → Autocorrect) with a live demo above them.
struct AutocorrectPage: View {
    let settings: SettingsModel
    /// A fixed demo frame instead of the running loop (snapshots only).
    var frozen: (sentence: Int, words: Int)?

    private var s: HunchSettings { settings.settings }

    private var switches: AutocorrectDemo.Switches {
        AutocorrectDemo.Switches(
            suggestCorrections: s.autocorrectEnabled, applyAutomatically: s.autocorrectFixAutomatically,
            capitalization: s.autocorrectCapitalization, punctuation: s.fixPunctuation,
            confusedWords: s.autocorrectFixConfusedWords, allowChatShorthand: s.autocorrectLeaveChatShorthand)
    }

    var body: some View {
        VStack(spacing: 14) {
            PageHeader(
                art: .symbol("textformat.abc.dottedunderline"), title: "Autocorrect that gets it",
                message: "It reads the sentence, not just the word. Choose what it fixes.")
            AutocorrectDemoView(switches: switches, frozen: frozen)
            // Fixed height, so the demo above stays put when the rows below come and go.
            VStack(spacing: 0) {
                TourCard {
                    row(AutocorrectCopy.suggestTitle, AutocorrectCopy.suggestInfo, \.autocorrectEnabled)
                    if s.autocorrectEnabled {
                        row(AutocorrectCopy.automaticTitle, AutocorrectCopy.automaticInfo, \.autocorrectFixAutomatically)
                        Divider().padding(.horizontal, 14)
                        row(AutocorrectCopy.capitalizationTitle, AutocorrectCopy.capitalizationInfo, \.autocorrectCapitalization)
                        row(AutocorrectCopy.punctuationTitle, AutocorrectCopy.punctuationInfo, \.fixPunctuation)
                        row(AutocorrectCopy.confusedTitle, AutocorrectCopy.confusedInfo, \.autocorrectFixConfusedWords)
                        row(AutocorrectCopy.shorthandTitle, AutocorrectCopy.shorthandInfo, \.autocorrectLeaveChatShorthand)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 196)
            .animation(.easeInOut(duration: 0.2), value: s.autocorrectEnabled)
        }
    }

    private func row(_ title: String, _ info: String,
                     _ keyPath: WritableKeyPath<HunchSettings, Bool> & Sendable) -> some View {
        HStack {
            SettingLabel(title, info: info)
            Spacer()
            Toggle(title, isOn: settings.bind(keyPath))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}
