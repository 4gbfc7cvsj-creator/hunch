import SwiftUI

/// A setting's name with its explanation behind a small info icon.
struct SettingLabel: View {
    let title: String
    let info: String?

    init(_ title: String, info: String? = nil) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let info { InfoTip(info) }
        }
    }
}

/// An "i" that shows `text` (markdown links work, see `SettingsLinks`) in a popover on click (click again or click away to close) or while
/// the pointer is on it. Inside a control's label, hover events don't always arrive, so the click
/// is what makes it dependable. No system tooltip: it would show a second copy next to the popover.
struct InfoTip: View {
    let text: String
    @State private var showing = false
    /// Opened by the click: stays open when the pointer leaves.
    @State private var pinned = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            pinned = !showing || !pinned
            showing = pinned
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { inside in
            if inside { showing = true } else if !pinned { showing = false }
        }
        .popover(isPresented: Binding(get: { showing },
                                      set: { showing = $0; if !$0 { pinned = false } }),
                 arrowEdge: .bottom) {
            Text(SettingsLinks.text(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(12)
                // A link to another part of Settings closes the popover on its way there.
                .environment(\.openURL, OpenURLAction { url in
                    guard SettingsLinks.open(url) else { return .systemAction }
                    showing = false
                    pinned = false
                    return .handled
                })
        }
        .accessibilityLabel("More about this setting")
        .accessibilityHint(SettingsLinks.plain(text))
    }
}
