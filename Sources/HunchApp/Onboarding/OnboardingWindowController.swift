import AppKit
import HunchCore
import SwiftUI

/// The welcome tour window (SwiftUI hosted in AppKit). Closing it, or "Skip tour", leaves the tour
/// unfinished so it opens again at the next launch; only Finish records it.
///
/// Like Settings, the open window doesn't pause Hunch (its own windows are skipped anyway), so
/// suggestions keep working in other apps during the tour. The folder picker follows
/// `SettingsWindowController`: a sheet on this window, with `onPanelWillOpen`/`onPanelDidClose`
/// around it.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    /// Called just before the open panel is shown.
    var onPanelWillOpen: () -> Void = {}
    /// Called after the panel closes, whatever the result.
    var onPanelDidClose: () -> Void = {}
    /// Called with the folder the user picked on the first page.
    var onFolderPicked: (URL) -> Void = { _ in }
    /// "Open Settings" on the last step.
    var onOpenSettings: () -> Void = {}

    private let store: any SettingsStoring
    private let model: OnboardingModel
    /// True while the folder panel is on screen; a second request is ignored.
    private(set) var panelOpen = false

    init(store: any SettingsStoring, models: ModelsPaneModel) {
        self.store = store
        self.model = OnboardingModel(permissions: PermissionsModel(), models: models,
                                     settings: SettingsModel(store: store))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Welcome to Hunch"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        model.chooseFolder = { [weak self] in self?.pickFolder() }
        model.openSettings = { [weak self] in self?.onOpenSettings() }
        model.skip = { [weak self] in self?.close() }
        model.finish = { [weak self] in self?.finish() }
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Brings the tour up; a closed tour starts again at Welcome, an open one keeps its step.
    func show() {
        if window?.isVisible != true {
            model.step = .welcome
            window?.center()
        }
        model.permissions.startPolling()
        showWindow(nil)
        // As for Settings: a menu-bar app isn't always granted activation by the cooperative call.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Diagnostics: shows a given step (the snapshot hook).
    func select(_ step: OnboardingFlow.Step) { model.step = step }

    func windowWillClose(_ notification: Notification) {
        model.permissions.stopPolling()
    }

    private func finish() {
        try? store.update { $0.onboardingCompletedVersion = OnboardingFlow.currentVersion }
        close()
    }

    /// The same panel as Settings → Model → Choose Folder…, as a sheet on this window. Every
    /// `onPanelWillOpen` is paired with exactly one `onPanelDidClose`, even if this controller
    /// goes away first.
    func pickFolder() {
        guard !panelOpen else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your .gguf models."
        let picked = onFolderPicked
        // Captured now so the resume and the result are delivered even without `self`.
        let didClose = onPanelDidClose
        panelOpen = true
        onPanelWillOpen()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            self?.panelOpen = false
            didClose()
            if response == .OK, let url = panel?.urls.first {
                picked(url)
            }
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
