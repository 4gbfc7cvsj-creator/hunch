import HunchSettingsStore
import SwiftUI

/// Links from one place in Settings to another. Settings text that names another pane or section
/// links to it (docs/design/settings-ui.md).
///
/// `hunch-settings://go/<pane>` opens a pane ("apps"); `hunch-settings://go/<anchor>` opens the pane
/// a search anchor belongs to and scrolls to that row ("apps.look"), the way a search result does.
/// The target sits in the path because a URL's host may lose its capitals.
enum SettingsLinks {
    static let scheme = "hunch-settings"

    /// Markdown for a link: `md("Apps & Sites", "apps")`, `md("Shortcuts", "shortcuts.dictation")`.
    static func md(_ text: String, _ target: String) -> String { "[\(text)](\(scheme)://go/\(target))" }

    /// Settings text with its markdown links made clickable (inline markdown only, spacing kept).
    static func text(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    /// The same text without its link markup, for VoiceOver hints.
    static func plain(_ markdown: String) -> String { String(text(markdown).characters) }

    /// Goes where `url` points; false when it isn't a Settings link.
    @MainActor @discardableResult
    static func open(_ url: URL) -> Bool {
        guard url.scheme == scheme else { return false }
        let target = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !target.isEmpty else { return false }
        // The sidebar's @AppStorage reads this default, so an open window follows.
        UserDefaults.standard.set(SettingsSearch.pane(of: target), forKey: "settingsPane")
        if target.contains(".") { SettingsJump.shared.pending = target }
        return true
    }

    /// For `.environment(\.openURL, …)`: Settings links stay in the window, others open as usual.
    @MainActor static let action = OpenURLAction { url in open(url) ? .handled : .systemAction }
}

/// A section footer: tips, and where to change a setting per app (docs/design/settings-ui.md).
/// Markdown links work.
struct FooterText: View {
    let markdown: String

    init(_ markdown: String) { self.markdown = markdown }

    var body: some View {
        Text(SettingsLinks.text(markdown))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
