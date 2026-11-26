import Foundation

/// `hunch://` links, for Shortcuts, Raycast and scripts. Parsing is pure and strict: any web
/// page can open the scheme, so anything not listed here is rejected rather than guessed at.
/// The app decides what runs at once (toggle, pause) and what needs the user's confirmation.
public enum HunchURLCommand {
    public static let scheme = "hunch"
    /// Longest pause or temporary per-app switch a link may ask for (one day).
    public static let maxMinutes = 1440
    /// `toggleApp` without `minutes`: the same five minutes as the toggle-app shortcut.
    public static let defaultToggleAppMinutes = 5

    public enum Command: Sendable, Equatable {
        /// `hunch://toggle`: global On/Off, like the menu-bar switch.
        case toggle
        /// `hunch://pause?minutes=N`.
        case pause(minutes: Int)
        /// `hunch://toggleApp?app=<bundle id>&minutes=N`; no `app` means the frontmost app.
        case toggleApp(bundleID: String?, minutes: Int)
        /// `hunch://setOverride?app=<bundle id>|domain=<pattern>|category=<name>&<field>=<value>…`;
        /// a value of `default` removes the field from the patch.
        case setOverride(PolicyKey, [OverrideChange])
        /// `hunch://clearOverride?app=<bundle id>|domain=<pattern>|category=<name>`.
        case clearOverride(PolicyKey)
        /// `hunch://settings?pane=…&select=…|category=…&setting=…&search=…`; see `SettingsRequest`.
        case settings(SettingsRequest)
        /// `hunch://set?suggestions=on&autocorrect=off&dictation=on&autocorrectStrength=strong`:
        /// the global feature switches, in link order.
        case set([GlobalChange])
        /// `hunch://model?select=<file name>`.
        case model(select: String)
    }

    /// What a `settings` link opens. Pane and setting names are only shape-checked here; the app
    /// knows its panes and rows (`SettingsSearch`). Opening Settings changes nothing, so it never asks.
    public struct SettingsRequest: Sendable, Equatable {
        /// Raw pane name, lowercased ("apps"); nil keeps the pane shown last, unless `setting` names one.
        public var pane: String?
        /// A place to pick on the Apps pane.
        public var place: PolicyKey?
        /// A search anchor ("general.length", "apps.insertion") to scroll to and highlight.
        public var setting: String?
        /// Text typed into the sidebar search.
        public var search: String?

        public init(pane: String? = nil, place: PolicyKey? = nil, setting: String? = nil, search: String? = nil) {
            self.pane = pane
            self.place = place
            self.setting = setting
            self.search = search
        }

        /// The pane to show: the setting's own pane, the Apps pane for a place, or `pane`.
        public var resolvedPane: String? {
            if let setting { return String(setting.prefix { $0 != "." }) }
            if place != nil { return "apps" }
            return pane
        }
    }

    /// Longest `search=` text a link may type.
    public static let maxSearchLength = 100

    /// Global switches a `set` link may change.
    public enum GlobalField: String, Sendable, CaseIterable {
        case suggestions, autocorrect, dictation, autocorrectStrength
    }

    public struct GlobalChange: Sendable, Equatable {
        public let field: GlobalField
        public let value: OverrideValue
        public init(field: GlobalField, value: OverrideValue) {
            self.field = field
            self.value = value
        }

        /// "autocorrect = off", for the confirmation alert.
        public var summary: String {
            if case .bool(let b) = value { return "\(field.rawValue) = \(b ? "on" : "off")" }
            return "\(field.rawValue) = \(value.text)"
        }

        /// True when this change, applied to the current value, turns a feature on or changes the
        /// strength. `current` gives the value now for `field`.
        public func asks(current: OverrideValue) -> Bool {
            guard current != value else { return false }
            if case .bool(let b) = value { return b }
            return true
        }
    }

    /// A `set` link asks first when any change turns a feature on or changes the strength;
    /// turning features off runs at once.
    public static func setAsks(_ changes: [GlobalChange], current: (GlobalField) -> OverrideValue) -> Bool {
        changes.contains { $0.asks(current: current($0.field)) }
    }

    /// The command would make Hunch read text where it doesn't now, so the app asks first: On
    /// while Off or paused, a pause while not On (it ends On), and turning an app back on that is
    /// off. Turning off and pausing while On only read less and run at once.
    /// `appEnabled` says whether an app (nil: the frontmost) is on now.
    public static func turnsReadingOn(_ command: Command, isOn: Bool, appEnabled: (String?) -> Bool) -> Bool {
        switch command {
        case .toggle, .pause: !isOn
        case .toggleApp(let bundleID, _): !appEnabled(bundleID)
        case .setOverride, .clearOverride, .settings, .model, .set: false
        }
    }

    /// Per-app fields a link may set: the on/off switches and the choice-of-a-few settings. Free
    /// text (`customInstructions`, `appCategory`), numbers and key combinations stay in the Apps pane.
    public enum OverrideField: String, Sendable, CaseIterable {
        case enabled, secureExcluded, insertion, tabAcceptEnabled, midLineEnabled, overlay, engineOverride
        case wakeChromiumAX, omitSurfaceContext, screenContextAllowed, learningAllowed, personalInfoAllowed
        case instructionsReplaceGlobal
        case autocorrectEnabled, autocorrectStrength, fixAutomaticallyAllowed, autoCapitalizationAllowed
        case fixesPunctuation, fixConfusedWordsAllowed, leavesChatShorthand, appliesTextReplacements
        case emoticonEmojiEnabled, emojiSearchEnabled, smartQuotesEnabled, excludeSearchFields, suggestedRepliesAllowed
        case nonBreakingSpaces, spaceAsKeyEvent, backspaceAfterPaste, greySuggestionColorEnabled
        case length, shellCommandMode, writeShape, acceptWordKey, acceptFullKey
    }

    public enum OverrideValue: Sendable, Equatable {
        case bool(Bool)
        case insertion(InsertionMode)
        case overlay(OverlayPreference)
        case engine(EngineKind)
        case strength(AutocorrectStrength)
        case length(LengthPreset)
        case shellMode(ShellCommandMode)
        case writeShape(WriteShape)
        /// `.shortcuts` or `.off`; key combinations are Settings-only.
        case acceptKey(AcceptKey)
        /// `default`: the field goes back to Default (removed from the patch).
        case reset

        public var text: String {
            switch self {
            case .bool(let b): b ? "true" : "false"
            case .insertion(let m): m.rawValue
            case .overlay(let o): o.rawValue
            case .engine(let e): e.rawValue
            case .strength(let s): s.rawValue
            case .length(let l): l.rawValue
            case .shellMode(let m): m.rawValue
            case .writeShape(let w): w.rawValue
            case .acceptKey(let k): k == .off ? "off" : "shortcuts"
            case .reset: "Default"
            }
        }
    }

    public struct OverrideChange: Sendable, Equatable {
        public let field: OverrideField
        public let value: OverrideValue
        public init(field: OverrideField, value: OverrideValue) {
            self.field = field
            self.value = value
        }

        /// "tabAcceptEnabled = false", for the confirmation alert.
        public var summary: String { "\(field.rawValue) = \(value.text)" }

        public func apply(to patch: inout AppPolicyPatch) {
            if value == .reset {
                reset(&patch)
                return
            }
            switch (field, value) {
            case (.enabled, .bool(let b)): patch.enabled = b
            case (.secureExcluded, .bool(let b)): patch.secureExcluded = b
            case (.insertion, .insertion(let m)): patch.insertion = m
            case (.tabAcceptEnabled, .bool(let b)): patch.tabAcceptEnabled = b
            case (.midLineEnabled, .bool(let b)): patch.midLineEnabled = b
            case (.overlay, .overlay(let o)): patch.overlay = o
            case (.engineOverride, .engine(let e)): patch.engineOverride = e
            case (.wakeChromiumAX, .bool(let b)): patch.wakeChromiumAX = b
            case (.omitSurfaceContext, .bool(let b)): patch.omitSurfaceContext = b
            case (.screenContextAllowed, .bool(let b)): patch.screenContextAllowed = b
            case (.learningAllowed, .bool(let b)): patch.learningAllowed = b
            case (.personalInfoAllowed, .bool(let b)): patch.personalInfoAllowed = b
            case (.instructionsReplaceGlobal, .bool(let b)): patch.instructionsReplaceGlobal = b
            case (.autocorrectEnabled, .bool(let b)): patch.autocorrectEnabled = b
            case (.autocorrectStrength, .strength(let s)): patch.autocorrectStrength = s
            case (.fixAutomaticallyAllowed, .bool(let b)): patch.fixAutomaticallyAllowed = b
            case (.autoCapitalizationAllowed, .bool(let b)): patch.autoCapitalizationAllowed = b
            case (.fixesPunctuation, .bool(let b)): patch.fixesPunctuation = b
            case (.fixConfusedWordsAllowed, .bool(let b)): patch.fixConfusedWordsAllowed = b
            case (.leavesChatShorthand, .bool(let b)): patch.leavesChatShorthand = b
            case (.appliesTextReplacements, .bool(let b)): patch.appliesTextReplacements = b
            case (.emoticonEmojiEnabled, .bool(let b)): patch.emoticonEmojiEnabled = b
            case (.emojiSearchEnabled, .bool(let b)): patch.emojiSearchEnabled = b
            case (.smartQuotesEnabled, .bool(let b)): patch.smartQuotesEnabled = b
            case (.excludeSearchFields, .bool(let b)): patch.excludeSearchFields = b
            case (.suggestedRepliesAllowed, .bool(let b)): patch.suggestedRepliesAllowed = b
            case (.nonBreakingSpaces, .bool(let b)): patch.nonBreakingSpaces = b
            case (.spaceAsKeyEvent, .bool(let b)): patch.spaceAsKeyEvent = b
            case (.backspaceAfterPaste, .bool(let b)): patch.backspaceAfterPaste = b
            case (.greySuggestionColorEnabled, .bool(let b)): patch.greySuggestionColorEnabled = b
            // The Apps pane writes these the same way: the newer field replaces the older one.
            case (.length, .length(let l)): patch.length = l; patch.maxWordsOverride = nil
            case (.shellCommandMode, .shellMode(let m)): patch.shellCommandMode = m; patch.shellCommandsEnabled = nil
            case (.writeShape, .writeShape(let w)): patch.writeShape = w; patch.writeCustomShapeID = nil
            case (.acceptWordKey, .acceptKey(let k)): patch.acceptWordKey = k; patch.tabAcceptEnabled = nil
            case (.acceptFullKey, .acceptKey(let k)): patch.acceptFullKey = k
            default: break  // parse never pairs a field with another field's type
            }
        }

        /// Back to Default, clearing the older field that stands for the same setting too.
        private func reset(_ patch: inout AppPolicyPatch) {
            switch field {
            case .enabled: patch.enabled = nil
            case .secureExcluded: break  // parse refuses lifting the exclusion
            case .insertion: patch.insertion = nil
            case .tabAcceptEnabled: patch.tabAcceptEnabled = nil
            case .midLineEnabled: patch.midLineEnabled = nil
            case .overlay: patch.overlay = nil
            case .engineOverride: patch.engineOverride = nil
            case .wakeChromiumAX: patch.wakeChromiumAX = nil
            case .omitSurfaceContext: patch.omitSurfaceContext = nil
            case .screenContextAllowed: patch.screenContextAllowed = nil
            case .learningAllowed: patch.learningAllowed = nil
            case .personalInfoAllowed: patch.personalInfoAllowed = nil
            case .instructionsReplaceGlobal: patch.instructionsReplaceGlobal = nil
            case .autocorrectEnabled: patch.autocorrectEnabled = nil
            case .autocorrectStrength: patch.autocorrectStrength = nil
            case .fixAutomaticallyAllowed: patch.fixAutomaticallyAllowed = nil
            case .autoCapitalizationAllowed: patch.autoCapitalizationAllowed = nil
            case .fixesPunctuation: patch.fixesPunctuation = nil
            case .fixConfusedWordsAllowed: patch.fixConfusedWordsAllowed = nil
            case .leavesChatShorthand: patch.leavesChatShorthand = nil
            case .appliesTextReplacements: patch.appliesTextReplacements = nil
            case .emoticonEmojiEnabled: patch.emoticonEmojiEnabled = nil
            case .emojiSearchEnabled: patch.emojiSearchEnabled = nil
            case .smartQuotesEnabled: patch.smartQuotesEnabled = nil
            case .excludeSearchFields: patch.excludeSearchFields = nil
            case .suggestedRepliesAllowed: patch.suggestedRepliesAllowed = nil
            case .nonBreakingSpaces: patch.nonBreakingSpaces = nil
            case .spaceAsKeyEvent: patch.spaceAsKeyEvent = nil
            case .backspaceAfterPaste: patch.backspaceAfterPaste = nil
            case .greySuggestionColorEnabled: patch.greySuggestionColorEnabled = nil
            case .length: patch.length = nil; patch.maxWordsOverride = nil
            case .shellCommandMode: patch.shellCommandMode = nil; patch.shellCommandsEnabled = nil
            case .writeShape: patch.writeShape = nil; patch.writeCustomShapeID = nil
            case .acceptWordKey: patch.acceptWordKey = nil; patch.tabAcceptEnabled = nil
            case .acceptFullKey: patch.acceptFullKey = nil
            }
        }
    }

    /// Why a `hunch://` link was refused. Messages name parameters, never their values.
    public enum Rejection: Error, Sendable, Equatable {
        case unknownCommand
        case unexpectedPath
        case missing(String)
        case invalid(String)
        case unknownParameter(String)
        case duplicate(String)
        /// Free text, numbers and the category: Apps pane only.
        case notSettable(String)
        /// `secureExcluded=false` would let suggestions into a field marked secure.
        case secureExclusionCannotBeLifted
        case appAndDomain
        case noChanges
        /// Two parameters that can't be used together.
        case conflicting(String, String)

        public var message: String {
            switch self {
            case .unknownCommand: "This isn't a Hunch command."
            case .unexpectedPath: "The link has an unexpected path."
            case .missing(let name): "The link is missing \(Self.short(name))."
            case .invalid(let name): "The value of \(Self.short(name)) isn't valid."
            case .unknownParameter(let name): "\(Self.short(name)) isn't a setting Hunch knows."
            case .duplicate(let name): "\(Self.short(name)) appears more than once."
            case .notSettable(let name): "\(Self.short(name)) can only be changed in Hunch Settings."
            case .secureExclusionCannotBeLifted: "Secure-field exclusion can only be turned off in Hunch Settings."
            case .appAndDomain: "The link must name just one app, domain or category."
            case .noChanges: "The link doesn't change any setting."
            case .conflicting(let a, let b): "\(Self.short(a)) and \(Self.short(b)) can't be used together."
            }
        }

        /// Parameter names come from the link: keep a hostile one from flooding the alert.
        private static func short(_ name: String) -> String {
            name.count > 40 ? String(name.prefix(40)) + "…" : name
        }
    }

    /// The command for `url`, or nil when it isn't a valid Hunch link.
    /// - Parameter siteKey: the Apps pane's website validation (`KnownPlacesStore.siteKey(fromInput:)`),
    ///   injected because HunchCore can't depend on HunchPolicy.
    public static func parse(_ url: URL, siteKey: (String) -> PolicyKey?) -> Command? {
        guard case .success(let command)? = validate(url, siteKey: siteKey) else { return nil }
        return command
    }

    /// Nil when `url` isn't a `hunch:` link at all; otherwise the command or why it was refused.
    public static func validate(_ url: URL, siteKey: (String) -> PolicyKey?) -> Result<Command, Rejection>? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let host = components.host, !host.isEmpty else { return .failure(.unknownCommand) }
        guard components.path.isEmpty || components.path == "/" else { return .failure(.unexpectedPath) }
        var query: [String: String] = [:]
        var order: [String] = []
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil else { return .failure(.duplicate(item.name)) }
            query[item.name] = item.value ?? ""
            order.append(item.name)
        }
        do {
            return .success(try command(host: host.lowercased(), query: query, order: order, siteKey: siteKey))
        } catch let rejection as Rejection {
            return .failure(rejection)
        } catch {
            return .failure(.unknownCommand)
        }
    }

    private static func command(host: String, query: [String: String], order: [String],
                                siteKey: (String) -> PolicyKey?) throws -> Command {
        func only(_ allowed: Set<String>) throws {
            if let extra = order.first(where: { !allowed.contains($0) }) { throw Rejection.unknownParameter(extra) }
        }
        func minutes(default fallback: Int?) throws -> Int {
            guard let raw = query["minutes"] else {
                guard let fallback else { throw Rejection.missing("minutes") }
                return fallback
            }
            guard let m = Int(raw), (1...maxMinutes).contains(m) else { throw Rejection.invalid("minutes") }
            return m
        }
        switch host {
        case "toggle":
            try only([])
            return .toggle
        case "pause":
            try only(["minutes"])
            return .pause(minutes: try minutes(default: nil))
        case "toggleapp":
            try only(["app", "minutes"])
            var app: String?
            if let raw = query["app"] {
                guard isBundleID(raw) else { throw Rejection.invalid("app") }
                app = raw
            }
            return .toggleApp(bundleID: app, minutes: try minutes(default: defaultToggleAppMinutes))
        case "setoverride":
            let key = try target(query, siteKey: siteKey)
            var changes: [OverrideChange] = []
            for name in order where name != "app" && name != "domain" && name != "category" {
                changes.append(try change(name, query[name] ?? ""))
            }
            guard !changes.isEmpty else { throw Rejection.noChanges }
            return .setOverride(key, changes)
        case "clearoverride":
            try only(["app", "domain", "category"])
            return .clearOverride(try target(query, siteKey: siteKey))
        case "settings":
            try only(["pane", "select", "category", "setting", "search"])
            var request = SettingsRequest()
            if let raw = query["pane"] {
                guard !raw.isEmpty, raw.count <= 32, raw.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                    throw Rejection.invalid("pane")
                }
                request.pane = raw.lowercased()
            }
            switch (query["select"], query["category"]) {
            case (let raw?, nil):
                if isBundleID(raw) {
                    request.place = .app(bundleID: raw)
                } else if case .domain(let pattern)? = siteKey(raw) {
                    request.place = .domain(pattern: pattern)
                } else {
                    throw Rejection.invalid("select")
                }
            case (nil, let raw?):
                request.place = .category(name: try categoryName(raw))
            case (_?, _?):
                throw Rejection.conflicting("select", "category")
            case (nil, nil):
                break
            }
            if let raw = query["setting"] {
                guard isSettingAnchor(raw) else { throw Rejection.invalid("setting") }
                request.setting = raw
                let pane = String(raw.prefix { $0 != "." })
                if let p = request.pane, p != pane { throw Rejection.conflicting("pane", "setting") }
                // A per-app row only exists once a place is picked; other rows ignore a place.
                if pane == "apps", request.place == nil { throw Rejection.missing("select") }
            }
            if request.place != nil {
                let pane = request.setting.map { String($0.prefix { $0 != "." }) } ?? request.pane
                guard pane == nil || pane == "apps" else {
                    throw query["select"] != nil ? Rejection.invalid("select") : Rejection.invalid("category")
                }
            }
            if let raw = query["search"] {
                let text = raw.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text.count <= maxSearchLength,
                      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { throw Rejection.invalid("search") }
                guard request.setting == nil else { throw Rejection.conflicting("setting", "search") }
                request.search = text
            }
            return .settings(request)
        case "set":
            var changes: [GlobalChange] = []
            for name in order {
                guard let field = GlobalField(rawValue: name) else { throw Rejection.unknownParameter(name) }
                let raw = query[name] ?? ""
                if field == .autocorrectStrength {
                    guard let s = AutocorrectStrength.allCases.first(where: { $0.rawValue == raw.lowercased() })
                    else { throw Rejection.invalid(name) }
                    changes.append(GlobalChange(field: field, value: .strength(s)))
                } else {
                    guard let b = bool(raw) else { throw Rejection.invalid(name) }
                    changes.append(GlobalChange(field: field, value: .bool(b)))
                }
            }
            guard !changes.isEmpty else { throw Rejection.noChanges }
            return .set(changes)
        case "model":
            try only(["select"])
            guard let raw = query["select"] else { throw Rejection.missing("select") }
            guard isModelFileName(raw) else { throw Rejection.invalid("select") }
            return .model(select: raw)
        default:
            throw Rejection.unknownCommand
        }
    }

    /// Exactly one of `app=` / `domain=` / `category=`.
    private static func target(_ query: [String: String], siteKey: (String) -> PolicyKey?) throws -> PolicyKey {
        switch (query["app"], query["domain"], query["category"]) {
        case (let app?, nil, nil):
            guard isBundleID(app) else { throw Rejection.invalid("app") }
            return .app(bundleID: app)
        case (nil, let domain?, nil):
            guard case .domain(let pattern)? = siteKey(domain) else { throw Rejection.invalid("domain") }
            return .domain(pattern: pattern)
        case (nil, nil, let category?):
            return .category(name: try categoryName(category))
        case (nil, nil, nil):
            throw Rejection.missing("app")
        default:
            throw Rejection.appAndDomain
        }
    }

    /// Longest category name a link may give.
    static let maxCategoryLength = 64

    /// Trimmed, non-empty, short, no control characters. Whether the category exists is the app's call.
    private static func categoryName(_ raw: String) throws -> String {
        guard let name = AppCategories.clean(raw), name.count <= maxCategoryLength,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Rejection.invalid("category") }
        return name
    }

    /// "general.length": a lowercase pane name, a dot, then letters and digits; at most 64 characters.
    static func isSettingAnchor(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard s.count <= 64, parts.count == 2,
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isLowercase }),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return false }
        return true
    }

    /// Fields of `AppPolicyPatch` a link may never set, named so the alert can say where to go instead.
    private static let settingsOnly: Set<String> = [
        "customInstructions", "appCategory", "maxWordsOverride", "injectionChunkSize",
        "minWordsBeforeSuggesting", "fontSizeAdjustmentFactor", "verticalAlignmentOffset",
        "writeCustomShapeID", "appearance",
    ]

    private static func change(_ name: String, _ raw: String) throws -> OverrideChange {
        guard let field = OverrideField(rawValue: name) else {
            throw settingsOnly.contains(name) ? Rejection.notSettable(name) : Rejection.unknownParameter(name)
        }
        func choice<T: RawRepresentable & CaseIterable>(_: T.Type, except: [T] = []) throws -> T
        where T.RawValue == String, T: Equatable {
            guard let v = T.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }),
                  !except.contains(v) else { throw Rejection.invalid(name) }
            return v
        }
        if raw.lowercased() == "default" {
            if field == .secureExcluded { throw Rejection.secureExclusionCannotBeLifted }
            return OverrideChange(field: field, value: .reset)
        }
        let value: OverrideValue
        switch field {
        case .autocorrectStrength: value = .strength(try choice(AutocorrectStrength.self))
        case .length: value = .length(try choice(LengthPreset.self))
        case .shellCommandMode: value = .shellMode(try choice(ShellCommandMode.self))
        // `paragraph` is no longer offered and reads as Default.
        case .writeShape: value = .writeShape(try choice(WriteShape.self, except: [.paragraph]))
        case .acceptWordKey, .acceptFullKey:
            switch raw.lowercased() {
            case "shortcuts": value = .acceptKey(.shortcuts)
            case "off": value = .acceptKey(.off)
            default: throw Rejection.invalid(name)
            }
        case .insertion:
            guard let m = InsertionMode.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() })
            else { throw Rejection.invalid(name) }
            value = .insertion(m)
        case .overlay:
            guard let o = OverlayPreference.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() })
            else { throw Rejection.invalid(name) }
            value = .overlay(o)
        case .engineOverride:
            guard let e = EngineKind.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() })
            else { throw Rejection.invalid(name) }
            value = .engine(e)
        default:
            guard let b = bool(raw) else { throw Rejection.invalid(name) }
            if field == .secureExcluded, !b { throw Rejection.secureExclusionCannotBeLifted }
            value = .bool(b)
        }
        return OverrideChange(field: field, value: value)
    }

    /// `true/false/1/0/on/off`, any case.
    static func bool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "1", "on": true
        case "false", "0", "off": false
        default: nil
        }
    }

    /// Reverse-DNS-ish: ASCII letters, digits, "-", "_" and ".", at least two non-empty parts,
    /// at most 255 characters.
    public static func isBundleID(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 255,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") })
        else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && !parts.contains(where: \.isEmpty)
    }

    /// A model's path relative to the models folder: no absolute paths, no "..", no control characters.
    static func isModelFileName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 255, !s.hasPrefix("/"), !s.hasPrefix("~"),
              !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return !s.split(separator: "/").contains("..")
    }

    /// What `clearOverride` leaves behind: like "Reset to built-in" in the Apps pane the category
    /// is kept (an explicit None too), and so is a secure-field exclusion, which a link may add but
    /// never lift.
    public static func cleared(_ patch: AppPolicyPatch?) -> AppPolicyPatch? {
        var kept = AppPolicyPatch()
        if let category = patch?.appCategory {
            kept.appCategory = AppCategories.clean(category) ?? ""
        }
        if patch?.secureExcluded == true { kept.secureExcluded = true }
        return kept == AppPolicyPatch() ? nil : kept
    }
}
