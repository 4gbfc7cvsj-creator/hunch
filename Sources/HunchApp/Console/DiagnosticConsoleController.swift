import AppKit
import HunchCore
import SwiftUI

/// The list behind the console window: the recorder's entries, newest first, and which one is open.
/// The newest entry stays selected until the user picks an older one; picking the newest again goes
/// back to following it.
@MainActor
@Observable
final class DiagnosticConsoleModel {
    private(set) var entries: [DiagnosticRecord] = []
    private var pickedID: Int?
    private var following = true
    @ObservationIgnored private var token: UInt64?

    var selected: DiagnosticRecord? {
        if !following, let pickedID, let entry = entries.first(where: { $0.id == pickedID }) { return entry }
        return entries.first
    }

    var isFollowingNewest: Bool { selected?.id == entries.first?.id && following }

    func select(_ id: Int) {
        if id == entries.first?.id {
            following = true
            pickedID = nil
        } else {
            following = false
            pickedID = id
        }
    }

    /// Starts listening to the recorder (the window opened).
    func start() {
        following = true
        pickedID = nil
        token = DiagnosticRecorder.shared.addObserver { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Stops listening and drops what was loaded (the window closed).
    func stop() {
        if let token { DiagnosticRecorder.shared.removeObserver(token) }
        token = nil
        entries = []
        pickedID = nil
        following = true
    }

    private func refresh() {
        entries = DiagnosticRecorder.shared.entries
    }
}

/// The diagnostic console window (Settings → Privacy & Data → Diagnostics → Diagnostic console…).
/// Recording runs only while this window is open: opening it switches the recorder on, closing it
/// switches it off and throws everything away. Nothing is saved.
@MainActor
final class DiagnosticConsoleController: NSObject, NSWindowDelegate {
    static let shared = DiagnosticConsoleController()

    private var window: NSWindow?
    private let model = DiagnosticConsoleModel()

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: true)
            window.title = "Hunch Diagnostic Console"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 420)
            window.contentViewController = NSHostingController(rootView: DiagnosticConsoleView(model: model))
            window.delegate = self
            window.center()
            self.window = window
        }
        guard let window else { return }
        if !DiagnosticRecorder.shared.isEnabled {
            DiagnosticRecorder.shared.enable()
            model.start()
        }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        DiagnosticRecorder.shared.disable()
        model.stop()
    }
}
