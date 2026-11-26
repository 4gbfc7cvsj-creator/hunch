import AppKit
import Foundation
import HunchCore

/// Fonts read from a host's own configuration, for hosts that report none through accessibility
/// (terminals) or may not (VS Code-family editors). One source per bundle id; each source's
/// candidates are cached for 60 s, so a host costs one preference or file read per minute. Missing
/// or unparseable configs give no candidates, and the caller falls back to what it did before.
///
/// Terminal.app: its profiles' fonts are in its preferences; the window's profile is not (asking
/// Terminal would need Automation permission), so the profile whose character cell matches the
/// measured cell width wins, preferring the startup and default profiles on ties. iTerm2 is matched
/// the same way across its profiles, default first.
enum HostFontConfigs {
    static let terminalBundleID = "com.apple.Terminal"

    struct Candidate: Equatable {
        /// PostScript name, or nil for the system monospaced face (stored as ".AppleSystemUIFont").
        var name: String?
        var size: CGFloat
        /// Cell width: the font's advance times the profile's character spacing.
        var advance: CGFloat
        /// False only for a proportional editor font (a CSS generic like `sans-serif`).
        var isMonospaced = true
    }

    struct Source: Sendable {
        /// Cache key.
        let id: String
        /// Terminals are consulted before accessibility; editors only when it reports no font.
        let isTerminal: Bool
        let load: @Sendable () -> [Candidate]
    }

    /// VS Code forks by bundle id → their folder under ~/Library/Application Support.
    static let vsCodeFolders: [String: String] = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "com.vscodium": "VSCodium",
    ]

    static func source(for bundleID: String) -> Source? {
        switch bundleID {
        case terminalBundleID:
            return Source(id: bundleID, isTerminal: true, load: terminalCandidates)
        case "com.googlecode.iterm2":
            return Source(id: bundleID, isTerminal: true, load: iTerm2Candidates)
        case "com.mitchellh.ghostty":
            return Source(id: bundleID, isTerminal: true, load: ghosttyCandidates)
        case "net.kovidgoyal.kitty":
            return Source(id: bundleID, isTerminal: true) {
                read(home + "/.config/kitty/kitty.conf").flatMap { candidate(FontConfigParsers.kitty($0)) }.map { [$0] } ?? []
            }
        default:
            guard let folder = vsCodeFolders[bundleID] else { return nil }
            return Source(id: bundleID, isTerminal: false) {
                read(home + "/Library/Application Support/\(folder)/User/settings.json")
                    .flatMap(FontConfigParsers.vsCode(settings:)).flatMap(candidate).map { [$0] } ?? []
            }
        }
    }

    /// Touched only on the AX thread, like the rest of `ContextReader`.
    nonisolated(unsafe) private static var cache: [String: (at: Date, candidates: [Candidate])] = [:]

    static func hint(_ source: Source, cellWidth: CGFloat?) -> FontHint? {
        let candidates = cachedCandidates(source)
        guard !candidates.isEmpty else { return nil }
        let chosen = pick(candidates, cellWidth: cellWidth)
        let size = pointSize(of: chosen, cellWidth: cellWidth)
        if let name = chosen.name {
            return FontHint(name: name, pointSize: size, isMonospaced: chosen.isMonospaced)
        }
        return FontHint(pointSize: size, isMonospaced: chosen.isMonospaced)
    }

    /// The configured size, scaled to the measured cell width when the window is zoomed (Terminal's
    /// View → Bigger/Smaller, ⌘+/⌘−, changes the window, not the profile), rounded to half points;
    /// the configured size when the cell matches it or wasn't measured.
    static func pointSize(of candidate: Candidate, cellWidth: CGFloat?) -> CGFloat {
        guard let cellWidth, cellWidth > 0, candidate.advance > 0,
              abs(candidate.advance - cellWidth) > 0.5 else { return candidate.size }
        return max(1, (candidate.size * cellWidth / candidate.advance * 2).rounded() / 2)
    }

    /// First candidate within half a point of the cell width, else the closest one; candidates come
    /// in preference order.
    static func pick(_ candidates: [Candidate], cellWidth: CGFloat?) -> Candidate {
        guard let cellWidth, cellWidth > 0 else { return candidates[0] }
        if let close = candidates.first(where: { abs($0.advance - cellWidth) <= 0.5 }) { return close }
        return candidates.min(by: { abs($0.advance - cellWidth) < abs($1.advance - cellWidth) })!
    }

    private static func cachedCandidates(_ source: Source) -> [Candidate] {
        if let entry = cache[source.id], Date().timeIntervalSince(entry.at) < 60 { return entry.candidates }
        let candidates = source.load()
        cache[source.id] = (Date(), candidates)
        return candidates
    }

    // MARK: Sources

    private static var home: String { NSHomeDirectory() }

    private static func read(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @Sendable private static func terminalCandidates() -> [Candidate] {
        let app = terminalBundleID as CFString
        let profiles = CFPreferencesCopyAppValue("Window Settings" as CFString, app) as? [String: Any] ?? [:]
        let preferred = ["Startup Window Settings", "Default Window Settings"].compactMap {
            CFPreferencesCopyAppValue($0 as CFString, app) as? String
        }
        let order = preferred + profiles.keys.sorted().filter { !preferred.contains($0) }
        var seen = Set<String>()
        return order.compactMap { name in
            guard seen.insert(name).inserted, let profile = profiles[name] as? [String: Any],
                  let data = profile["Font"] as? Data,
                  let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data) else { return nil }
            let spacing = (profile["FontWidthSpacing"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1
            let system = font.fontName.hasPrefix(".")
            let face = system ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
            let advance = ("M" as NSString).size(withAttributes: [.font: face]).width * spacing
            return Candidate(name: system ? nil : font.fontName, size: font.pointSize, advance: advance)
        }
    }

    @Sendable private static func iTerm2Candidates() -> [Candidate] {
        let app = "com.googlecode.iterm2" as CFString
        let bookmarks = CFPreferencesCopyAppValue("New Bookmarks" as CFString, app) as? [[String: Any]] ?? []
        let guid = CFPreferencesCopyAppValue("Default Bookmark Guid" as CFString, app) as? String
        return FontConfigParsers.iTerm2(bookmarks: bookmarks, defaultGuid: guid).compactMap(candidate)
    }

    /// Ghostty loads the XDG files, then the macOS ones, each `config.ghostty` before `config`.
    @Sendable private static func ghosttyCandidates() -> [Candidate] {
        let dirs = [home + "/.config/ghostty", home + "/Library/Application Support/com.mitchellh.ghostty"]
        let roots = dirs.flatMap { [$0 + "/config.ghostty", $0 + "/config"] }
        return FontConfigParsers.ghostty(roots: roots, home: home, read: read).flatMap(candidate).map { [$0] } ?? []
    }

    // MARK: Resolution

    /// Matches a configured font against installed ones: a PostScript name through `NSFont(name:)`,
    /// a family list through `NSFontManager`; anything unresolvable becomes the system monospaced face.
    private static func candidate(_ configured: ConfiguredFont) -> Candidate? {
        let size = CGFloat(configured.size)
        guard size > 0 else { return nil }
        var font: NSFont?
        var monospaced = true
        if let name = configured.postScriptName {
            if !name.hasPrefix(".") { font = NSFont(name: name, size: size) }
        } else {
            switch FontConfigParsers.resolveFamily(configured.families, installed: installedFamily) {
            case .installed(let family):
                font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            case .system:
                font = NSFont.systemFont(ofSize: size)
                monospaced = false
            case .systemMonospaced, nil:
                break
            }
        }
        let system = font == nil || font!.fontName.hasPrefix(".")
        let face = font ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: face]).width * CGFloat(configured.widthSpacing)
        return Candidate(name: system ? nil : face.fontName, size: size, advance: advance, isMonospaced: monospaced)
    }

    /// The system's spelling of an installed family, matched case-insensitively as CSS does.
    private static func installedFamily(_ family: String) -> String? {
        let wanted = family.lowercased()
        return NSFontManager.shared.availableFontFamilies.first { $0.lowercased() == wanted }
    }
}
