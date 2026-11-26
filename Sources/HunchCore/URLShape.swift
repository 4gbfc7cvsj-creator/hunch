import Foundation

/// Recognizes web addresses in free text: a scheme ("https://"), a "www." start, or a host name
/// followed by a path, query, or fragment ("google.com/search?q=..."). A bare host ("google.com")
/// counts only with a common top-level domain, so "Node.js" or "e.g." stay ordinary words.
public enum URLShape {
    static let commonTLDs: Set<String> = [
        "com", "org", "net", "io", "ai", "app", "dev", "co", "edu", "gov", "me", "info", "xyz",
        "us", "uk", "tw", "cn", "hk", "jp", "kr", "de", "fr", "ca", "au",
    ]

    /// `[sub.]host.tld[:port][/path|?query|#fragment]`, ASCII letters, digits and hyphens.
    static let hostPattern = try! NSRegularExpression(
        pattern: #"^(?:[a-z0-9-]+\.)+([a-z]{2,24})(?::[0-9]{1,5})?([/?#].*)?$"#, options: [.caseInsensitive])

    /// Wrapping punctuation trimmed before the check: quotes, brackets, and sentence punctuation.
    static let wrapping = CharacterSet(charactersIn: "\"'()[]{}<>,;!\u{201C}\u{201D}\u{2018}\u{2019}")

    /// True when one whitespace-free token is a web address.
    public static func isURL(_ token: Substring) -> Bool { isURL(String(token)) }

    public static func isURL(_ token: String) -> Bool {
        var t = token.trimmingCharacters(in: wrapping)
        while let last = t.last, ".:?".contains(last) { t.removeLast() }   // sentence end after the address
        guard t.count >= 4 else { return false }
        let lower = t.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return true }
        let range = NSRange(t.startIndex..., in: t)
        guard let match = hostPattern.firstMatch(in: t, range: range) else { return false }
        if match.range(at: 2).location != NSNotFound { return true }
        guard let tld = Range(match.range(at: 1), in: t) else { return false }
        return commonTLDs.contains(t[tld].lowercased())
    }

    /// The text with every web-address token removed (whitespace between the remaining tokens is
    /// collapsed to single spaces). Text without addresses comes back unchanged.
    public static func removingURLs(_ text: String) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.contains(where: isURL) else { return text }
        return tokens.filter { !isURL($0) }.joined(separator: " ")
    }
}
