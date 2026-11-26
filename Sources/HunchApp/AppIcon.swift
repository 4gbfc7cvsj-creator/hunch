import AppKit
import HunchCore

/// Puts the picked app icon (Settings → Appearance → Icons) on Hunch: in its own windows, alerts and
/// notifications (`applicationIconImage`), and on the app bundle so Finder, Launchpad and Spotlight
/// show it too. macOS keeps a custom icon on the bundle as an `Icon\r` file inside it, which an update
/// replaces, so this runs at every launch as well as on each change. The shipped icon removes the
/// custom one, leaving `AppIcon.icns`.
enum AppIcon {
    /// The icon's artwork from the app's `AppIcons` resources (nil outside an app bundle, e.g. tests).
    static func image(_ choice: AppIconChoice) -> NSImage? {
        guard let url = Bundle.main.url(forResource: choice.rawValue, withExtension: "png", subdirectory: "AppIcons")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    /// The bundle's own icon file, for the shipped choice when the artwork can't be found.
    static func preview(_ choice: AppIconChoice) -> NSImage? {
        image(choice) ?? (choice == .standard ? NSImage(named: "AppIcon") : nil)
    }

    @MainActor static func apply(_ choice: AppIconChoice) {
        // Any pick, even one that writes nothing, cancels an older pick's delayed write.
        generation += 1
        let pick = generation
        let custom = choice == .standard ? nil : image(choice)
        NSApp.applicationIconImage = custom  // nil restores the bundle's icon
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let marker = bundle.appendingPathComponent("Icon\r").path
        let hasCustom = FileManager.default.fileExists(atPath: marker)
        // Skip the write when nothing would change: the shipped icon with no custom one on the bundle.
        if custom == nil, !hasCustom { return }
        if custom != nil, hasCustom, UserDefaults.standard.string(forKey: appliedKey) == choice.rawValue { return }
        // Finder refreshes an icon when the bundle's custom-icon flag changes, not when the custom
        // icon's contents do, so a swap from one custom icon to another clears it first and tells
        // Finder, then sets the new one a moment later. Only the latest pick is written.
        let workspace = NSWorkspace.shared
        func write() {
            guard pick == generation else { return }
            if workspace.setIcon(custom, forFile: bundle.path, options: []) {
                UserDefaults.standard.set(custom == nil ? nil : choice.rawValue, forKey: appliedKey)
            }
            workspace.noteFileSystemChanged(bundle.path)
        }
        if custom != nil, hasCustom {
            workspace.setIcon(nil, forFile: bundle.path, options: [])
            workspace.noteFileSystemChanged(bundle.path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { write() }
        } else {
            write()
        }
    }

    /// Bumped by each `apply`, so a delayed write from an older pick is dropped.
    @MainActor private static var generation = 0

    /// The choice last written onto the bundle, so a launch with the same choice skips the rewrite.
    private static let appliedKey = "appliedBundleIcon"
}
