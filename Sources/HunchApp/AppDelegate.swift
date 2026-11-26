import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import HunchCore
import HunchFocus
import HunchHistory
import HunchText
import HunchInput
import HunchLlama
import HunchModels
import HunchOverlay
import HunchPolicy
import HunchScreen
import HunchSettingsStore
import os

/// Flags read from non-main threads (the AX thread and tap thread).
final class SharedFlags: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (enabled: true, debug: false, windowTitle: false))
    var enabled: Bool {
        get { lock.withLock { $0.enabled } }
        set { lock.withLock { $0.enabled = newValue } }
    }
    var debug: Bool {
        get { lock.withLock { $0.debug } }
        set { lock.withLock { $0.debug = newValue } }
    }
    var windowTitle: Bool {
        get { lock.withLock { $0.windowTitle } }
        set { lock.withLock { $0.windowTitle = newValue } }
    }
    private let pausedLock = OSAllocatedUnfairLock(initialState: false)
    /// A timed pause is in effect (the saved `enabled` setting is untouched).
    var paused: Bool {
        get { pausedLock.withLock { $0 } }
        set { pausedLock.withLock { $0 = newValue } }
    }
}

/// Composition root: builds every service and connects them through the coordinator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// The app turned off by Esc until the next app switch, and the activation observer for it.
    private var offUntilSwitch: String?
    private var appSwitchObserver: (any NSObjectProtocol)?
    /// Shown (disabled, at the very top) only while something needs the user's attention.
    private let problemItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Shown only while macOS's own inline predictions are on; opens Keyboard settings.
    private let predictionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let problemSeparator = NSMenuItem.separator()
    private let modeItem = NSMenuItem(title: "Hunch: On", action: nil, keyEquivalent: "")
    private let modeMenu = NSMenu(title: "Hunch")
    private let modelItem = NSMenuItem(title: "Language Model", action: nil, keyEquivalent: "")
    private let modelsMenu = NSMenu(title: "Language Model")
    private let speechItem = NSMenuItem(title: "Speech to Text", action: nil, keyEquivalent: "")
    private let speechMenu = NSMenu(title: "Speech to Text")
    private let unloadItem = NSMenuItem(title: "Unload Model Now", action: nil, keyEquivalent: "")
    /// "Efficiency: battery 18%" (disabled); shown only while Dynamic Power Mode is in Efficiency.
    private let efficiencyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Battery, Low Power Mode, memory, GPU and heat for Dynamic Power Mode (runs only while it's on).
    private let loadMonitor = SystemLoadMonitor()
    /// Efficiency at once, back to Performance after a minute of calm.
    private var powerGate = PowerGate()
    private var powerTimer: Timer?
    /// A pause lives only in memory (settings.enabled stays true), so quitting resumes it.
    private var pausedUntil: Date?
    private var pauseSeconds: TimeInterval?
    private var pauseTimer: Timer?
    private var serviceProblem: String?

    /// A fresh install has no models folder; the first download adopts `defaultModelsFolder`.
    private let store = JSONSettingsStore(fileURL: HunchSettingsStoreModule.defaultFileURL(), freshDefaults: .firstLaunch)
    private let models = ModelController()
    private lazy var router = EngineRouter(models: models)
    private let flags = SharedFlags()
    /// While debug logging is on: GPU busy % and memory footprint into perf.log once a second.
    private var perfSampler: Task<Void, Never>?
    private let gate = DefaultSecureGate()
    private let keyboard = KeyboardMonitor()
    private let presenter = GhostOverlayPresenter()
    private let wordFlash = WordFlashPresenter()
    /// The suggestion style's name under the caret while one is on.
    private let styleTag = StyleTagPresenter()
    /// Faint lines under fixed words that can still be put back, and their Revert offer.
    private let fixMarks = FixUnderlinePresenter()
    private let chooser = DefaultGhostModeChooser()
    private let inserter = UnicodeEventInserter()
    private let screenProvider = ScreenContextProvider()
    private let modelsPane = ModelsPaneModel()
    private let learningPane = LearningPaneModel()
    private var learning: LearningController!
    private nonisolated(unsafe) var policyStore: JSONPolicyStore!
    /// Apps and websites listed in Settings → Apps.
    private let places = KnownPlacesStore(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hunch/places.json"))
    private var resolver: DefaultPolicyResolver!
    private var arbiter: DefaultAcceptanceArbiter!
    private var focus: AXFocusTracker!
    private var screen: ScreenContextController!
    private var coordinator: SuggestionCoordinator!
    /// The write-for-me flow (shortcut → preview panel → replace).
    private var writeForMe: WriteForMeController?
    private var replies: SuggestedRepliesController?
    private var dictation: DictationController?
    private let pasteDictationItem = NSMenuItem(title: "Paste Last Dictation", action: nil, keyEquivalent: "")
    private let pasteRawItem = NSMenuItem(title: "Paste Last Raw Transcript", action: nil, keyEquivalent: "")
    private var settingsWindow: SettingsWindowController?
    private var applied: HunchSettings?
    /// A folder path Hunch itself wrote to the settings (so the change isn't re-applied).
    private var selfWrittenFolderPath: String?
    /// Folder choices in flight; the settings path isn't synced from the manager meanwhile.
    private var choosingFolder = 0
    /// Work waiting for the default models folder to be adopted (see `withModelsFolder`).
    private var waitingForDefaultFolder: [(URL) -> Void]?
    private var servicesStarted = false
    private var permissionTimer: Timer?
    private var streamTasks: [Task<Void, Never>] = []
    private var settingsTask: Task<Void, Never>?
    /// Focus was last blocked by Secure Input; the owner (nil when the system didn't say) is
    /// named in the menu until Secure Input turns off or focus is blocked for another reason.
    private var secureInputBlocked = false
    private var secureInputOwnerPID: pid_t?
    /// Other apps whose consuming key taps run before Hunch's; re-read when the menu opens.
    /// Catalog downloads from Settings → Model.
    private let downloads = ModelDownloadController()
    /// Shown only while the folder has no usable model; opens Settings → Model.
    private let downloadModelItem = NSMenuItem(title: "Download recommended model…", action: nil, keyEquivalent: "")
    private var onboardingWindow: OnboardingWindowController?
    /// Own windows and panels currently holding focus tracking paused. `.ownPanelOpen` is one
    /// reason in a set, so the first holder pauses and the last one resumes (a folder panel
    /// closing must not resume tracking while a URL alert is still up).
    private var ownPanelHolds = 0
    private var welcomeTourObserver: (any NSObjectProtocol)?

    private var settings: HunchSettings { store.current() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = store.current()
        flags.enabled = settings.enabled
        flags.debug = settings.debugLogging
        PromptDebugLog.isEnabled = settings.debugLogging
        AlignmentCheckLog.isEnabled = settings.debugLogging
        Task.detached(priority: .utility) { _ = autocorrectLexicon.count }  // build it off the main thread
        perfSampler = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard PromptDebugLog.isEnabled else { continue }
                let gpu = GPUUtilization.current().map(String.init) ?? "-"
                let footprint = ProcessMemory.snapshot().map { String($0.physFootprint / 1_048_576) } ?? "-"
                SuggestionCoordinator.perf("sample gpuBusy=\(gpu)% footprintMB=\(footprint)")
            }
        }
        flags.windowTitle = settings.windowTitleContextEnabled
        InputSourceScripts.shared.start(debug: settings.debugLogging)
        InputMethodState.shared.start()

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hunch", isDirectory: true)
        let policies = JSONPolicyStore(fileURL: support.appendingPathComponent("app-policies.json"),
                                       freshPatches: FirstLaunchPolicies.patches,
                                       freshMigrations: FirstLaunchPolicies.migrations)
        policyStore = policies
        // Categories gained settings: values equal to the category's go, so places follow it.
        let mainAppearance = settings.appearance
        try? policies.runMigration(CategoryMigration.id) {
            CategoryMigration.migrate(&$0, mainAppearance: mainAppearance)
        }
        // Apps and sites with saved settings are always listed.
        places.adopt(policies.userPatches.keys.filter(\.isPlace))
        // JSONPolicyStore guards its patches with an internal lock, so reading them from the AX
        // thread is safe even though the type isn't declared Sendable.
        nonisolated(unsafe) let lockedStore = policies
        resolver = DefaultPolicyResolver(completionsEnabledByDefault: settings.completionsEnabledByDefault,
                                         userPatches: { lockedStore.userPatches })
        resolver.setMidLineByDefault(settings.midLineByDefault)
        resolver.setAutocorrectByDefault(settings.autocorrectEnabled)
        resolver.setAutocorrectStrengthByDefault(settings.autocorrectStrength)
        resolver.setEmojiByDefault(settings.emoji.enabled)
        arbiter = DefaultAcceptanceArbiter(bindings: settings.bindings)

        let flags = self.flags
        focus = AXFocusTracker(
            secureInput: {
                SecureInputState(enabled: SecureInputProbe.isSecureEventInputEnabled(),
                                 ownerPID: SecureInputProbe.ownerPID())
            },
            globallyEnabled: { flags.enabled },
            // Autocorrect keeps reading fields with suggestions off (a timed pause stops both).
            autocorrectActive: { !flags.paused },
            debugLogging: { flags.debug },
            windowTitleEnabled: { flags.windowTitle })

        let focus = self.focus!
        let store = self.store
        let myAvatars = MyAvatarStore(fileURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hunch/my-avatars.json"))
        ChatAvatarsPaneState.shared.attach(myAvatars)
        screen = ScreenContextController(
            provider: screenProvider,
            freshPass: { field in await focus.currentPass(for: field) },
            settings: { store.current() }, myAvatars: myAvatars)
        screen?.isMisspelled = { [models] w in models.spellChecker.isMisspelled(w, languages: Locale.preferredLanguages) }
        let history = HistoryService(store: EncryptedHistoryStore())
        // Ordinary typing never teaches typos: a word the system dictionary rejects AND that has a
        // fix one small edit away ("dont" → "don't"). Names and terms the dictionary lacks
        // ("hunch") have no such fix and stay learnable. Plain system checker (not
        // LearnedWordsSpellChecker, which treats learned words as fine), uncertain-aware. Both
        // calls hop to the main thread with a bounded wait (never main.sync), and nothing on the
        // main thread waits synchronously on the history actor, so this cannot deadlock; a busy
        // main thread yields nil and the word is simply not learned this time.
        let systemSpelling = SystemSpellChecker()
        let systemFixes = SystemCorrectionSuggester()
        Task {
            await history.setSpelling { word in
                let languages = Locale.preferredLanguages
                guard let misspelled = systemSpelling.lookupMisspelled(word, languages: languages) else { return nil }
                guard misspelled else { return false }
                guard let fix = systemFixes.correction(for: word, context: word, languages: languages) else { return false }
                return TypoShape.isSlip(word, fixedTo: fix) || TypoShape.isCutContraction(word, fixedTo: fix)
            }
            // Words kept over fixes that are most likely the user's own typos ("stil", "teh") are
            // blocked as potential typos instead of learned.
            await history.setLikelyTypo { word in
                // Chat shorthand ("ur", "cuz") is the writer's style, not a slip.
                if ChatShorthand.contains(word.lowercased()) { return false }
                let languages = Locale.preferredLanguages
                guard let misspelled = systemSpelling.lookupMisspelled(word, languages: languages) else { return nil }
                guard misspelled else { return false }
                guard let fix = systemFixes.correction(for: word, context: word, languages: languages) else { return false }
                return TypoShape.isLikelyTypo(word, fixedTo: fix, isEveryday: CommonEnglish.isEveryday)
            }
        }
        Task { await history.setAppCategories { AppCategories(patches: lockedStore.userPatches) } }
        learningPane.categoriesProvider = { AppCategories(patches: lockedStore.userPatches) }
        let learning = LearningController(service: history, settings: { store.current() }, policies: resolver,
                                          spellChecker: models.spellChecker)
        self.learning = learning
        learningPane.countProvider = { await learning.entryCount }
        learningPane.deleteAll = {
            try await learning.deleteAll()
            await MainActor.run { ChatAvatarsPaneState.shared.store?.clear() }
        }
        learningPane.readOnlyProvider = { await learning.isReadOnly }
        learningPane.listProvider = { await learning.entries() }
        learningPane.renameEntry = { id, text in try await learning.rename(id: id, to: text) }
        learningPane.deleteEntry = { id in try await learning.delete(id: id) }
        learningPane.addEntry = { text in try await learning.add(text) }
        learningPane.replyQuestionsProvider = { await learning.learnedReplyQuestions() }
        learningPane.editReplies = { edit in try await learning.editLearnedReplies(edit) }
        learningPane.snippetsProvider = { await learning.styleSnippets() }
        learningPane.deleteSnippet = { id in await learning.deleteSnippet(id: id) }
        learningPane.deleteAllSnippets = { await learning.deleteAllSnippets() }
        learningPane.blockEntry = { id, blocked in try await learning.setBlocked(id: id, blocked) }
        let router = self.router
        let suggester = SystemCorrectionSuggester()
        coordinator = SuggestionCoordinator(
            engine: { policy in router.engine(for: policy) },
            keyboard: keyboard, arbiter: arbiter, presenter: presenter, modeChooser: chooser,
            inserter: inserter, policies: resolver,
            // A pause reads as "off" to the coordinator without touching the saved setting.
            settings: {
                var current = store.current()
                if flags.paused { current.enabled = false; current.autocorrectEnabled = false }
                return current
            },
            noteTyping: { focus.noteTypingActivity() },
            setEditableFocus: { [keyboard] on in keyboard.setEditableFocus(on) },
            screen: screen,
            requestFreshContext: { focus.noteTypingActivity() },
            learning: learning,
            clipboard: ClipboardContextController(settings: { store.current() }, policies: resolver),
            corrections: { [models] in
                CorrectionFinder(spellChecker: models.spellChecker, suggester: suggester,
                                 languages: Locale.preferredLanguages, knownWords: models.spellChecker.learnedWords,
                                 isCommonWord: { CommonEnglish.contains($0) },
                                 isEverydayWord: { CommonEnglish.isEveryday($0) },
                                 lexicon: autocorrectLexicon)
            },
            learnedWords: { [models] in models.spellChecker.learnedWords },
            inputMethodKind: { InputMethodState.shared.kind },
            notePlaceUsed: { [places] context in
                places.noteUsed(.app(bundleID: context.app.bundleID), name: context.app.localizedName)
                if let host = context.urlHost, let key = KnownPlacesStore.siteKey(host) { places.noteUsed(key) }
            },
            calibrationStore: CalibrationStore(fileURL: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Hunch/calibrations.json")),
            anchorStore: TypedAnchorStore(fileURL: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Hunch/typed-anchors.json")),
            onBlocked: { [weak self] reason, _ in self?.noteBlocked(reason) },
            styleTag: { [styleTag] names, caret in styleTag.show(names, caret: caret) })
        coordinator.autocorrect = makeAutocorrectFollowUp(focus: focus, learning: learning)
        coordinator.isMisspelled = { [models] w in models.spellChecker.isMisspelled(w, languages: Locale.preferredLanguages) }
        let keyboard = self.keyboard
        coordinator.keyTimingSnapshot = { keyboard.keyTimingSnapshot() }
        coordinator.slipProfileSnapshot = { [models] in models.spellChecker.slipProfile }
        coordinator.learnedHereSnapshot = { [models] appKey in
            models.spellChecker.learnedWords(here: appKey, categories: AppCategories(patches: lockedStore.userPatches))
        }
        coordinator.isEfficiencyPower = { [weak self] in
            guard let self else { return false }
            return self.settings.dynamicPower.enabled && self.powerGate.applied.mode == .efficiency
        }
        coordinator.resetKeyTiming = { keyboard.resetKeyTiming() }
        TypingSampleLog.recordKeys = { keyboard.setRecordsSampleKeys($0) }
        TypingSampleLog.drainKeys = { keyboard.drainSampleKeys() }

        writeForMe = WriteForMeController(
            coordinator: coordinator, router: router, models: models, policies: resolver, inserter: inserter,
            learning: learning,
            pauseFocus: { focus.pause(.writePanelOpen) }, resumeFocus: { focus.resume(.writePanelOpen) },
            downloadModel: { [weak self] in
                guard let self else { return }
                startDownload(ModelController.writeCatalogFileName)
                settingsController().showModelsPane()
            },
            setWritingModel: { [weak self] in
                guard let self else { return }
                update { $0.useWritingModel = true }
                modelsPane.scrollTo = .writing
                settingsController().showModelsPane()
            },
            selectAroundCaret: { field, backward, forward, expected in
                switch await focus.selectAroundCaret(field: field, backward: backward, forward: forward,
                                                     expected: expected) {
                case .success: nil
                case .failure(let why): why.rawValue
                }
            },
            readWider: { field, limits in await focus.read(field: field, limits: limits) })

        replies = SuggestedRepliesController(
            coordinator: coordinator, router: router, models: models, screen: screen, inserter: inserter,
            settings: {
                var current = store.current()
                if flags.paused { current.enabled = false }
                return current
            },
            setReplyKeys: { [keyboard] shown, highlighted, arrows in
                keyboard.setReplyKeys(shown: shown, highlighted: highlighted, arrows: arrows)
            })
        coordinator.replies = replies
        replies?.learning = learning
        screen?.onSent = { [weak learning] text, context, screenText in
            learning?.noteSent(text, context: context, screen: screenText)
        }

        let dictationFixes = DictationFixStore(url: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hunch/dictation-fixes.json"))
        DictationPaneState.shared.attach(dictationFixes)
        dictation = DictationController(
            coordinator: coordinator, router: router, models: models, inserter: inserter, learning: learning,
            fixes: dictationFixes,
            // Dynamic Power Mode picks the speech model; it is read when a dictation starts, so a
            // change never lands mid-recording.
            settings: { [weak self] in
                var current = store.current()
                if let self, let pick = self.dynamicSpeechModel { current.dictation.speechModel = pick }
                return current
            },
            openSettings: { [weak self] in self?.settingsController().showSpeechModels() },
            boost: { [weak self] dictated in self?.writeForMe?.start(boosting: dictated) },
            voice: DictationController.VoiceHooks(
                panelOpen: { [weak self] in self?.writeForMe?.isOpen ?? false },
                writeBusy: { [weak self] in self?.writeForMe?.isBusy ?? false },
                deliver: { [weak self] text, target in
                    guard let writeForMe = self?.writeForMe else { return .refuse(.off) }
                    switch target {
                    case .panel: return writeForMe.refineByVoice(text)
                    case .field: return await writeForMe.startVoice(instruction: text)
                    }
                }))
        dictation?.apply(settings)
        DictationPaneState.shared.shortcutRefused = dictation?.isShortcutRefused ?? false
        DictationPaneState.shared.voiceShortcutProblem = dictation?.voiceShortcutProblem

        configureModelsPane()
        buildMenu()
        statusItem?.button?.image = MenuBarIcon.image(settings.menuBarIcon)
        AppIcon.apply(settings.appIcon)
        snapshotSettingsIfRequested()
        models.onChange = { [weak self] in self?.modelsChanged() }
        presenter.appearance = settings.appearance
        router.apply(settings: settings)
        router.onAvailabilityChange = { [weak self] in self?.refreshMenu() }
        models.hasLocalOverride = { [policyStore] in
            policyStore?.userPatches.values.contains { $0.engineOverride == .local } ?? false
        }
        models.start(settings: settings)
        applied = settings
        loadMonitor.modelLoaded = { [models] in
            switch models.status {
            case .ready, .loading: true
            default: false
            }
        }
        loadMonitor.onChange = { [weak self] _ in self?.evaluatePower() }
        dynamicPowerChanged()

        // Edits to settings.json made outside the app (an editor, a script) arrive through
        // `changes()` like any other change.
        let changes = store.changes()
        settingsTask = Task { [weak self] in
            for await next in changes { self?.apply(next) }
        }
        store.startWatching()

        startServicesIfPermitted()
        if !servicesStarted {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.startServicesIfPermitted() }
            }
        }
        snapshotSettingsIfAsked()
        welcomeTourObserver = NotificationCenter.default.addObserver(
            forName: .showWelcomeTour, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showWelcomeTour() }
        }
        // Even before permissions are granted: the tour is where they get granted.
        if OnboardingFlow.needsTour(completedVersion: settings.onboardingCompletedVersion) {
            onboardingController().show()
        }
        snapshotOnboardingIfRequested()
    }

    /// Developer aid: `HUNCH_SETTINGS_SNAPSHOT=/path/to.png` opens Settings and writes an image of
    /// the window shortly after launch (the pane shown is the last one selected).
    private func snapshotSettingsIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["HUNCH_SETTINGS_SNAPSHOT"] else { return }
        let controller = settingsController()
        controller.show()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let view = controller.window?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Saves learned vocabulary before quitting (the store debounces writes).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never hold up quitting for long: a Keychain prompt or a slow disk must not hang it.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        let learning = self.learning
        let host = models.host
        Task {
            await learning?.flush()
            // Free the model (and its Metal buffers) before exit: llama.cpp's Metal device asserts
            // during process teardown if residency sets are still registered.
            await host.unload()
            reply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { reply() } }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.stop()
        inserter.restorePendingClipboard()
        focus?.stop()
        streamTasks.forEach { $0.cancel() }
        settingsTask?.cancel()
        store.stopWatching()
        // Everything is saved by now (settings are written synchronously; learning was flushed in
        // applicationShouldTerminate). Skip C++ static teardown, which can abort inside ggml-metal
        // if a model is still mapped (e.g. the 2 s quit cap expired before unloading finished).
        _exit(0)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        models.rescan()
    }

    // MARK: Settings

    /// Reacts to every settings change, whoever made it (Settings window, menu, shortcuts, file).
    private func apply(_ next: HunchSettings) {
        guard let old = applied else { return }
        applied = next
        guard old != next else { return }
        learning?.settingsChanged(next)
        SuggestedRepliesStatus.shared.blockedReason = replies?.blockedReason(next)
        if !next.enabled || !next.suggestedRepliesEnabled { replies?.focusEnded() }
        presenter.appearance = next.appearance
        if old.menuBarIcon != next.menuBarIcon { statusItem?.button?.image = MenuBarIcon.image(next.menuBarIcon) }
        if old.appIcon != next.appIcon { AppIcon.apply(next.appIcon) }
        if old.dictation != next.dictation || old.experimentalVoiceInstructions != next.experimentalVoiceInstructions
            || old.voiceInstruction != next.voiceInstruction || old.bindings != next.bindings {
            dictation?.apply(next)
            DictationPaneState.shared.shortcutRefused = dictation?.isShortcutRefused ?? false
            DictationPaneState.shared.voiceShortcutProblem = dictation?.voiceShortcutProblem
            modelsPane.speechSelected = next.dictation.speechModel
        }
        flags.enabled = next.enabled && pausedUntil == nil
        flags.debug = next.debugLogging
        PromptDebugLog.isEnabled = next.debugLogging
        AlignmentCheckLog.isEnabled = next.debugLogging
        flags.windowTitle = next.windowTitleContextEnabled
        if old.bindings != next.bindings {
            arbiter.setBindings(next.bindings)
            keyboard.bindingsDidChange()
        }
        resolver.setCompletionsEnabledByDefault(next.completionsEnabledByDefault)
        resolver.setMidLineByDefault(next.midLineByDefault)
        resolver.setAutocorrectByDefault(next.autocorrectEnabled)
        resolver.setAutocorrectStrengthByDefault(next.autocorrectStrength)
        resolver.setEmojiByDefault(next.emoji.enabled)
        // Every category's source and endpoint (unchanged slots are left alone).
        router.apply(settings: next)
        models.apply(settings: next)
        if old.dynamicPower != next.dynamicPower || old.engine != next.engine { dynamicPowerChanged() }
        if old.modelsFolderPath != next.modelsFolderPath, let path = next.modelsFolderPath,
           path != selfWrittenFolderPath, path != models.availableFolderPath {
            chooseFolder(URL(fileURLWithPath: path, isDirectory: true), updateSettings: false)
        }
        if !next.screenContextEnabled || !next.enabled { screen.clear() }
        refreshMenu()
        refreshModelsPane()
    }

    private func update(_ mutate: @escaping @Sendable (inout HunchSettings) -> Void) {
        try? store.update(mutate)
    }

    // MARK: Models

    private func configureModelsPane() {
        modelsPane.selectModel = { [weak self] id in self?.selectModel(id) }
        modelsPane.selectWriteModel = { [weak self] id in
            self?.update { $0.writeModel = id }
        }
        modelsPane.setUseWritingModel = { [weak self] on in
            self?.update { $0.useWritingModel = on }
        }
        modelsPane.rescan = { [weak self] in self?.models.rescan() }
        modelsPane.download = { [weak self] fileName in self?.startDownload(fileName) }
        modelsPane.cancelDownload = { [weak self] fileName in self?.downloads.cancel(fileName) }
        modelsPane.downloadPicked = { [weak self] repo, file, use in
            self?.withModelsFolder { [weak self] root in
                guard let self else { return }
                // Remembered now so the file lists in this category once it lands.
                let name = file.fileName
                update { Self.add(&$0.addedModels, path: name, use: use) }
                downloads.start(picked: .huggingFace(repo: repo, file: file, use: use), in: root)
            }
        }
        modelsPane.removeAdded = { [weak self] id in
            self?.update { $0.addedModels.removeAll { $0.path == id.relativePath } }
        }
        downloads.onChange = { [weak self] in self?.refreshCatalogRows() }
        downloads.onCompleted = { [weak self] id in
            guard let self else { return }
            // A whisper model is dictation's, never the Language Model.
            if ModelCatalog.entry(forFileName: id.relativePath)?.use == .speechToText {
                if settings.dictation.speechModel == nil {
                    let name = id.relativePath
                    update { $0.dictation.speechModel = name }
                }
                refreshCatalogRows()
                return
            }
            if models.downloadCompleted(id) { selectModel(id) }
        }
        modelsPane.speechSelected = settings.dictation.speechModel
        modelsPane.selectSpeechModel = { [weak self] name in self?.update { $0.dictation.speechModel = name } }
        refreshModelsPane()
    }

    /// Adds or re-files a model in `added` under `use` (one entry per path).
    nonisolated static func add(_ added: inout [AddedModel], path: String, use: ModelUse) {
        added.removeAll { $0.path == path }
        added.append(AddedModel(path: path, use: use.rawValue))
    }

    /// "Add a model file…": keeps the file where it is (by absolute path; a file already inside the
    /// folder by its folder path) or copies it into the folder first. Either way it lists in `use`.
    private func addModelFile(_ url: URL, use: ModelUse, copy: Bool) {
        withModelsFolder { [weak self] root in self?.addModelFile(url, use: use, copy: copy, root: root) }
    }

    private func addModelFile(_ url: URL, use: ModelUse, copy: Bool, root: URL) {
        let file = url.standardizedFileURL
        let rootPrefix = root.standardizedFileURL.path + "/"
        if file.path.hasPrefix(rootPrefix) {
            let relative = String(file.path.dropFirst(rootPrefix.count))
            update { Self.add(&$0.addedModels, path: relative, use: use) }
            modelsPane.addMessage = nil
            return
        }
        guard copy else {
            let path = file.path
            update { Self.add(&$0.addedModels, path: path, use: use) }
            modelsPane.addMessage = nil
            return
        }
        let name = file.lastPathComponent
        let target = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            modelsPane.addMessage = "The models folder already has a file named \(name)."
            return
        }
        modelsPane.addMessage = "Copying \(name) to the models folder…"
        Task {
            // Copied under a .part name (the scan lists only .gguf), then renamed when complete.
            let part = DownloadPlan.partURL(for: name, in: root)
            let error: String? = await Task.detached {
                let fm = FileManager.default
                do {
                    try? fm.removeItem(at: part)
                    try fm.copyItem(at: file, to: part)
                    try fm.moveItem(at: part, to: target)
                    return nil
                } catch {
                    try? fm.removeItem(at: part)
                    return error.localizedDescription
                }
            }.value
            if let error {
                modelsPane.addMessage = "Couldn't copy \(name): \(error)"
            } else {
                modelsPane.addMessage = nil
                update { Self.add(&$0.addedModels, path: name, use: use) }
                models.rescan()
            }
        }
    }

    /// Downloads go into the models folder (the default one when none was ever chosen); the button
    /// is disabled while a chosen folder is unavailable.
    private func startDownload(_ fileName: String) {
        withModelsFolder { [weak self] root in self?.downloads.start(fileName, in: root) }
    }

    /// Where models go when no folder was ever chosen.
    static var defaultModelsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/Hunch", isDirectory: true)
    }

    /// Runs `work` with the models folder. With none chosen yet, creates `defaultModelsFolder`, makes
    /// it the models folder, then runs it. A chosen folder that is offline or missing never falls
    /// back (the work is dropped, and its buttons are disabled), so models don't land somewhere else.
    private func withModelsFolder(_ work: @escaping (URL) -> Void) {
        switch models.snapshot.state {
        case .available(let root):
            work(root)
        case .notConfigured:
            if waitingForDefaultFolder != nil {
                waitingForDefaultFolder?.append(work)
                return
            }
            let url = Self.defaultModelsFolder
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                modelsPane.folderStateText = "Couldn\u{2019}t create \((url.path as NSString).abbreviatingWithTildeInPath): "
                    + error.localizedDescription
                return
            }
            waitingForDefaultFolder = [work]
            choosingFolder += 1
            Task {
                defer { choosingFolder -= 1 }
                do {
                    try await models.choose(folder: url)
                    if let path = models.availableFolderPath {
                        selfWrittenFolderPath = path
                        update { $0.modelsFolderPath = path }
                    }
                } catch {
                    modelsPane.folderStateText = "Couldn\u{2019}t use \((url.path as NSString).abbreviatingWithTildeInPath): \(Self.describe(error))"
                }
                // Everything asked for while the folder was being set up.
                let waiting = waitingForDefaultFolder ?? []
                waitingForDefaultFolder = nil
                guard case .available(let root) = models.snapshot.state else { return }
                waiting.forEach { $0(root) }
            }
        default:
            return
        }
    }

    private func refreshCatalogRows() {
        let snapshot = models.snapshot
        let root: URL? = if case .available(let url) = snapshot.state { url } else { nil }
        modelsPane.catalog = downloads.paneRows(models: snapshot.models, folder: root)
        // With no folder chosen yet, a download adopts the default one (`withModelsFolder`).
        if case .notConfigured = snapshot.state { modelsPane.canDownload = true } else { modelsPane.canDownload = root != nil }
        modelsPane.downloadStates = downloads.paneStates
    }

    private func selectModel(_ id: ModelEntryID) {
        update { $0.activeModel = id }
        models.apply(settings: settings)
        models.userSelectedModel()
    }

    private func chooseFolder(_ url: URL, updateSettings: Bool) {
        choosingFolder += 1
        Task {
            defer { choosingFolder -= 1 }
            do {
                try await models.choose(folder: url)
                if updateSettings, let path = models.availableFolderPath {
                    selfWrittenFolderPath = path
                    update { $0.modelsFolderPath = path }
                }
            } catch {
                modelsPane.folderStateText = "Couldn't use that folder: \(Self.describe(error))"
            }
        }
    }

    private func modelsChanged() {
        // Keep the settings path in step when the manager followed a rename or move.
        if choosingFolder == 0, let path = models.availableFolderPath, path != settings.modelsFolderPath {
            selfWrittenFolderPath = path
            update { $0.modelsFolderPath = path }
        }
        switchToInstructOnceIfPending()
        loadMonitor.modelStateChanged()
        refreshMenu()
        refreshModelsPane()
    }

    // MARK: Dynamic Power Mode

    /// Dynamic Power Mode applies to the Language Model only while it runs locally.
    private var dynamicLanguageActive: Bool { settings.dynamicPower.enabled && settings.engine == .local }

    /// Turned on or off, or a threshold, signal or Efficiency model changed.
    private func dynamicPowerChanged() {
        let dynamic = settings.dynamicPower
        if dynamic.enabled {
            loadMonitor.start(gpu: dynamic.useGPU)
            evaluatePower()
        } else {
            loadMonitor.stop()
            powerTimer?.invalidate()
            powerTimer = nil
            powerGate = PowerGate()
            models.clearDynamic()
        }
        refreshMenu()
        refreshModelsPane()
    }

    /// A new reading (or new settings): through the gate, then to the models.
    private func evaluatePower() {
        guard settings.dynamicPower.enabled else { return }
        let reading = DynamicPower.reading(loadMonitor.load, settings: settings.dynamicPower)
        handlePower(powerGate.observe(reading, now: ProcessInfo.processInfo.systemUptime))
        // The Efficiency model may have changed without the mode changing.
        applyPowerMode()
    }

    private func handlePower(_ decision: PowerGate.Decision) {
        switch decision {
        case .none:
            break
        case .apply:
            powerTimer?.invalidate()
            powerTimer = nil
            applyPowerMode()
        case .wait(let until):
            powerTimer?.invalidate()
            let t = Timer(timeInterval: max(0, until - ProcessInfo.processInfo.systemUptime), repeats: false) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.powerTimer = nil
                    self.handlePower(self.powerGate.fire(now: ProcessInfo.processInfo.systemUptime))
                }
            }
            RunLoop.main.add(t, forMode: .common)
            powerTimer = t
        }
    }

    private func applyPowerMode() {
        guard settings.dynamicPower.enabled else { return }
        if dynamicLanguageActive {
            models.setDynamic(mode: powerGate.applied.mode, efficiency: settings.dynamicPower.languageEfficiencyModel)
        } else {
            models.clearDynamic()
        }
        refreshMenu()
        refreshModelsPane()
    }

    /// Downloaded speech models with their sizes.
    private var downloadedSpeechModels: [(id: String, size: Int64)] {
        (modelsPane.catalog[.speechToText] ?? []).filter { $0.state == .downloaded }.map { ($0.id, $0.byteSize) }
    }

    /// The speech model Dynamic Power Mode picks; nil while it is off (dictation uses the hand pick).
    private var dynamicSpeechModel: String? {
        guard settings.dynamicPower.enabled, let top = modelsPane.effectiveSpeechModel else { return nil }
        return DynamicPower.pick(mode: powerGate.applied.mode, performance: top,
                                 efficiencyChoice: settings.dynamicPower.speechEfficiencyModel,
                                 available: downloadedSpeechModels)
    }

    /// Settings from before the Language Model: once the folder is available, a base Language Model
    /// switches to an instruct model in the folder (if any). Either way it happens only once.
    private func switchToInstructOnceIfPending() {
        guard settings.instructSwitchPending, models.availableFolderPath != nil, !models.snapshot.models.isEmpty
        else { return }
        let target = models.instructSwitchTarget()
        update { $0.instructSwitchPending = false }
        if let target { selectModel(target) }
    }

    private func refreshModelsPane() {
        let snapshot = models.snapshot
        modelsPane.folderPath = Self.folderPath(of: snapshot.state) ?? settings.modelsFolderPath
        modelsPane.folderStateText = modelStatusText
        // The pick for this Mac (the Language Model and the writing model share the instruct
        // catalog), matched to the folder's files by name.
        let picks = Set([ModelController.recommendedFileName(.writing)?.lowercased()].compactMap { $0 })
        let addedPaths = Set(settings.addedModels.map(\.path))
        modelsPane.rows = snapshot.models.map { entry in
            let path = entry.id.relativePath as NSString
            let file = path.lastPathComponent.lowercased()
            // A file added from outside the folder shows its name, with its folder underneath.
            let outside = entry.id.isOutsideFolder
            return ModelRow(id: entry.id, name: outside ? path.lastPathComponent : entry.id.relativePath,
                            detail: Self.detail(for: entry), usable: entry.validity == .valid,
                            use: models.isInstruct(entry) ? .writing : .autocomplete,
                            isRecommended: picks.contains(file),
                            location: outside ? path.deletingLastPathComponent : nil,
                            addedByUser: addedPaths.contains(entry.id.relativePath), byteSize: entry.byteSize)
        }
        modelsPane.languageModelIsBase = models.languageModelIsBase
        SuggestedRepliesStatus.shared.blockedReason = replies?.blockedReason(settings)
        // With Dynamic Power Mode, the hand pick stays checked (greyed); the pick shows above it.
        modelsPane.selected = dynamicLanguageActive
            ? (models.handPickedEntry()?.id ?? settings.activeModel)
            : (models.activeEntry?.id ?? settings.activeModel)
        modelsPane.dynamicLanguageActive = dynamicLanguageActive
        modelsPane.dynamicLanguageModel = dynamicLanguageActive ? models.activeEntry?.id : nil
        modelsPane.dynamicLanguageOptions = models.dynamicCandidates().map(\.id)
        modelsPane.dynamicLanguageEfficiency = DynamicPower.efficiencyModel(
            chosen: settings.dynamicPower.languageEfficiencyModel.map(ModelEntryID.init(relativePath:)),
            available: models.dynamicCandidates().map { ($0.id, $0.byteSize) })
        modelsPane.dynamicSpeechEfficiency = DynamicPower.efficiencyModel(
            chosen: settings.dynamicPower.speechEfficiencyModel, available: downloadedSpeechModels)
        modelsPane.dynamicSpeechModel = dynamicSpeechModel
        modelsPane.dynamicReason = settings.dynamicPower.enabled ? powerGate.applied.reason : nil
        modelsPane.writeSelected = models.instructEntry()?.id
        modelsPane.useWritingModel = settings.useWritingModel
        refreshCatalogRows()
        modelsPane.folderConfigured = snapshot.state != .notConfigured
    }

    private static func folderPath(of state: FolderState) -> String? {
        switch state {
        case .notConfigured: nil
        case .available(let url), .permissionDenied(let url), .notADirectory(let url): url.path
        case .volumeOffline(_, let path), .missing(let path): path
        }
    }

    private static func detail(for entry: ModelEntry) -> String {
        let size = ByteCountFormatter.string(fromByteCount: entry.byteSize, countStyle: .file)
        guard entry.validity == .valid else { return "\(size) · \(reason(entry.validity))" }
        let parts = [entry.summary?.architecture, entry.summary?.sizeLabel, size].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    static func reason(_ validity: GGUFValidity) -> String {
        switch validity {
        case .valid: "usable"
        case .notGGUF: "not a GGUF model (unrecognized header)"
        case .unsupportedVersion(let v): "unsupported GGUF version \(v)"
        case .truncated: "file is truncated"
        case .malformedMetadata: "damaged metadata"
        case .splitPart(let index, let count): "part \(index) of \(count) of a split model (parts missing)"
        case .auxiliary(let kind): "\(kind), not a language model"
        case .unreadable: "can't be read"
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? ModelsFolderError {
        case .notADirectory: "it isn't a folder."
        case .doesNotExist: "it doesn't exist."
        case .notReadable: "Hunch can't read it."
        case .bookmarkFailed: "macOS couldn't remember it."
        case nil: error.localizedDescription
        }
    }

    private var modelStatusText: String {
        switch models.status {
        case .noFolder: "Choose a models folder"
        case .volumeOffline(let name): name.map { "Drive “\($0)” not connected" } ?? "Models drive not connected"
        case .folderMissing: "Models folder moved or deleted"
        case .permissionDenied(let path): "Hunch can't read \((path as NSString).lastPathComponent)"
        case .notADirectory: "The models location isn't a folder"
        case .noUsableModel(let folder): "No usable models in \((folder as NSString).lastPathComponent)"
        case .unloaded: "Model unloaded"
        case .loading(let name): "Loading \(name)…"
        case .ready(let name): "Model: \(name)"
        case .idle(let name): "Model: \(name) (idle, reloads when you type)"
        case .failed(let message): "Couldn't load the model: \(message)"
        }
    }

    // MARK: Services

    private var permissionsGranted: Bool { AXIsProcessTrusted() && CGPreflightListenEventAccess() }

    private func startServicesIfPermitted() {
        refreshMenu()
        guard !servicesStarted, permissionsGranted else { return }
        do {
            try keyboard.start(arbiter: arbiter)
        } catch {
            serviceProblem = "Keyboard monitor failed: \(error)"
            refreshMenu()
            return
        }
        focus.start(gate: gate, policies: resolver)
        servicesStarted = true
        permissionTimer?.invalidate()
        permissionTimer = nil

        let coordinator = self.coordinator!
        let focusEvents = focus.events()
        let typing = keyboard.events()
        let commands = keyboard.commands()
        streamTasks = [
            Task { @MainActor [weak self] in
                for await event in focusEvents {
                    coordinator.handle(event)
                    self?.dictation?.noteFocus(event)
                }
            },
            Task { @MainActor [weak self] in
                for await event in typing {
                    coordinator.handle(event)
                    self?.dictation?.noteTyping(event)
                }
            },
            Task { @MainActor [weak self] in for await command in commands { self?.handle(command) } },
        ]
        refreshMenu()
    }

    /// Called on every blocked focus (clicks on non-text elements too): refreshes the menu only
    /// when the Secure Input state it shows changed.
    private func noteBlocked(_ reason: BlockReason) {
        var blocked = false
        var ownerPID: pid_t?
        if case .secureEventInput(let owner) = reason {
            blocked = true
            ownerPID = owner
        }
        guard blocked != secureInputBlocked || ownerPID != secureInputOwnerPID else { return }
        secureInputBlocked = blocked
        secureInputOwnerPID = ownerPID
        refreshMenu()
        runPendingURLs()
    }

    private func handle(_ command: InputCommand) {
        switch command {
        case .escapeDismissed:
            let suggestion = coordinator.showsSuggestion
            coordinator.dismissFromEscape()
            if suggestion, settings.escapeBehavior == .dismissUntilAppSwitch,
               let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                turnOffUntilAppSwitch(bundleID)
            }
        case .shortcut(.forceActivate):
            coordinator.forceActivate()
        case .shortcut(.toggleCurrentApp):
            guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else { return }
            let enabled = resolver.resolve(bundleID: bundleID, urlHost: nil).policy.enabled
            resolver.setTemporaryOverride(bundleID: bundleID, enabled: !enabled, until: Date().addingTimeInterval(300))
        case .shortcut(.toggleGlobal):
            setEnabled(!isOn)
        case .shortcut(.writeForMe):
            // While the pill offers Boost, the shortcut polishes what was just dictated.
            writeForMe?.start(boosting: dictation?.takeBoostOffer())
        case .shortcut(.catchUp):
            coordinator.catchUpMissedFix()
        case .shortcut(.revertFix):
            coordinator.revertNewestFix()
        case .undoAutoFix:
            coordinator.undoAutoFix()
        case .cycleAlternative(let forward):
            coordinator.cycleAlternative(forward: forward)
        case .switchStyle(let forward):
            coordinator.switchStyle(forward: forward)
        case .reply(let key):
            replies?.handle(key)
        }
    }

    /// Autocorrect catch-up and "Apply Corrections Automatically", wired to the focus tracker (checked selections
    /// and reads), the keyboard monitor (holding keys, the shortcut, Backspace undo) and the overlay.
    private func makeAutocorrectFollowUp(focus: AXFocusTracker, learning: LearningController) -> AutocorrectFollowUp {
        func step(_ failure: CaretSelection.Failure) -> AutocorrectFollowUp.AXStepFailure {
            switch failure {
            case .mismatch: .textDiffers
            case .focusMoved: .gone
            default: .refused
            }
        }
        let keyboard = self.keyboard, inserter = self.inserter, wordFlash = self.wordFlash, store = self.store
        var hooks = AutocorrectFollowUp.Hooks()
        hooks.setCatchUpWaiting = { keyboard.setCatchUpWaiting($0) }
        hooks.armBackspaceUndo = { keyboard.armBackspaceUndo($0) }
        hooks.holdKeys = { keyboard.holdKeys() }
        hooks.releaseHeldKeys = { keyboard.releaseHeldKeys() }
        hooks.isHoldingKeys = { keyboard.isHoldingKeys }
        hooks.readNow = { field in await focus.read(field: field, limits: ContextLimits(), timeout: .milliseconds(300)) }
        hooks.selectBehindCaret = { field, span, word in
            let result = await focus.selectBehindCaret(field: field, expectedSpan: span, expectedWord: word)
            if case .failure(let failure) = result { SuggestionCoordinator.perf("autocorrect select: \(failure.rawValue)") }
            return result.mapError(step)
        }
        hooks.placeCaret = { field, location, expected, back, length in
            (await focus.placeCaret(field: field, location: location, expectedBefore: expected,
                                    highlightStartBack: back, highlightUTF16: length)).mapError(step)
        }
        hooks.boundsBehindCaret = { field, back, length in await focus.boundsBehindCaret(field: field, back: back, length: length) }
        hooks.pressKey = { key, shift, app in
            let ok = inserter.pressKey(key, shift: shift, into: app)
            if !ok {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
                SuggestionCoordinator.perf("autocorrect key refused: secureInput=\(IsSecureEventInputEnabled()) "
                                           + "frontmost=\(front) target=\(app.bundleID)")
            }
            return ok
        }
        hooks.flash = { wordFlash.flash($0) }
        let fixMarks = self.fixMarks
        hooks.setRevertWaiting = { keyboard.setRevertWaiting($0) }
        hooks.showFixMarks = { fixMarks.show($0) }
        // Keys typed into the menu itself are seen by the monitor too: they don't close it.
        hooks.dismissFixOffer = { if fixMarks.isOffering, !fixMarks.isEditing { fixMarks.dismissOffer() } }
        hooks.ensureFrontmost = { app in
            func front() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            if front() == app.pid { return true }
            SuggestionCoordinator.perf("autocorrect revert: frontmost is "
                + "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"), activating \(app.bundleID)")
            NSRunningApplication(processIdentifier: app.pid)?.activate()
            let deadline = ContinuousClock.now + .milliseconds(800)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
                if front() == app.pid { return true }
            }
            return false
        }
        hooks.wordBounds = { field, textToCaret, word in
            await focus.wordBoundsBehindCaret(field: field, textToCaret: textToCaret, word: word)
        }
        hooks.moveCaretForward = { field, forward, expected in
            if case .success = await focus.moveCaretForward(field: field, forward: forward, expectedBefore: expected) {
                return true
            }
            return false
        }
        var menuHadKeyboard = false
        fixMarks.choicesFor = { [weak self] id in self?.coordinator.fixChoices(id: id) }
        fixMarks.onMenuKeyboard = { focus.setLendingFocus($0) }
        fixMarks.onMenuClosed = {
            // The menu took the keyboard without activating Hunch: hand it back to the host.
            menuHadKeyboard = true
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                front.activate()
            }
        }
        fixMarks.onChoose = { [weak self] id, word in
            self?.coordinator.changeMarkedFix(id: id, to: word, settle: menuHadKeyboard)
            menuHadKeyboard = false
        }
        return AutocorrectFollowUp(hooks: hooks, inserter: inserter, learning: learning, settings: { store.current() })
    }

    /// Esc set to "turn off until I switch apps": suggestions stay off in this app until another
    /// app comes to the front (a temporary override, cleared on the next activation).
    private func turnOffUntilAppSwitch(_ bundleID: String) {
        if let previous = offUntilSwitch, previous != bundleID { resolver.clearTemporaryOverride(bundleID: previous) }
        offUntilSwitch = bundleID
        resolver.setTemporaryOverride(bundleID: bundleID, enabled: false, until: .distantFuture)
        guard appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let off = self.offUntilSwitch, activated != off else { return }
                self.resolver.clearTemporaryOverride(bundleID: off)
                self.offUntilSwitch = nil
            }
        }
    }

    /// On or Off (persisted); either one cancels a pause.
    private func setEnabled(_ on: Bool) {
        clearPause()
        flags.enabled = on
        update { $0.enabled = on }
        refreshMenu()
    }

    /// Suggestions off for a while, then back on by themselves; `settings.enabled` is untouched.
    private func pause(for seconds: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(seconds)
        pauseSeconds = seconds
        flags.paused = true
        flags.enabled = false
        screen?.clear()
        if pauseTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pauseTimer = timer
        }
        if !settings.enabled { update { $0.enabled = true } }
        refreshMenu()
    }

    private func clearPause() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pausedUntil = nil
        pauseSeconds = nil
        flags.paused = false
        flags.enabled = settings.enabled
    }

    private func pauseTick() {
        guard let until = pausedUntil else { clearPause(); return }
        if until <= Date() {
            clearPause()
        }
        refreshMenu()
    }

    private var isOn: Bool { settings.enabled && pausedUntil == nil }

    static func resumeTitle(remaining: TimeInterval) -> String {
        let secs = max(1, Int(remaining.rounded(.up)))
        return secs < 60 ? "Resuming in \(secs) s" : "Resuming in \((secs + 59) / 60) min"
    }

    // MARK: Settings window

    private func settingsController() -> SettingsWindowController {
        if let settingsWindow { return settingsWindow }
        let controller = SettingsWindowController(store: store, policyStore: policyStore, places: places, models: modelsPane,
                                                  learning: learningPane)
        controller.onPanelWillOpen = { [weak self] in self?.holdOwnPanelPause() }
        controller.onPanelDidClose = { [weak self] in self?.releaseOwnPanelPause() }
        controller.onFolderPicked = { [weak self] url in self?.chooseFolder(url, updateSettings: true) }
        controller.onModelFilePicked = { [weak self] url, use, copy in self?.addModelFile(url, use: use, copy: copy) }
        settingsWindow = controller
        return controller
    }

    private func holdOwnPanelPause() {
        ownPanelHolds += 1
        if ownPanelHolds == 1 { focus.pause(.ownPanelOpen) }
    }

    private func releaseOwnPanelPause() {
        guard ownPanelHolds > 0 else { return }
        ownPanelHolds -= 1
        if ownPanelHolds == 0 { focus.resume(.ownPanelOpen) }
    }

    // MARK: Welcome tour

    private func onboardingController() -> OnboardingWindowController {
        if let onboardingWindow { return onboardingWindow }
        let controller = OnboardingWindowController(store: store, models: modelsPane)
        controller.onPanelWillOpen = { [weak self] in self?.holdOwnPanelPause() }
        controller.onPanelDidClose = { [weak self] in self?.releaseOwnPanelPause() }
        controller.onFolderPicked = { [weak self] url in self?.chooseFolder(url, updateSettings: true) }
        controller.onOpenSettings = { [weak self] in self?.settingsController().show() }
        onboardingWindow = controller
        return controller
    }

    @objc private func showWelcomeTour() {
        onboardingController().show()
    }

    /// Diagnostics: with `HUNCH_ONBOARDING_SNAPSHOT=<path.png>` in the launch environment, opens
    /// the welcome tour (at `HUNCH_ONBOARDING_SNAPSHOT_STEP`, a step name such as `howTo`, when
    /// given) and writes the window's contents to that file. Has no effect otherwise.
    private func snapshotOnboardingIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["HUNCH_ONBOARDING_SNAPSHOT"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let controller = self.onboardingController()
            controller.show()
            if let name = env["HUNCH_ONBOARDING_SNAPSHOT_STEP"],
               let step = OnboardingFlow.Step.allCases.first(where: { "\($0)" == name }) {
                controller.select(step)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let view = controller.window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image()
        let menu = NSMenu()
        menu.delegate = self
        problemItem.isEnabled = false
        problemItem.isHidden = true
        problemSeparator.isHidden = true
        menu.addItem(problemItem)
        predictionsItem.title = "macOS inline predictions are on (may overlap): Open Keyboard Settings…"
        predictionsItem.target = self
        predictionsItem.action = #selector(openKeyboardSettings)
        predictionsItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        predictionsItem.isHidden = true
        menu.addItem(predictionsItem)
        menu.addItem(problemSeparator)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self

        modeMenu.autoenablesItems = false
        for (title, tag) in [("On", ModeTag.on), ("Pause for 1 Minute", .pause(60)),
                             ("Pause for 5 Minutes", .pause(300)), ("Pause for 1 Hour", .pause(3600)),
                             ("Off", .off)] {
            let entry = NSMenuItem(title: title, action: #selector(modeChosen(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = tag.rawValue
            modeMenu.addItem(entry)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        modelsMenu.autoenablesItems = false
        modelItem.submenu = modelsMenu
        menu.addItem(modelItem)
        downloadModelItem.target = self
        downloadModelItem.action = #selector(openModelsSettings)
        downloadModelItem.isHidden = true
        menu.addItem(downloadModelItem)
        speechMenu.autoenablesItems = false
        speechItem.submenu = speechMenu
        menu.addItem(speechItem)
        efficiencyItem.isEnabled = false
        efficiencyItem.isHidden = true
        menu.addItem(efficiencyItem)
        unloadItem.target = self
        unloadItem.action = #selector(unloadModel)
        menu.addItem(.separator())
        pasteDictationItem.target = self
        pasteDictationItem.action = #selector(pasteLastDictation)
        menu.addItem(pasteDictationItem)
        pasteRawItem.target = self
        pasteRawItem.action = #selector(pasteLastRawTranscript)
        menu.addItem(pasteRawItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hunch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        refreshMenu()
    }

    /// Tags of the mode submenu items (pause durations are the tag in seconds).
    private enum ModeTag: Int {
        case on = 0, off = -1
        case pause60 = 60, pause300 = 300, pause3600 = 3600
        static func pause(_ seconds: Int) -> ModeTag { ModeTag(rawValue: seconds) ?? .on }
    }

    private func refreshMenu() {
        var problems: [String] = []
        if let serviceProblem { problems.append(serviceProblem) }
        if settings.engine == .endpoint, !router.usesEndpointGlobally, let problem = router.endpointProblem {
            problems.append("Endpoint unusable (\(problem))")
        }
        if router.slot(.autocomplete).unavailable {
            let fallback = models.activeEntry.map { ($0.id.relativePath as NSString).lastPathComponent }
            problems.append(fallback.map { "Endpoint unavailable, using \($0)" }
                            ?? "Endpoint unavailable, and no local model to use instead")
        }
        if let version = store.newerSchemaVersion {
            problems.append("settings.json is from a newer Hunch (v\(version)); changes aren't saved")
        }
        // Focus events don't report Secure Input turning off, so re-check it here.
        if secureInputBlocked, !SecureInputProbe.isSecureEventInputEnabled() {
            secureInputBlocked = false
            secureInputOwnerPID = nil
        }
        if secureInputBlocked {
            problems.append(DiagnosticsWording.secureInputProblem(
                ownerName: secureInputOwnerPID.map(KeyDiagnostics.appName(pid:)),
                ownerBundleID: secureInputOwnerPID.flatMap(KeyDiagnostics.bundleID(pid:))))
        }
        problemItem.title = problems.joined(separator: " · ")
        problemItem.isHidden = problems.isEmpty
        // macOS's own inline predictions: a clickable warning, shown only while they are on.
        let predictions = MacInlinePredictions.isEnabled
        predictionsItem.isHidden = !predictions
        problemSeparator.isHidden = problems.isEmpty && !predictions

        let mode: ModeTag
        if let until = pausedUntil {
            modeItem.title = "Hunch: " + Self.resumeTitle(remaining: until.timeIntervalSinceNow)
            mode = ModeTag(rawValue: Int(pauseSeconds ?? 0)) ?? .on
        } else {
            mode = settings.enabled ? .on : .off
            modeItem.title = settings.enabled ? "Hunch: On" : "Hunch: Off"
        }
        for entry in modeMenu.items { entry.state = entry.tag == mode.rawValue ? .on : .off }

        refreshModelTitle()
        refreshSpeechTitle()
        let reason = settings.dynamicPower.enabled && powerGate.applied.mode == .efficiency
            ? powerGate.applied.reason : nil
        efficiencyItem.title = reason.map { "Efficiency: \($0)" } ?? ""
        efficiencyItem.isHidden = reason == nil
        statusItem?.button?.appearsDisabled = !isOn || !servicesStarted
    }

    private func refreshModelTitle() {
        func base(_ name: String) -> String {
            var file = (name as NSString).lastPathComponent
            if file.lowercased().hasSuffix(".gguf") { file = String(file.dropLast(5)) }
            return file
        }
        var loaded = false
        // Title "Language Model" (or "Dynamic Language Model" while Dynamic Power Mode picks it),
        // with the model name as a small grey line under it.
        var name: String?
        switch models.status {
        case .ready(let n):
            name = base(n)
            loaded = true
        case .idle(let n):
            name = "\(base(n)) (idle)"
        case .loading(let n):
            name = "\(base(n)) (loading)"
        case .unloaded:
            name = (models.activeEntry?.id.relativePath ?? settings.activeModel?.relativePath).map { "\(base($0)) (idle)" }
        default:
            name = nil
        }
        modelItem.title = name != nil && dynamicLanguageActive ? "Dynamic Language Model" : "Language Model"
        modelItem.subtitle = name ?? "none"
        unloadItem.isEnabled = loaded
        let noUsableModel = if case .noUsableModel = models.status { true } else { false }
        downloadModelItem.isHidden = !noUsableModel
    }

    @objc private func modeChosen(_ sender: NSMenuItem) {
        switch ModeTag(rawValue: sender.tag) ?? .on {
        case .on: setEnabled(true)
        case .off: setEnabled(false)
        case .pause60, .pause300, .pause3600: pause(for: TimeInterval(sender.tag))
        }
    }

    private func rebuildModelsMenu() {
        modelsMenu.removeAllItems()
        let snapshot = models.snapshot
        guard case .available = snapshot.state else {
            modelsMenu.addItem(NSMenuItem(title: modelStatusText, action: nil, keyEquivalent: ""))
            addFolderItems()
            return
        }
        if snapshot.models.isEmpty {
            modelsMenu.addItem(NSMenuItem(title: "No .gguf files found", action: nil, keyEquivalent: ""))
        }
        let current = models.activeEntry?.id ?? settings.activeModel
        // Dynamic Power Mode picks: the list is greyed, with a way to turn it off.
        let dynamic = dynamicLanguageActive
        for entry in snapshot.models {
            let usable = entry.validity == .valid
            let title = usable ? entry.id.relativePath : "\(entry.id.relativePath) (\(Self.reason(entry.validity)))"
            let item = NSMenuItem(title: title, action: usable ? #selector(selectModelItem(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.isEnabled = usable && !dynamic
            item.representedObject = entry.id.relativePath
            item.state = current == entry.id ? .on : .off
            modelsMenu.addItem(item)
        }
        if dynamic { addTurnOffDynamicItem(to: modelsMenu) }
        addFolderItems()
    }

    private func addFolderItems() {
        modelsMenu.addItem(.separator())
        modelsMenu.addItem(withTitle: "Rescan Models Folder", action: #selector(rescanModels), keyEquivalent: "").target = self
        modelsMenu.addItem(withTitle: "Choose Models Folder…", action: #selector(chooseModelsFolder), keyEquivalent: "").target = self
        modelsMenu.addItem(unloadItem)
    }

    /// Speech to Text: the downloaded whisper models to pick from, the one dictation uses checked.
    private func rebuildSpeechMenu() {
        speechMenu.removeAllItems()
        let downloaded = (modelsPane.catalog[.speechToText] ?? []).filter { $0.state == .downloaded }
        let dynamic = dynamicSpeechModel
        let current = dynamic ?? modelsPane.effectiveSpeechModel
        refreshSpeechTitle()
        for row in downloaded {
            let item = NSMenuItem(title: row.name, action: #selector(selectSpeechItem(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = dynamic == nil
            item.representedObject = row.id
            item.state = row.id == current ? .on : .off
            speechMenu.addItem(item)
        }
        if downloaded.isEmpty {
            let none = NSMenuItem(title: "No speech models downloaded", action: nil, keyEquivalent: "")
            none.isEnabled = false
            speechMenu.addItem(none)
        }
        if dynamic != nil { addTurnOffDynamicItem(to: speechMenu) }
        speechMenu.addItem(.separator())
        speechMenu.addItem(withTitle: downloaded.isEmpty ? "Download a Speech Model…" : "More Speech Models…",
                           action: #selector(openSpeechModels), keyEquivalent: "").target = self
    }

    /// "Speech to Text" (or "Dynamic Speech to Text" while Dynamic Power Mode picks it), model name under it.
    private func refreshSpeechTitle() {
        let downloaded = (modelsPane.catalog[.speechToText] ?? []).filter { $0.state == .downloaded }
        let dynamic = dynamicSpeechModel
        let current = dynamic ?? modelsPane.effectiveSpeechModel
        let name = downloaded.first { $0.id == current }?.name ?? "none"
        speechItem.title = dynamic != nil && name != "none" ? "Dynamic Speech to Text" : "Speech to Text"
        speechItem.subtitle = name
    }

    private func addTurnOffDynamicItem(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(withTitle: "Turn Off Dynamic Power Mode", action: #selector(turnOffDynamicPower),
                     keyEquivalent: "").target = self
    }

    @objc private func turnOffDynamicPower() {
        update { $0.dynamicPower.enabled = false }
    }

    @objc private func selectSpeechItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        modelsPane.speechSelected = name
        update { $0.dictation.speechModel = name }
    }

    @objc private func openSpeechModels() { settingsController().showSpeechModels() }

    @objc private func selectModelItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        selectModel(ModelEntryID(relativePath: name))
    }

    @objc private func pasteLastDictation() { dictation?.pasteLast(raw: false) }
    @objc private func pasteLastRawTranscript() { dictation?.pasteLast(raw: true) }

    @objc private func unloadModel() {
        Task { await models.unloadNow() }
    }

    @objc private func rescanModels() { models.rescan() }

    @objc private func chooseModelsFolder() {
        let controller = settingsController()
        controller.show()
        controller.pickFolder()
    }

    @objc private func openKeyboardSettings() {
        MacInlinePredictions.openKeyboardSettings()
    }

    @objc private func openSettings() {
        settingsController().show()
    }

    /// Opens Settings → Model; the download itself starts only from the pane's button.
    @objc private func openModelsSettings() {
        settingsController().showModelsPane()
    }

    /// Diagnostics: with `HUNCH_SETTINGS_SNAPSHOT=<path.png>` in the launch environment, opens
    /// Settings and writes the window's contents to that file (works while the screen is locked,
    /// for checking layouts without the user). Has no effect otherwise.
    private func snapshotSettingsIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["HUNCH_SETTINGS_SNAPSHOT"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let controller = self.settingsController()
            controller.show()
            if let id = ProcessInfo.processInfo.environment["HUNCH_SETTINGS_SNAPSHOT_SELECT"] {
                controller.selectPlace(id)
            }
            // `HUNCH_SETTINGS_SNAPSHOT_DELAY` (seconds) waits longer, e.g. to catch a jump link's result.
            let delay = ProcessInfo.processInfo.environment["HUNCH_SETTINGS_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let view = controller.window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: URL scheme

    /// `hunch://` links not yet applied. An LSUIElement app is sent `open urls` right after
    /// launch, often before permissions are checked; links wait here until services start.
    private var pendingURLs: [URL] = []
    private var applyingURLs = false

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        runPendingURLs()
    }

    /// Applies queued links once each, in order. A link arriving while a confirmation is up only
    /// queues; the running loop picks it up next.
    private func runPendingURLs() {
        guard servicesStarted, !applyingURLs else { return }
        applyingURLs = true
        defer { applyingURLs = false }
        while !pendingURLs.isEmpty { perform(pendingURLs.removeFirst()) }
    }

    private func perform(_ url: URL) {
        switch HunchURLCommand.validate(url, siteKey: KnownPlacesStore.siteKey(fromInput:)) {
        case nil: return
        case .failure(let rejection)?: urlNotice("Hunch ignored a link", rejection.message)
        case .success(let command)?: perform(command)
        }
    }

    /// Turning off and pausing while On apply at once. Anything that turns reading back on, and
    /// saved per-app settings, run only after the user confirms (any web page can open the scheme).
    private func perform(_ command: HunchURLCommand.Command) {
        let asks = HunchURLCommand.turnsReadingOn(command, isOn: isOn) { id in
            guard let bundleID = id ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
            return resolver.resolve(bundleID: bundleID, urlHost: nil).policy.enabled
        }
        switch command {
        case .toggle:
            if asks {
                guard confirmURL("Turn Hunch on?", "Hunch will read the text you type in apps again.")
                else { return }
            }
            setEnabled(!isOn)
        case .pause(let minutes):
            if asks {
                guard confirmURL("Pause Hunch and turn it on after \(Self.minutesText(minutes))?",
                                 "Hunch is off now. When the pause ends it will read the text you type again.")
                else { return }
            }
            pause(for: TimeInterval(minutes * 60))
        case .toggleApp(let id, let minutes):
            guard let bundleID = id ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
            let enabled = resolver.resolve(bundleID: bundleID, urlHost: nil).policy.enabled
            if asks {
                guard confirmURL("Turn Hunch on in \(placeName(.app(bundleID: bundleID))) for "
                                 + "\(Self.minutesText(minutes))?",
                                 "Hunch is off in this app now. It will read the text you type there until then.")
                else { return }
            }
            resolver.setTemporaryOverride(bundleID: bundleID, enabled: !enabled,
                                          until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        case .setOverride(var key, let changes):
            if case .category(let name) = key {
                guard let existing = existingCategory(name) else {
                    urlNotice("Hunch ignored a link", "There is no category with that name.")
                    return
                }
                key = .category(name: existing)
            }
            guard confirmURL("Change Hunch settings for \(placeName(key))?",
                             changes.map(\.summary).joined(separator: "\n")) else { return }
            var patch = policyStore.userPatches[key] ?? AppPolicyPatch()
            for change in changes { change.apply(to: &patch) }
            savePatch(patch, for: key)
        case .clearOverride(var key):
            if case .category(let name) = key, let found = existingCategory(name) { key = .category(name: found) }
            guard let existing = policyStore.userPatches[key] else {
                urlNotice("Hunch ignored a link", "\(placeName(key)) has no saved settings to reset.")
                return
            }
            guard confirmURL("Reset Hunch settings for \(placeName(key))?",
                             "Its settings return to built-in. Its category and any secure-field exclusion are kept.")
            else { return }
            savePatch(HunchURLCommand.cleared(existing), for: key)
        case .settings(var request):
            if case .category(let name)? = request.place {
                guard let existing = existingCategory(name) else {
                    urlNotice("Hunch ignored a link", "There is no category with that name.")
                    return
                }
                request.place = .category(name: existing)
            }
            if let anchor = request.setting {
                // A row hidden behind a switch that is off jumps to that switch, like a search result.
                guard let target = SettingsSearch.jumpTarget(anchor, settings: settings) else {
                    urlNotice("Hunch ignored a link", "There is no such setting in Hunch Settings.")
                    return
                }
                request.setting = target
            }
            let controller = settingsController()
            if let pane = request.resolvedPane, !controller.selectPane(pane) {
                urlNotice("Hunch ignored a link", "There is no \"\(pane)\" settings pane.")
                return
            }
            if let place = request.place { controller.selectPlace(place) }
            controller.show()
            if let anchor = request.setting { controller.jump(to: anchor) }
            if let search = request.search { controller.search(search) }
        case .set(let changes):
            let current: (HunchURLCommand.GlobalField) -> HunchURLCommand.OverrideValue = { [settings, isOn] in
                switch $0 {
                case .suggestions: .bool(isOn)
                case .autocorrect: .bool(settings.autocorrectEnabled)
                case .dictation: .bool(settings.dictation.enabled)
                case .autocorrectStrength: .strength(settings.autocorrectStrength)
                }
            }
            if HunchURLCommand.setAsks(changes, current: current) {
                guard confirmURL("Change Hunch settings?", changes.map(\.summary).joined(separator: "\n"))
                else { return }
            }
            for change in changes {
                switch (change.field, change.value) {
                case (.suggestions, .bool(let on)): if on != isOn { setEnabled(on) }
                case (.autocorrect, .bool(let on)): update { $0.autocorrectEnabled = on }
                case (.dictation, .bool(let on)): update { $0.dictation.enabled = on }
                case (.autocorrectStrength, .strength(let s)): update { $0.autocorrectStrength = s }
                default: break  // parse never pairs a field with another field's type
                }
            }
        case .model(let name):
            guard let entry = models.snapshot.models.first(where: {
                $0.validity == .valid
                    && ($0.id.relativePath == name || ($0.id.relativePath as NSString).lastPathComponent == name)
            }) else {
                urlNotice("Hunch ignored a link", "No usable model with that name is in the models folder.")
                return
            }
            selectModel(entry.id)
        }
    }

    /// The category's saved spelling when one by that name exists (names compare like the Apps
    /// pane's: case- and diacritic-insensitively); nil otherwise. A link never creates a category.
    private func existingCategory(_ name: String) -> String? {
        let patches = policyStore.userPatches
        var names = AppCategories(patches: patches).names
        for case .category(let n) in patches.keys { names.append(n) }
        return names.first { AppCategories.same($0, name) }
    }

    /// Writes the patch and lists the place, which also refreshes an open Apps pane.
    private func savePatch(_ patch: AppPolicyPatch?, for key: PolicyKey) {
        do {
            try policyStore.setPatch(patch, for: key)
        } catch {
            urlNotice("Hunch couldn't save the change", error.localizedDescription)
            return
        }
        // A category isn't a place in the list; the Apps pane shows it from its patch.
        if case .category = key { return }
        var name: String?
        if case .app(let id) = key, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        places.add(key, name: name)
    }

    /// "5 minutes", "1 minute".
    static func minutesText(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// "Notes (com.apple.Notes)" for an installed app, the bundle ID or pattern otherwise.
    private func placeName(_ key: PolicyKey) -> String {
        switch key {
        case .app(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return "\(name) (\(id))"
        case .domain(let pattern):
            return pattern
        case .category(let name):
            return name
        }
    }

    /// "Apply" / "Cancel"; true only for Apply. Cancel is the default (Return and Escape): any
    /// web page can open the scheme, so a reflexive Return must never write settings.
    private func confirmURL(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail + "\n\nRequested by a hunch:// link."
        let apply = alert.addButton(withTitle: "Apply")
        let cancel = alert.addButton(withTitle: "Cancel")
        apply.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        // A button has one key equivalent, so Escape is caught here for the alert's lifetime.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window == alert.window else { return event }
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        return runURLAlert(alert) == .alertFirstButtonReturn
    }

    /// When the last rejection notice was shown; see `urlNotice`.
    private var lastURLNotice: Date?

    /// A page opening malformed links in a loop gets one notice; others within 3 s of one being
    /// shown or dismissed are dropped.
    private func urlNotice(_ title: String, _ detail: String) {
        if let last = lastURLNotice, Date().timeIntervalSince(last) < 3 { return }
        lastURLNotice = Date()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        _ = runURLAlert(alert)
        lastURLNotice = Date()
    }

    /// A modal run while focus tracking is live can deadlock (see `SettingsWindowController`), so
    /// tracking pauses like it does for an open panel (one more hold on that pause).
    private func runURLAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        holdOwnPanelPause()
        defer { releaseOwnPanelPause() }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Listed once there is something to paste (kept in memory only).
        pasteDictationItem.isHidden = dictation?.lastText == nil
        pasteRawItem.isHidden = dictation?.lastRaw == nil
        refreshMenu()
        rebuildModelsMenu()
        rebuildSpeechMenu()
        models.rescan()
    }
}

/// Common words searched for long garbled words (`CorrectionFinder.fuzzyCandidates`). Built on first use, which
/// launch triggers off the main thread.
let autocorrectLexicon = FuzzyLexicon(words: CommonEnglish.lexiconWords())
