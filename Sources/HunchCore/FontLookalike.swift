import CoreGraphics

/// Installed stand-ins for web fonts that apps ship inside themselves and macOS can't load (Discord's
/// "gg sans"). Without one the ghost falls back to the system face, whose taller x-height makes the
/// ghost look a size larger than the typed text. Each stand-in is a face that comes with macOS and
/// matches the web font's x-height and ascender at the same point size.
public enum FontLookalike {
    /// Lowercased host family (spaces removed) → installed family.
    static let table: [String: String] = [
        // Discord. x-height 0.47 em and ascender 0.75 em, both within 0.1 pt of Avenir Next at 16 pt.
        "ggsans": "Avenir Next",
        // Discord's earlier face, same proportions.
        "whitney": "Avenir Next",
    ]

    /// The installed family to draw with for a host font that can't be loaded, or nil when the
    /// host font has no known stand-in. Accepts a CSS-style family list, quoted names, a family
    /// with a style suffix ("gg sans Normal") and PostScript names ("ggsans-Medium").
    public static func family(forFamily family: String?, name: String?) -> String? {
        for raw in [family, name].compactMap({ $0 }) {
            for item in raw.split(separator: ",") {
                let key = item.lowercased().filter { $0.isLetter || $0.isNumber }
                if let hit = table.first(where: { key.hasPrefix($0.key) }) { return hit.value }
            }
        }
        return nil
    }

    /// The installed face to draw `hint` with when its own font can't be loaded: the known stand-in
    /// for a reported name, else the face picked from on-screen measurement, else nil (system face).
    /// Callers try the host's own font first.
    public static func standIn(for hint: FontHint?) -> String? {
        family(forFamily: hint?.family, name: hint?.name) ?? hint?.measuredFamily
    }

    /// Letter spacing (points per character) that makes text in a stand-in run as wide as the host's:
    /// the learned `widthScale` (host width ÷ stand-in width) spread over each character's average
    /// advance. A stand-in has the host's height but not its width, so the width goes into spacing
    /// rather than size. Zero without a scale; the scale is clamped to 0.85...1.1.
    public static func tracking(widthScale: CGFloat?, meanAdvance: CGFloat) -> CGFloat {
        guard let widthScale, widthScale > 0, meanAdvance > 0 else { return 0 }
        return (min(max(widthScale, 0.85), 1.1) - 1) * meanAdvance
    }
}
