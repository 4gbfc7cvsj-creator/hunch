import HunchCore
import SwiftUI

/// Settings → Autocorrect: the general switches. Each can be overridden per app, site or category in
/// Apps & Sites → Autocorrect (Chats keep most of the fixes off).
struct AutocorrectPane: View {
    let model: SettingsModel

    private var on: Bool { model.settings.autocorrectEnabled }
    /// Strong's reread changes text by itself, so it needs Apply Corrections Automatically.
    private var automatic: Bool { model.settings.autocorrectFixAutomatically }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: model.bind(\.autocorrectEnabled)) {
                    SettingLabel(AutocorrectCopy.suggestTitle, info: AutocorrectCopy.suggestInfo)
                }
                .searchAnchor("autocorrect.suggest")
                // Everything below only matters while Suggest Corrections is on.
                if on {
                    toggle(AutocorrectCopy.automaticTitle, \.autocorrectFixAutomatically,
                           info: AutocorrectCopy.automaticInfo)
                    .searchAnchor("autocorrect.automatic")
                }
            } header: { Text("Corrections") }

            if on {
                Section {
                    let shown = AutocorrectStrength.allowed(model.settings.autocorrectStrength, automatic: automatic)
                    StopSlider(title: AutocorrectCopy.strengthTitle,
                               detail: shown.summary,
                               count: AutocorrectStrength.allCases.count,
                               index: Binding(
                                   get: { AutocorrectStrength.allCases.firstIndex(of: shown) ?? 1 },
                                   set: { model.set(\.autocorrectStrength,
                                                    to: AutocorrectStrength.allowed(AutocorrectStrength.allCases[$0], automatic: automatic)) }),
                               value: shown.title,
                               tip: automatic ? nil : AttributedString(AutocorrectCopy.strongNeedsAutomatic),
                               maxIndex: AutocorrectStrength.maxIndex(automatic: automatic))
                    .searchAnchor("autocorrect.strength")
                    // The pause only matters for Strong's reread.
                    if shown == .strong {
                        LabeledContent {
                            HStack {
                                Slider(value: model.bind(\.autocorrectRewritePause),
                                       in: HunchSettings.rewritePauseRange, step: 0.1)
                                Text(String(format: "%.1f s", model.settings.autocorrectRewritePause))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        } label: {
                            SettingLabel(AutocorrectCopy.rewritePauseTitle, info: AutocorrectCopy.rewritePauseInfo)
                        }
                        .searchAnchor("autocorrect.rewritePause")
                    }
                } header: { Text("Strength") } footer: {
                    Text("Apps, sites and categories can use their own strength in Apps & Sites \u{2192} Autocorrect. In Dynamic Power Mode\u{2019}s Efficiency state, autocorrect acts like Light.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    toggle(AutocorrectCopy.capitalizationTitle, \.autocorrectCapitalization,
                           info: AutocorrectCopy.capitalizationInfo)
                    .searchAnchor("autocorrect.capitalization")
                    toggle(AutocorrectCopy.punctuationTitle, \.fixPunctuation,
                           info: AutocorrectCopy.punctuationInfo)
                    .searchAnchor("autocorrect.punctuation")
                    toggle(AutocorrectCopy.confusedTitle, \.autocorrectFixConfusedWords,
                           info: AutocorrectCopy.confusedInfo)
                    .searchAnchor("autocorrect.confused")
                    toggle(AutocorrectCopy.shorthandTitle, \.autocorrectLeaveChatShorthand,
                           info: AutocorrectCopy.shorthandInfo)
                    .searchAnchor("autocorrect.shorthand")
                } header: { Text("Customizations") } footer: {
                    Text("Apps, sites and categories can override these switches in Apps & Sites \u{2192} Autocorrect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .searchScrollTarget("autocorrect")
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<HunchSettings, Bool> & Sendable,
                        info: String) -> some View {
        Toggle(isOn: model.bind(keyPath)) { SettingLabel(title, info: info) }
    }
}
