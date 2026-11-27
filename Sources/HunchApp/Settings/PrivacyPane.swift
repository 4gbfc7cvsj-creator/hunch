import HunchCore
import HunchInput
import HunchModels
import SwiftUI

/// Privacy & Data: permissions, what Hunch can see and keep, and diagnostics.
struct PrivacyDataPane: View {
    let model: SettingsModel
    /// Other apps' key taps and the Secure Input owner; read on appear and on Refresh.
    @State private var keyDiagnostics = KeyDiagnostics.Snapshot()
    @State private var showingLogs = false
    @State private var savedSummary = ""

    var body: some View {
        Form {
            PermissionsSection(settings: model)
            PrivacySection(settings: model)
            Section("Diagnostics") {
                Toggle(isOn: model.bind(\.debugLogging)) {
                    Text("Debug logging")
                    if model.settings.debugLogging {
                        Text(PrivacySummary.debugLoggingDisclaimer)
                    }
                }
                .searchAnchor("privacy.debugLogging")
                LabeledContent {
                    Button("Show\u{2026}") { showingLogs = true }
                } label: {
                    Text("Saved logs")
                    Text(savedSummary)
                }
                .searchAnchor("privacy.savedLogs")
                .onAppear { savedSummary = SavedLogsSheet.summary() }
                LabeledContent {
                    Button("Diagnostic console\u{2026}") { DiagnosticConsoleController.shared.show() }
                } label: {
                    SettingLabel("Diagnostic console", info: "Shows what went into each model request and what came out, live, while its window is open. Kept in memory only and thrown away when you close it; nothing is saved.")
                }
                .searchAnchor("privacy.console")
                DictationDiagnosticsRows(model: model)
                LabeledContent("Apps that intercept keys") {
                    Button("Refresh") { keyDiagnostics = KeyDiagnostics.snapshot() }
                }
                .searchAnchor("privacy.interceptors")
                .onAppear { keyDiagnostics = KeyDiagnostics.snapshot() }
                if keyDiagnostics.rows.isEmpty {
                    Text(DiagnosticsWording.noInterceptors).foregroundStyle(.secondary)
                } else {
                    ForEach(keyDiagnostics.rows) { row in
                        LabeledContent {
                            if let warning = row.warning {
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            Text(row.name)
                            Text(row.caption)
                        }
                    }
                }
                if let secureInput = keyDiagnostics.secureInput {
                    Text(secureInput)
                }
            }
        }
        .formStyle(.grouped)
        .searchScrollTarget("privacy")
        .sheet(isPresented: $showingLogs, onDismiss: { savedSummary = SavedLogsSheet.summary() }) {
            SavedLogsSheet()
        }
    }
}

/// What Hunch can see, what it keeps, and what leaves this Mac, following the current
/// permissions and settings. (A first version; more privacy controls will go here.)
struct PrivacySection: View {
    let settings: SettingsModel
    @State private var permissions = PermissionsModel()

    var body: some View {
        let s = settings.settings
        Section {
            block("What Hunch can see",
                  PermissionsModel.privacyParagraphs(granted: permissions.granted, settings: s)
                      + Self.seeExtras(granted: permissions.granted, settings: s))
            block("What stays on this Mac",
                  PrivacySummary.kept(settings: s, logsSaved: SavedLogs.anySaved()))
            block("What leaves this Mac", Self.leaves(settings: s))
        } header: {
            Text("Privacy").searchAnchor("privacy.privacy")
        }
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private func block(_ title: String, _ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(paragraphs, id: \.self) { Text(SettingsLinks.text($0)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    nonisolated static func seeExtras(granted: [PermissionsModel.Kind: Bool], settings: HunchSettings) -> [String] {
        var out: [String] = []
        if settings.dictation.enabled {
            out.append((granted[.microphone] ?? false)
                ? "Microphone \u{2013} Hunch listens only while you dictate, from the shortcut until you stop. "
                    + "Speech is turned into text on this Mac and the audio isn\u{2019}t saved."
                : "Microphone \u{2013} Not allowed: dictation can\u{2019}t hear you.")
        }
        if settings.clipboardContextEnabled {
            out.append("Clipboard \u{2013} Plain text you copied in the last 5 minutes can inform suggestions. "
                       + "Password-manager copies and secret-looking text are skipped, and nothing is stored.")
        }
        if settings.windowTitleContextEnabled {
            out.append("Window titles \u{2013} The title of the window you\u{2019}re typing in (such as an email "
                       + "subject) is used for suggestions, in memory only.")
        }
        out.append("Password fields and other secure text are never read.")
        return out
    }

    nonisolated static func leaves(settings: HunchSettings) -> [String] {
        var out = ["Nothing you type or say is sent over the internet. Suggestions, Write for me and dictation run "
                   + "on this Mac, and Hunch collects no analytics."]
        if settings.engine == .endpoint || (settings.useWritingModel && settings.writeEngine == .endpoint) {
            out.append("Text is sent to the local server you set up as an endpoint. Only servers on this Mac are allowed.")
        }
        out.append("Hunch connects to \(ModelCatalog.host) only when you download a model or search for one.")
        return out
    }
}
