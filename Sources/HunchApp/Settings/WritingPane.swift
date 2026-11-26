import HunchCore
import HunchHistory
import Observation
import SwiftUI

/// Learned-vocabulary status and actions for the Personalization pane; the app delegate fills the closures.
@MainActor
@Observable
final class LearningPaneModel {
    private(set) var entryCount: Int?
    private(set) var readOnly = false
    private(set) var deleteError: String?
    @ObservationIgnored var countProvider: (() async -> Int)?
    @ObservationIgnored var readOnlyProvider: (() async -> Bool)?
    @ObservationIgnored var deleteAll: (() async throws -> Void)?
    @ObservationIgnored var listProvider: (() async -> [LearnedWordInfo])?
    @ObservationIgnored var renameEntry: ((String, String) async throws -> Void)?
    @ObservationIgnored var deleteEntry: ((String) async throws -> Void)?
    @ObservationIgnored var addEntry: ((String) async throws -> Void)?
    @ObservationIgnored var blockEntry: ((String, Bool) async throws -> Void)?
    @ObservationIgnored var snippetsProvider: (() async -> [StyleSnippet])?
    @ObservationIgnored var deleteSnippet: ((String) async -> Void)?
    @ObservationIgnored var deleteAllSnippets: (() async -> Void)?
    @ObservationIgnored var categoriesProvider: (() -> AppCategories)?
    @ObservationIgnored var replyQuestionsProvider: (() async -> [LearnedQuestion])?
    @ObservationIgnored var editReplies: ((@escaping @Sendable (inout LearnedReplies) throws -> Void) async throws -> Void)?
    private(set) var replyQuestions: [LearnedQuestion] = []
    private(set) var snippets: [StyleSnippet] = []
    /// App categories (Settings → Apps), for the saved sentences' "App category" column.
    private(set) var categories = AppCategories()
    private(set) var words: [LearnedWordInfo] = []
    private(set) var editError: String?

    func reloadWords() async {
        words = await listProvider?() ?? []
        snippets = await snippetsProvider?() ?? []
        replyQuestions = await replyQuestionsProvider?() ?? []
        categories = categoriesProvider?() ?? AppCategories()
    }

    /// Runs an edit, then refreshes the list and count; errors are shown under the table.
    func perform(_ edit: () async throws -> Void) async {
        do {
            try await edit()
            editError = nil
        } catch {
            editError = error.localizedDescription
        }
        await reloadWords()
        await refresh()
    }

    func refresh() async {
        entryCount = await countProvider?()
        readOnly = await readOnlyProvider?() ?? false
    }

    func delete() async {
        do {
            try await deleteAll?()
            deleteError = nil
        } catch {
            deleteError = "Couldn't delete everything: \(error.localizedDescription)"
        }
        await refresh()
        await reloadWords()
    }
}

/// About me, how I write, the suggestion and dictation context (with learning), and what was learned.
struct PersonalizationPane: View {
    let model: SettingsModel
    let learning: LearningPaneModel
    let screen: ScreenPaneModel
    @State private var showingLearned = false

    private static let strengthLevels: [(name: String, value: Float)] = [
        ("Off", 0), ("Light", 0.75), ("Medium", 1.5), ("Strong", 2.25), ("Max", 3),
    ]

    /// The level index nearest to the stored strength.
    private var strengthIndex: Binding<Double> {
        Binding(
            get: {
                let stored = Float(model.settings.learning.strength)
                let nearest = Self.strengthLevels.indices.min {
                    abs(Self.strengthLevels[$0].value - stored) < abs(Self.strengthLevels[$1].value - stored)
                } ?? 0
                return Double(nearest)
            },
            set: { newValue in
                let index = min(max(Int(newValue.rounded()), 0), Self.strengthLevels.count - 1)
                model.set(\.learning.strength, to: type(of: model.settings.learning.strength).init(Self.strengthLevels[index].value))
            })
    }

    /// Screen text cap in tokens, in 100-token steps.
    private var screenTokens: Binding<Double> {
        Binding(
            get: { Double(model.settings.screenContextTokenLimit) },
            set: { model.set(\.screenContextTokenLimit, to: Int(($0 / 100).rounded()) * 100) })
    }

    // Example text drawn over an empty box. It is only a view, never saved, so the model never sees it.
    static let aboutMePlaceholder = "e.g. I\u{2019}m a product designer at a small studio. I often write about our mobile app and work with Sam and Priya."
    static let howIWritePlaceholder = "e.g. I write casually and briefly, mostly lowercase. I mix English and Chinese in the same sentence. I rarely use exclamation marks."

    var body: some View {
        Form {
            Section {
                Toggle(isOn: model.bind(\.usePersonalInfo)) {
                    SettingLabel("Personal info", info: "Your Mac account\u{2019}s name (\(NSFullUserName())) and what you write below help with sign-offs, introductions and anything about you. Turn it off for single apps or sites in Apps & Sites. It stays on this Mac.")
                }
                .searchAnchor("personalization.personalInfo")
                TextEditor(text: model.bind(\.aboutMe))
                .searchAnchor("personalization.aboutMe")
                    .settingsTextBox(minHeight: 90)
                    .settingsPlaceholder(Self.aboutMePlaceholder, shown: model.settings.aboutMe.isEmpty)
                    .disabled(!model.settings.usePersonalInfo)
                    .opacity(model.settings.usePersonalInfo ? 1 : 0.45)
            } header: {
                SettingLabel("About me", info: "Who you are: your role, where you work or study, people and projects you often write about.")
            }
            Section {
                TextEditor(text: model.bind(\.customInstructions))
                .searchAnchor("personalization.howIWrite")
                    .settingsTextBox(minHeight: 140)
                    .settingsPlaceholder(Self.howIWritePlaceholder, shown: model.settings.customInstructions.isEmpty)
            } header: {
                SettingLabel("How I write", info: "Your style: tone, sentence length, the languages you mix, words you like or avoid. It applies everywhere; add per-app notes in Apps & Sites.")
            }
            if model.settings.enabled {
                SuggestionStylesSection(model: model)
            }
            // Each context section shows only while its feature is on in General.
            if model.settings.enabled {
                Section("Suggestions Context") {
                    Toggle(isOn: model.bind(\.windowTitleContextEnabled)) {
                        SettingLabel("Window title", info: "The app's name and, in browsers, the website are always used so suggestions fit where you're writing. The window title is more specific and more private; it stays on this Mac.")
                    }
                    .searchAnchor("personalization.windowTitle")
                    Toggle(isOn: model.bind(\.clipboardContextEnabled)) {
                        SettingLabel("Recent clipboard", info: "Plain text copied in the last 5 minutes can inform suggestions. Password-manager copies, single-word passwords or codes, and secret-looking lines are skipped. Nothing is stored.")
                    }
                    .searchAnchor("personalization.clipboard")
                    Toggle(isOn: screen.enabled) {
                        SettingLabel("Screen Awareness", info: "Use text near the cursor to improve suggestions.")
                    }
                    .searchAnchor("personalization.screenAwareness")
                    LabeledContent {
                        HStack(spacing: 8) {
                            Slider(value: screenTokens,
                                   in: Double(HunchSettings.screenContextTokenRange.lowerBound)...Double(HunchSettings.screenContextTokenRange.upperBound),
                                   step: 100)
                            Text("\(model.settings.screenContextTokenLimit) tokens")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                    } label: {
                        SettingLabel("Screen text amount", info: "How much on-screen text a suggestion can use, nearest to the cursor first. More helps when the whole window is one topic (an email, a document); less keeps busy chats from crowding out your own writing.")
                    }
                    .searchAnchor("personalization.screenAmount")
                    .disabled(!model.settings.screenContextEnabled)
                    .opacity(model.settings.screenContextEnabled ? 1 : 0.45)
                    Toggle(isOn: model.bind(\.learning.enabled)) {
                        SettingLabel("Learn words and phrases", info: "Hunch notes which suggestions you keep, correct, or type over, and learns names, jargon, and phrasings you use often (not common words like \u{201C}the\u{201D}). It also saves sentences you type and leans suggestions toward how they continue, using only sentences from the same app or category. Stored encrypted on this Mac only; never from password fields or apps where learning is off (see Apps & Sites).")
                    }
                    .searchAnchor("personalization.learnWords")
                    LabeledContent {
                        VStack(spacing: 2) {
                            Slider(value: strengthIndex, in: 0...Double(Self.strengthLevels.count - 1), step: 1)
                            HStack {
                                ForEach(Self.strengthLevels.indices, id: \.self) { index in
                                    Text(Self.strengthLevels[index].name)
                                        .font(.caption2)
                                        .foregroundStyle(Int(strengthIndex.wrappedValue) == index ? .primary : .secondary)
                                    if index < Self.strengthLevels.count - 1 { Spacer(minLength: 0) }
                                }
                            }
                        }
                        .frame(width: 260)
                    } label: {
                        SettingLabel("Personalize word choice",
                                     info: "How strongly learned words and phrases steer suggestions.")
                    }
                    .searchAnchor("personalization.wordChoice")
                    .disabled(!model.settings.learning.enabled)
                    Toggle(isOn: model.bind(\.learning.styleExamplesEnabled)) {
                        SettingLabel("Learn writing style", info: "Shows the model the two saved sentences most relevant to what you're writing, so suggestions sound like you. Sentences are saved by \u{201C}Learn words and phrases\u{201D}; turning this off keeps saving them.")
                    }
                    .searchAnchor("personalization.learnStyle")
                    .disabled(!model.settings.learning.enabled)
                }
            }
            if model.settings.dictation.enabled {
                DictationContextSection(model: model)
            }
            Section {
                LabeledContent {
                    Button("Show\u{2026}") { showingLearned = true }
                } label: {
                    Text("Learned data")
                }
                .searchAnchor("personalization.learnedData")
                if learning.readOnly {
                    Text("Your saved history couldn't be unlocked this session (Keychain unavailable). Hunch is learning in memory only and won't overwrite it.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .searchScrollTarget("personalization")
        .task {
            await learning.refresh()
            await learning.reloadWords()
        }
        .sheet(isPresented: $showingLearned) {
            LearnedSheet(model: model, learning: learning)
        }
    }
}

/// "Learned data": learned words, often-mistyped words, learned replies, dictation fixes, chat avatars and saved
/// sentences, each in a
/// fixed-height scrolling table.
private struct LearnedSheet: View {
    let model: SettingsModel
    let learning: LearningPaneModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    /// Full content is about 2,050 pt tall; shorter screens scroll instead.
    private var sheetHeight: CGFloat {
        min(2050, (NSScreen.main?.visibleFrame.height ?? 900) - 80)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Learned words").font(.headline)
                        LearnedWordsEditor(learning: learning)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Often mistyped").font(.headline)
                        OftenMistypedEditor(learning: learning)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Learned replies").font(.headline)
                        LearnedRepliesEditor(learning: learning, repliesOn: model.settings.suggestedRepliesEnabled)
                            .disabled(!model.settings.learning.enabled)
                            .opacity(model.settings.learning.enabled ? 1 : 0.5)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Learned dictation fixes").font(.headline)
                        DictationFixesEditor()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chat avatars").font(.headline)
                        ChatAvatarsEditor()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved sentences").font(.headline)
                        SavedSentencesEditor(learning: learning)
                            .disabled(!model.settings.learning.enabled)
                            .opacity(model.settings.learning.enabled ? 1 : 0.5)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Delete Everything Learned\u{2026}", role: .destructive) { confirmDelete = true }
                    .confirmationDialog("Delete everything Hunch has learned from your writing?",
                                        isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive) { Task { await learning.delete() } }
                    } message: {
                        Text("This removes the encrypted history file and its key, and the saved chat avatars. It can't be undone.")
                    }
                if let error = learning.deleteError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: sheetHeight)
        .task {
            await learning.refresh()
            await learning.reloadWords()
        }
    }
}

/// Searchable list of learned words and phrases with add, edit, delete, and block.
struct LearnedWordsEditor: View {
    let learning: LearningPaneModel
    enum Filter: String, CaseIterable { case active = "In use", learning = "Learning", blocked = "Blocked", all = "All" }
    @AppStorage("learnedWordsFilter") private var filter: Filter = .active
    @State private var search = ""
    @State private var newWord = ""
    @State private var editing: LearnedWordInfo?
    @State private var editText = ""

    private var shown: [LearnedWordInfo] {
        learning.words.filter { info in
            guard !info.oftenMistyped else { return false }   // own section: OftenMistypedEditor
            let statusOK: Bool = switch filter {
            case .all: true
            case .active: info.status == .active
            case .learning: info.status == .learning
            case .blocked: info.status == .blocked
            }
            return statusOK && (search.isEmpty || info.text.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            }
            Table(shown) {
                TableColumn("Word or phrase", value: \.text)
                TableColumn("Status") { info in Text(label(info)) }.width(150)
                TableColumn("Used") { info in Text("\(info.positiveCount)") }.width(44)
                TableColumn("Used in") { info in UsedInCell(apps: info.apps) }.width(90)
                TableColumn("Last used") { info in
                    Text(info.lastSeen, format: .relative(presentation: .named))
                }.width(110)
                TableColumn("") { info in
                    HStack(spacing: 6) {
                        Button("Edit") { editing = info; editText = info.text }
                        Button(info.status == .blocked ? "Unblock" : "Block") {
                            Task { await learning.perform { try await learning.blockEntry?(info.id, info.status != .blocked) } }
                        }
                        Button(role: .destructive) {
                            Task { await learning.perform { try await learning.deleteEntry?(info.id) } }
                        } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                }.width(150)
            }
            .frame(height: 270)
            if filter == .active && shown.isEmpty && search.isEmpty {
                Text("Words appear here after you've used them on a few occasions (3 times over 2 days or in 2 places), or after you've undone an automatic fix of them twice and kept the word. 'Learning' shows the ones being watched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Add a word or name (up to 3 words)", text: $newWord).textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                Button("Add", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = learning.editError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Active words influence suggestions and are never flagged as typos; delete one to have it fixed again. Added words are active right away. Blocked words are never learned and Hunch steers away from them. Words you kept over fixes that look like your own typos (\u{201C}stil\u{201D} for \u{201C}still\u{201D}) are blocked as potential typos; unblock one if it is a real word.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { info in
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit “\(info.text)”").font(.headline)
                TextField("Word or phrase", text: $editText).textFieldStyle(.roundedBorder).frame(width: 280)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let id = info.id, text = editText
                        editing = nil
                        Task { await learning.perform { try await learning.renameEntry?(id, text) } }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    private func addWord() {
        let text = newWord
        Task {
            await learning.perform { try await learning.addEntry?(text) }
            if learning.editError == nil { newWord = "" }   // keep the text to fix on a validation error
        }
    }

    private func label(_ info: LearnedWordInfo) -> String {
        switch info.status {
        case .active: info.origin == .manual ? "Active (added)" : info.origin == .dictation ? "Active (dictation)"
            : info.keptOverFix ? "Active (kept over a fix)" : "Active"
        case .learning: info.keptOverFix ? "Learning (kept over a fix)" : "Learning"
        case .blocked: info.likelyTypo ? "Blocked (potential typo)" : "Blocked"
        }
    }
}

/// Words the user often mistypes (automatic fixes of them kept 3 times): delete-only, apart from
/// the learned words since they are not words Hunch learned to suggest.
struct OftenMistypedEditor: View {
    let learning: LearningPaneModel

    private var shown: [LearnedWordInfo] { learning.words.filter(\.oftenMistyped) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(shown) {
                TableColumn("Word", value: \.text)
                TableColumn("Times fixed") { info in Text("\(info.positiveCount)") }.width(80)
                TableColumn("Last fixed") { info in
                    Text(info.lastSeen, format: .relative(presentation: .named))
                }.width(110)
                TableColumn("") { info in
                    Button(role: .destructive) {
                        Task { await learning.perform { try await learning.deleteEntry?(info.id) } }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }.width(40)
            }
            .frame(height: 160)
            Text("Words Hunch fixed for you 3 times and you kept the fix. It now recognizes more garbled spellings of them. Delete one to forget it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Sentences kept for "Learn my writing style": review, delete selected, or delete all.
struct SavedSentencesEditor: View {
    let learning: LearningPaneModel
    @State private var selection = Set<String>()
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(learning.snippets, selection: $selection) {
                TableColumn("Sentence", value: \.text)
                TableColumn("App") { snippet in Text(appName(snippet.appKey ?? snippet.appBundleID)) }.width(110)
                TableColumn("Category") { snippet in
                    if let c = (snippet.appKey ?? snippet.appBundleID).flatMap(learning.categories.category(of:)) {
                        Text(c)
                    } else {
                        Text("\u{2013}").foregroundStyle(.secondary)
                    }
                }.width(110)
                TableColumn("Saved") { snippet in
                    Text(snippet.createdAt, format: .relative(presentation: .named))
                }.width(110)
            }
            .frame(height: 270)
            HStack {
                Button("Delete Selected") {
                    let ids = selection
                    selection = []
                    Task {
                        for id in ids { await learning.deleteSnippet?(id) }
                        await learning.reloadWords()
                    }
                }
                .disabled(selection.isEmpty)
                Button("Delete All\u{2026}", role: .destructive) { confirmDeleteAll = true }
                    .disabled(learning.snippets.isEmpty)
                    .confirmationDialog("Delete all saved sentences?", isPresented: $confirmDeleteAll) {
                        Button("Delete All", role: .destructive) {
                            selection = []
                            Task {
                                await learning.deleteAllSnippets?()
                                await learning.reloadWords()
                            }
                        }
                    } message: {
                        Text("This can't be undone.")
                    }
            }
            Text("Sentences are saved when you finish writing in a field or send a message, never from password fields or apps where learning is off. Suggestions use sentences from the same app, or from any app or website in the same category (Settings → Apps).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func appName(_ key: String?) -> String { AppKeyName.display(key) }
}

/// Readable names for app keys (bundle IDs or site hosts).
enum AppKeyName {
    /// A bundle ID shows as the app's display name when the app is installed, else its last
    /// component; a domain (no installed app has it as a bundle ID) is shown as-is.
    static func display(_ key: String?) -> String {
        guard let key else { return "\u{2013}" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            let fm = FileManager.default
            return fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        if key.hasPrefix("com.") || key.hasPrefix("org.") || key.hasPrefix("io."),
           let last = key.split(separator: ".").last { return String(last) }
        return key
    }
}

/// "Everywhere" for words with no app data, otherwise "N apps"; click for the list with shares.
private struct UsedInCell: View {
    let apps: [(key: String, share: Float)]
    @State private var showing = false

    var body: some View {
        if apps.isEmpty {
            Text("Everywhere").foregroundStyle(.secondary)
                .help("Learned before apps were recorded, or added by hand: used at full strength in every app.")
        } else {
            Button(apps.count == 1 ? "1 app" : "\(apps.count) apps") { showing.toggle() }
                .buttonStyle(.link)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Used in").font(.headline)
                        ForEach(apps, id: \.key) { app in
                            HStack {
                                Text(AppKeyName.display(app.key))
                                Spacer(minLength: 16)
                                Text(app.share, format: .percent.precision(.fractionLength(0)))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Text("Strongest in the apps it's used in most, weaker elsewhere.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    .padding(12)
                    .frame(minWidth: 220)
                }
        }
    }
}

extension View {
    /// Every multi-line text box in Settings: the same font, size and weight as the rest of the
    /// form, with a light border.
    func settingsTextBox(minHeight: CGFloat) -> some View {
        font(.body.weight(.regular))
            .frame(minHeight: minHeight)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    /// Grey example text over an empty text box, gone as soon as anything is typed. Clicks pass
    /// through to the box underneath. The insets match TextEditor's own text position.
    func settingsPlaceholder(_ text: String, shown: Bool) -> some View {
        overlay(alignment: .topLeading) {
            if shown {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .padding(.trailing, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
