import Foundation
import HunchCore

/// One-time update when categories gained settings: an app's or site's own value equal to its
/// category's value is removed, so the place follows the category (and later edits to it). Values
/// that differ stay as the place's own choice. "Always grey" becomes an own look in grey.
public enum CategoryMigration {
    public static let id = "categorySettings1"

    public static func migrate(_ patches: inout [PolicyKey: AppPolicyPatch], mainAppearance: AppearanceSettings,
                               automatic: AutoCategories = .builtIn) {
        let categories = AppCategories(patches: patches, automatic: automatic)
        for (key, original) in patches {
            var p = original
            let name: String? = switch key {
            case .app(let id): categories.category(ofApp: id)
            case .domain(let pattern): categories.category(ofSite: pattern)
            case .category: nil
            }
            if let name, let category = CategoryPresets.patch(named: name, in: patches) {
                clearMatching(&p, category)
            }
            if p.greySuggestionColorEnabled == true, p.appearance == nil {
                var look = mainAppearance
                look.color = .grey
                p.appearance = look
            }
            if p.greySuggestionColorEnabled != nil { p.greySuggestionColorEnabled = nil }
            if p != original { patches[key] = p == AppPolicyPatch() ? nil : p }
        }
    }

    /// Removes each value `p` sets to the same thing as `category`.
    static func clearMatching(_ p: inout AppPolicyPatch, _ category: AppPolicyPatch) {
        func clear<T: Equatable>(_ kp: WritableKeyPath<AppPolicyPatch, T?>) {
            if let v = p[keyPath: kp], v == category[keyPath: kp] { p[keyPath: kp] = nil }
        }
        clear(\.enabled); clear(\.excludeSearchFields); clear(\.suggestedRepliesAllowed)
        clear(\.acceptFullKey); clear(\.midLineEnabled); clear(\.autocorrectEnabled); clear(\.autocorrectStrength)
        clear(\.fixAutomaticallyAllowed); clear(\.leavesChatShorthand); clear(\.autoCapitalizationAllowed); clear(\.appliesTextReplacements)
        clear(\.fixesPunctuation)
        clear(\.fixConfusedWordsAllowed)
        clear(\.emoticonEmojiEnabled); clear(\.emojiSearchEnabled); clear(\.smartQuotesEnabled)
        clear(\.writeShape); clear(\.writeCustomShapeID); clear(\.overlay)
        clear(\.screenContextAllowed); clear(\.learningAllowed); clear(\.personalInfoAllowed)
        clear(\.instructionsReplaceGlobal); clear(\.appearance)
        if let k = p.layerAcceptWordKey, k == category.layerAcceptWordKey { p.acceptWordKey = nil; p.tabAcceptEnabled = nil }
        if let m = p.layerShellCommandMode, m == category.layerShellCommandMode {
            p.shellCommandMode = nil; p.shellCommandsEnabled = nil
        }
        let trim = { (s: String?) in s?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let mine = trim(p.customInstructions), mine == trim(category.customInstructions) { p.customInstructions = nil }
    }
}
