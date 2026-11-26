import AppKit
import HunchCore
import HunchModels
import HunchPolicy
import HunchSettingsStore
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (SwiftUI hosted in AppKit).
///
/// Open-panel safety: a modal `NSOpenPanel` run while focus tracking and the event tap are live
/// can deadlock, so panels opened here are sheets, and `onPanelWillOpen`/`onPanelDidClose`
/// let the owner pause and resume focus tracking around them.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Called just before any open panel is shown (pause focus tracking, `PauseReason.ownPanelOpen`).
    var onPanelWillOpen: () -> Void = {}
    /// Called after the panel closes, whatever the result.
    var onPanelDidClose: () -> Void = {}
    /// Called with the folder the user picked in the Model pane.
    var onFolderPicked: (URL) -> Void = { _ in }
    /// Called with a .gguf picked by "Add a model file…", its category, and whether to copy it into
    /// the models folder (false keeps it where it is).
    var onModelFilePicked: (_ file: URL, _ use: ModelUse, _ copy: Bool) -> Void = { _, _, _ in }

    let settingsModel: SettingsModel
    let modelsPane: ModelsPaneModel
    /// Each model category's endpoint form, shown in the Models pane.
    let endpoints: [ModelUse: EndpointFormModel]
    let screenPane: ScreenPaneModel
    private let appsModel: AppsModel
    /// True while an open panel from `pickFolder()` is on screen; a second request is ignored.
    private(set) var panelOpen = false

    /// - Parameters:
    ///   - store: the settings store.
    ///   - policyStore: user per-app and per-domain patches.
    ///   - resolver: optional; receives `completionsEnabledByDefault` changes.
    ///   - policiesChanged: called after any per-app/domain edit.
    ///   - settingsChanged: called after any settings edit made in this window.
    init(store: any SettingsStoring, policyStore: any AppPolicyStoring,
         places: KnownPlacesStore = KnownPlacesStore(fileURL: nil), resolver: DefaultPolicyResolver? = nil,
         models: ModelsPaneModel = ModelsPaneModel(), learning: LearningPaneModel = LearningPaneModel(),
         policiesChanged: @escaping () -> Void = {},
         settingsChanged: @escaping (HunchSettings) -> Void = { _ in }) {
        let settingsModel = SettingsModel(store: store) { s in
            resolver?.setCompletionsEnabledByDefault(s.completionsEnabledByDefault)
            settingsChanged(s)
        }
        self.settingsModel = settingsModel
        self.modelsPane = models
        self.endpoints = Dictionary(uniqueKeysWithValues: ModelsPane.shownUses.map {
            ($0, EndpointFormModel(settings: settingsModel, use: $0))
        })
        self.screenPane = ScreenPaneModel(settings: settingsModel)
        self.appsModel = AppsModel(store: policyStore, places: places, onChange: policiesChanged,
                                   general: { settingsModel.settings },
                                   saveShapes: { settingsModel.set(\.writeShapes, to: $0) })

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "Hunch Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HunchSettings")
        super.init(window: window)
        window.delegate = self
        if models.chooseFolder == nil {
            models.chooseFolder = { [weak self] in self?.pickFolder() }
        }
        if models.addFile == nil {
            models.addFile = { [weak self] use in self?.pickModelFile(use) }
        }
        appsModel.chooseApps = { [weak self] category in self?.pickApps(into: category) }
        let appsModel = self.appsModel
        window.contentViewController = NSHostingController(rootView: SettingsRoot(
            settings: settingsModel, apps: appsModel, models: models, endpoints: endpoints, screen: screenPane,
            learning: learning))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Selects an app (bundle ID) or website (pattern) on the Apps page (diagnostics).
    /// Picks a place (app, site or category) on the Apps pane.
    func selectPlace(_ key: PolicyKey) {
        appsModel.selection = key
    }

    /// Scrolls to and highlights a search anchor; the pane must already be selected.
    func jump(to anchor: String) {
        SettingsJump.shared.requestedSearch = nil
        SettingsJump.shared.pending = anchor
    }

    /// Types `text` into the sidebar search.
    func search(_ text: String) {
        SettingsJump.shared.requestedSearch = text
    }

    func selectPlace(_ id: String) {
        appsModel.selection = id.contains(".") && !appsModel.apps.contains { $0.bundleID == id }
            ? .domain(pattern: id) : .app(bundleID: id)
    }

    func show() {
        appsModel.reloadApps()
        showWindow(nil)
        // A menu-bar app isn't always granted activation by the cooperative `activate()`, which left
        // the window behind others: ask outright, and bring the window up even if that is refused.
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Opens Settings on the Model pane (the menu's "Download recommended model…").
    func showModelsPane() {
        UserDefaults.standard.set(SettingsPane.model.rawValue, forKey: "settingsPane")
        show()
    }

    /// Opens Settings on the Model pane at Speech to Text (no speech model yet).
    func showSpeechModels() {
        modelsPane.scrollTo = .speechToText
        showModelsPane()
    }

    /// Shows an open panel as a sheet on the settings window, with the pause hooks around it.
    /// Every `onPanelWillOpen` is paired with exactly one `onPanelDidClose`, even if this
    /// controller goes away first; a request while a panel is already open does nothing.
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your .gguf models."
        let picked = onFolderPicked
        run(panel) { urls in if let url = urls.first { picked(url) } }
    }

    /// "Add a model file…": one .gguf, kept where it is or copied into the models folder.
    func pickModelFile(_ use: ModelUse) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.prompt = "Add"
        panel.message = use == .writing ? "Choose a .gguf instruct model to add as a writing model."
            : "Choose a .gguf model to add as a Language Model (instruct models work best)."
        let choice = ModelFileChoice()
        panel.accessoryView = choice.view
        panel.isAccessoryViewDisclosed = true
        let picked = onModelFilePicked
        run(panel) { urls in if let url = urls.first { picked(url, use, choice.copy) } }
    }

    /// Add App…: choose one or more apps to list, put into `category` when given.
    func pickApps(into category: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose apps to add to Hunch's app list."
        let apps = appsModel
        run(panel) { urls in apps.addApps(urls, into: category) }
    }

    private func run(_ panel: NSOpenPanel, onOK: @escaping ([URL]) -> Void) {
        guard !panelOpen else { return }
        // Captured now so the resume and the result are delivered even without `self`.
        let didClose = onPanelDidClose
        panelOpen = true
        onPanelWillOpen()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            self?.panelOpen = false
            didClose()
            if response == .OK, let urls = panel?.urls { onOK(urls) }
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Shows the pane with this raw name ("apps", "model"…); false when there is no such pane.
    /// Writes the same default the sidebar's `@AppStorage` reads, so an open window follows.
    @discardableResult
    func selectPane(_ raw: String) -> Bool {
        // The endpoint settings moved into the Models pane.
        guard let pane = raw == "endpoint" ? .model : SettingsPane(rawValue: raw) else { return false }
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        return true
    }
}

/// The open panel's "Keep it where it is" / "Copy to the models folder" choice.
@MainActor
private final class ModelFileChoice: NSObject {
    let view: NSView
    private let keep = NSButton(radioButtonWithTitle: "Keep it where it is", target: nil, action: nil)
    private let copyButton = NSButton(radioButtonWithTitle: "Copy to the models folder", target: nil, action: nil)

    var copy: Bool { copyButton.state == .on }

    override init() {
        let stack = NSStackView(views: [keep, copyButton])
        stack.orientation = .horizontal
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.setFrameSize(stack.fittingSize)
        view = stack
        super.init()
        keep.state = .on
        // Radio buttons sharing an action form one group.
        for button in [keep, copyButton] {
            button.target = self
            button.action = #selector(changed(_:))
        }
    }

    @objc private func changed(_ sender: NSButton) {}
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, personalization, autocorrect, appearance, shortcuts, apps, model, privacy, about
    var id: String { rawValue }

    /// Old persisted values ("writing", "learning", "context") open Personalization; "endpoint" opens Model.
    init(stored raw: String) {
        switch raw {
        case "writing", "learning", "context": self = .personalization
        case "dictation": self = .general
        case "endpoint": self = .model
        default: self = SettingsPane(rawValue: raw) ?? .general
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .personalization: "Personalization"
        case .autocorrect: "Autocorrect"
        case .shortcuts: "Shortcuts"
        case .apps: "Apps & Sites"
        case .model: "Performance & Models"
        case .privacy: "Privacy & Data"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush.fill"
        case .personalization: "sparkles"
        case .autocorrect: "text.badge.checkmark"
        case .shortcuts: "command"
        case .apps: "square.grid.2x2"
        case .model: "cpu"
        case .privacy: "hand.raised.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: .teal
        case .personalization: .purple
        case .autocorrect: .green
        case .shortcuts: .pink
        case .apps: .orange
        case .model: .indigo
        case .privacy: .blue
        case .about: .gray
        }
    }

    static let groups: [[SettingsPane]] = [
        [.general, .personalization, .autocorrect, .appearance, .shortcuts],
        [.apps, .model, .privacy, .about],
    ]
}

private struct SidebarRow: View {
    let pane: SettingsPane

    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            Image(systemName: pane.symbol)
                .font(.system(size: 12, weight: .medium))
                .imageScale(.small)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .clipped()
                .background(pane.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

private struct SettingsRoot: View {
    let settings: SettingsModel
    let apps: AppsModel
    let models: ModelsPaneModel
    let endpoints: [ModelUse: EndpointFormModel]
    let screen: ScreenPaneModel
    let learning: LearningPaneModel
    @AppStorage("settingsPane") private var selectedRaw = SettingsPane.general.rawValue

    private var current: SettingsPane { SettingsPane(stored: selectedRaw) }

    // MARK: Search

    @State private var query = ""
    @State private var searchFocused = false
    /// The result picked last while searching (kept selected in the list).
    @State private var pickedResult: String?

    private enum SidebarItem: Hashable {
        case pane(SettingsPane)
        case result(String)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var results: [SettingsSearchResult] {
        guard searching else { return [] }
        return SettingsSearchResults.find(
            query, settings: settings.settings, apps: apps,
            paneTitles: Dictionary(uniqueKeysWithValues: SettingsPane.allCases.map { ($0.rawValue, $0.title) }))
    }

    private var listSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                if searching { return pickedResult.map(SidebarItem.result) ?? .pane(current) }
                return .pane(current)
            },
            set: { item in
                switch item {
                case .pane(let pane)?:
                    pickedResult = nil
                    selectedRaw = pane.rawValue
                case .result(let id)?:
                    if let result = results.first(where: { $0.id == id }) { open(result) }
                case nil: break
                }
            })
    }

    /// A link's search text replaces the query (see `SettingsJump.requestedSearch`).
    private func takeRequestedSearch() {
        guard let text = SettingsJump.shared.requestedSearch else { return }
        SettingsJump.shared.requestedSearch = nil
        query = text
    }

    private func open(_ result: SettingsSearchResult) {
        pickedResult = result.id
        let jump = SettingsJump.shared
        switch result.target {
        case .anchor(let anchor):
            selectedRaw = SettingsPane(stored: SettingsSearch.pane(of: anchor)).rawValue
            jump.pending = anchor
        case .place(let key, let anchor):
            selectedRaw = SettingsPane.apps.rawValue
            apps.selection = key
            jump.pending = anchor
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .frame(minWidth: 235)
                .navigationSplitViewColumnWidth(235)
                .toolbar(removing: .sidebarToggle)
                .searchable(text: $query, isPresented: $searchFocused, placement: .sidebar, prompt: "Search")
                .onSubmit(of: .search) { if let first = results.first { open(first) } }
                .onChange(of: query) { pickedResult = nil }
                .onAppear(perform: takeRequestedSearch)
                .onChange(of: SettingsJump.shared.requestedSearch) { takeRequestedSearch() }
                .background {
                    // ⌘F puts the cursor in the search field, as in System Settings.
                    Button("Search Settings") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
        } detail: {
            detail
                .navigationTitle(current.title)
        }
        .frame(minWidth: 800, minHeight: 520)
    }

    @ViewBuilder private var sidebar: some View {
        if searching {
            let found = results
            let byPane = Dictionary(grouping: found, by: \.pane)
            let lowered = query.trimmingCharacters(in: .whitespaces)
            // Panes with a result, or whose own name matches, in sidebar order.
            let panes = SettingsPane.groups.flatMap { $0 }.filter {
                byPane[$0.rawValue] != nil || SettingsSearch.score(lowered, title: $0.title) != nil
            }
            List(selection: listSelection) {
                ForEach(panes) { pane in
                    Section {
                        SidebarRow(pane: pane).tag(SidebarItem.pane(pane))
                        ForEach(byPane[pane.rawValue] ?? []) { result in
                            SettingsSearchResultRow(result: result).tag(SidebarItem.result(result.id))
                        }
                    }
                }
            }
            .overlay {
                if panes.isEmpty { ContentUnavailableView.search(text: lowered) }
            }
        } else {
            List(selection: listSelection) {
                ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { pane in
                            SidebarRow(pane: pane).tag(SidebarItem.pane(pane))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch current {
        case .general: GeneralPane(model: settings)
        case .appearance: AppearancePane(model: settings)
        case .personalization: PersonalizationPane(model: settings, learning: learning, screen: screen)
        case .autocorrect: AutocorrectPane(model: settings)
        case .shortcuts: ShortcutsPane(model: settings)
        case .apps: AppsPane(model: apps)
        case .model: ModelsPane(model: models, endpoints: endpoints, settings: settings)
        case .privacy: PrivacyDataPane(model: settings)
        case .about: AboutPane()
        }
    }
}
