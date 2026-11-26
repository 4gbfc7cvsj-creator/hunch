import Foundation
import HunchCore

/// The settings the built-in categories (AI, Work, Chats, Private) start with. The user can edit
/// them; an edited category is saved as its own patch (`PolicyKey.category`), which then replaces
/// the preset completely. Removing that patch restores the preset.
public enum CategoryPresets {
    public static let table: [String: AppPolicyPatch] = {
        var ai = AppPolicyPatch()
        ai.customInstructions = "Here I\u{2019}m writing prompts for an AI model, in my own words. I say exactly what I want done, give the background it needs, and spell out the requirements and what the result should look like. For bigger tasks I lay out the steps in order and mention edge cases up front. I get straight to the point, with no greeting, small talk or thank-yous."
        ai.instructionsReplaceGlobal = true
        ai.writeShape = .aiPrompt
        ai.emojiSearchEnabled = false
        ai.emoticonEmojiEnabled = false
        ai.personalInfoAllowed = false
        ai.length = .long
        // Prompts are written out in full: shorthand gets corrected here.
        ai.leavesChatShorthand = false

        var work = AppPolicyPatch()
        work.customInstructions = "Here I\u{2019}m writing to coworkers, clients and business contacts. I write complete sentences with proper capitals and punctuation, clear and well organized, and I keep it brief. My tone is courteous, confident and approachable, more formal with clients and a bit lighter with close colleagues. I stick to what matters and say clearly what happens next."
        work.instructionsReplaceGlobal = true
        work.writeShape = .email
        work.emojiSearchEnabled = false
        work.emoticonEmojiEnabled = false
        work.length = .long
        work.leavesChatShorthand = false

        var chats = AppPolicyPatch()
        chats.customInstructions = "here i\u{2019}m texting friends. i keep it short and casual, mostly lowercase, with contractions and abbreviations like lol, idk, tbh, and the odd emoji. i match their energy and show i\u{2019}m actually listening. i use commas sparingly and a question mark only on real questions, otherwise no punctuation, not even at the end"
        chats.instructionsReplaceGlobal = true
        // "id", "ofc", "tbh", "rn" are left as typed; other slips are fixed as you type.
        chats.leavesChatShorthand = true
        // Chat typing is loose on purpose: no apostrophe, spacing or full-stop fixes.
        chats.fixesPunctuation = false
        // Chat apps are casual: "i", "monday", "iphone" stay as typed.
        chats.autoCapitalizationAllowed = false
        // Casual chat isn't checked for their/there, your/you're (a formal-apps fix).
        chats.fixConfusedWordsAllowed = false

        var personal = AppPolicyPatch()
        personal.learningAllowed = false
        personal.screenContextAllowed = false
        personal.personalInfoAllowed = false
        personal.emojiSearchEnabled = false
        personal.emoticonEmojiEnabled = false
        // Nothing is changed behind the user's back here: fixes wait for Tab.
        personal.fixAutomaticallyAllowed = false

        return [CategoryNames.ai: ai, CategoryNames.work: work, CategoryNames.chats: chats,
                CategoryNames.private: personal]
    }()

    /// The preset settings for a name (case-insensitive), nil for a user-made category.
    public static func preset(named name: String) -> AppPolicyPatch? {
        CategoryNames.preset(name).flatMap { table[$0] }
    }

    /// A category's settings now: the user's saved patch for it, else its preset.
    public static func patch(named name: String, in user: [PolicyKey: AppPolicyPatch]) -> AppPolicyPatch? {
        if let saved = savedKey(named: name, in: user) { return user[saved] }
        return preset(named: name)
    }

    /// The saved key of a category, matched case-insensitively.
    public static func savedKey(named name: String, in user: [PolicyKey: AppPolicyPatch]) -> PolicyKey? {
        if user[.category(name: name)] != nil { return .category(name: name) }
        return user.keys.first {
            if case .category(let n) = $0 { AppCategories.same(n, name) } else { false }
        }
    }

    /// Every category: the presets, the ones the user saved settings for, and the ones in use.
    public static func allNames(_ user: [PolicyKey: AppPolicyPatch], used: [String]) -> [String] {
        var names = CategoryNames.presets
        func add(_ n: String) {
            guard let n = AppCategories.clean(n), !names.contains(where: { AppCategories.same($0, n) }) else { return }
            names.append(n)
        }
        for key in user.keys { if case .category(let n) = key { add(n) } }
        used.forEach(add)
        let own = names.dropFirst(CategoryNames.presets.count)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return CategoryNames.presets + own
    }
}
