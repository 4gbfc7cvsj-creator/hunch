import Foundation
import HunchCore
import Synchronization

extension AppPolicy {
    func applying(_ p: AppPolicyPatch) -> AppPolicy {
        var r = self
        if let v = p.enabled { r.enabled = v }
        if let v = p.secureExcluded { r.secureExcluded = v }
        if let v = p.customInstructions { r.customInstructions = v }
        if let v = p.insertion { r.insertion = v }
        if let v = p.layerAcceptWordKey { r.acceptWordKey = v }
        if let v = p.acceptFullKey { r.acceptFullKey = v }
        if let v = p.midLineEnabled { r.midLineEnabled = v }
        if let v = p.overlay { r.overlay = v }
        if let v = p.maxWordsOverride { r.maxWordsOverride = v }
        if let v = p.length { r.length = v }
        if let v = p.minWordsBeforeSuggesting { r.minWordsBeforeSuggesting = v }
        if let v = p.engineOverride { r.engineOverride = v }
        if let v = p.wakeChromiumAX { r.wakeChromiumAX = v }
        if let v = p.injectionChunkSize { r.injectionChunkSize = v }
        if let v = p.omitSurfaceContext { r.omitSurfaceContext = v }
        if let v = p.screenContextAllowed { r.screenContextAllowed = v }
        if let v = p.learningAllowed { r.learningAllowed = v }
        if let v = p.personalInfoAllowed { r.personalInfoAllowed = v }
        if let v = p.instructionsReplaceGlobal { r.instructionsReplaceGlobal = v }
        if let v = p.fontSizeAdjustmentFactor { r.fontSizeAdjustmentFactor = v }
        if let v = p.verticalAlignmentOffset { r.verticalAlignmentOffset = v }
        if let v = p.greySuggestionColorEnabled { r.greySuggestionColorEnabled = v }
        if let v = p.autocorrectEnabled { r.autocorrectEnabled = v }
        if let v = p.autocorrectStrength { r.autocorrectStrength = v }
        if let v = p.fixAutomaticallyAllowed { r.fixAutomaticallyAllowed = v }
        if let v = p.leavesChatShorthand { r.leavesChatShorthand = v }
        if let v = p.autoCapitalizationAllowed { r.autoCapitalizationAllowed = v }
        if let v = p.appliesTextReplacements { r.appliesTextReplacements = v }
        if let v = p.fixesPunctuation { r.fixesPunctuation = v }
        if let v = p.fixConfusedWordsAllowed { r.fixConfusedWordsAllowed = v }
        if let v = p.emoticonEmojiEnabled { r.emoticonEmojiEnabled = v }
        if let v = p.emojiSearchEnabled { r.emojiSearchEnabled = v }
        if let v = p.smartQuotesEnabled { r.smartQuotesEnabled = v }
        if let v = p.excludeSearchFields { r.excludeSearchFields = v }
        if let v = p.suggestedRepliesAllowed { r.suggestedRepliesAllowed = v }
        if let v = p.layerShellCommandMode { r.shellCommandMode = v }
        if let v = p.estimatedGeometryOnly { r.estimatedGeometryOnly = v }
        // A layer's preset replaces a custom shape from below; Paragraph is no longer a choice.
        if let v = p.writeShape, v != .paragraph { r.writeShape = v; r.writeCustomShapeID = nil }
        if let v = p.writeCustomShapeID { r.writeCustomShapeID = v }
        if let v = p.nonBreakingSpaces { r.insertionWorkarounds.nonBreakingSpaces = v }
        if let v = p.spaceAsKeyEvent { r.insertionWorkarounds.spaceAsKeyEvent = v }
        if let v = p.backspaceAfterPaste { r.insertionWorkarounds.backspaceAfterPaste = v }
        if let v = p.appearance { r.appearance = v }
        return r
    }
}

/// Layers base < seed < app's category < user app patch < site's category < user domain patch
/// < temporary override. Thread-safe.
public final class DefaultPolicyResolver: AppPolicyResolving {
    private struct TempOverride { var enabled: Bool; var until: Date }
    private struct State {
        var enabledByDefault: Bool
        var midLineByDefault = false
        var overrides: [String: TempOverride] = [:]
        var autocorrectByDefault = true
        var strengthByDefault = AutocorrectStrength.balanced
        var emojiByDefault = true
    }

    private let state: Mutex<State>
    private let seeds: [PolicyKey: AppPolicyPatch]
    private let userPatches: @Sendable () -> [PolicyKey: AppPolicyPatch]
    private let now: @Sendable () -> Date
    private let automaticCategories: AutoCategories

    public init(completionsEnabledByDefault: Bool,
                seeds: [PolicyKey: AppPolicyPatch] = Seeds.table,
                userPatches: @escaping @Sendable () -> [PolicyKey: AppPolicyPatch] = { [:] },
                automaticCategories: AutoCategories = .builtIn,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.automaticCategories = automaticCategories
        self.state = Mutex(State(enabledByDefault: completionsEnabledByDefault))
        self.seeds = seeds
        self.userPatches = userPatches
        self.now = now
    }

    public func setCompletionsEnabledByDefault(_ value: Bool) {
        state.withLock { $0.enabledByDefault = value }
    }

    /// Base-layer default for mid-line completion; seeds and user patches still override it.
    public func setMidLineByDefault(_ value: Bool) {
        state.withLock { $0.midLineByDefault = value }
    }

    /// Base-layer default for autocorrect (the general setting); per-app patches override it.
    public func setAutocorrectByDefault(_ value: Bool) {
        state.withLock { $0.autocorrectByDefault = value }
    }

    /// Base-layer default for the autocorrect Strength (the general setting); per-app patches override it.
    public func setAutocorrectStrengthByDefault(_ value: AutocorrectStrength) {
        state.withLock { $0.strengthByDefault = value }
    }

    /// Base-layer default for emoticon emoji and ":" emoji search (the general emoji setting);
    /// per-app patches override either.
    public func setEmojiByDefault(_ value: Bool) {
        state.withLock { $0.emojiByDefault = value }
    }

    public func setTemporaryOverride(bundleID: String, enabled: Bool, until: Date) {
        state.withLock { $0.overrides[bundleID] = TempOverride(enabled: enabled, until: until) }
    }

    public func clearTemporaryOverride(bundleID: String) {
        state.withLock { _ = $0.overrides.removeValue(forKey: bundleID) }
    }

    public func resolve(bundleID: String, urlHost: String?) -> ResolvedPolicy {
        let current = now()
        let (byDefault, midLine, temp, autocorrect, emoji, strength): (Bool, Bool, TempOverride?, Bool, Bool, AutocorrectStrength) = state.withLock { s in
            if let o = s.overrides[bundleID], o.until <= current { s.overrides.removeValue(forKey: bundleID) }
            return (s.enabledByDefault, s.midLineByDefault, s.overrides[bundleID], s.autocorrectByDefault,
                    s.emojiByDefault, s.strengthByDefault)
        }
        var policy = AppPolicy.default
        policy.enabled = byDefault
        policy.midLineEnabled = midLine
        policy.autocorrectEnabled = autocorrect
        policy.autocorrectStrength = strength
        policy.emoticonEmojiEnabled = emoji
        policy.emojiSearchEnabled = emoji
        var sources: [PolicyKey] = []
        var instructionsSource: PolicyKey?
        // Apply a layer, noting it when it changes the instructions in effect.
        func apply(_ patch: AppPolicyPatch, from key: PolicyKey) {
            let before = policy.customInstructions
            policy = policy.applying(patch)
            guard policy.customInstructions != before else { return }
            let text = policy.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            instructionsSource = text.isEmpty ? nil : key
        }
        let appKey = PolicyKey.app(bundleID: bundleID)

        if let seed = seeds[appKey] { apply(seed, from: appKey); sources.append(appKey) }
        let user = userPatches()
        let categories = AppCategories(patches: user, automatic: automaticCategories)
        if let (key, patch) = Self.categoryLayer(categories.category(ofApp: bundleID), in: user) {
            apply(patch, from: key)
            sources.append(key)
        }
        if let patch = user[appKey] {
            apply(patch, from: appKey)
            if !sources.contains(appKey) { sources.append(appKey) }
        }
        if let host = urlHost {
            if let (key, patch) = Self.categoryLayer(categories.category(ofSite: host), in: user), !sources.contains(key) {
                apply(patch, from: key)
                sources.append(key)
            }
            if let (key, patch) = Self.bestDomainMatch(host: host, in: user) {
                apply(patch, from: key)
                sources.append(key)
            }
        }
        if let temp {
            policy.enabled = temp.enabled
            if !sources.contains(appKey) { sources.append(appKey) }
        }
        return ResolvedPolicy(policy: policy, sources: sources, instructionsSource: instructionsSource)
    }

    /// A category's settings (saved, else preset) under the key they are reported as.
    static func categoryLayer(_ name: String?, in user: [PolicyKey: AppPolicyPatch]) -> (PolicyKey, AppPolicyPatch)? {
        guard let name, let patch = CategoryPresets.patch(named: name, in: user) else { return nil }
        let key = CategoryPresets.savedKey(named: name, in: user) ?? .category(name: CategoryNames.preset(name) ?? name)
        return (key, patch.behavior)
    }

    static func normalizeHost(_ s: String) -> String {
        var h = s.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Exact host or `*.suffix` (subdomains only). Longest pattern wins; exact beats wildcard on ties.
    static func bestDomainMatch(host rawHost: String,
                                in patches: [PolicyKey: AppPolicyPatch]) -> (PolicyKey, AppPolicyPatch)? {
        let host = normalizeHost(rawHost)
        guard !host.isEmpty else { return nil }
        var best: (key: PolicyKey, patch: AppPolicyPatch, length: Int, exact: Bool)?
        for (key, patch) in patches {
            guard case .domain(let raw) = key else { continue }
            let pattern = normalizeHost(raw)
            let exact: Bool
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1))  // ".example.com"
                guard suffix.count > 1, host.hasSuffix(suffix) else { continue }
                exact = false
            } else {
                guard host == pattern else { continue }
                exact = true
            }
            if let b = best {
                if pattern.count < b.length || (pattern.count == b.length && !(exact && !b.exact)) { continue }
            }
            best = (key, patch, pattern.count, exact)
        }
        return best.map { ($0.key, $0.patch) }
    }
}

// MARK: - App-level policy decisions (pure; used by the app's coordinator)

/// What a code buffer (`SurfaceKind.code`) opts out of, whatever the app policy says: identifiers
/// and string literals are neither vocabulary nor misspellings, and `:)` or `:smile` in code is
/// not an emoji request.
public enum CodeSurfaceRules {
    /// "Learn from my writing": words learned, sentences kept, learned words biasing suggestions.
    public static func learningAllowed(policy: AppPolicy, surface: SurfaceKind) -> Bool {
        policy.learningAllowed && surface != .code
    }

    /// The replacement ghosts (autocorrect strikethrough, emoji triggers).
    public static func replacementsAllowed(surface: SurfaceKind) -> Bool { surface != .code }
}
