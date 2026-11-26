import AppKit

/// macOS's own inline predictive text (System Settings → Keyboard → Text Input → "Show inline
/// predictive text"). When it is on, Apple apps draw their own grey prediction at the caret, so
/// Hunch's suggestion can appear on top of a second one. Hunch only reads the setting and
/// points the user to it; it never changes system settings.
enum MacInlinePredictions {
    static let defaultsKey = "NSAutomaticInlinePredictionEnabled"

    /// On unless the user turned it off: macOS treats a missing value as on. Read from the global
    /// preferences domain (`UserDefaults(suiteName: .globalDomain)` is not allowed and returns nil),
    /// re-synced first so a change in System Settings shows without restarting Hunch.
    static var isEnabled: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyValue(defaultsKey as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let value else { return true }
        if let number = value as? NSNumber { return number.boolValue }
        return true
    }

    /// Opens the Keyboard pane of System Settings.
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
