import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// Launch-at-login state, read live from `SMAppService.mainApp` (never stored as a setting).
@MainActor
@Observable
final class LoginItemModel {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var errorText: String?

    var isOn: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        let now = SMAppService.mainApp.status
        if now != status { status = now }
    }

    func setEnabled(_ on: Bool) {
        errorText = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorText = error.localizedDescription
        }
        refresh()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The "Startup" section of the General pane.
struct LoginItemSection: View {
    @State private var model = LoginItemModel()

    var body: some View {
        Section("Startup") {
            Toggle(isOn: Binding(get: { model.isOn }, set: { model.setEnabled($0) })) {
                Text("Open at login")
                if model.needsApproval {
                    Text("Approve Hunch in System Settings \u{2192} General \u{2192} Login Items.")
                }
            }
            .searchAnchor("general.openAtLogin")
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if model.needsApproval {
                Button("Open Login Items") { model.openLoginItems() }
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
        }
    }
}
