import Foundation
import HunchCore
import HunchEndpoint
import HunchModels
import Observation
import SwiftUI

/// One model category's endpoint: its draft configuration (edits stay in the draft until "Save"),
/// whether the category uses it, and its API key. The key goes straight to the Keychain and is
/// never read back into the UI.
@MainActor
@Observable
final class EndpointFormModel {
    let use: ModelUse
    var baseURL = "http://127.0.0.1:11434/v1"
    var modelName = ""
    var api: EndpointAPI
    var keyDraft = ""
    private(set) var hasStoredKey = false
    private(set) var keyMessage: String?
    private(set) var testResult: String?
    private(set) var testing = false
    private(set) var saveMessage: String?
    /// The sheet is open.
    var editing = false
    /// The sheet was opened by picking an endpoint that isn't set up yet: saving also selects it.
    @ObservationIgnored private var selectOnSave = false

    @ObservationIgnored private let settings: SettingsModel
    @ObservationIgnored private let keys = KeychainKeyStore()
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private let engineKey: WritableKeyPath<HunchSettings, EngineKind> & Sendable
    @ObservationIgnored private let configKey: WritableKeyPath<HunchSettings, EndpointConfig?> & Sendable

    init(settings: SettingsModel, use: ModelUse) {
        self.settings = settings
        self.use = use
        switch use {
        case .autocomplete: engineKey = \.engine; configKey = \.endpoint
        case .writing: engineKey = \.writeEngine; configKey = \.writeEndpoint
        case .speechToText: engineKey = \.speechEngine; configKey = \.speechEndpoint
        }
        api = use == .autocomplete ? .completions : .chatCompletions
        if let config = settings.settings[keyPath: configKey] {
            baseURL = config.baseURL.absoluteString
            modelName = config.model
            api = config.api
        }
        hasStoredKey = keys.hasKey(forAccount: keyAccount)
    }

    /// This category's own Keychain account. Autocomplete keeps the original "endpoint".
    var ownAccount: String {
        switch use {
        case .autocomplete: "endpoint"
        case .writing: "endpoint.writing"
        case .speechToText: "endpoint.speech"
        }
    }

    /// The account the saved configuration points at (a migrated copy may share Autocomplete's).
    private var keyAccount: String { saved?.keychainAccount ?? ownAccount }

    /// The sheet's heading.
    var title: String {
        switch use {
        case .autocomplete: "Language Model endpoint"
        case .writing: "Writing endpoint"
        case .speechToText: "Speech to text endpoint"
        }
    }

    var saved: EndpointConfig? { settings.settings[keyPath: configKey] }
    var isSaved: Bool { saved != nil }
    /// The category uses this endpoint.
    var isSelected: Bool { settings.settings[keyPath: engineKey] == .endpoint }

    /// e.g. "llama3 at 127.0.0.1:11434", or "Not set up".
    var summary: String {
        guard let saved else { return "Not set up" }
        let host = saved.baseURL.host.map { h in saved.baseURL.port.map { "\(h):\($0)" } ?? h } ?? saved.baseURL.absoluteString
        return saved.model.isEmpty ? host : "\(saved.model) at \(host)"
    }

    /// Picking the Endpoint row: selects it when saved, otherwise opens the sheet to set it up first.
    func choose() {
        if isSaved {
            settings.set(engineKey, to: .endpoint)
        } else {
            selectOnSave = true
            configure()
        }
    }

    /// Picking one of the category's local models.
    func chooseLocal() {
        if isSelected { settings.set(engineKey, to: .local) }
    }

    func configure() {
        saveMessage = nil
        testResult = nil
        keyMessage = nil
        editing = true
    }

    func close() {
        selectOnSave = false
        testTask?.cancel()
        testing = false
        editing = false
    }

    /// Validation of the draft URL, or nil when it is acceptable.
    var validationProblem: String? {
        do {
            _ = try draftConfig()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func draftConfig() throws -> EndpointConfig {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else { throw EndpointError.invalidURL }
        try EndpointURLPolicy.validate(url)
        return EndpointConfig(baseURL: url, model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                              api: api, allowNonLoopback: false,
                              keychainAccount: hasStoredKey ? keyAccount : nil,
                              timeoutSeconds: saved?.timeoutSeconds ?? 10)
    }

    func save() {
        do {
            let config = try draftConfig()
            settings.set(configKey, to: config)
            if selectOnSave {
                settings.set(engineKey, to: .endpoint)
                selectOnSave = false
            }
            saveMessage = "Saved."
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    func removeEndpoint() {
        // Delete this category's own key too, unless another category's endpoint still uses it
        // (a migrated Writing endpoint can share Autocomplete's).
        let others: [WritableKeyPath<HunchSettings, EndpointConfig?>] = [\.endpoint, \.writeEndpoint, \.speechEndpoint]
        let shared = others.contains { $0 != configKey && settings.settings[keyPath: $0]?.keychainAccount == ownAccount }
        if keyAccount == ownAccount, !shared { _ = keys.deleteAPIKey(forAccount: ownAccount) }
        settings.set(configKey, to: nil)
        hasStoredKey = keys.hasKey(forAccount: ownAccount)
        if isSelected { settings.set(engineKey, to: .local) }
        saveMessage = "Endpoint removed."
    }

    func storeKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        keyDraft = ""
        guard !key.isEmpty else { return }
        if keys.setAPIKey(key, forAccount: ownAccount) {
            hasStoredKey = true
            keyMessage = "Key saved in the Keychain."
            relinkKey(to: ownAccount)
        } else {
            keyMessage = "The Keychain refused to store the key."
        }
    }

    func deleteKey() {
        // A key shared with another category is only unlinked here, never deleted.
        if keyAccount != ownAccount || keys.deleteAPIKey(forAccount: ownAccount) {
            hasStoredKey = false
            keyMessage = "Key deleted."
            relinkKey(to: nil)
        } else {
            keyMessage = "The key could not be deleted."
        }
    }

    /// Keeps the saved configuration's key reference in step with the Keychain.
    private func relinkKey(to account: String?) {
        guard var config = saved else { return }
        config.keychainAccount = account
        settings.set(configKey, to: config)
    }

    /// Runs one tiny completion against the draft configuration.
    func testConnection() {
        testTask?.cancel()
        let config: EndpointConfig
        do {
            config = try draftConfig()
        } catch {
            testResult = error.localizedDescription
            return
        }
        testing = true
        testResult = nil
        testTask = Task { [weak self] in
            let outcome = await Self.probe(config)
            guard let self, !Task.isCancelled else { return }
            self.testing = false
            self.testResult = outcome
        }
    }

    nonisolated private static func probe(_ config: EndpointConfig) async -> String {
        let engine = EndpointCompletionEngine(config: config)
        let app = AppIdentity(bundleID: "local.hunch.connection-test", pid: 0, localizedName: nil)
        let context = TextContext(app: app, field: FieldID(pid: 0, elementHash: 0, generation: 0),
                                  before: "The quick brown fox jumps over the", after: "", contentSignature: 0)
        var decode = DecodeConfig()
        decode.maxWords = 2
        decode.minWords = 1
        let input = PromptInput(before: context.before, maxWords: 2)
        let request = CompletionRequest(id: RequestID(1), context: context, input: input, decode: decode)
        do {
            let result = try await engine.complete(request) { _ in }
            if case .show = result.outcome { return "OK: the endpoint answered with a suggestion." }
            return "OK: the endpoint answered (the reply was filtered out, which is fine for a test)."
        } catch let error as EndpointError {
            return error.errorDescription ?? "The endpoint test failed."
        } catch is CancellationError {
            return "Test cancelled."
        } catch {
            return "The endpoint test failed: \(error.localizedDescription)"
        }
    }
}

/// The "Configure…" sheet for one category's endpoint.
struct EndpointSheet: View {
    @Bindable var model: EndpointFormModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent {
                        TextField("", text: $model.baseURL, prompt: Text("http://127.0.0.1:8080/v1"))
                            .labelsHidden()
                    } label: {
                        SettingLabel("Base URL", info: "Only servers running on this Mac (localhost) are supported.")
                    }
                    TextField("Model name", text: $model.modelName, prompt: Text("as the server lists it"))
                    Picker("API", selection: $model.api) {
                        Text("Text completions (/completions)").tag(EndpointAPI.completions)
                        Text("Chat (/chat/completions)").tag(EndpointAPI.chatCompletions)
                    }
                    if let problem = model.validationProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Save") { model.save() }.disabled(model.validationProblem != nil)
                        Button("Test Connection") { model.testConnection() }
                            .disabled(model.validationProblem != nil || model.testing)
                        if model.testing { ProgressView().controlSize(.small) }
                        Spacer()
                        if model.isSaved { Button("Remove", role: .destructive) { model.removeEndpoint() } }
                    }
                    if let message = model.saveMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if let result = model.testResult { Text(result).font(.caption).textSelection(.enabled) }
                } header: {
                    Text(model.title)
                }
                Section("API key (optional)") {
                    HStack {
                        LabeledContent {
                            SecureField("", text: $model.keyDraft).labelsHidden()
                        } label: {
                            Text(model.hasStoredKey ? "Replace key" : "Key")
                            Text(model.hasStoredKey ? "A key is stored in your Keychain." : "No key stored.")
                        }
                        Button("Store") { model.storeKey() }.disabled(model.keyDraft.isEmpty)
                        if model.hasStoredKey { Button("Delete Key", role: .destructive) { model.deleteKey() } }
                    }
                    if let message = model.keyMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 420)
    }
}
