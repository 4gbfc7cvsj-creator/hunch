import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import HunchCore
import Observation
import SwiftUI

/// Live status of the system permissions Hunch uses.
@MainActor
@Observable
final class PermissionsModel {
    enum Kind: CaseIterable {
        case accessibility, inputMonitoring, screenRecording, microphone

        /// Asked for during the welcome tour (the microphone again on its Dictation page, and on first
        /// dictation).
        static let tourKinds: [Kind] = [.accessibility, .inputMonitoring, .screenRecording, .microphone]

        var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .inputMonitoring: "Input Monitoring"
            case .screenRecording: "Screen Recording"
            case .microphone: "Microphone"
            }
        }

        var caption: String {
            switch self {
            case .accessibility: "Read the text you're typing and where the cursor is"
            case .inputMonitoring: "See Tab and other keys to accept suggestions"
            case .screenRecording: "Optional: read text near the cursor (Screen awareness)"
            case .microphone: "Optional: hear you while you dictate (Dictation)"
            }
        }

        var settingsURL: URL {
            let pane = switch self {
            case .accessibility: "Privacy_Accessibility"
            case .inputMonitoring: "Privacy_ListenEvent"
            case .screenRecording: "Privacy_ScreenCapture"
            case .microphone: "Privacy_Microphone"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        }
    }

    private(set) var granted: [Kind: Bool] = [:]
    /// Kinds where a request was made and the permission is still missing (the system may not
    /// prompt again, so the deep link is offered).
    private(set) var requested: Set<Kind> = []
    private var timer: Timer?

    init() { refresh() }

    func refresh() {
        let next: [Kind: Bool] = [
            .accessibility: AXIsProcessTrusted(),
            .inputMonitoring: CGPreflightListenEventAccess(),
            .screenRecording: CGPreflightScreenCaptureAccess(),
            .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
        ]
        if next != granted { granted = next }
    }

    func isGranted(_ kind: Kind) -> Bool { granted[kind] ?? false }

    func request(_ kind: Kind) {
        switch kind {
        case .accessibility:
            // Value of kAXTrustedCheckOptionPrompt; the global itself is not concurrency-safe in Swift 6.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        }
        requested.insert(kind)
        refresh()
    }

    func openSystemSettings(_ kind: Kind) { NSWorkspace.shared.open(kind.settingsURL) }

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

extension PermissionsModel {
    /// One short paragraph per permission, worded from the current permission and settings state.
    nonisolated static func privacyParagraphs(granted: [Kind: Bool], settings: HunchSettings) -> [String] {
        var out: [String] = []
        if granted[.accessibility] ?? false {
            var text = "Accessibility \u{2013} Hunch reads the text around your cursor in the field you're typing in, "
                + "plus the field's position and font and the app or website name, to make suggestions. It's read "
                + "when needed, kept in memory only while you're in that field, and never sent anywhere: "
                + "suggestions are made by the model on this Mac. Secret-looking text such as API keys, tokens, "
                + "and passwords is redacted from the surrounding context before it reaches the model, your saved "
                + "history, or a remote endpoint; the text right at your cursor is used as typed."
            if settings.learning.enabled {
                text += " Because learning is on, words you use and sentences you typed are saved encrypted on this "
                    + "Mac; see \(SettingsLinks.md("Personalization", "personalization.learnWords"))."
            }
            out.append(text)
        } else {
            out.append("Accessibility \u{2013} Not allowed: Hunch can't read text, so it makes no suggestions.")
        }
        if granted[.inputMonitoring] ?? false {
            out.append("Input Monitoring \u{2013} Hunch watches key presses only to know when you're typing and to accept "
                       + "suggestions with Tab and the other shortcuts. Keys aren't recorded or stored.")
        } else {
            out.append("Input Monitoring \u{2013} Not allowed: Hunch can't see Tab or your shortcuts, so suggestions can't be accepted.")
        }
        if granted[.screenRecording] ?? false {
            if settings.screenContextEnabled {
                out.append("Screen Recording \u{2013} Hunch captures only the window you're typing in (never other apps, "
                           + "notifications, or menus), reads the text near the cursor on this Mac, and discards the "
                           + "image immediately; only a short cleaned-up passage is kept in memory for the current "
                           + "field. It also measures a small strip of your typed text to match the ghost text's size "
                           + "and height.")
            } else {
                out.append("Screen Recording \u{2013} Allowed, but Screen Awareness is off: Hunch only measures a small "
                           + "strip of your typed text next to the cursor to match the ghost text's size and height, "
                           + "and discards it immediately.")
            }
        } else {
            out.append("Screen Recording \u{2013} Not allowed: Hunch doesn't capture the screen; ghost text size and "
                       + "position use the app's reported values.")
        }
        if settings.engine == .endpoint, let host = settings.endpoint?.baseURL.host {
            out.append("Suggestions are currently made by your local server at \(host); text near the cursor is sent to it.")
        }
        // Writing uses its own endpoint only while "Use a writing model" is on; off, it follows Autocomplete.
        if settings.useWritingModel, settings.writeEngine == .endpoint, let host = settings.writeEndpoint?.baseURL.host {
            out.append("Write for me drafts are currently made by your local server at \(host); your request and the "
                       + "text you're polishing are sent to it.")
        }
        return out
    }
}

struct PermissionsSection: View {
    let settings: SettingsModel
    @State private var model = PermissionsModel()

    var body: some View {
        Section {
            ForEach(PermissionsModel.Kind.allCases, id: \.self) { kind in
                row(kind)
            }
        } header: {
            Text("Permissions").searchAnchor("privacy.permissions")
        }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private func row(_ kind: PermissionsModel.Kind) -> some View {
        let granted = model.isGranted(kind)
        return HStack(spacing: 8) {
            Circle()
                .fill(granted ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .accessibilityLabel(granted ? "Granted" : "Not granted")
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Request…") { model.request(kind) }
                if model.requested.contains(kind) {
                    Button("Open System Settings") { model.openSystemSettings(kind) }
                }
            }
        }
    }
}
