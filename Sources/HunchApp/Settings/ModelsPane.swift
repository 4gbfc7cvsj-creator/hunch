import HunchCore
import HunchModels
import Observation
import SwiftUI

/// A model file in the folder.
struct ModelRow: Identifiable, Equatable {
    var id: ModelEntryID
    var name: String
    var detail: String
    var usable: Bool
    /// The kind it is (`.writing` = instruct, `.autocomplete` = base). Both sections list instruct models;
    /// a base one shows under Language Model only when added by the user or selected.
    var use: ModelUse
    /// The catalog's pick for this Mac in its category.
    var isRecommended: Bool
    /// The folder of a file added from outside the models folder (it then has "Remove from list").
    var location: String?
    /// Added by hand or from Hugging Face search (not just found in the folder).
    var addedByUser: Bool
    /// File size; the lists are sorted by it.
    var byteSize: Int64
    init(id: ModelEntryID, name: String, detail: String = "", usable: Bool = true, use: ModelUse = .autocomplete,
         isRecommended: Bool = false, location: String? = nil, addedByUser: Bool = false, byteSize: Int64 = 0) {
        self.id = id
        self.byteSize = byteSize
        self.addedByUser = addedByUser
        self.location = location
        self.name = name
        self.detail = detail
        self.usable = usable
        self.use = use
        self.isRecommended = isRecommended
    }
}

/// One catalog model in the Models pane.
struct CatalogRow: Identifiable, Equatable {
    enum State: Equatable {
        case available
        /// `text` is "x of y GB · n MB/s".
        case downloading(fraction: Double, text: String)
        case downloaded
        /// One line, shown in red with Retry.
        case failed(String)
    }
    /// The catalog file name.
    var id: String
    var name: String
    /// Parameters and quantization, e.g. "E4B · Q5_K_M".
    var detail: String
    /// e.g. "5.8 GB".
    var size: String
    /// Why it's recommended (empty for the other models).
    var reason: String
    var warnings: [String]
    var state: State
    /// File size; the lists are sorted by it.
    var byteSize: Int64 = 0
    /// The catalog's pick for this Mac in its category.
    var isRecommended = false
}

/// One line of a category's list: a model in the folder or a catalog model to download.
enum ModelListItem: Identifiable {
    case file(ModelRow)
    case catalog(CatalogRow)

    var id: String {
        switch self {
        case .file(let row): "file:" + row.id.relativePath
        case .catalog(let row): "catalog:" + row.id
        }
    }

    var byteSize: Int64 {
        switch self {
        case .file(let row): row.byteSize
        case .catalog(let row): row.byteSize
        }
    }

    /// Folder files and catalog models in one list, smallest first, so a selected, downloaded or
    /// added model keeps its place by size. Equal sizes keep folder files first, then by name.
    static func sorted(files: [ModelRow], catalog: [CatalogRow]) -> [ModelListItem] {
        let items = files.map(ModelListItem.file) + catalog.map(ModelListItem.catalog)
        return items.enumerated().sorted { a, b in
            a.element.byteSize != b.element.byteSize ? a.element.byteSize < b.element.byteSize : a.offset < b.offset
        }.map(\.element)
    }
}

/// State and actions for the Models pane. Track C's folder manager feeds the properties and
/// provides `selectModel`/`rescan`; the window controller supplies `chooseFolder` (open panel with hooks)
/// unless the owner already set one.
@MainActor
@Observable
final class ModelsPaneModel {
    var folderPath: String?
    var folderStateText: String
    var rows: [ModelRow]
    /// The Language Model.
    var selected: ModelEntryID?
    /// The model Write for me uses.
    var writeSelected: ModelEntryID?
    @ObservationIgnored var chooseFolder: (() -> Void)?
    /// "Add a model file…" for a category (the window controller's open panel unless set).
    @ObservationIgnored var addFile: ((ModelUse) -> Void)?
    /// Takes an added file off the list (by its path or ID); the file itself stays.
    @ObservationIgnored var removeAdded: (ModelEntryID) -> Void = { _ in }
    /// A copy into the models folder in progress or its failure, shown under the folder.
    var addMessage: String?
    @ObservationIgnored var selectModel: (ModelEntryID) -> Void
    @ObservationIgnored var selectWriteModel: (ModelEntryID) -> Void = { _ in }
    /// Write for me uses the writing model chosen here; off, it uses the Language Model.
    var useWritingModel = false
    /// The Language Model is a local base model: Write for me can't use it well.
    var languageModelIsBase = false
    /// A section to scroll to when the pane shows (set by "Set a separate writing model").
    var scrollTo: ModelUse?
    @ObservationIgnored var setUseWritingModel: (Bool) -> Void = { _ in }
    @ObservationIgnored var rescan: () -> Void
    /// Each category's catalog models, its recommendation for this Mac first (static data).
    var catalog: [ModelUse: [CatalogRow]] = [:]
    /// False while no models folder is available to download into.
    var canDownload = false
    /// Starts (or resumes) downloading a catalog file name. Only ever called from a button.
    @ObservationIgnored var download: (String) -> Void = { _ in }
    @ObservationIgnored var cancelDownload: (String) -> Void = { _ in }
    /// Running or failed downloads by file name, catalog or Hugging Face picks.
    var downloadStates: [String: CatalogRow.State] = [:]
    /// Starts (or resumes) downloading a file picked in Hugging Face search, for this category.
    @ObservationIgnored var downloadPicked: (_ repo: String, HFFile, ModelUse) -> Void = { _, _, _ in }
    /// A models folder has been chosen (it may since have gone missing); `folderStateText` then
    /// describes it rather than asking for one.
    var folderConfigured = false
    /// Dictation's chosen whisper model (file name); nil uses the best one downloaded.
    var speechSelected: String?
    @ObservationIgnored var selectSpeechModel: (String) -> Void = { _ in }

    // Dynamic Power Mode (set by the app delegate).
    /// It picks the Language Model now (on, and the Language Model runs locally).
    var dynamicLanguageActive = false
    /// The Language Model it picked, and the speech model (nil while off).
    var dynamicLanguageModel: ModelEntryID?
    var dynamicSpeechModel: String?
    /// Language Models it can use (the dropdowns' choices).
    var dynamicLanguageOptions: [ModelEntryID] = []
    /// The Efficiency models in effect (the chosen one, or the smallest).
    var dynamicLanguageEfficiency: ModelEntryID?
    var dynamicSpeechEfficiency: String?
    /// Why it is in Efficiency ("battery 18%"); nil in Performance.
    var dynamicReason: String?

    /// The whisper model dictation will use: the chosen one if it's downloaded, else the best
    /// downloaded one (Turbo first), else none.
    var effectiveSpeechModel: String? {
        let downloaded = Set((catalog[.speechToText] ?? []).filter { $0.state == .downloaded }.map(\.id))
        if let chosen = speechSelected, downloaded.contains(chosen) { return chosen }
        let preference = ["ggml-large-v3-turbo.bin", "ggml-large-v3.bin", "ggml-medium.bin", "ggml-small.bin",
                          "ggml-base.bin", "ggml-tiny.bin"]
        return preference.first(where: downloaded.contains)
    }

    init(folderPath: String? = nil, folderStateText: String = "No folder chosen", rows: [ModelRow] = [],
         selected: ModelEntryID? = nil, chooseFolder: (() -> Void)? = nil,
         selectModel: @escaping (ModelEntryID) -> Void = { _ in }, rescan: @escaping () -> Void = {}) {
        self.folderPath = folderPath
        self.folderStateText = folderStateText
        self.rows = rows
        self.selected = selected
        self.chooseFolder = chooseFolder
        self.selectModel = selectModel
        self.rescan = rescan
    }
}

struct ModelsPane: View {
    @Bindable var model: ModelsPaneModel
    /// Each category's endpoint, listed as one more choice next to its local models.
    let endpoints: [ModelUse: EndpointFormModel]
    /// For Dynamic Power Mode's switch, signals and thresholds.
    let settings: SettingsModel
    /// The category whose Hugging Face search sheet is open.
    @State private var searching: HuggingFaceSearchModel?

    /// Categories shown, in order.
    static let shownUses: [ModelUse] = [.autocomplete, .speechToText, .writing]

    /// The section's settings-search anchor ("model.autocomplete"…).
    static func anchor(_ use: ModelUse) -> String { "model.\(use.rawValue)" }

    static func title(_ use: ModelUse) -> String {
        switch use {
        case .autocomplete: "Language Model"
        case .writing: "Writing Model"
        case .speechToText: "Speech to Text"
        }
    }

    static func explanation(_ use: ModelUse) -> String {
        switch use {
        case .autocomplete: "Instruct models for suggestions as you type and for Write for me."
        case .writing: "Optional: a different instruct model just for Write for me (drafts and polish)."
        case .speechToText: "Whisper models for dictation. They run on this Mac."
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear { scroll(proxy) }
                .onChange(of: model.scrollTo) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let use = model.scrollTo else { return }
        withAnimation { proxy.scrollTo(Self.anchor(use), anchor: .top) }
        model.scrollTo = nil
    }

    private var form: some View {
        Form {
            DynamicPowerSection(model: model, settings: settings)
            ForEach(Self.shownUses, id: \.self) { use in
                categorySection(use, isLast: use == Self.shownUses.last)
            }
            Section("Models folder") {
                LabeledContent {
                    Text(model.folderPath ?? "None").textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                } label: {
                    Text("Location")
                    Text(model.folderStateText)
                }
                .searchAnchor("model.folder")
                HStack {
                    Button("Choose Folder…") { model.chooseFolder?() }
                    Button("Rescan") { model.rescan() }
                }
                if let message = model.addMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .searchScrollTarget("model")
        .sheet(item: $searching) { search in
            HuggingFaceSheet(search: search, model: model)
        }
    }

    /// The category's models in the folder (pick one), then its catalog models not downloaded yet.
    @ViewBuilder
    private func categorySection(_ use: ModelUse, isLast: Bool) -> some View {
        if use == .speechToText {
            Section {
                // Dynamic Power Mode picks the speech model: the list is hidden (its pickers are above).
                if model.dynamicSpeechModel != nil {
                    DynamicChoosingNote()
                } else {
                    SpeechModelRows(model: model)
                }
            } header: {
                SettingLabel(Self.title(use), info: model.dynamicSpeechModel == nil ? Self.explanation(use) : nil)
                    .searchAnchor(Self.anchor(use))
            } footer: {
                if isLast {
                    Text("Models download from \(ModelCatalog.host), only when you press Download.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            languageModelSection(use, isLast: isLast)
        }
    }

    @ViewBuilder
    private func languageModelSection(_ use: ModelUse, isLast: Bool) -> some View {
        let endpoint = endpoints[use]
        // A local model is checked only while the category doesn't use its endpoint.
        let selected = endpoint?.isSelected == true ? nil : (use == .writing ? model.writeSelected : model.selected)
        // Both list instruct models; a base model shows under Language Model only when the user added
        // it or it is the current choice.
        let files = model.rows.filter {
            $0.use == .writing || (use == .autocomplete && ($0.addedByUser || $0.id == model.selected))
        }
        let toDownload = (model.catalog[use] ?? []).filter { $0.state != .downloaded }
        // Dynamic Power Mode picking the Language Model, or the separate writing model switched off:
        // the list is hidden.
        let dynamic = use == .autocomplete && model.dynamicLanguageActive
        let off = use == .writing && !model.useWritingModel
        Section {
            if use == .writing {
                Toggle(isOn: Binding(get: { model.useWritingModel },
                                     set: { model.useWritingModel = $0; model.setUseWritingModel($0) })) {
                    SettingLabel("Separate writing model", info: "Off: Write for me uses the Language Model, already loaded for suggestions.")
                }
                if off && model.languageModelIsBase {
                    Label("Your Language Model is a base model. Base models aren't trained to follow instructions, "
                          + "so drafts will be rougher and may ignore what you asked. Turn this on and pick an "
                          + "instruct model for Write for me.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if dynamic {
                DynamicChoosingNote()
            } else if !off {
                if files.isEmpty && toDownload.isEmpty && endpoint == nil {
                    Text("No models yet.").foregroundStyle(.secondary)
                }
                ForEach(ModelListItem.sorted(files: files, catalog: toDownload)) { item in
                    switch item {
                    case .file(let row): fileRow(row, use: use, endpoint: endpoint, selected: selected)
                    case .catalog(let row): CatalogRowView(row: row, model: model)
                    }
                }
                // The endpoint is always last, just above the buttons that add models.
                if let endpoint {
                    EndpointRow(endpoint: endpoint)
                }
                HStack {
                    Button("Search Hugging Face…") { searching = HuggingFaceSearchModel(use: use) }
                    Button("Add a model file…") { model.addFile?(use) }.disabled(!model.canDownload)
                }
            }
        } header: {
            SettingLabel(Self.title(use), info: dynamic ? nil : Self.explanation(use))
                .searchAnchor(Self.anchor(use))
        } footer: {
            if isLast {
                Text("Models download from \(ModelCatalog.host), only when you press Download.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A model in the folder: pick it, or take an added file off the list.
    private func fileRow(_ row: ModelRow, use: ModelUse, endpoint: EndpointFormModel?, selected: ModelEntryID?)
        -> some View {
        HStack {
            Button {
                guard row.usable else { return }
                endpoint?.chooseLocal()
                if use == .writing {
                    model.writeSelected = row.id
                    model.selectWriteModel(row.id)
                } else {
                    model.selected = row.id
                    model.selectModel(row.id)
                }
            } label: {
                HStack {
                    Image(systemName: selected == row.id ? "checkmark.circle.fill" : "circle")
                    VStack(alignment: .leading) {
                        HStack(spacing: 6) {
                            Text(row.name)
                            if row.isRecommended { RecommendedBadge() }
                        }
                        if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary) }
                        if let location = row.location {
                            Text(location).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(row.usable ? 1 : 0.5)
            // Added from outside the folder: it can be taken off the list (the file stays).
            if row.location != nil {
                Button("Remove from list") { model.removeAdded(row.id) }
            }
        }
    }
}

/// "Endpoint": a server on this Mac, picked like a local model, with "Configure…" for its sheet.
private struct EndpointRow: View {
    @Bindable var endpoint: EndpointFormModel

    var body: some View {
        HStack {
            Button {
                endpoint.choose()
            } label: {
                HStack {
                    Image(systemName: endpoint.isSelected ? "checkmark.circle.fill" : "circle")
                    VStack(alignment: .leading) {
                        Text("Endpoint")
                        Text(endpoint.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Configure…") { endpoint.configure() }
        }
        .sheet(isPresented: $endpoint.editing, onDismiss: { endpoint.close() }) {
            EndpointSheet(model: endpoint)
        }
    }
}

/// "Recommended for this Mac", next to the category's pick.
struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended for this Mac")
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }
}

/// A catalog model not in the folder yet: name and size, with details and warnings for the
/// recommendation, and its Download / progress / failure state.
struct CatalogRowView: View {
    let row: CatalogRow
    let model: ModelsPaneModel
    /// Details and warnings show for the recommendation only.
    private var showsDetails: Bool { row.isRecommended }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name)
                        if row.isRecommended { RecommendedBadge() }
                    }
                    Text(showsDetails ? "\(row.detail) · \(row.size)" : row.size)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch row.state {
                case .available:
                    Button("Download") { model.download(row.id) }.disabled(!model.canDownload)
                case .downloaded:
                    Text("Downloaded ✓").foregroundStyle(.secondary)
                case .downloading, .failed:
                    EmptyView()
                }
            }
            if showsDetails {
                if !row.reason.isEmpty { Text(row.reason).font(.caption) }
                ForEach(row.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                }
            }
            switch row.state {
            case .downloading(let fraction, let text):
                ProgressView(value: fraction)
                HStack {
                    Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelDownload(row.id) }
                }
            case .failed(let message):
                HStack {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Button("Retry") { model.download(row.id) }.disabled(!model.canDownload)
                }
            case .available, .downloaded:
                EmptyView()
            }
        }
    }
}

/// The whisper models: downloaded ones to pick from, the rest to download. Shared by Settings →
/// Models.
struct SpeechModelRows: View {
    @Bindable var model: ModelsPaneModel

    var body: some View {
        let rows = model.catalog[.speechToText] ?? []
        let selected = model.effectiveSpeechModel
        if !model.canDownload {
            Text("Choose a models folder (Settings → Performance & Models) to download a speech model into.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(rows.sorted { $0.byteSize < $1.byteSize }) { row in
            if row.state == .downloaded {
                Button {
                    model.speechSelected = row.id
                    model.selectSpeechModel(row.id)
                } label: {
                    HStack {
                        Image(systemName: selected == row.id ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            HStack(spacing: 6) {
                                Text(row.name)
                                if row.isRecommended { RecommendedBadge() }
                            }
                            Text("\(row.detail) · \(row.size)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                CatalogRowView(row: row, model: model)
            }
        }
    }
}
