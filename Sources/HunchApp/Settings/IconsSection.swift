import AppKit
import HunchCore
import HunchOverlay
import SwiftUI

/// Settings → Appearance → Icons: pick the app icon and the menu bar icon. Both apply at once.
struct IconsSection: View {
    let model: SettingsModel

    private var appIcon: AppIconChoice { model.settings.appIcon }
    private var menuBarIcon: MenuBarIconChoice { model.settings.menuBarIcon }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("App icon")
                    Spacer()
                    Text(appIcon.title).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 6),
                          alignment: .leading, spacing: 8) {
                    ForEach(AppIconChoice.allCases, id: \.self) { choice in
                        appIconButton(choice)
                    }
                }
            }
            .searchAnchor("appearance.appIcon")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Menu bar icon")
                    Spacer()
                    Text(menuBarIcon.title).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ForEach(MenuBarIconChoice.allCases, id: \.self) { choice in
                        menuBarButton(choice)
                    }
                }
            }
            .searchAnchor("appearance.menuBarIcon")
        } header: {
            Text("Icons")
        } footer: {
            Text("The app icon also shows in Finder, Launchpad and Spotlight. Hunch puts it back after "
                 + "an update.")
                .foregroundStyle(.secondary)
        }
    }

    private func appIconButton(_ choice: AppIconChoice) -> some View {
        let selected = appIcon == choice
        return Button {
            model.set(\.appIcon, to: choice)
        } label: {
            Group {
                if let image = AppIcon.preview(choice) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                }
            }
            .frame(width: 56, height: 56)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.title)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func menuBarButton(_ choice: MenuBarIconChoice) -> some View {
        let selected = menuBarIcon == choice
        let glyph = MenuBarIcon.image(choice)
        return Button {
            model.set(\.menuBarIcon, to: choice)
        } label: {
            VStack(spacing: 0) {
                // The glyph on a light and a dark menu bar.
                ForEach([false, true], id: \.self) { dark in
                    Image(nsImage: glyph)
                        .renderingMode(.template)
                        .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
                        .frame(width: 52, height: 26)
                        .background(dark ? Color(red: 0.17, green: 0.17, blue: 0.19)
                                         : Color(red: 0.93, green: 0.93, blue: 0.95))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.title)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
