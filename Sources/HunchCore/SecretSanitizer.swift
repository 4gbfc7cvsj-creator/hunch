import Foundation

/// Replaces secret-looking material (API keys, tokens, private keys, credentials in URLs,
/// `password=` pairs, IBANs, signed-URL signatures) with `[redacted]` before text reaches the
/// model, the history, or an endpoint. Pure and shared, so every consumer redacts the same way.
/// Patterns are deliberately specific: ordinary prose, plain URLs, hex colors, and short ids
/// pass through unchanged.
public enum SecretSanitizer {
    /// What a redacted match becomes.
    public static let token = "[redacted]"

    struct Rule: @unchecked Sendable {  // NSRegularExpression is immutable and thread-safe.
        let regex: NSRegularExpression
        /// Capture group 1 (a key name or URL scheme) stays, so the text still reads naturally.
        let keepsLabel: Bool
        /// Skipped on code surfaces, where `NAME=value` lines are ordinary code.
        let skipsCode: Bool
        /// Lowercase literals of which at least one must occur (ASCII case ignored) before the regex
        /// runs; empty means always run. ICU scans are slow on prose, the literal check is not.
        let hints: [[UInt8]]

        init(_ pattern: String, options: NSRegularExpression.Options = [], keepsLabel: Bool = false,
             skipsCode: Bool = false, hints: [String] = []) {
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.keepsLabel = keepsLabel
            self.skipsCode = skipsCode
            self.hints = hints.map { Array($0.utf8) }
        }

        func mayMatch(_ folded: [UInt8]) -> Bool {
            hints.isEmpty || hints.contains { SecretSanitizer.contains(folded, $0) }
        }
    }

    /// Applied in order; each rule sees the previous rules' output.
    static let rules: [Rule] = [
        // PEM private key blocks; an unterminated block is redacted to the end.
        Rule(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----(?:.*?-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|.*)"#,
             options: [.dotMatchesLineSeparators], hints: ["private key"]),
        // Credentials in a URL: scheme://user:pass@host keeps the scheme and host.
        Rule(#"(://)[^\s/?#@:]+:[^\s/?#@]+(?=@)"#, keepsLabel: true, hints: ["://"]),
        // JSON Web Tokens.
        Rule(#"\beyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*"#, hints: ["eyj"]),
        // AWS access key id.
        Rule(#"\bAKIA[0-9A-Z]{16}\b"#, hints: ["akia"]),
        // Stripe secret and restricted keys.
        Rule(#"\b[sr]k_(?:live|test)_[0-9A-Za-z]{10,}"#, hints: ["k_live_", "k_test_"]),
        // OpenAI-style keys (sk-…, sk-proj-…).
        Rule(#"\bsk-[A-Za-z0-9_-]{20,}"#, hints: ["sk-"]),
        // GitHub tokens.
        Rule(#"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#,
             hints: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"]),
        // Google API keys.
        Rule(#"\bAIza[0-9A-Za-z_-]{35}"#, hints: ["aiza"]),
        // Slack tokens.
        Rule(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, hints: ["xox"]),
        // `password: …`, `api_key=…`, `"token": "…"`, German `Passwort: …`; the key name stays.
        Rule(#"((?:password|passwd|pwd|secret|token|api[_-]?key|passwort|kennwort)["']?[ \t]*[:=][ \t]*)[^\s]+"#,
             options: [.caseInsensitive], keepsLabel: true,
             hints: ["passw", "pwd", "secret", "token", "apikey", "api_key", "api-key", "kennwort"]),
        // Environment assignments (`DB_URL=…`, `export API_TOKEN=…`); the name stays.
        Rule(#"^([ \t]*(?:export[ \t]+)?[A-Z_][A-Z0-9_]{2,}=)\S{8,}"#, options: [.anchorsMatchLines],
             keepsLabel: true, skipsCode: true, hints: ["="]),
        // Signed-URL signatures (`sig=`, `signature=`, `X-Amz-Signature=`); the parameter name stays.
        Rule(#"([?&;](?:[A-Za-z0-9]+-)*(?:sig|signature)=)[^&\s#]+"#, options: [.caseInsensitive],
             keepsLabel: true, hints: ["sig=", "signature="]),
        // IBAN-like account numbers, contiguous or in groups of four.
        Rule(#"\b[A-Z]{2}[0-9]{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,3})?)\b"#),
    ]

    private static let codeRules = rules.filter { !$0.skipsCode }

    static func rules(for surface: SurfaceKind) -> [Rule] {
        surface == .code ? codeRules : rules
    }

    /// True when `text` holds anything `redact` would replace.
    public static func containsSecret(_ text: String, surface: SurfaceKind = .unknown) -> Bool {
        guard !text.isEmpty else { return false }
        let folded = fold(text)
        let range = NSRange(location: 0, length: text.utf16.count)
        return rules(for: surface).contains { $0.mayMatch(folded) && $0.regex.firstMatch(in: text, range: range) != nil }
    }

    /// `text` with every secret-looking match replaced by `token`. The last `exactSuffix`
    /// characters are left untouched (a match reaching into them is redacted only up to that
    /// point), so text right at the caret stays byte-identical for healing and anchoring.
    /// Returns `text` itself when nothing matches.
    public static func redact(_ text: String, keepingLast exactSuffix: Int = 0,
                              surface: SurfaceKind = .unknown) -> String {
        guard !text.isEmpty else { return text }
        var tailUTF16 = 0
        if exactSuffix > 0 {
            guard let cut = text.index(text.endIndex, offsetBy: -exactSuffix, limitedBy: text.startIndex),
                  cut > text.startIndex else { return text }
            tailUTF16 = text.utf16.distance(from: cut, to: text.endIndex)
        }
        let folded = fold(text)
        var working = text
        // Hints are checked against the original text: a redaction never introduces a new hint.
        for rule in rules(for: surface) where rule.mayMatch(folded) {
            let length = working.utf16.count
            let limit = length - tailUTF16
            let matches = rule.regex.matches(in: working, range: NSRange(location: 0, length: length))
                .filter { $0.range.location < limit }
            guard !matches.isEmpty else { continue }
            let out = NSMutableString(string: working)
            for match in matches.reversed() {
                let end = min(NSMaxRange(match.range), limit)
                var start = match.range.location
                if rule.keepsLabel {
                    let label = match.range(at: 1)
                    if label.location != NSNotFound, NSMaxRange(label) <= limit { start = NSMaxRange(label) }
                }
                guard start < end else { continue }
                out.replaceCharacters(in: NSRange(location: start, length: end - start), with: token)
            }
            working = out as String
        }
        return working
    }

    /// True when `text` holds at least one `token` and nothing else but whitespace: what is left of
    /// text that was only a secret (a copied key or PEM block), which is not worth passing on.
    public static func isOnlyRedacted(_ text: String) -> Bool {
        let rest = text.replacingOccurrences(of: token, with: "")
        return rest.utf16.count < text.utf16.count && rest.allSatisfy(\.isWhitespace)
    }

    /// UTF-8 bytes with ASCII letters lowercased, for the hint check.
    static func fold(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        for i in bytes.indices where bytes[i] >= 65 && bytes[i] <= 90 { bytes[i] |= 0x20 }
        return bytes
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
            }
        }
    }
}
