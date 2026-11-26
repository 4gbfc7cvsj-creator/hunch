import Foundation

/// The user's app categories, read from the per-app/per-site patches. Learned data stays
/// stored under each app key (bundle ID or site host); categories only decide which keys count
/// as "the same place" when reading it, so moving an app between categories is reversible.
/// A category also carries settings (`PolicyKey.category`), layered between an app's built-in
/// rule and its own choices.
///
/// An app or site the user never put in a category falls back to `AutoCategories`; an explicit
/// None (`appCategory == ""`) keeps it out of every category.
public struct AppCategories: Sendable, Equatable {
    /// Bundle ID -> category name ("" = explicit None).
    public var apps: [String: String]
    /// Host pattern (exact host or `*.suffix`) -> category name ("" = explicit None).
    public var sites: [String: String]
    /// Built-in categories for places the user hasn't decided on.
    public var automatic: AutoCategories

    public init(apps: [String: String] = [:], sites: [String: String] = [:], automatic: AutoCategories = .none) {
        self.apps = apps
        self.sites = sites
        self.automatic = automatic
    }

    public init(patches: [PolicyKey: AppPolicyPatch], automatic: AutoCategories = .builtIn) {
        var apps: [String: String] = [:], sites: [String: String] = [:]
        for (key, patch) in patches {
            guard let raw = patch.appCategory else { continue }
            let name = Self.clean(raw) ?? ""
            switch key {
            case .app(let id): apps[id] = name
            case .domain(let pattern): sites[Self.host(pattern)] = name
            case .category: continue
            }
        }
        self.init(apps: apps, sites: sites, automatic: automatic)
    }

    public var isEmpty: Bool { apps.isEmpty && sites.isEmpty && automatic.isEmpty }

    /// Category names the user put places in, sorted (automatic ones not included).
    public var names: [String] {
        Array(Set(apps.values).union(sites.values).subtracting([""]))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The category of an app key: a bundle ID, else a site host.
    public func category(of appKey: String) -> String? {
        if apps[appKey] != nil || automatic.apps[appKey] != nil { return category(ofApp: appKey) }
        return category(ofSite: appKey)
    }

    /// The user's choice for a bundle ID, else its automatic category.
    public func category(ofApp bundleID: String) -> String? {
        if let c = apps[bundleID] { return Self.clean(c) }
        return automatic.apps[bundleID]
    }

    /// The user's choice for a host (exact pattern, then the longest matching `*.suffix`), else the
    /// automatic one matched the same way.
    public func category(ofSite rawHost: String) -> String? {
        let host = Self.host(rawHost)
        if let c = Self.match(host, in: sites) { return Self.clean(c) }
        return Self.match(host, in: automatic.sites)
    }

    /// Whether the user chose this place's category (a name or None), as opposed to automatic.
    public func isExplicit(_ key: PolicyKey) -> Bool {
        switch key {
        case .app(let id): apps[id] != nil
        case .domain(let pattern): sites[Self.host(pattern)] != nil
        case .category: false
        }
    }

    /// Same app key, or both in one category (names compared case-insensitively).
    public func sameCategory(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let ca = category(of: a), let cb = category(of: b) else { return false }
        return Self.same(ca, cb)
    }

    /// Category names compare case- and diacritic-insensitively.
    public static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(b.trimmingCharacters(in: .whitespacesAndNewlines),
                     options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Trimmed name, nil when blank.
    public static func clean(_ name: String?) -> String? {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    static func host(_ s: String) -> String {
        var h = s.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Exact host first, then the longest matching `*.suffix`.
    static func match(_ host: String, in patterns: [String: String]) -> String? {
        if let c = patterns[host] { return c }
        var best: (length: Int, name: String)?
        for (pattern, name) in patterns where pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(1))
            guard suffix.count > 1, host.hasSuffix(suffix) else { continue }
            if best == nil || pattern.count > best!.length { best = (pattern.count, name) }
        }
        return best?.name
    }
}

/// Built-in categories for well-known apps and sites, used until the user picks one (or None).
public struct AutoCategories: Sendable, Equatable {
    /// Bundle ID -> category name.
    public var apps: [String: String]
    /// Host pattern (exact host or `*.suffix`) -> category name.
    public var sites: [String: String]

    public init(apps: [String: String] = [:], sites: [String: String] = [:]) {
        self.apps = apps
        self.sites = sites
    }

    public var isEmpty: Bool { apps.isEmpty && sites.isEmpty }

    public static let none = AutoCategories()

    public static let builtIn: AutoCategories = {
        var apps: [String: String] = [:], sites: [String: String] = [:]
        func add(_ name: String, apps ids: [String], sites hosts: [String]) {
            for id in ids { assert(apps[id] == nil, "listed twice: \(id)"); apps[id] = name }
            for h in hosts { assert(sites[h] == nil, "listed twice: \(h)"); sites[h] = name }
        }
        // Bundle IDs are exact: each was checked against an installed copy or the app's Homebrew
        // cask. A wrong ID matches nothing, so leave out apps whose ID can't be confirmed.
        add(CategoryNames.ai,
            apps: [
                "com.anthropic.claudefordesktop",                   // Claude
                "com.openai.chat", "com.openai.codex",              // ChatGPT (older and current), Codex
                "ai.perplexity.macv3",                              // Perplexity
                "ai.elementlabs.lmstudio",                          // LM Studio
                "com.nousresearch.hermes",                          // Hermes
                "com.electron.ollama",                              // Ollama
                "app.msty.app",                                     // Msty
                "jan.ai.app",                                       // Jan
                "com.todesktop.230313mzl4w4u92",                    // Cursor
                "com.exafunction.windsurf",                         // Windsurf
            ],
            sites: ["claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "aistudio.google.com",
                    "notebooklm.google.com", "perplexity.ai", "copilot.microsoft.com", "grok.com",
                    "chat.deepseek.com", "chat.mistral.ai", "chat.qwen.ai", "kimi.com", "poe.com", "meta.ai",
                    "lmarena.ai", "t3.chat", "openrouter.ai", "v0.app", "v0.dev", "bolt.new", "lovable.dev"])
        add(CategoryNames.work,
            apps: [
                "com.apple.mail",                                   // Mail
                "com.microsoft.Outlook",                            // Outlook
                "com.readdle.smartemail-Mac", "com.readdle.SparkDesktop", // Spark (classic, current)
                "it.bloop.airmail2",                                // Airmail
                "com.mimestream.Mimestream",                        // Mimestream
                "com.superhuman.mail",                              // Superhuman
                "ch.protonmail.desktop",                            // Proton Mail
                "org.mozilla.thunderbird",                          // Thunderbird
                "com.tinyspeck.slackmacgap",                        // Slack
                "com.microsoft.teams2", "com.microsoft.teams",      // Teams (current, classic)
                "us.zoom.xos",                                      // Zoom
                "Cisco-Systems.Spark",                              // Webex
                "com.larksuite.larkApp", "com.electron.lark",       // Lark, Feishu
            ],
            sites: ["mail.google.com", "chat.google.com", "outlook.live.com", "outlook.office.com",
                    "outlook.office365.com", "*.slack.com", "teams.microsoft.com", "app.zoom.us", "linkedin.com",
                    "mail.proton.me", "app.fastmail.com", "mail.zoho.com", "mail.superhuman.com"])
        add(CategoryNames.chats,
            apps: [
                "com.apple.MobileSMS",                              // Messages
                "com.hnc.Discord",                                  // Discord
                "ru.keepcoder.Telegram", "com.tdesktop.Telegram",   // Telegram, Telegram Desktop
                "net.whatsapp.WhatsApp",                            // WhatsApp
                "org.whispersystems.signal-desktop",                // Signal
                "jp.naver.line.mac",                                // LINE
                "com.tencent.xinWeChat",                            // WeChat
                "com.tencent.qq",                                   // QQ
                "com.facebook.archon", "com.facebook.archon.developerID", // Messenger
                "com.viber.osx",                                    // Viber
                "im.riot.app",                                      // Element
                "com.automattic.beeper.desktop",                    // Beeper
            ],
            sites: ["discord.com", "web.whatsapp.com", "web.telegram.org", "messenger.com", "messages.google.com",
                    "web.wechat.com", "wx.qq.com", "app.element.io", "instagram.com"])
        return AutoCategories(apps: apps, sites: sites)
    }()
}

/// The built-in categories' names. Their settings are `CategoryPresets` (HunchPolicy).
public enum CategoryNames {
    public static let ai = "AI"
    public static let work = "Work"
    public static let chats = "Chats"
    public static let `private` = "Private"
    public static let presets = [ai, work, chats, `private`]

    /// The preset this name refers to (case-insensitive), if any.
    public static func preset(_ name: String) -> String? {
        presets.first { AppCategories.same($0, name) }
    }
}
