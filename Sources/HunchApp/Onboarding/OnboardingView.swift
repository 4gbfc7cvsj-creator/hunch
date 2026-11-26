import AppKit
import HunchCore
import Observation
import SwiftUI

/// Posted by Settings → General’s "Welcome tour"; the app delegate opens the tour.
extension Notification.Name {
    static let showWelcomeTour = Notification.Name("HunchShowWelcomeTour")
}

/// State of the welcome tour: the current step, the models picked on the first page, and the models
/// it reads. Step order comes from `OnboardingFlow`; the window controller supplies the actions.
@MainActor
@Observable
final class OnboardingModel {
    typealias Step = OnboardingFlow.Step

    /// The language model row for a model already in use that isn't in the catalog.
    static let currentModelPick = "current"

    var step: Step = .welcome
    let permissions: PermissionsModel
    let models: ModelsPaneModel
    let settings: SettingsModel
    /// The language model picked on the first page: a catalog file name, or `currentModelPick`.
    var languagePick: String?
    /// The speech model picked on the first page (a catalog file name); nil for none.
    var speechPick: String?
    /// Picked files to select once they are downloaded.
    @ObservationIgnored private var wantedLanguage: String?
    @ObservationIgnored private var wantedSpeech: String?
    @ObservationIgnored var chooseFolder: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}
    /// Close for now; the tour reopens at the next launch.
    @ObservationIgnored var skip: () -> Void = {}
    /// Record the tour as completed and close.
    @ObservationIgnored var finish: () -> Void = {}

    init(permissions: PermissionsModel, models: ModelsPaneModel, settings: SettingsModel) {
        self.permissions = permissions
        self.models = models
        self.settings = settings
    }

    /// Accessibility and Input Monitoring; Hunch does nothing without both.
    var requiredGranted: Bool {
        permissions.isGranted(.accessibility) && permissions.isGranted(.inputMonitoring)
    }

    var canContinue: Bool { step != .permissions || requiredGranted }

    func advance() {
        if step == .welcome { applyModelPicks() }
        guard step != .done else { finish(); return }
        step = OnboardingFlow.next(from: step, requiredGranted: requiredGranted)
    }

    func goBack() { step = OnboardingFlow.previous(from: step) }

    func skipFeatures() { step = OnboardingFlow.skipFeatures(from: step) }

    /// The permission poll saw the required grants appear: leave the permissions step by itself.
    func requiredGrantsChanged(to granted: Bool) {
        if granted, step == .permissions { advance() }
    }

    // MARK: Models

    var languageRows: [CatalogRow] { (models.catalog[.autocomplete] ?? []).sorted { $0.byteSize < $1.byteSize } }
    var speechRows: [CatalogRow] { (models.catalog[.speechToText] ?? []).sorted { $0.byteSize < $1.byteSize } }

    /// The model in use when it isn't one of the catalog's (the user's own file).
    var currentOwnModel: ModelRow? {
        guard let selected = models.selected, let row = models.rows.first(where: { $0.id == selected }), row.usable
        else { return nil }
        return languageRows.contains { Self.file(row.id) == $0.id.lowercased() } ? nil : row
    }

    /// Fills in the picks the first time the page shows: what's in use, else the recommendations.
    func preparePicks() {
        if languagePick == nil {
            if currentOwnModel != nil {
                languagePick = Self.currentModelPick
            } else if let selected = models.selected,
                      let row = languageRows.first(where: { $0.id.lowercased() == Self.file(selected) }) {
                languagePick = row.id
            } else {
                languagePick = (languageRows.first(where: \.isRecommended) ?? languageRows.first)?.id
            }
        }
        if speechPick == nil {
            speechPick = models.effectiveSpeechModel
                ?? (speechRows.first(where: \.isRecommended) ?? speechRows.first)?.id
        }
    }

    /// Continue on the first page: picked models already here become the selection; the others start
    /// downloading (the app uses the default folder when none was chosen) and are selected when they arrive.
    private func applyModelPicks() {
        var toDownload: [String] = []
        if let pick = languagePick, pick != Self.currentModelPick,
           let row = languageRows.first(where: { $0.id == pick }) {
            if row.state == .downloaded { selectLanguage(file: row.id) } else {
                wantedLanguage = row.id
                if !Self.isActive(row.state) { toDownload.append(row.id) }
            }
        }
        if let pick = speechPick, let row = speechRows.first(where: { $0.id == pick }) {
            if row.state == .downloaded { selectSpeech(row.id) } else {
                wantedSpeech = row.id
                if !Self.isActive(row.state) { toDownload.append(row.id) }
            }
        }
        toDownload.forEach { models.download($0) }
    }

    /// Called when the models' state changes: selects picked models that just arrived.
    func modelsChanged() {
        if let file = wantedLanguage, languageRows.first(where: { $0.id == file })?.state == .downloaded,
           models.rows.contains(where: { Self.file($0.id) == file.lowercased() && $0.usable }) {
            wantedLanguage = nil
            selectLanguage(file: file)
        }
        if let file = wantedSpeech, speechRows.first(where: { $0.id == file })?.state == .downloaded {
            wantedSpeech = nil
            selectSpeech(file)
        }
    }

    private func selectLanguage(file: String) {
        guard let row = models.rows.first(where: { Self.file($0.id) == file.lowercased() }),
              row.id != models.selected else { return }
        models.selectModel(row.id)
    }

    private func selectSpeech(_ file: String) {
        guard models.effectiveSpeechModel != file || models.speechSelected != file else { return }
        models.speechSelected = file
        models.selectSpeechModel(file)
    }

    /// The downloads in progress or failed, for the footer.
    var downloadSummary: (text: String, fraction: Double?, failed: Bool)? {
        let rows = languageRows + speechRows
        let active = rows.compactMap { row -> (String, Double)? in
            if case .downloading(let fraction, _) = row.state { return (row.name, fraction) }
            return nil
        }
        if let first = active.first {
            let more = active.count > 1 ? " and \(active.count - 1) more" : ""
            return ("Downloading \(first.0)\(more)\u{2026} \(Int((first.1 * 100).rounded()))%", first.1, false)
        }
        if let failed = rows.first(where: { if case .failed = $0.state { true } else { false } }) {
            return ("\(failed.name) didn\u{2019}t download. Retry on the first page.", nil, true)
        }
        return nil
    }

    static func isActive(_ state: CatalogRow.State) -> Bool {
        if case .downloading = state { return true }
        return false
    }

    static func file(_ id: ModelEntryID) -> String {
        (id.relativePath as NSString).lastPathComponent.lowercased()
    }
}

struct OnboardingView: View {
    let model: OnboardingModel

    static let size = CGSize(width: 700, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            ProgressHeader(current: model.step)
                .padding(.top, 18)
            page
                .padding(.horizontal, 48)
                .padding(.top, model.step == .welcome ? 18 : 0)
                .padding(.bottom, model.step == .welcome ? 0 : 30)
                // The first page fills the window from the top; the others sit centered.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.step == .welcome ? .top : .center)
            Divider()
            bottomBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        // Fixed, so the hosting view never resizes the (non-resizable) window from step to step.
        .frame(width: Self.size.width, height: Self.size.height)
        .onChange(of: model.requiredGranted) { _, granted in model.requiredGrantsChanged(to: granted) }
        .onChange(of: model.models.catalog) { model.modelsChanged() }
        .onChange(of: model.models.rows) { model.modelsChanged() }
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome: WelcomePage(model: model)
        case .intro: IntroVideoPage()
        case .permissions: PermissionsPage(permissions: model.permissions)
        case .loginItem: LoginItemPage()
        case .suggestions: SuggestionsPage(model: model)
        case .quickReplies: QuickRepliesPage(settings: model.settings)
        case .autocorrect: AutocorrectPage(settings: model.settings)
        case .writeForMe: WriteForMePage(settings: model.settings)
        case .dictation: DictationPage(model: model)
        case .appearance: AppearancePage(settings: model.settings)
        case .personalize: PersonalizePage(settings: model.settings)
        case .done: DonePage(model: model)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            switch OnboardingFlow.part(of: model.step) {
            case .setup:
                Button("Set up later") { model.skip() }.buttonStyle(.link)
            case .features where model.step != .done:
                Button("Skip the tour") { model.skipFeatures() }.buttonStyle(.link)
            case .features:
                EmptyView()
            }
            if model.step != .welcome, let download = model.downloadSummary {
                DownloadStatus(text: download.text, fraction: download.fraction, failed: download.failed)
            }
            Spacer()
            if model.step != .welcome {
                Button("Back") { model.goBack() }
            }
            Button(continueTitle) { model.advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
        }
        .controlSize(.large)
    }

    private var continueTitle: String {
        switch model.step {
        case .welcome: "Get Started"
        case .loginItem: "See What It Can Do"
        case .done: "Finish"
        default: "Continue"
        }
    }
}

/// Two labelled groups of dots, Setup and Features: filled up to and including the current step.
private struct ProgressHeader: View {
    let current: OnboardingFlow.Step

    var body: some View {
        HStack(spacing: 22) {
            group("Setup", OnboardingFlow.steps(in: .setup))
            group("Features", OnboardingFlow.steps(in: .features))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingFlow.Step.allCases.count)")
    }

    private func group(_ title: String, _ steps: [OnboardingFlow.Step]) -> some View {
        let active = steps.contains(current)
        return HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
            ForEach(steps, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: step == current ? 18 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
    }
}

private struct DownloadStatus: View {
    let text: String
    let fraction: Double?
    let failed: Bool

    var body: some View {
        HStack(spacing: 6) {
            if failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let fraction {
                ProgressView(value: fraction).frame(width: 60)
            }
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, 8)
    }
}

/// The top of every page: a large symbol (or the app icon), a centered headline and a short message.
struct PageHeader: View {
    enum Art {
        case appIcon
        case symbol(String)
    }

    let art: Art
    let title: String
    /// Nil: the title stands alone, with no gap under it.
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            switch art {
            case .appIcon:
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 52)
            }
            Text(title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            }
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity)
    }
}

/// A rounded group box like the ones in System Settings.
struct TourCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// One shortcut row: what it does on the left, its recorder on the right (changes save at once).
struct ShortcutRow: View {
    let title: String
    let chord: Binding<KeyChord?>

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            KeyRecorder(chord: chord).frame(width: 150, height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// A shortcut that isn't recordable here (Esc), shown as a key cap.
struct FixedShortcutRow: View {
    let title: String
    let keys: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys)
                .font(.callout.monospaced())
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.4)))
                .frame(width: 150, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
