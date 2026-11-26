import Foundation
import HunchCore

/// Default implementation of the secure gate (design §7.1). Pure: metadata in, decision out.
public struct DefaultSecureGate: SecureGating {
    public init() {}

    public func evaluateSystem(_ probe: SystemProbe, policy: ResolvedPolicy) -> GateDecision {
        if probe.secureEventInputEnabled { return .block(.secureEventInput(ownerPID: probe.secureInputOwnerPID)) }
        // Autocorrect alone keeps a field readable where suggestions are off (its own switch for the app).
        let autocorrectOnly = probe.autocorrectActive && policy.policy.autocorrectEnabled
        if !probe.globallyEnabled && !autocorrectOnly { return .block(.globallyDisabled) }
        if probe.frontmost.pid == probe.ownPID { return .block(.ownProcess) }
        if probe.trackingPaused { return .block(.trackingPaused) }
        if policy.policy.secureExcluded { return .block(.secureExcludedApp) }
        if !policy.policy.enabled && !autocorrectOnly { return .block(.appDisabled) }
        return .allow
    }

    public func evaluateElement(_ probe: ElementProbe, field: FieldID,
                                policy: ResolvedPolicy) -> Result<SecureGatePass, BlockReasonError> {
        if probe.role == "AXSecureTextField" || probe.subrole == "AXSecureTextField" {
            return .failure(BlockReasonError(.secureRole))
        }
        if probe.protectedContent == true { return .failure(BlockReasonError(.protectedContent)) }
        let texts = [probe.identifier, probe.title, probe.placeholder, probe.roleDescription]
        if texts.contains(where: { $0.map(SensitiveMarkers.matches) ?? false }) {
            return .failure(BlockReasonError(.sensitiveMarker))
        }
        if !probe.isEditable { return .failure(BlockReasonError(.notEditable)) }
        // Opt-in per app or site; by default search fields pass (surface `.search`).
        if policy.policy.excludeSearchFields, probe.role == "AXSearchField" || probe.subrole == "AXSearchField" {
            return .failure(BlockReasonError(.searchField))
        }
        return .success(SecureGatePass(field: field))
    }
}

/// Word-boundary-aware matching of sensitive field labels.
enum SensitiveMarkers {
    /// Token sequences (lowercased). Single tokens match whole words only (plural "s" tolerated).
    static let phrases: [[String]] = [
        ["password"], ["passcode"], ["passphrase"], ["pin"], ["otp"], ["2fa"], ["cvv"], ["cvc"], ["ssn"], ["secret"],
        ["one", "time", "code"], ["one", "time", "password"], ["verification", "code"], ["security", "code"],
        ["card", "number"], ["credit", "card"], ["social", "security"], ["private", "key"],
        ["recovery", "phrase"], ["seed", "phrase"], ["secure", "text", "field"],
    ]
    /// Simplified and traditional spellings are both listed (no reliance on a conversion here).
    static let substrings: [String] = ["密码", "密碼", "验证码", "驗證碼", "校验码", "校驗碼", "口令", "动态码", "動態碼"]

    static func matches(_ text: String) -> Bool {
        if substrings.contains(where: { text.contains($0) }) { return true }
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return false }
        for phrase in phrases where phrase.count <= tokens.count {
            for start in 0...(tokens.count - phrase.count) {
                var ok = true
                for (i, word) in phrase.enumerated() where !tokenEquals(tokens[start + i], word) { ok = false; break }
                if ok { return true }
            }
        }
        return false
    }

    private static func tokenEquals(_ token: String, _ word: String) -> Bool {
        token == word || (token.count == word.count + 1 && token.hasSuffix("s") && token.hasPrefix(word))
    }

    /// Splits on non-alphanumerics and camelCase boundaries, lowercases.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current: [Character] = []
        let chars = Array(text)
        func flush() {
            if !current.isEmpty { tokens.append(String(current).lowercased()); current.removeAll() }
        }
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else { flush(); continue }
            if let prev = current.last {
                let lowerToUpper = prev.isLowercase && c.isUppercase
                let acronymEnd = prev.isUppercase && c.isUppercase && i + 1 < chars.count && chars[i + 1].isLowercase
                if lowerToUpper || acronymEnd { flush() }
            }
            current.append(c)
        }
        flush()
        return tokens
    }
}
