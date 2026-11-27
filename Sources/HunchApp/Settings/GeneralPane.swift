import HunchCore
import HunchEmoji
import HunchInput
import SwiftUI

struct GeneralPane: View {
    let model: SettingsModel
    @State private var macPredictionsOn = MacInlinePredictions.isEnabled

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .searchScrollTarget("general")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            macPredictionsOn = MacInlinePredictions.isEnabled
        }
        .onAppear { macPredictionsOn = MacInlinePredictions.isEnabled }
    }

    @ViewBuilder private var content: some View {
            if macPredictionsOn {
                Section {
                    LabeledContent {
                        Button("Open Keyboard Settings") { MacInlinePredictions.openKeyboardSettings() }
                    } label: {
                        Label("macOS inline predictions are on", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Apple apps like Mail and Notes show their own grey prediction at the cursor, so it can overlap Hunch\u{2019}s. Turn off \u{201C}Show inline predictive text\u{201D} under Keyboard \u{2192} Text Input.")
                    }
                }
            }
            LoginItemSection()
            Section {
                Toggle("Suggestions", isOn: model.bind(\.enabled))
                .searchAnchor("general.suggestions")
                // The rest only matters while suggestions are on.
                if model.settings.enabled {
                    Toggle(isOn: model.bind(\.midLineByDefault)) {
                        SettingLabel("Mid-sentence suggestion", info: "Suggest inside existing text, not just at the end.")
                    }
                    .searchAnchor("general.midSentence")
                    StopSlider(title: "Suggestion length",
                               detail: "\(model.settings.length.minWords)–\(model.settings.length.maxWords) words per suggestion.",
                               count: LengthPreset.allCases.count,
                               index: Binding(
                                   get: { LengthPreset.allCases.firstIndex(of: model.settings.length) ?? 0 },
                                   set: { model.set(\.length, to: LengthPreset.allCases[$0]) }),
                               value: Self.lengthName(model.settings.length))
                    .searchAnchor("general.length")
                    StopSlider(title: "Start suggesting after",
                               detail: "Words typed on the line before suggestions appear.",
                               count: Self.minWordsRange.count,
                               index: Binding(
                                   get: { Self.minWordsIndex(model.settings.minWordsBeforeSuggesting) },
                                   set: { model.set(\.minWordsBeforeSuggesting, to: Self.minWordsRange.lowerBound + $0) }),
                               value: Self.minWordsLabel(model.settings.minWordsBeforeSuggesting),
                               detailAsInfo: true)
                    .searchAnchor("general.startAfter")
                    LabeledContent {
                        HStack {
                            // Evenly spaced stops over uneven values: fine steps under 100 ms (GPU
                            // savings), then 500 ms and 1 s for "only when I stop to think".
                            Slider(value: Binding(
                                get: { Double(Self.pauseStopIndex(model.settings.suggestionPauseMs)) },
                                set: { i in
                                    let stops = HunchSettings.suggestionPauseStops
                                    model.set(\.suggestionPauseMs, to: stops[min(max(Int(i.rounded()), 0), stops.count - 1)])
                                }),
                                   in: 0...Double(HunchSettings.suggestionPauseStops.count - 1), step: 1)
                            Text(Self.pauseLabel(model.settings.suggestionPauseMs))
                                .monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                        .frame(maxWidth: 260)
                    } label: {
                        SettingLabel("Wait for pause",
                                     info: "A short wait skips suggestions for keys typed in quick succession, saving GPU "
                                         + "and battery. A suggestion that still matches what you type stays without waiting.")
                    }
                    .searchAnchor("general.pause")
                    Toggle(isOn: model.bind(\.suggestedRepliesEnabled)) {
                        SettingLabel("Quick replies", info: Self.quickRepliesInfo)
                    }
                    .searchAnchor("general.suggestedReplies")
                    if model.settings.suggestedRepliesEnabled {
                        if let reason = SuggestedRepliesStatus.shared.blockedReason {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        Picker(selection: model.bind(\.suggestedRepliesLayout)) {
                            ForEach(SuggestedRepliesLayout.allCases, id: \.self) { layout in
                                Text(Self.replyLayoutLabel(layout)).tag(layout)
                            }
                        } label: {
                            SettingLabel("Quick replies layout", info: Self.quickRepliesLayoutInfo)
                        }
                        .searchAnchor("general.suggestedRepliesLayout")
                    }
                    Toggle(isOn: model.bind(\.showWhileWriting)) {
                        SettingLabel("Stream suggestions", info: "The first words appear sooner. The finished suggestion can still change or remove them.")
                    }
                    .searchAnchor("general.stream")
                    Picker(selection: model.bind(\.suggestionConfidence)) {
                        ForEach(SuggestionConfidence.allCases, id: \.self) { level in
                            Text(Self.confidenceLabel(level)).tag(level)
                        }
                    } label: {
                        SettingLabel("Suggestion confidence",
                                     info: "How sure the model must be of the next word before a suggestion shows at the "
                                         + "start of a word. Higher hides more unsure guesses; Off shows them all. "
                                         + "Completions of a word you're typing aren't affected.")
                    }
                    .searchAnchor("general.confidence")
                    Toggle("Trailing space", isOn: model.bind(\.wordUnits.includeTrailingSpace))
                    .searchAnchor("general.trailingSpace")
                    Toggle("Include trailing punctuation", isOn: model.bind(\.wordUnits.includeTrailingPunctuation))
                    .searchAnchor("general.trailingPunctuation")
                    Picker("Esc key", selection: model.bind(\.escapeBehavior)) {
                        Text("Dismiss it").tag(EscapeBehavior.dismiss)
                        Text("Dismiss and pause briefly").tag(EscapeBehavior.dismissAndPauseBriefly)
                        Text("Turn off until I switch apps").tag(EscapeBehavior.dismissUntilAppSwitch)
                    }
                    .searchAnchor("general.escape")
                    Toggle(isOn: model.bind(\.emoji.enabled)) {
                        SettingLabel("Emoji suggestions", info: emojiLanguagesNote)
                    }
                    .searchAnchor("general.emoji")
                    Picker("Skin tone", selection: model.bind(\.emoji.skinTone)) {
                        Text("Default (yellow)").tag("none")
                        Text("Light").tag("light")
                        Text("Medium-light").tag("mediumLight")
                        Text("Medium").tag("medium")
                        Text("Medium-dark").tag("mediumDark")
                        Text("Dark").tag("dark")
                    }
                    .searchAnchor("general.skinTone")
                    Toggle("Also offer yellow", isOn: model.bind(\.emoji.includeNeutral))
                    .searchAnchor("general.alsoYellow")
                    Picker("People", selection: model.bind(\.emoji.gender)) {
                        Text("Gender-neutral").tag("neutral")
                        Text("Female").tag("female")
                        Text("Male").tag("male")
                    }
                    .searchAnchor("general.emojiPeople")
                }
            } header: {
                Text("Suggestions")
            } footer: {
                if model.settings.enabled {
                    FooterText("Tips: \(SettingsLinks.md("Apps & Sites", "apps")) can set mid-sentence suggestions and "
                               + "length per app, for example shorter suggestions for chat apps and longer ones for work apps.")
                }
            }
            Section("Dictation") {
                DictationGeneralRows(model: model)
            }
            Section("Experimental") {
                Toggle(isOn: model.bind(\.experimentalVoiceInstructions)) {
                    SettingLabel("Voice instructions for Write for me", info: "Hold or tap the voice instruction shortcut and say what you want: with text selected it is applied to the selection (\u{201C}make this shorter\u{201D}, \u{201C}translate to Chinese\u{201D}); with nothing selected it describes what to write; with Write for me open it refines the draft. What you say is never typed into the text box. Uses dictation's speech model.")
                }
                .searchAnchor("general.voiceInstructions")
                VoiceInstructionShortcutRow(model: model)
            }
            Section {
                Button("Welcome tour") {
                    NotificationCenter.default.post(name: .showWelcomeTour, object: nil)
                }
                .searchAnchor("general.welcomeTour")
            }
    }

    /// Which languages emoji names can be typed in (the macOS emoji picker's names for the
    /// user's macOS languages; changing languages takes effect on the next launch).
    private var emojiLanguagesNote: String {
        let names = ["English"] + EmojiIndex.shared.nameLanguages.compactMap {
            Locale.current.localizedString(forIdentifier: $0)
        }
        let list = ListFormatter.localizedString(byJoining: names)
        return "Names work in \(list), from your macOS languages. A full-width colon (：) works too, so you can search without switching input methods."
    }

    static func lengthName(_ p: LengthPreset) -> String {
        switch p {
        case .short: "Short"
        case .medium: "Medium"
        case .long: "Long"
        case .veryLong: "Very long"
        case .ultra: "Ultra"
        }
    }
}

struct ShortcutsPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                recorder("Accept next word", \.bindings.word)
                .searchAnchor("shortcuts.acceptWord")
                recorder("Accept whole suggestion", \.bindings.full)
                .searchAnchor("shortcuts.acceptAll")
                recorder("Next suggestion style", \.bindings.styleNext)
                .searchAnchor("shortcuts.styleNext")
                recorder("Previous suggestion style", \.bindings.stylePrevious)
                .searchAnchor("shortcuts.stylePrevious")
                recorder("Write for me", \.bindings.writeForMe,
                         info: "Turns the instruction you typed (or the text you selected) into a draft, or polishes it.")
                .searchAnchor("shortcuts.writeForMe")
                DictationShortcutRow(model: model)
                .searchAnchor("shortcuts.dictation")
                VoiceInstructionShortcutRow(model: model)
                .searchAnchor("shortcuts.voiceInstruction")
            } footer: {
                FooterText("Tips: Click a field and press the keys. Delete clears it, Esc cancels. Letters, numbers, Space and Return need ⌃, ⌥ or ⌘.")
            }
        }
        .formStyle(.grouped)
        .searchScrollTarget("shortcuts")
    }

    private func recorder(_ title: String, _ keyPath: WritableKeyPath<HunchSettings, KeyChord?> & Sendable,
                          info: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                KeyRecorder(chord: model.bind(keyPath)).frame(width: 150, height: 24)
            } label: {
                SettingLabel(title, info: info)
            }
            ShortcutConflictWarning(settings: model.settings, keyPath: keyPath)
        }
    }
}

/// A slider with evenly spaced stops, its value on the right, and a title and detail on the left:
/// the look General uses for every scale.
struct StopSlider: View {
    let title: String
    let detail: String
    let count: Int
    @Binding var index: Int
    let value: String
    /// The detail doesn't change with the slider: show it behind an info icon instead.
    var detailAsInfo = false
    /// The highest stop that may be picked (nil: the last); stops above it stay visible but the
    /// slider snaps back to it.
    var maxIndex: Int? = nil

    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: Binding(get: { Double(index) },
                                      set: { index = min(max(Int($0.rounded()), 0), maxIndex ?? count - 1) }),
                       in: 0...Double(count - 1), step: 1)
                Text(value).monospacedDigit().frame(width: 70, alignment: .trailing)
            }
            .frame(maxWidth: 260)
        } label: {
            if detailAsInfo {
                SettingLabel(title, info: detail)
            } else {
                Text(title)
                Text(detail)
            }
        }
    }
}

extension GeneralPane {
    /// "Start suggesting after" goes from 1 to 5 words; older values outside it show at the nearest end.
    static let minWordsRange = 1...5

    static func minWordsIndex(_ words: Int) -> Int {
        min(max(words, minWordsRange.lowerBound), minWordsRange.upperBound) - minWordsRange.lowerBound
    }

    static func wordsLabel(_ n: Int) -> String { n == 1 ? "1 word" : "\(n) words" }

    /// The value shown beside the slider: the stored count, even one below the slider's first stop
    /// (a 0 from a URL command or an older build shows as "0 words", not "1 word").
    static func minWordsLabel(_ stored: Int) -> String {
        stored < minWordsRange.lowerBound ? wordsLabel(max(stored, 0))
            : wordsLabel(minWordsRange.lowerBound + minWordsIndex(stored))
    }

    /// The slider stop closest to a stored value (older values like 150 snap to the nearest).
    static func pauseStopIndex(_ ms: Int) -> Int {
        let stops = HunchSettings.suggestionPauseStops
        return stops.indices.min(by: { abs(stops[$0] - ms) < abs(stops[$1] - ms) }) ?? 0
    }

    /// "Off", then each floor with a typographic minus; the default is marked.
    static func confidenceLabel(_ level: SuggestionConfidence) -> String {
        guard level != .off else { return "Off" }
        let value = level.rawValue.replacingOccurrences(of: "-", with: "−")
        return level == .standard ? "\(value) (default)" : value
    }

    static func pauseLabel(_ ms: Int) -> String {
        ms <= 0 ? "No wait" : ms >= 1000 ? "\(ms / 1000) s" : "\(ms) ms"
    }

    static let quickRepliesInfo = "In an empty text box, a bubble above the cursor offers a few ways to answer "
        + "the message on screen. Tab picks one, Return or a click inserts it (nothing is sent), Esc closes it. "
        + "Needs screen context and an instruct model."
    static let quickRepliesLayoutInfo = "Stacked: one panel above the caret. Row above the box: side-by-side chips "
        + "above the text box. Inline: outlined chips at the caret, inside the box."

    static func replyLayoutLabel(_ layout: SuggestedRepliesLayout) -> String {
        switch layout {
        case .verticalStack: "Stacked above the caret"
        case .rowAboveField: "Row above the box"
        case .inlineAtCaret: "Inline at the caret"
        }
    }

    static func nearest(_ value: Int, in stops: [Int]) -> Int {
        stops.indices.min(by: { abs(stops[$0] - value) < abs(stops[$1] - value) }) ?? 0
    }
}
