import AppKit
import HunchCore
import HunchSettingsStore
import HunchFocus
import HunchPolicy
import HunchPrompt
import Observation
import SwiftUI

/// A row in the Apps list.
struct AppEntry: Identifiable, Hashable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var installedURL: URL?
    var running: Bool
}

@MainActor
@Observable
final class AppsModel {
    private(set) var patches: [PolicyKey: AppPolicyPatch]
    private(set) var apps: [AppEntry] = []
    private(set) var sites: [PolicyKey] = []
    var selection: PolicyKey?
    /// The open "new category" / "rename category" prompt.
    var naming: CategoryNaming?
    /// Shows the open panel for adding apps, put into the given category (set by the window controller).
    @ObservationIgnored var chooseApps: (_ category: String?) -> Void = { _ in }
    @ObservationIgnored private let store: any AppPolicyStoring
    @ObservationIgnored private let places: KnownPlacesStore
    @ObservationIgnored private let onChange: () -> Void
    /// The general settings, for what a per-app "Default" comes to (read from the observable
    /// settings model, so labels follow changes made in other panes).
    @ObservationIgnored private let general: () -> HunchSettings
    /// Saves the "Write for me" shape library into the general settings.
    @ObservationIgnored private let saveShapes: (WriteShapeLibrary) -> Void
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    enum CategoryNaming: Identifiable {
        /// A new category with this place in it.
        case new(PolicyKey)
        /// A new, empty category (+ under Categories).
        case create
        case rename(String)
        var id: String {
            switch self {
            case .new(let key): "new:\(key)"
            case .create: "create"
            case .rename(let old): "rename:" + old
            }
        }
    }

    init(store: any AppPolicyStoring, places: KnownPlacesStore, onChange: @escaping () -> Void = {},
         general: @escaping () -> HunchSettings,
         saveShapes: @escaping (WriteShapeLibrary) -> Void = { _ in }) {
        self.general = general
        self.saveShapes = saveShapes
        self.store = store
        self.places = places
        self.patches = store.userPatches
        self.onChange = onChange
        places.adopt(patches.keys.filter(\.isPlace))
        reloadApps()
        observer = NotificationCenter.default.addObserver(forName: KnownPlacesStore.didChange, object: places,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadApps() }
        }
    }

    /// Rebuilds both lists from the saved places (apps and sites stay listed until removed).
    func reloadApps() {
        patches = store.userPatches
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var appRows: [AppEntry] = []
        var siteRows: [PolicyKey] = []
        for place in places.places {
            switch place.key {
            case .app(let id):
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                    ?? place.name ?? id
                appRows.append(AppEntry(bundleID: id, name: name, installedURL: url, running: running.contains(id)))
            case .domain:
                siteRows.append(place.key)
            case .category:
                continue
            }
        }
        apps = appRows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sites = siteRows.sorted { title($0) < title($1) }
    }

    func title(_ key: PolicyKey) -> String {
        switch key {
        case .app(let id): apps.first { $0.bundleID == id }?.name ?? id
        case .domain(let pattern): pattern
        case .category(let name): name
        }
    }

    func seed(for key: PolicyKey) -> AppPolicyPatch? { Seeds.table[key] }

    /// The general settings now (the editor hides what the general switches make moot).
    var generalSettings: HunchSettings { general() }

    /// What "Default" comes to for an app (built-in rule, then its category) or a category (the
    /// general settings); nil for a site, which follows whichever browser it is opened in.
    func inherited(_ key: PolicyKey) -> InheritedPolicy? {
        switch key {
        case .app(let id): InheritedPolicy(bundleID: id, settings: general(), category: categoryPatch(for: key))
        case .domain: nil
        case .category: InheritedPolicy(bundleID: nil, settings: general())
        }
    }

    /// Settings → Appearance, which an own look starts from.
    var mainAppearance: AppearanceSettings { general().appearance }

    /// For a site in a category: what Default comes to from the category alone (the browser's
    /// settings aren't known here). Nil otherwise.
    func siteCategoryInherited(_ key: PolicyKey) -> InheritedPolicy? {
        guard case .domain = key, let cat = categoryPatch(for: key) else { return nil }
        return InheritedPolicy(bundleID: nil, settings: general(), category: cat)
    }

    /// A place's own choices, or a category's settings (saved, else its preset).
    func patch(_ key: PolicyKey) -> AppPolicyPatch {
        if case .category(let name) = key {
            return CategoryPresets.patch(named: name, in: patches) ?? AppPolicyPatch()
        }
        return patches[key] ?? AppPolicyPatch()
    }

    /// The Shortcuts pane's keys, which a per-app accept key follows by default.
    var shortcutBindings: AcceptBindings { general().bindings }

    func edit(_ key: PolicyKey, _ change: (inout AppPolicyPatch) -> Void) {
        var p = patch(key)
        change(&p)
        if case .category(let name) = key {
            // A category stays saved even with every setting on Default (that is how it exists);
            // a preset equal to its built-in settings is simply not saved.
            let saved = CategoryPresets.savedKey(named: name, in: patches) ?? .category(name: name)
            let isPresetValue = CategoryPresets.preset(named: name) == p
            do { try store.setPatch(isPresetValue ? nil : p, for: saved) } catch { return }
        } else {
            let stored: AppPolicyPatch? = p == AppPolicyPatch() ? nil : p
            do { try store.setPatch(stored, for: key) } catch { return }
        }
        patches = store.userPatches
        onChange()
    }

    // MARK: Write for me shapes

    /// Saved custom shapes and preset edits, shared by every app and site.
    var shapes: WriteShapeLibrary { general().writeShapes }

    func editShapes(_ change: (inout WriteShapeLibrary) -> Void) {
        var library = shapes
        change(&library)
        guard library != shapes else { return }
        saveShapes(library)
    }

    /// The preset's wording now: the user's edit, or the built-in text.
    func presetText(_ shape: WriteShape) -> String {
        shapes.editedText(shape) ?? WriteForMeFramer.builtInShapeText(shape) ?? ""
    }

    /// Saves an edit to a preset's wording; text equal to the built-in one clears the edit.
    func setPresetText(_ shape: WriteShape, _ text: String) {
        editShapes { $0.presetTexts[shape.rawValue] = text == WriteForMeFramer.builtInShapeText(shape) ? nil : text }
    }

    /// Saves a new custom shape and uses it here.
    func newCustomShape(startingFrom text: String, for key: PolicyKey) {
        let shape = CustomWriteShape(name: shapes.nextCustomName(), text: text)
        editShapes { $0.custom.append(shape) }
        edit(key) { $0.writeShape = nil; $0.writeCustomShapeID = shape.id }
    }

    func updateCustomShape(_ id: UUID, _ change: (inout CustomWriteShape) -> Void) {
        editShapes { lib in
            guard let i = lib.custom.firstIndex(where: { $0.id == id }) else { return }
            change(&lib.custom[i])
        }
    }

    /// Apps and sites set to this custom shape, by name.
    func places(using id: UUID) -> [String] {
        patches.filter { $0.value.writeCustomShapeID == id }.map { title($0.key) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Deletes a custom shape; the apps and sites that used it go back to Default.
    func deleteCustomShape(_ id: UUID) {
        for (key, p) in patches where p.writeCustomShapeID == id {
            edit(key) { $0.writeCustomShapeID = nil }
        }
        editShapes { $0.custom.removeAll { $0.id == id } }
    }

    // MARK: Add and remove

    /// Add App…, with the apps picked in the open panel; put into `category` when given.
    func addApps(_ urls: [URL], into category: String? = nil) {
        var last: PolicyKey?
        for url in urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            places.add(.app(bundleID: id), name: name)
            last = .app(bundleID: id)
            if let category { setCategory(category, for: .app(bundleID: id)) }
        }
        reloadApps()
        if let last { selection = last }
    }

    /// Add Website…: a host ("example.com") or subdomain pattern ("*.example.com"); put into
    /// `category` when given.
    @discardableResult
    func addSite(_ raw: String, into category: String? = nil) -> Bool {
        guard let final = KnownPlacesStore.siteKey(fromInput: raw) else { return false }
        places.add(final)
        if let category { setCategory(category, for: final) }
        reloadApps()
        selection = final
        return true
    }

    /// "−": forgets the place's settings and category and unlists it. What was learned there is kept.
    func remove(_ key: PolicyKey) {
        try? store.setPatch(nil, for: key)
        places.remove(key)
        if selection == key { selection = nil }
        reloadApps()
        onChange()
    }

    /// Resets behavior to built-in; the category (or explicit None) is kept (it isn't a behavior).
    func removeAll(_ key: PolicyKey) {
        if case .category(let name) = key {
            if isPreset(name) { restorePreset(name) } else { edit(key) { $0 = AppPolicyPatch() } }
            return
        }
        var kept: AppPolicyPatch?
        if let c = patches[key]?.appCategory { kept = AppPolicyPatch(); kept?.appCategory = c }
        try? store.setPatch(kept, for: key)
        patches = store.userPatches
        onChange()
    }

    /// Whether the user changed any behavior (anything besides the category).
    /// True when this place or category sets anything itself (a category's built-in preset counts).
    func hasPatch(_ key: PolicyKey) -> Bool {
        if case .category = key { return patch(key) != AppPolicyPatch() }
        return patches[key] != nil
    }

    func hasBehavior(_ key: PolicyKey) -> Bool {
        if case .category(let name) = key {
            return isPreset(name) ? isEdited(name) : patch(key) != AppPolicyPatch()
        }
        guard let p = patches[key] else { return false }
        return p.behavior != AppPolicyPatch()
    }

    // MARK: Categories

    /// The user's choices plus the built-in automatic ones.
    var categories: AppCategories { AppCategories(patches: patches) }

    /// Presets first, then the user's own categories.
    var categoryNames: [String] { CategoryPresets.allNames(patches, used: categories.names) }

    /// The category a place is in (chosen or automatic); nil for None and for a category.
    func category(_ key: PolicyKey) -> String? {
        let name: String? = switch key {
        case .app(let id): categories.category(ofApp: id)
        case .domain(let pattern): categories.category(ofSite: pattern)
        case .category: nil
        }
        // Show the name as the category list spells it.
        return name.map { n in categoryNames.first { AppCategories.same($0, n) } ?? n }
    }

    /// The built-in category for a well-known app or site, whatever the user picked.
    func automaticCategory(_ key: PolicyKey) -> String? {
        let auto = AppCategories(automatic: .builtIn)
        return switch key {
        case .app(let id): auto.category(ofApp: id)
        case .domain(let pattern): auto.category(ofSite: pattern)
        case .category: nil
        }
    }

    /// Back to the automatic category (forgets the user's pick, including None).
    func useAutomaticCategory(for key: PolicyKey) {
        edit(key) { $0.appCategory = nil }
    }

    /// In a category only because Hunch knows the app or site (the user hasn't picked one).
    func isAutomatic(_ key: PolicyKey) -> Bool { category(key) != nil && !categories.isExplicit(key) }

    /// The settings of the category a place is in.
    func categoryPatch(for key: PolicyKey) -> AppPolicyPatch? {
        category(key).flatMap { CategoryPresets.patch(named: $0, in: patches)?.behavior }
    }

    /// nil = None (saved as an explicit choice, so no automatic category applies).
    func setCategory(_ name: String?, for key: PolicyKey) {
        edit(key) { $0.appCategory = AppCategories.clean(name) ?? "" }
    }

    func isPreset(_ name: String) -> Bool { CategoryNames.preset(name) != nil }

    /// A preset whose settings the user changed.
    func isEdited(_ name: String) -> Bool { CategoryPresets.savedKey(named: name, in: patches) != nil }

    func restorePreset(_ name: String) {
        guard isPreset(name), let saved = CategoryPresets.savedKey(named: name, in: patches) else { return }
        try? store.setPatch(nil, for: saved)
        patches = store.userPatches
        onChange()
    }

    /// Apps and websites in a category (chosen or automatic), listed ones only.
    func members(of name: String) -> [PolicyKey] {
        (apps.map { PolicyKey.app(bundleID: $0.bundleID) } + sites).filter {
            category($0).map { AppCategories.same($0, name) } ?? false
        }
    }

    /// A new, empty category (+ under Categories). False when the name is taken.
    @discardableResult
    func createCategory(_ name: String) -> Bool {
        guard let name = AppCategories.clean(name),
              !categoryNames.contains(where: { AppCategories.same($0, name) }) else { return false }
        try? store.setPatch(AppPolicyPatch(), for: .category(name: name))
        patches = store.userPatches
        selection = .category(name: name)
        onChange()
        return true
    }

    /// Deletes a user category: its settings go and its members move to None.
    func deleteCategory(_ name: String) {
        guard !isPreset(name) else { return }
        for (key, p) in patches where key.isPlace && p.appCategory.map({ AppCategories.same($0, name) }) == true {
            edit(key) { $0.appCategory = "" }
        }
        if let saved = CategoryPresets.savedKey(named: name, in: patches) { try? store.setPatch(nil, for: saved) }
        patches = store.userPatches
        if case .category(let n)? = selection, AppCategories.same(n, name) { selection = nil }
        onChange()
    }

    /// Renames a user category: its settings and every app and site in it. Presets keep their names.
    func renameCategory(_ old: String, to new: String) {
        guard !isPreset(old), let new = AppCategories.clean(new) else { return }
        guard AppCategories.same(old, new) || !categoryNames.contains(where: { AppCategories.same($0, new) }) else { return }
        if let saved = CategoryPresets.savedKey(named: old, in: patches) {
            let settings = patches[saved]
            try? store.setPatch(nil, for: saved)
            try? store.setPatch(settings, for: .category(name: new))
            patches = store.userPatches
        }
        for (key, p) in patches where key.isPlace && p.appCategory.map({ AppCategories.same($0, old) }) == true {
            edit(key) { $0.appCategory = new }
        }
        if case .category(let n)? = selection, AppCategories.same(n, old) { selection = .category(name: new) }
        onChange()
    }
}

// MARK: - Views

struct AppsPane: View {
    @Bindable var model: AppsModel
    @State private var search = ""
    /// The category a website being added goes into; .some(nil) = no category. nil = sheet closed.
    @State private var addingSite: String?? = nil
    @State private var newSite = ""
    @State private var siteError = false
    @State private var confirmRemove: PolicyKey?
    @State private var nameText = ""
    @State private var nameTaken = false
    /// Closed groups ("cat:Work", "none", "sites:cat:Work", …), one per line. Groups start open.
    @AppStorage("appsClosedGroups") private var closedRaw = ""

    /// A category (nil = No category) with its listed apps and websites.
    private struct PlaceGroup: Identifiable {
        let category: String?
        var apps: [PolicyKey]
        var sites: [PolicyKey]
        var id: String { category.map { "cat:" + $0 } ?? "none" }
        var isEmpty: Bool { apps.isEmpty && sites.isEmpty }
    }

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private func matches(_ key: PolicyKey) -> Bool {
        if model.title(key).localizedCaseInsensitiveContains(search) { return true }
        if case .app(let id) = key { return id.localizedCaseInsensitiveContains(search) }
        return false
    }

    /// Categories in list order, then No category. While searching, only groups with a match
    /// (a matching category name shows all of it).
    private var groups: [PlaceGroup] {
        let appKeys = model.apps.map { PolicyKey.app(bundleID: $0.bundleID) }
        var byCategory: [String: PlaceGroup] = [:]
        var none = PlaceGroup(category: nil, apps: [], sites: [])
        let names = model.categoryNames
        func file(_ key: PolicyKey, site: Bool) {
            if let c = model.category(key), let name = names.first(where: { AppCategories.same($0, c) }) {
                var g = byCategory[name] ?? PlaceGroup(category: name, apps: [], sites: [])
                if site { g.sites.append(key) } else { g.apps.append(key) }
                byCategory[name] = g
            } else {
                if site { none.sites.append(key) } else { none.apps.append(key) }
            }
        }
        appKeys.forEach { file($0, site: false) }
        model.sites.forEach { file($0, site: true) }
        var result = names.map { byCategory[$0] ?? PlaceGroup(category: $0, apps: [], sites: []) } + [none]
        if searching {
            result = result.compactMap { g in
                if let c = g.category, c.localizedCaseInsensitiveContains(search) { return g }
                let filtered = PlaceGroup(category: g.category, apps: g.apps.filter(matches), sites: g.sites.filter(matches))
                return filtered.isEmpty ? nil : filtered
            }
        }
        return result
    }

    private var closed: Set<String> { Set(closedRaw.split(separator: "\n").map(String.init)) }

    /// Open/closed state of a group; while searching every group is open.
    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { searching || !closed.contains(id) },
                set: { open in
                    guard !searching else { return }
                    var set = closed
                    if open { set.remove(id) } else { set.insert(id) }
                    closedRaw = set.sorted().joined(separator: "\n")
                })
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search apps, websites, categories", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(selection: $model.selection) {
                    ForEach(groups) { group in groupView(group) }
                }
                .listStyle(.inset)
                .overlay {
                    if searching && groups.isEmpty {
                        Text("No matches.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Divider()
                bottomBar
            }
            .frame(minWidth: 270, idealWidth: 320, maxWidth: 420)

            Group {
                if let key = model.selection {
                    PatchEditor(model: model, key: key).id(key)
                } else {
                    ContentUnavailableView("Pick a category, app or website", systemImage: "app.dashed")
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reloadApps(); reveal(model.selection) }
        .onChange(of: model.selection) { _, key in reveal(key) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmRemove != nil },
                                                              set: { if !$0 { confirmRemove = nil } })) {
            Button(isCategory(confirmRemove) ? "Delete" : "Remove", role: .destructive) {
                if case .category(let name)? = confirmRemove { model.deleteCategory(name) }
                else if let key = confirmRemove { model.remove(key) }
                confirmRemove = nil
            }
        } message: {
            if isCategory(confirmRemove) {
                Text("Its settings are deleted and its apps and websites move to No category. What Hunch learned there is kept.")
            } else {
                Text("Its settings and category are removed and it won\u{2019}t be added automatically again; use + to add it back. What Hunch learned there is kept.")
            }
        }
        .sheet(item: $model.naming) { mode in namingSheet(mode) }
        .sheet(isPresented: Binding(get: { addingSite != nil }, set: { if !$0 { addingSite = nil } })) {
            addSiteSheet
        }
    }

    // MARK: Groups

    /// Rows are drawn flat with their own arrows (List's built-in disclosure keeps its own
    /// open/closed state and doesn't reliably follow a saved one).
    @ViewBuilder private func groupView(_ group: PlaceGroup) -> some View {
        let open = expanded(group.id)
        groupHeader(group, open: open)
            .listRowSeparator(.hidden)
            // A grey box behind each header, shaped like the selection highlight.
            .listRowBackground(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.45))
                .padding(.horizontal, 10))
        if open.wrappedValue {
            ForEach(group.apps, id: \.self) { placeRow($0, indent: 1) }
            if !group.sites.isEmpty {
                let sitesOpen = expanded("sites:" + group.id)
                HStack(spacing: 6) {
                    disclosure(sitesOpen)
                    Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16, height: 16)
                    Text("Websites")
                    Spacer(minLength: 8)
                    Text("\(group.sites.count)").font(.callout).foregroundStyle(.tertiary).monospacedDigit()
                }
                .padding(.leading, Self.indent)
                .contentShape(Rectangle())
                .onTapGesture { sitesOpen.wrappedValue.toggle() }
                .listRowSeparator(.hidden)
                if sitesOpen.wrappedValue {
                    ForEach(group.sites, id: \.self) { placeRow($0, indent: 2) }
                }
            }
            if group.isEmpty {
                Text("No apps or websites").font(.callout).foregroundStyle(.tertiary)
                    .padding(.leading, Self.indent + 22)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private static let indent: CGFloat = 18

    private func disclosure(_ open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                .frame(width: 14, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func groupHeader(_ group: PlaceGroup, open: Binding<Bool>) -> some View {
        if let name = group.category {
            HStack(spacing: 6) {
                disclosure(open)
                CategoryRow(model: model, key: .category(name: name))
            }
            .tag(PolicyKey.category(name: name))
            .contextMenu { groupMenu(name) }
            .help("Click to edit \(name)\u{2019}s settings. Apps and websites in it follow them and share what Hunch learned there.")
        } else {
            HStack(spacing: 6) {
                disclosure(open)
                Image(systemName: "tray").foregroundStyle(.secondary).frame(width: 16, height: 16)
                Text("No category").fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                let count = group.apps.count + group.sites.count
                Text(count == 0 ? "empty" : "\(count)").font(.callout).foregroundStyle(.tertiary).monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture { open.wrappedValue.toggle() }
            .contextMenu { groupMenu(nil) }
        }
    }

    /// Opens the groups holding the selected app or website (e.g. when picked from a link).
    private func reveal(_ key: PolicyKey?) {
        guard let key, key.isPlace else { return }
        let group = model.category(key).map { "cat:" + $0 } ?? "none"
        var ids = [group]
        if case .domain = key { ids.append("sites:" + group) }
        let set = closed.subtracting(ids)
        if set != closed { closedRaw = set.sorted().joined(separator: "\n") }
    }

    @ViewBuilder private func groupMenu(_ name: String?) -> some View {
        Button("Add App\u{2026}") { model.chooseApps(name) }
        Button("Add Website\u{2026}") { startAddingSite(into: name) }
        if let name, !model.isPreset(name) {
            Divider()
            Button("Rename\u{2026}") { model.naming = .rename(name) }
            Button("Delete\u{2026}", role: .destructive) { confirmRemove = .category(name: name) }
        }
    }

    private func placeRow(_ key: PolicyKey, indent: Int) -> some View {
        PlaceRow(model: model, key: key, selected: model.selection == key)
            .padding(.leading, CGFloat(indent) * Self.indent + 20)
            .tag(key)
            .listRowSeparator(.hidden)
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Add App\u{2026}") { model.chooseApps(selectedCategory) }
                Button("Add Website\u{2026}") { startAddingSite(into: selectedCategory) }
                Divider()
                Button("New Category\u{2026}") { model.naming = .create }
            } label: {
                Image(systemName: "plus").frame(width: 22, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(selectedCategory.map { "Add an app or website to \($0), or a new category" } ?? "Add an app, website or category")
            Button {
                confirmRemove = model.selection
            } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                .buttonStyle(.borderless)
                .help(isCategory(model.selection) ? "Delete the selected category" : "Remove the selected app or website")
                .disabled(!canRemoveSelection)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// The category to add into: the selected category, or the selected item's.
    private var selectedCategory: String? {
        switch model.selection {
        case .category(let name)?: name
        case let key?: model.category(key)
        case nil: nil
        }
    }

    private var canRemoveSelection: Bool {
        switch model.selection {
        case .category(let name)?: !model.isPreset(name)
        case .some: true
        case nil: false
        }
    }

    private var confirmTitle: String {
        guard let key = confirmRemove else { return "" }
        return isCategory(key) ? "Delete the category \u{201C}\(model.title(key))\u{201D}?"
            : "Remove \u{201C}\(model.title(key))\u{201D} from the list?"
    }

    private func isCategory(_ key: PolicyKey?) -> Bool {
        if case .category? = key { true } else { false }
    }

    // MARK: Add a website

    private func startAddingSite(into category: String?) {
        newSite = ""
        siteError = false
        addingSite = .some(category)
    }

    private var addSiteSheet: some View {
        let category = addingSite ?? nil
        return VStack(alignment: .leading, spacing: 8) {
            Text(category.map { "Add a website to \($0)" } ?? "Add a website").font(.headline)
            TextField("example.com or *.example.com", text: $newSite)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit(addSite)
            if siteError {
                Text("Enter a site address like example.com.").font(.caption).foregroundStyle(.red)
            } else {
                Text("*.example.com covers every subdomain. A site follows its browser\u{2019}s settings until you change it.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 280, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { addingSite = nil }.keyboardShortcut(.cancelAction)
                Button("Add", action: addSite).keyboardShortcut(.defaultAction)
                    .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func addSite() {
        let category = addingSite ?? nil
        if model.addSite(newSite, into: category) { addingSite = nil } else { siteError = true }
    }

    private func namingSheet(_ mode: AppsModel.CategoryNaming) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .new, .create:
                Text("New category").font(.headline)
                Text("Apps and websites in a category share what Hunch learned there and follow the category\u{2019}s settings.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 280, alignment: .leading)
            case .rename(let old):
                Text("Rename \u{201C}\(old)\u{201D}").font(.headline)
                Text("Every app and website in this category is updated.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Category name, e.g. Work", text: $nameText)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit { commitName(mode) }
            if nameTaken {
                Text("There\u{2019}s already a category with this name.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.naming = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { commitName(mode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(AppCategories.clean(nameText) == nil)
            }
        }
        .padding(20)
        .onAppear {
            nameTaken = false
            if case .rename(let old) = mode { nameText = old } else { nameText = "" }
        }
    }

    private func commitName(_ mode: AppsModel.CategoryNaming) {
        guard let name = AppCategories.clean(nameText) else { return }
        let taken = model.categoryNames.first { AppCategories.same($0, name) }
        switch mode {
        case .new(let key):
            // An existing name just puts the place in that category.
            model.setCategory(taken ?? name, for: key)
        case .create:
            guard model.createCategory(name) else { nameTaken = true; return }
        case .rename(let old):
            if let taken, !AppCategories.same(taken, old) { nameTaken = true; return }
            model.renameCategory(old, to: name)
        }
        model.naming = nil
    }
}

/// Name on the left; on hover or selection, a menu on the right to move it to another category.
private struct PlaceRow: View {
    let model: AppsModel
    let key: PolicyKey
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            icon.frame(width: 16, height: 16)
            Text(model.title(key)).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if case .app(let id) = key, model.apps.first(where: { $0.bundleID == id })?.installedURL == nil {
                Text("not installed").font(.caption).foregroundStyle(.tertiary)
            }
            if model.hasBehavior(key) {
                Image(systemName: "slider.horizontal.3").font(.caption).foregroundStyle(.secondary)
                    .help("Has its own settings")
            }
            Spacer(minLength: 8)
            if hovering || selected { categoryMenu }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        switch key {
        case .app(let id):
            if let url = model.apps.first(where: { $0.bundleID == id })?.installedURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.dashed").foregroundStyle(.secondary)
            }
        case .domain:
            Image(systemName: "globe").foregroundStyle(.secondary)
        case .category:
            Image(systemName: "folder").foregroundStyle(.secondary)
        }
    }

    private var categoryMenu: some View {
        let current = model.category(key)
        let automatic = model.isAutomatic(key)
        return Menu {
            if let auto = model.automaticCategory(key) {
                Button { model.useAutomaticCategory(for: key) } label: {
                    if automatic { Label("Automatic (\(auto))", systemImage: "checkmark") } else { Text("Automatic (\(auto))") }
                }
                Divider()
            }
            Button { model.setCategory(nil, for: key) } label: {
                if current == nil { Label("No category", systemImage: "checkmark") } else { Text("No category") }
            }
            ForEach(model.categoryNames, id: \.self) { name in
                Button { model.setCategory(name, for: key) } label: {
                    if name == current, !automatic { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button("New Category\u{2026}") { model.naming = .new(key) }
            if let current, !model.isPreset(current) {
                Button("Rename \u{201C}\(current)\u{201D}\u{2026}") { model.naming = .rename(current) }
            }
        } label: {
            Text(current ?? "Category")
                .font(.callout)
                .italic(automatic)
                .foregroundStyle(current == nil ? .tertiary : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(current == nil ? .hidden : .visible)
        .fixedSize()
        .help(automatic
              ? "Put in \u{201C}\(current ?? "")\u{201D} automatically. Apps and websites in a category share learned words and follow its settings."
              : "Apps and websites in the same category share learned words and follow the category\u{2019}s settings.")
    }
}

/// A category in the Categories list: name, how many apps and sites are in it, and whether its
/// settings were changed.
private struct CategoryRow: View {
    let model: AppsModel
    let key: PolicyKey

    private var name: String { if case .category(let n) = key { n } else { "" } }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isPreset(name) ? "folder.fill" : "folder")
                .foregroundStyle(.secondary).frame(width: 16, height: 16)
            Text(name).fontWeight(.semibold).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if model.isPreset(name), model.isEdited(name) {
                Image(systemName: "slider.horizontal.3").font(.caption).foregroundStyle(.secondary)
                    .help("Changed from the built-in settings")
            }
            Spacer(minLength: 8)
            let count = model.members(of: name).count
            Text(count == 0 ? "empty" : "\(count)").font(.callout).foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

private enum Tri: Hashable { case inherit, on, off }

private struct PatchEditor: View {
    let model: AppsModel
    let key: PolicyKey
    @State private var replay = 0
    @State private var confirmDelete = false
    @State private var advancedInsertionOpen = false
    @State private var advancedAppearanceOpen = false

    var body: some View {
        Form {
            header
            let base = model.inherited(key)
            Section {
                // A category can only turn suggestions off (`AppPolicyPatch.behavior`).
                // Off in General is the hard gate: every place then reads "Default (Off)".
                tri("Suggestions", \.enabled, suggestionsOffGenerally ? false : base?.suggestions, allowOn: !isCategory)
                .searchAnchor("apps.suggestions")
                if !suggestionsOffGenerally {
                    tri("Search fields suggestions", \.excludeSearchFields, base?.excludeSearchFields, inverted: true)
                    .searchAnchor("apps.searchFields")
                        .disabled(suggestionsOff)
                    tri("Quick replies", \.suggestedRepliesAllowed, base?.suggestedReplies)
                    .searchAnchor("apps.suggestedReplies")
                        .disabled(suggestionsOff)
                }
            } header: { Text("Suggestions") } footer: {
                if suggestionsOffGenerally {
                    FooterText("Suggestions are off in \(SettingsLinks.md("General", "general.suggestions")), so only autocorrect and dictation settings are shown.")
                } else if suggestionsOff {
                    FooterText("Suggestions are off here, so the settings below don\u{2019}t apply.")
                }
            }
            // Autocorrect works with suggestions off, so it sits outside the greyed-out group.
            Section {
                tri("Suggest Corrections", \.autocorrectEnabled, autocorrectOffGenerally ? false : base?.autocorrect)
                .searchAnchor("apps.autocorrect")
                if !autocorrectOffGenerally {
                    strengthRow(base)
                        .disabled(autocorrectOff)
                    tri("Apply Corrections Automatically", \.fixAutomaticallyAllowed, base?.fixAutomatically)
                    .searchAnchor("apps.fixAutomatically")
                        .disabled(autocorrectOff)
                    tri("Auto-capitalization", \.autoCapitalizationAllowed, base?.autoCapitalization)
                    .searchAnchor("apps.capitalization")
                        .disabled(autocorrectOff)
                    tri("Fix punctuation", \.fixesPunctuation, base?.fixesPunctuation)
                    .searchAnchor("apps.punctuation")
                        .disabled(autocorrectOff)
                    tri("Fix commonly confused words", \.fixConfusedWordsAllowed, base?.fixConfusedWords)
                    .searchAnchor("apps.confused")
                        .disabled(autocorrectOff)
                    tri("Allow chat shorthand", \.leavesChatShorthand, base?.leavesChatShorthand)
                    .searchAnchor("apps.shorthand")
                        .disabled(autocorrectOff)
                    tri("Apply Text Replacements", \.appliesTextReplacements, base?.appliesTextReplacements)
                    .searchAnchor("apps.textReplacements")
                        .disabled(autocorrectOff)
                }
            } header: { Text("Autocorrect") } footer: {
                if !autocorrectOffGenerally, model.patch(key).autocorrectStrength != nil, !strongAllowed(base) {
                    FooterText("Tips: \(AutocorrectCopy.strongNeedsAutomatic)")
                }
            }
            if suggestionsOffGenerally {
                // Dictation still uses the personal information setting; nothing else here applies.
                if model.generalSettings.dictation.enabled {
                    Section("Context") {
                        tri("Personal info", \.personalInfoAllowed, base?.personalInfo)
                        .searchAnchor("apps.personalInfo")
                    }
                }
            } else {
              Group {
                Section("Suggestion behavior") {
                    lengthRows(base)
                    acceptKeyRow("Accept word with", word: true, inherited: base?.acceptWordKey)
                    .searchAnchor("apps.acceptWord")
                    acceptKeyRow("Accept all with", word: false, inherited: base?.acceptFullKey)
                    .searchAnchor("apps.acceptAll")
                    tri("Mid-sentence suggestion", \.midLineEnabled, base?.midLine)
                    .searchAnchor("apps.midSentence")
                    tri("Emoticon to emoji", \.emoticonEmojiEnabled, base?.emoticonEmoji)
                    .searchAnchor("apps.emoticon")
                    tri("Emoji", \.emojiSearchEnabled, base?.emojiSearch)
                    .searchAnchor("apps.emoji")
                    tri("Smart quotes", \.smartQuotesEnabled, base?.smartQuotes)
                    .searchAnchor("apps.smartQuotes")
                    if isTerminal {
                        shellCommandRow(inherited: base?.shellCommandMode)
                        .searchAnchor("apps.shell")
                    }
                    if !isCategory {
                        choice("Insertion method", \.insertion, [
                            (.unicodeEvents, "Type it"), (.paste, "Paste"), (.pasteMatchStyle, "Paste, match style")],
                               inherited: base?.insertion)
                        .searchAnchor("apps.insertion")
                        DisclosureGroup("Advanced insertion", isExpanded: $advancedInsertionOpen) {
                            tri("Use non-breaking spaces", \.nonBreakingSpaces, workaroundDefault(\.nonBreakingSpaces))
                            .searchAnchor("apps.nonBreakingSpaces")
                            tri("Space as keypress", \.spaceAsKeyEvent, workaroundDefault(\.spaceAsKeyEvent))
                            .searchAnchor("apps.spaceAsKey")
                            tri("Backspace after paste", \.backspaceAfterPaste, workaroundDefault(\.backspaceAfterPaste))
                            .searchAnchor("apps.backspaceAfterPaste")
                        }
                    }
                }
                WriteShapeRows(model: model, key: key, inherited: shapeInherited,
                               isDomain: isDomain && shapeFromCategory == nil,
                               inheritedFrom: shapeFromCategory)
                Section("Context") {
                    tri("Allow screen context", \.screenContextAllowed, base?.screenContext)
                    .searchAnchor("apps.screenContext")
                    tri("Learning", \.learningAllowed, base?.learning)
                    .searchAnchor("apps.learning")
                    tri("Personal info", \.personalInfoAllowed, base?.personalInfo)
                    .searchAnchor("apps.personalInfo")
                    instructionsRows(base)
                    .searchAnchor("apps.instructions")
                }
                appearanceSection(base)
              }
              .disabled(suggestionsOff)
            }
            Section {
                resetButtons
            }
        }
        .formStyle(.grouped)
        .searchScrollTarget("apps") { anchor in
            // A search result inside a closed group opens it first.
            if SettingsSearch.advancedInsertionAnchors.contains(anchor) { advancedInsertionOpen = true }
            if SettingsSearch.advancedAppearanceAnchors.contains(anchor) { advancedAppearanceOpen = true }
        }
        .confirmationDialog("Delete the category \u{201C}\(categoryKeyName)\u{201D}?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteCategory(categoryKeyName) }
        } message: {
            Text("Its settings are deleted and its apps and websites move to No category. What Hunch learned there is kept.")
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if isCategory {
            Section {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text(model.isPreset(categoryKeyName)
                         ? "Built-in category. Apps and websites in it follow these settings and share what Hunch learned there. A choice made in an app or website wins over the category."
                         : "Apps and websites in it follow these settings and share what Hunch learned there. A choice made in an app or website wins over the category.")
                    Text("\u{201C}Default\u{201D} follows your general settings; the brackets show what that is now.")
                }
                LabeledContent("In this category") {
                    Text(memberList).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                if !model.isPreset(categoryKeyName) {
                    HStack {
                        Spacer()
                        Button("Rename\u{2026}") { model.naming = .rename(categoryKeyName) }
                        Button("Delete\u{2026}", role: .destructive) { confirmDelete = true }
                    }
                }
            } header: { Text(categoryKeyName) }
        } else {
            Section {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text(seedSummary)
                    Text(isDomain
                         ? "Choices below override the browser\u{2019}s settings for this site. \u{201C}Default\u{201D} follows the browser."
                         : "Choices below override the built-in behavior. \u{201C}Default\u{201D} follows the built-in rule and your general settings; the brackets show what that is now.")
                }
                if let c = model.category(key) {
                    LabeledContent {
                        Button("Edit \u{201C}\(c)\u{201D}") { model.selection = .category(name: c) }
                    } label: {
                        Text("Category: \(c)\(model.isAutomatic(key) ? " (automatic)" : "")")
                        Text("\u{201C}Default\u{201D} follows \(c)\u{2019}s settings where it sets one.")
                    }
                }
            } header: { Text(model.title(key)) }
        }
    }

    private var memberList: String {
        let names = model.members(of: categoryKeyName).map(model.title)
        return names.isEmpty ? "None yet. Right-click the category in the list to add an app or website." : names.joined(separator: ", ")
    }

    @ViewBuilder private var resetButtons: some View {
        if isCategory {
            if model.isPreset(categoryKeyName) {
                Button("Restore built-in settings", role: .destructive) { model.restorePreset(categoryKeyName) }
                    .disabled(!model.isEdited(categoryKeyName))
            } else {
                Button("Set everything to Default", role: .destructive) { model.removeAll(key) }
                    .disabled(!model.hasBehavior(key))
            }
        } else {
            Button("Reset to built-in behavior", role: .destructive) { model.removeAll(key) }
                .disabled(!model.hasBehavior(key))
        }
    }

    // MARK: Context

    @ViewBuilder private func instructionsRows(_ base: InheritedPolicy?) -> some View {
        let fromCategory = model.categoryPatch(for: key)?.customInstructions
        let inherited = isCategory ? nil : (base?.customInstructions ?? fromCategory)
        let source: String = if let c = model.category(key), !(fromCategory ?? "").isEmpty { c } else { "the built-in rule" }
        InstructionsRows(model: model, key: key, inherited: inherited, source: source,
                         inheritedReplace: base?.instructionsReplaceGlobal
                            ?? model.categoryPatch(for: key)?.instructionsReplaceGlobal ?? false)
    }

    // MARK: Appearance

    /// The look this place gets when it has none of its own: its category's, else the main one.
    private func inheritedLook(_ base: InheritedPolicy?) -> (look: AppearanceSettings?, name: String) {
        if isCategory { return (nil, "Main appearance") }
        if let c = model.category(key), let look = model.categoryPatch(for: key)?.appearance { return (look, "\(c)\u{2019}s look") }
        if let look = base?.appearance { return (look, "built-in look") }
        return (nil, isDomain ? "browser" : "Main appearance")
    }

    @ViewBuilder private func appearanceSection(_ base: InheritedPolicy?) -> some View {
        let p = model.patch(key)
        let inherited = inheritedLook(base)
        Section {
            choice("Suggestion display", \.overlay, [
                (.automatic, "Automatic"), (.inline, "Inline"), (.card, "Below the line"),
                (.mirror, "Mirror the field (covers the line)")],
                   inherited: base?.overlay)
            .searchAnchor("apps.display")
            Picker(selection: Binding<Bool>(
                get: { p.appearance != nil },
                set: { own in
                    model.edit(key) { $0.appearance = own ? (inherited.look ?? model.mainAppearance) : nil }
                    replay += 1
                })) {
                Text("Default (\(inherited.name))").tag(false)
                Text("Own look").tag(true)
            } label: {
                SettingLabel("Look", info: "The effect, color and strength of suggestions here. Default follows "
                             + (isCategory ? "\(SettingsLinks.md("Appearance", "appearance"))." : "the category\u{2019}s look if it has one, else \(SettingsLinks.md("Appearance", "appearance"))."))
            }
            .searchAnchor("apps.look")
            if let look = p.appearance {
                OwnLookEditor(look: Binding(get: { model.patch(key).appearance ?? look },
                                            set: { new in model.edit(key) { $0.appearance = new } }),
                              replay: $replay)
            }
            if !isCategory {
                DisclosureGroup("Advanced appearance", isExpanded: $advancedAppearanceOpen) {
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(
                                get: { (p.fontSizeAdjustmentFactor ?? 1) * 100 },
                                set: { v in model.edit(key) { $0.fontSizeAdjustmentFactor = v.rounded() / 100 } }),
                                   in: 70...150, step: 5)
                            Text("\(Int(((p.fontSizeAdjustmentFactor ?? 1) * 100).rounded())) %")
                                .monospacedDigit()
                        }
                    } label: {
                        Text("Text size")
                        if p.fontSizeAdjustmentFactor == nil { Text("Default") }
                    }
                    .searchAnchor("apps.textSize")
                    Stepper(value: Binding(
                        get: { p.verticalAlignmentOffset ?? 0 },
                        set: { v in model.edit(key) { $0.verticalAlignmentOffset = v } }),
                            in: -6...6, step: 0.5) {
                        LabeledContent("Vertical offset", value: Self.offsetLabel(p.verticalAlignmentOffset ?? 0))
                    }
                    .searchAnchor("apps.verticalOffset")
                    Button("Reset text size and offset") {
                        model.edit(key) {
                            $0.fontSizeAdjustmentFactor = nil
                            $0.verticalAlignmentOffset = nil
                        }
                    }
                    .disabled(p.fontSizeAdjustmentFactor == nil && p.verticalAlignmentOffset == nil)
                }
            }
        } header: { Text("Appearance") }
    }

    // MARK: Helpers

    private var isCategory: Bool { if case .category = key { true } else { false } }
    private var categoryKeyName: String { if case .category(let n) = key { n } else { "" } }

    /// The category's name when it sets this value (for "Default (Work: Off)").
    private func categoryName(setting isSet: (AppPolicyPatch) -> Bool) -> String? {
        guard let c = model.category(key), let p = model.categoryPatch(for: key), isSet(p) else { return nil }
        return c
    }

    /// The category whose "Write for me" shape Default follows, if it sets one.
    private var shapeFromCategory: String? {
        categoryName(setting: { $0.writeShape != nil || $0.writeCustomShapeID != nil })
    }

    /// What "Write for me" Default comes to: a site takes its category's shape when it sets one.
    private var shapeInherited: InheritedPolicy? {
        model.inherited(key) ?? (shapeFromCategory == nil ? nil : model.siteCategoryInherited(key))
    }

    private var isDomain: Bool { if case .domain = key { true } else { false } }
    /// The Suggestions switch resolves to Off here (a site with no choice follows the browser: not off).
    /// Autocorrect is off here (own choice, else Default), so the other autocorrect rows can't apply.
    private var autocorrectOff: Bool {
        (model.patch(key).autocorrectEnabled ?? model.inherited(key)?.autocorrect
            ?? model.categoryPatch(for: key)?.autocorrectEnabled) == false
    }

    /// Suggestions are off in General (the hard gate), so places have nothing of their own to set for them.
    private var suggestionsOffGenerally: Bool { !model.generalSettings.enabled }
    /// Suggest Corrections is off in Autocorrect settings.
    private var autocorrectOffGenerally: Bool { !model.generalSettings.autocorrectEnabled }

    private var suggestionsOff: Bool {
        (model.patch(key).enabled ?? model.inherited(key)?.suggestions ?? model.categoryPatch(for: key)?.enabled) == false
    }
    private var isTerminal: Bool { if case .app(let id) = key { Seeds.terminals.contains(id) } else { false } }
    private var shellCommandsNote: String {
        switch model.patch(key).layerShellCommandMode ?? model.inherited(key)?.shellCommandMode ?? .automatic {
        case .automatic:
            "Automatic: the window title decides. A shell gets only valid shell commands (from your history, else the on-device model; Right arrow accepts the next word, Option+Right all of it); Claude Code, Gemini CLI, Codex and Aider get suggestions in their prompts; editors, ssh and other programs get none. When the title names nothing, the screen decides."
        case .always:
            "Always: only valid shell commands at the shell prompt (from your history, else the on-device model). Claude Code, Gemini CLI, Codex and Aider prompts get no suggestions. Right arrow accepts the next word, Option+Right all of it."
        case .never:
            "Never: suggestions only inside Claude Code, Gemini CLI, Codex and Aider prompts, nothing at the shell prompt."
        }
    }

    /// "+2 pt", "0 pt", "\u{2212}1.5 pt": the inline ghost's baseline shift (positive = up).
    static func offsetLabel(_ points: Double) -> String {
        let magnitude = abs(points)
        let number = magnitude == magnitude.rounded() ? String(Int(magnitude)) : String(format: "%.1f", magnitude)
        if points > 0 { return "+\(number) pt" }
        if points < 0 { return "\u{2212}\(number) pt" }
        return "0 pt"
    }

    private var seedSummary: String {
        if isCategory { return "" }
        if isDomain { return "Follows the settings of the browser it\u{2019}s opened in." }
        if case .app(let id) = key, TerminalHosts.profile(for: id) == .unsupported {
            return "Built-in rule: this terminal exposes no text to Accessibility, so suggestions can\u{2019}t work here."
        }
        guard let s = model.seed(for: key) else { return "No built-in rule applies here." }
        if case .app(let id) = key, Seeds.codeEditors.contains(id) {
            return Self.monacoEditors.contains(id) ? Self.monacoEditorSummary : Self.codeEditorSummary
        }
        var parts: [String] = []
        if s.secureExcluded == true { parts.append("treated as sensitive") }
        if s.enabled == false { parts.append("suggestions off") }
        if s.wakeChromiumAX == true { parts.append("accessibility wake-up for web-based editors") }
        if let k = s.layerAcceptWordKey, k != .shortcuts {
            parts.append(k == .off ? "Tab passes through" : "\(describe(k, word: true)) accepts the next word")
        }
        if parts.isEmpty { parts.append("custom tuning") }
        return "Built-in rule: " + parts.joined(separator: ", ") + "."
    }

    /// Code editors are seeded off, with Right arrow for the next word so Tab stays with the editor.
    static let codeEditorSummary = "Built-in rule: suggestions off in code editors. Turn on with the Suggestions switch below. "
        + "Tab keeps indenting here; Right arrow accepts the next word and Option+Tab the whole suggestion."
    /// The VS Code family (Monaco) exposes its text only with `editor.accessibilitySupport` on.
    static let monacoEditorSummary = "Built-in rule: suggestions off in code editors. Turn on with the Suggestions switch below; "
        + "for best results set editor.accessibilitySupport to on in the editor. "
        + "Tab keeps indenting here; Right arrow accepts the next word and Option+Tab the whole suggestion."
    static let monacoEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.vscodium",
    ]

    /// "Default (On)": what the default comes to here; "Default (browser)" for a site;
    /// "Default (Work: Off)" when the category sets it.
    private func defaultLabel(_ resolved: String?, from category: String? = nil) -> String {
        if let category, let resolved { return "Default (\(category): \(resolved))" }
        return "Default (\(resolved ?? "browser"))"
    }

    /// `inverted` shows the stored flag flipped, for a setting worded the other way round
    /// ("Search fields suggestions" stores `excludeSearchFields`).
    private func tri(_ title: String, _ kp: WritableKeyPath<AppPolicyPatch, Bool?>, _ inherited: Bool?,
                     inverted: Bool = false, allowOn: Bool = true) -> some View {
        let binding = Binding<Tri>(
            get: {
                switch model.patch(key)[keyPath: kp].map({ $0 != inverted }) {
                case nil: .inherit; case true?: allowOn ? .on : .inherit; case false?: .off
                }
            },
            set: { v in
                model.edit(key) { $0[keyPath: kp] = (v == .inherit ? nil : (v == .on) != inverted) }
            })
        let fromCategory = model.categoryPatch(for: key)?[keyPath: kp]
        let shown = inherited ?? fromCategory
        return Picker(title, selection: binding) {
            Text(defaultLabel(shown.map { ($0 != inverted) ? "On" : "Off" },
                              from: fromCategory == nil ? nil : model.category(key))).tag(Tri.inherit)
            if allowOn { Text("On").tag(Tri.on) }
            Text("Off").tag(Tri.off)
        }
    }

    /// Apply Corrections Automatically as it comes out here: Strong needs it (its reread changes text itself).
    private func strongAllowed(_ base: InheritedPolicy?) -> Bool {
        let general = model.generalSettings
        return general.autocorrectEnabled && general.autocorrectFixAutomatically
            && (model.patch(key).fixAutomaticallyAllowed ?? base?.fixAutomatically ?? true)
    }

    /// Per-app Strength: a Custom toggle (off = Default: the category's, else the general one), and the same
    /// slider as in Settings → Autocorrect once it is on.
    @ViewBuilder private func strengthRow(_ base: InheritedPolicy?) -> some View {
        let chosen = model.patch(key).autocorrectStrength
        let fromCategory = model.categoryPatch(for: key)?.autocorrectStrength
        let general = model.generalSettings
        let automatic = strongAllowed(base)
        let inherited = AutocorrectStrength.allowed(base?.strength ?? fromCategory ?? general.autocorrectStrength,
                                                    automatic: automatic)
        Toggle(isOn: Binding(
            get: { chosen != nil },
            set: { on in model.edit(key) { $0.autocorrectStrength = on ? inherited : nil } })) {
            Text("Custom autocorrect strength")
            if chosen == nil {
                Text(defaultLabel(inherited.title, from: fromCategory == nil ? nil : model.category(key)))
            }
        }
        .searchAnchor("apps.autocorrectStrength")
        if let chosen {
            let shown = AutocorrectStrength.allowed(chosen, automatic: automatic)
            StopSlider(title: "Strength", detail: shown.summary,
                       count: AutocorrectStrength.allCases.count,
                       index: Binding(
                           get: { AutocorrectStrength.allCases.firstIndex(of: shown) ?? 1 },
                           set: { i in model.edit(key) {
                               $0.autocorrectStrength = AutocorrectStrength.allowed(AutocorrectStrength.allCases[i],
                                                                                    automatic: automatic)
                           } }),
                       value: shown.title,
                       maxIndex: AutocorrectStrength.maxIndex(automatic: automatic))
        }
    }

    // MARK: Length and start

    /// What Default comes to here for a length setting: the app's or category's resolved value, a
    /// site's category value, or nil for a site that follows its browser.
    private func inheritedValue<T>(_ base: InheritedPolicy?, _ kp: KeyPath<InheritedPolicy, T>,
                                   _ patchKP: KeyPath<AppPolicyPatch, T?>) -> T? {
        if let base { return base[keyPath: kp] }
        if model.categoryPatch(for: key)?[keyPath: patchKP] != nil {
            return model.siteCategoryInherited(key)?[keyPath: kp]
        }
        return nil
    }

    /// "Suggestion length" and "Start suggesting after": a Custom toggle each (off = Default), and
    /// the same slider as in General once it is on.
    @ViewBuilder private func lengthRows(_ base: InheritedPolicy?) -> some View {
        let p = model.patch(key)
        let fallback = model.inherited(.category(name: ""))
        let length = inheritedValue(base, \.length, \.length)
        let start = inheritedValue(base, \.minWordsBeforeSuggesting, \.minWordsBeforeSuggesting)
        Toggle(isOn: Binding(
            get: { p.length != nil },
            set: { on in model.edit(key) { $0.length = on ? (length ?? fallback?.length ?? .medium) : nil } })) {
            Text("Custom suggestion length")
            if p.length == nil { Text("Default: \(length.map(GeneralPane.lengthName) ?? "browser")") }
        }
        .searchAnchor("apps.length")
        if let chosen = p.length {
            StopSlider(title: "Suggestion length",
                       detail: "\(chosen.minWords)\u{2013}\(chosen.maxWords) words per suggestion.",
                       count: LengthPreset.allCases.count,
                       index: Binding(
                           get: { LengthPreset.allCases.firstIndex(of: chosen) ?? 0 },
                           set: { i in model.edit(key) { $0.length = LengthPreset.allCases[i] } }),
                       value: GeneralPane.lengthName(chosen))
        }
        Toggle(isOn: Binding(
            get: { p.minWordsBeforeSuggesting != nil },
            set: { on in
                model.edit(key) {
                    $0.minWordsBeforeSuggesting = on ? (start ?? fallback?.minWordsBeforeSuggesting ?? 2) : nil
                }
            })) {
            Text("Custom suggestion start")
            if p.minWordsBeforeSuggesting == nil { Text("Default: \(start.map(GeneralPane.wordsLabel) ?? "browser")") }
        }
        .searchAnchor("apps.start")
        if let chosen = p.minWordsBeforeSuggesting {
            StopSlider(title: "Start suggesting after",
                       detail: "Words typed on the line before suggestions appear.",
                       count: GeneralPane.minWordsRange.count,
                       index: Binding(
                           get: { GeneralPane.minWordsIndex(chosen) },
                           set: { i in model.edit(key) { $0.minWordsBeforeSuggesting = GeneralPane.minWordsRange.lowerBound + i } }),
                       value: GeneralPane.minWordsLabel(chosen),
                       detailAsInfo: true)
        }
    }

    /// "Tab", "None", "\u{2325}Tab": an accept key as the user sees it here.
    private func describe(_ k: AcceptKey, word: Bool) -> String {
        let shortcut = word ? model.shortcutBindings.word : model.shortcutBindings.full
        return k == .off ? "None" : chordDescription(k.resolved(shortcut))
    }

    /// A key recorder for this app's accept key. Delete sets None (that accept has no key here);
    /// the reset button, shown while a key is set, goes back to Default.
    private func acceptKeyRow(_ title: String, word: Bool, inherited: AcceptKey?) -> some View {
        let p = model.patch(key)
        let current = word ? p.layerAcceptWordKey : p.acceptFullKey
        let cat = model.categoryPatch(for: key)
        let fromCategory = word ? cat?.layerAcceptWordKey : cat?.acceptFullKey
        let emptyTitle: String = switch current {
        case nil: (inherited ?? fromCategory).map {
            defaultLabel(describe($0, word: word), from: fromCategory == nil ? nil : model.category(key))
        } ?? defaultLabel(nil)
        case .off?: "None"
        case .shortcuts?: "Shortcuts key (\(describe(.shortcuts, word: word)))"
        case .chord?: ""
        }
        let binding = Binding<KeyChord?>(
            get: { if case .chord(let c)? = current { c } else { nil } },
            set: { chord in
                model.edit(key) {
                    let value: AcceptKey = chord.map { .chord($0) } ?? .off
                    if word { $0.acceptWordKey = value; $0.tabAcceptEnabled = nil } else { $0.acceptFullKey = value }
                }
            })
        return LabeledContent(title) {
            HStack(spacing: 4) {
                KeyRecorder(chord: binding, emptyTitle: emptyTitle).frame(width: 170, height: 24)
                Button {
                    model.edit(key) {
                        if word { $0.acceptWordKey = nil; $0.tabAcceptEnabled = nil } else { $0.acceptFullKey = nil }
                    }
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Back to Default")
                    .opacity(current == nil ? 0 : 1)
                    .disabled(current == nil)
            }
        }
        .help("Click and press the keys. Delete sets None, so this accept has no key here.")
    }

    /// What "Default" comes to for an insertion workaround: off unless a built-in rule turns it on;
    /// nil for a site, which follows the browser.
    private func workaroundDefault(_ kp: KeyPath<AppPolicyPatch, Bool?>) -> Bool? {
        guard !isDomain, !isCategory else { return nil }
        return model.seed(for: key)?[keyPath: kp] ?? false
    }

    /// "Write for me": the shape of a draft here. Default is adaptive unless a built-in rule fixes it.
    /// Writes `shellCommandMode` and clears the older On/Off switch it replaces.
    private func shellCommandRow(inherited: ShellCommandMode?) -> some View {
        let fromCategory = model.categoryPatch(for: key)?.layerShellCommandMode
        let names: [ShellCommandMode: String] = [.automatic: "Automatic", .always: "Always", .never: "Never"]
        let binding = Binding<ShellCommandMode?>(
            get: { model.patch(key).layerShellCommandMode },
            set: { v in model.edit(key) { $0.shellCommandMode = v; $0.shellCommandsEnabled = nil } })
        return Picker(selection: binding) {
            Text(defaultLabel(names[inherited ?? fromCategory ?? .automatic],
                              from: fromCategory == nil ? nil : model.category(key))).tag(ShellCommandMode?.none)
            ForEach(ShellCommandMode.allCases, id: \.self) { Text(names[$0]!).tag(ShellCommandMode?.some($0)) }
        } label: {
            SettingLabel("Suggest shell commands", info: shellCommandsNote)
        }
    }

    private func choice<T: Hashable>(_ title: String, _ kp: WritableKeyPath<AppPolicyPatch, T?>,
                                     _ options: [(T, String)], inherited: T?) -> some View {
        let binding = Binding<T?>(
            get: { model.patch(key)[keyPath: kp] },
            set: { v in model.edit(key) { $0[keyPath: kp] = v } })
        let fromCategory = model.categoryPatch(for: key)?[keyPath: kp]
        let shown = inherited ?? fromCategory
        return Picker(title, selection: binding) {
            Text(defaultLabel(shown.flatMap { v in options.first { $0.0 == v }?.1 },
                              from: fromCategory == nil ? nil : model.category(key))).tag(T?.none)
            ForEach(options, id: \.0) { Text($0.1).tag(T?.some($0.0)) }
        }
    }
}

// MARK: - Write for me shape

/// The "Write for me" section: the picker plus the wording of the chosen shape: presets (Email, Message, AI prompt)
/// edited once for every app, and the user's saved custom shapes.
private struct WriteShapeRows: View {
    let model: AppsModel
    let key: PolicyKey
    let inherited: InheritedPolicy?
    let isDomain: Bool
    /// The category whose shape Default follows, if it sets one.
    var inheritedFrom: String? = nil
    @State private var confirmDelete: CustomWriteShape?

    private enum Choice: Hashable { case inherit, preset(WriteShape), custom(UUID), new }

    static let names: [WriteShape: String] = [.adaptive: "Adaptive", .email: "Email", .message: "Message",
                                              .paragraph: "Paragraph", .aiPrompt: "AI prompt"]

    private var library: WriteShapeLibrary { model.shapes }

    /// What this place sets itself. A saved shape that was deleted, and the old Paragraph, read as Default.
    private var current: Choice {
        let patch = model.patch(key)
        if let id = patch.writeCustomShapeID, library.custom(id) != nil { return .custom(id) }
        if let shape = patch.writeShape, WriteShapeLibrary.presets.contains(shape) { return .preset(shape) }
        return .inherit
    }

    private var defaultName: String {
        if let custom = library.custom(inherited?.writeCustomShapeID) { return custom.name }
        return Self.names[inherited?.writeShape ?? .adaptive] ?? "Adaptive"
    }

    /// The wording a new custom shape starts from: what shows here now, or Message for Adaptive.
    private var startText: String {
        switch current {
        case .preset(let shape): return model.presetText(shape)
        case .custom(let id): return library.custom(id)?.text ?? ""
        case .inherit, .new:
            if let custom = library.custom(inherited?.writeCustomShapeID) { return custom.text }
            let shape = inherited?.writeShape ?? .adaptive
            return model.presetText(WriteShapeLibrary.presets.contains(shape) ? shape : .message)
        }
    }

    var body: some View {
        let binding = Binding<Choice>(
            get: { current },
            set: { choice in
                switch choice {
                case .inherit: model.edit(key) { $0.writeShape = nil; $0.writeCustomShapeID = nil }
                case .preset(let s): model.edit(key) { $0.writeShape = s; $0.writeCustomShapeID = nil }
                case .custom(let id): model.edit(key) { $0.writeShape = nil; $0.writeCustomShapeID = id }
                case .new: model.newCustomShape(startingFrom: startText, for: key)
                }
            })
        Section {
            Picker(selection: binding) {
                Text(inheritedFrom.map { "Default (\($0): \(defaultName))" } ?? "Default (\(defaultName))").tag(Choice.inherit)
                Divider()
                ForEach(WriteShapeLibrary.presets, id: \.self) { Text(Self.names[$0]!).tag(Choice.preset($0)) }
                if !library.custom.isEmpty {
                    Divider()
                    ForEach(library.custom) { Text($0.name).tag(Choice.custom($0.id)) }
                }
                Divider()
                Text("New Custom Shape\u{2026}").tag(Choice.new)
            } label: {
                SettingLabel("Write for me", info: "What a draft looks like here. Each shape is an instruction given to the model. Adaptive picks an email, a chat message, a paragraph or a prompt for an AI from the app or site.")
            }
            .searchAnchor("apps.writeShape")
            editor
                .confirmationDialog("Delete \u{201C}\(confirmDelete?.name ?? "")\u{201D}?",
                                    isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                    presenting: confirmDelete) { shape in
                    Button("Delete", role: .destructive) { model.deleteCustomShape(shape.id) }
                } message: { shape in
                    let users = model.places(using: shape.id)
                    Text(users.isEmpty ? "No app or site uses it."
                         : "\(users.joined(separator: ", ")) will go back to Default.")
                }
        } footer: {
            FooterText("Tips: " + footerTip)
        }
    }

    /// Under the section: what editing the shown instruction changes, or how to edit one.
    private var footerTip: String {
        switch current {
        case .preset(let shape):
            "Changes apply in every app and site that uses \(Self.names[shape]!)."
        case .custom(let id):
            "Changes apply in every app and site that uses \u{201C}\(library.custom(id)?.name ?? "")\u{201D}. "
                + "Polish ignores custom shapes and keeps the text\u{2019}s own shape."
        case .inherit, .new:
            "Pick a shape to see and edit its instruction."
        }
    }

    @ViewBuilder private var editor: some View {
        switch current {
        case .preset(let shape):
            VStack(alignment: .leading, spacing: 6) {
                textBox(Binding(get: { model.presetText(shape) }, set: { model.setPresetText(shape, $0) }))
                HStack {
                    Spacer()
                    if library.editedText(shape) != nil {
                        Text("Edited").font(.caption).foregroundStyle(.secondary)
                        Button("Reset to Default") { model.setPresetText(shape, WriteForMeFramer.builtInShapeText(shape) ?? "") }
                    }
                }
            }
        case .custom(let id):
            if let shape = library.custom(id) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: Binding(
                            get: { shape.name },
                            set: { name in model.updateCustomShape(id) { $0.name = name } }))
                            .font(.body.weight(.regular))
                        Button("Delete\u{2026}", role: .destructive) { confirmDelete = shape }
                    }
                    textBox(Binding(get: { shape.text }, set: { text in model.updateCustomShape(id) { $0.text = text } }))
                    HStack {
                        let users = model.places(using: id)
                        Text(users.isEmpty ? "Not used anywhere yet." : "Used in: " + users.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu("Reset to") {
                            ForEach(WriteShapeLibrary.presets, id: \.self) { preset in
                                Button(Self.names[preset]!) {
                                    let text = model.presetText(preset)
                                    model.updateCustomShape(id) { $0.text = text }
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        case .inherit, .new:
            inheritedNote
        }
    }

    @ViewBuilder private var inheritedNote: some View {
        if isDomain {
            Text("Follows the browser\u{2019}s choice.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let custom = library.custom(inherited?.writeCustomShapeID) {
            readOnly(custom.text)
        } else if let shape = inherited?.writeShape, WriteShapeLibrary.presets.contains(shape) {
            readOnly(model.presetText(shape))
        }
    }

    private func readOnly(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func textBox(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .settingsTextBox(minHeight: 80)
    }
}

// MARK: - Own look

/// An app's or category's own look: the effect, color and strength from Settings → Appearance,
/// with a preview. The effect's fine-tuning comes along from where the look was copied.
private struct OwnLookEditor: View {
    @Binding var look: AppearanceSettings
    @Binding var replay: Int

    private var effects: [PopInAnimation] {
        var list = AppearancePane.effects
        if !list.contains(look.animation) { list.insert(look.animation, at: list.count - 1) }
        return list
    }

    var body: some View {
        AppearancePreview(appearance: look, replay: replay)
            .onTapGesture { replay += 1 }
        Picker("Effect", selection: Binding(get: { look.animation }, set: { look.animation = $0; replay += 1 })) {
            ForEach(effects, id: \.self) { Text(AppearancePane.name($0)).tag($0) }
        }
        Text(AppearancePane.blurb(look.animation)).font(.caption).foregroundStyle(.secondary)
        Picker("Color", selection: Binding(get: { look.color }, set: { look.color = $0; replay += 1 })) {
            Text("Follow effect").tag(SuggestionColorChoice.followEffect)
            Text("Match text").tag(SuggestionColorChoice.matchText)
            Text("Grey").tag(SuggestionColorChoice.grey)
            Text("Accent").tag(SuggestionColorChoice.accent)
            Text("Custom").tag(SuggestionColorChoice.custom)
        }
        if look.color == .custom {
            ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
        }
        LabeledContent("Strength") {
            HStack {
                Slider(value: $look.opacity, in: AppearanceSettings.opacityRange, step: 0.05)
                Text("\(Int((look.clampedOpacity * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        HStack {
            Spacer()
            Button("Replay") { replay += 1 }
        }
    }

    private var customColor: Binding<Color> {
        Binding(get: {
            let c = look.customColor
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
        }, set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            look.customColor = StoredColor(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                                           blue: Double(ns.blueComponent))
        })
    }
}

/// The Instructions box. With nothing of its own, an app or site shows (and follows) its
/// category's instructions; typing makes them its own copy, and clearing the box or "Use …"
/// goes back to following the category.
private struct InstructionsRows: View {
    let model: AppsModel
    let key: PolicyKey
    /// What applies here with nothing of its own (the category's or built-in text).
    let inherited: String?
    /// Where `inherited` comes from: a category name or "the built-in rule".
    let source: String
    let inheritedReplace: Bool
    /// What the box shows. Kept apart from the saved value so that clearing the box doesn't
    /// refill it with the inherited text while typing.
    @State private var draft: String

    init(model: AppsModel, key: PolicyKey, inherited: String?, source: String, inheritedReplace: Bool) {
        self.model = model
        self.key = key
        self.inherited = inherited
        self.source = source
        self.inheritedReplace = inheritedReplace
        _draft = State(initialValue: model.patch(key).customInstructions ?? inherited ?? "")
    }

    private var own: String? { model.patch(key).customInstructions }
    private var inheritedText: String { (inherited ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isApp: Bool { if case .app = key { true } else { false } }
    private var sourceName: String { source == "the built-in rule" ? source : "\(source)\u{2019}s" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instructions")
            TextEditor(text: $draft)
                .settingsTextBox(minHeight: 90)
                .foregroundStyle(own == nil && !inheritedText.isEmpty ? .secondary : .primary)
                .onChange(of: draft) { _, text in save(text) }
                .onChange(of: inherited) { _, new in
                    // The category changed under us: keep following it.
                    if own == nil { draft = new ?? "" }
                }
            if !inheritedText.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if own != nil {
                        Button("Use \(sourceName) instructions") {
                            model.edit(key) { $0.customInstructions = nil }
                            draft = inherited ?? ""
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        let replace = model.patch(key).instructionsReplaceGlobal ?? inheritedReplace
        Toggle(isOn: Binding(
            get: { replace },
            set: { on in model.edit(key) { $0.instructionsReplaceGlobal = on == inheritedReplace ? nil : on } })) {
            SettingLabel("Replace How I write", info: replace
                 ? "Only these instructions are used here; your general \u{201C}How I write\u{201D} is ignored."
                 : "These instructions are added to your general \u{201C}How I write\u{201D}. Turn on to use only these here.")
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && inheritedText.isEmpty
                  && model.patch(key).instructionsReplaceGlobal == nil)
    }

    private var note: String {
        let from = source == "the built-in rule" ? "From the built-in rule." : "From \(source)."
        if own != nil { return "Changed here, so \(sourceName) instructions no longer apply." }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Empty, so \(sourceName) instructions are used."
        }
        return "\(from) Typing here makes these this \(isApp ? "app" : "website")\u{2019}s own."
    }

    /// Text equal to the inherited one, or empty, means "follow the category".
    private func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty || (!inheritedText.isEmpty && trimmed == inheritedText) ? nil : text
        guard value != own else { return }
        model.edit(key) { $0.customInstructions = value }
    }
}
