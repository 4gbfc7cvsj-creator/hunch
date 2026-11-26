import Foundation
import HunchCore

/// The per-app and per-site settings a new install starts with (no app-policies file yet).
/// Only places in a named category other than Private: nothing personal, no private sites.
/// Apps that are only in their built-in category (`AutoCategories.builtIn`) aren't listed.
public enum FirstLaunchPolicies {
    /// Migrations a seeded file doesn't need: its entries are already written the current way.
    public static let migrations = [CategoryMigration.id]

    public static let patches: [PolicyKey: AppPolicyPatch] = {
        struct Entry: Decodable { var key: PolicyKey; var patch: AppPolicyPatch }
        struct CategoryEntry: Decodable { var name: String; var patch: AppPolicyPatch }
        struct Seed: Decodable { var entries: [Entry]; var categories: [CategoryEntry] }
        guard let seed = try? JSONDecoder().decode(Seed.self, from: Data(json.utf8)) else {
            assertionFailure("first-launch policies don't decode")
            return [:]
        }
        var out: [PolicyKey: AppPolicyPatch] = [:]
        for e in seed.entries { out[e.key] = e.patch }
        for c in seed.categories { out[.category(name: c.name)] = c.patch }
        // Discord shows suggestions with the Decode effect.
        out[.app(bundleID: "com.hnc.Discord")]?.appearance = .firstLaunchDecode
        return out
    }()

    private static let json = """
{
 "categories": [
  {"name": "AI Image", "patch": {"fixAutomaticallyAllowed": false}}
 ],
 "entries": [
  {"key": {"app": {"bundleID": "com.anthropic.claudefordesktop"}}, "patch": {"appCategory": "AI", "length": "veryLong"}},
  {"key": {"app": {"bundleID": "com.apple.MobileSMS"}}, "patch": {"appCategory": "Chats", "writeShape": "message"}},
  {"key": {"app": {"bundleID": "com.apple.Notes"}}, "patch": {"appCategory": "Notes", "emojiSearchEnabled": false, "emoticonEmojiEnabled": false}},
  {"key": {"app": {"bundleID": "com.apple.Terminal"}}, "patch": {"appCategory": "AI", "emojiSearchEnabled": false, "emoticonEmojiEnabled": false, "instructionsReplaceGlobal": true, "personalInfoAllowed": false}},
  {"key": {"app": {"bundleID": "com.hnc.Discord"}}, "patch": {"appCategory": "Chats", "autocorrectStrength": "balanced"}},
  {"key": {"app": {"bundleID": "com.liuliu.draw-things"}}, "patch": {"appCategory": "AI Image", "customInstructions": "Here I’m writing prompts for an image generator. I describe the picture in plain sentences: the subject and pose, the setting, the composition and camera angle, the lighting, the colors, and the art style. I keep my core idea and add concrete visual details that make it clearer, rather than strings of keywords or tags.", "instructionsReplaceGlobal": true, "personalInfoAllowed": false, "writeCustomShapeID": "FE022DD4-726E-4D8D-B0FB-93A704EB4B28"}},
  {"key": {"app": {"bundleID": "com.todesktop.230313mzl4w4u92"}}, "patch": {"appCategory": "AI", "enabled": true, "tabAcceptEnabled": true}},
  {"key": {"app": {"bundleID": "md.obsidian"}}, "patch": {"appCategory": "Notes"}},
  {"key": {"domain": {"pattern": "docs.google.com"}}, "patch": {"appCategory": "Work"}},
  {"key": {"domain": {"pattern": "mail.google.com"}}, "patch": {"appCategory": "Work", "autoCapitalizationAllowed": true, "autocorrectEnabled": true, "customInstructions": "Write in a professional, polished, and respectful tone suitable for communicating with coworkers, clients, and business contacts. Use proper capitalization, grammar, punctuation, and complete sentences, keeping the message clear, concise, and well-organized. Maintain a courteous and confident voice, adapting the level of formality to the context while remaining approachable. Prioritize clarity, accuracy, and actionable information, avoiding slang, excessive informality, and unnecessary filler.", "fixAutomaticallyAllowed": true, "fixConfusedWordsAllowed": true, "fixesPunctuation": true}}
 ]
}
"""
}
