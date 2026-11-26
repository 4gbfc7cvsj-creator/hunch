// Which of the writer's languages the prompt names: the one the current keyboard types. Pure.
import Foundation

public enum InputLanguage {
    /// The writer's preferred languages that match `inputSource` (the selected keyboard input
    /// source's main language, e.g. "en" for ABC/US, "zh-Hant" for Zhuyin), keeping their order and
    /// regional form ("en" → "en-US"). All of `preferred` when there is no input language or none
    /// matches, so the prompt never names a language the writer did not set up.
    public static func promptLanguages(inputSource: String?, preferred: [String]) -> [String] {
        guard let inputSource, let wanted = Tag(inputSource) else { return preferred }
        let matches = preferred.filter { Tag($0).map(wanted.matches) ?? false }
        return matches.isEmpty ? preferred : matches
    }

    struct Tag {
        var language: String
        var script: String?

        init?(_ identifier: String) {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let first = parts.first, !first.isEmpty else { return nil }
            language = first.lowercased()
            script = parts.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) }?.lowercased()
        }

        /// Same language, and the same script when the input source names one (Zhuyin's "zh-Hant"
        /// does not match a "zh-Hans" preference).
        func matches(_ other: Tag) -> Bool {
            guard language == other.language else { return false }
            guard let script else { return true }
            return other.script == nil || other.script == script
        }
    }
}
