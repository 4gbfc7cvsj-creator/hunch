import Foundation
import HunchCore

/// Derives the writer's Han variant from the languages of the enabled keyboard input sources.
public enum HanPreference {
    public static func variant(forLanguages identifiers: [String]) -> HanVariant? {
        var traditional = false, simplified = false
        for id in identifiers {
            let parts = id.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard parts.first == "zh" else { continue }
            if parts.contains("hant") || parts.contains("tw") || parts.contains("hk") || parts.contains("mo") {
                traditional = true
            } else if parts.contains("hans") || parts.contains("cn") || parts.contains("sg") {
                simplified = true
            }
        }
        if traditional && !simplified { return .traditional }
        if simplified && !traditional { return .simplified }
        return nil
    }
}
