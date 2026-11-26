import Foundation
import HunchCore

/// Heuristics that keep secret-looking material out of the screen excerpt. OCR-specific checks
/// (one-time codes, card numbers, long random tokens) live here; key families, credentials, and
/// `password=` pairs come from the shared `SecretSanitizer`.
public enum SecretFilter {
    private static let otpHints = [
        "code", "otp", "passcode", "password", "verification", "one-time", "token", "pin",
        "验证码", "驗證碼", "校验码", "动态码", "密码", "密碼", "口令",
    ]

    /// Removes secret-looking tokens from a line; returns nil when the whole line should go.
    public static func sanitize(_ line: String) -> String? {
        let lower = line.lowercased()
        // One-time codes: a hint word plus a 4-8 digit token anywhere on the line.
        if otpHints.contains(where: { lower.contains($0) }), containsShortDigitToken(line) {
            return nil
        }
        // Card-like digit groups: drop the entire line.
        if hasCardLikeDigits(line) { return nil }
        let kept = SecretSanitizer.redact(line).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" })
            .filter { !isSecretToken(String($0)) }
        if kept.isEmpty { return nil }
        return kept.joined(separator: " ")
    }

    static func isSecretToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "+/=_-")))
        guard token.count >= 20 else { return false }
        let scalars = token.unicodeScalars
        // Long hex string.
        if token.count >= 24, scalars.allSatisfy({ isHex($0) }) { return true }
        // Base64 / base64url / API-key-like: long, restricted alphabet, mixes letters and digits.
        guard token.count >= 32 else { return false }
        var letters = false, digits = false
        for s in scalars {
            switch s {
            case "a"..."z", "A"..."Z": letters = true
            case "0"..."9": digits = true
            case "+", "/", "=", "_", "-": break
            default: return false
            }
        }
        return letters && digits
    }

    private static func isHex(_ s: Unicode.Scalar) -> Bool {
        switch s {
        case "0"..."9", "a"..."f", "A"..."F": true
        default: false
        }
    }

    private static func containsShortDigitToken(_ line: String) -> Bool {
        var run = 0
        for ch in line.unicodeScalars + [" "] {
            if ch.properties.numericType == .decimal, ch.isASCII { run += 1 } else {
                if (4...8).contains(run) { return true }
                run = 0
            }
        }
        return false
    }

    /// 13-19 digits allowing single spaces or dashes between digits.
    static func hasCardLikeDigits(_ line: String) -> Bool {
        var digits = 0
        var pendingSep = false
        var best = 0
        for ch in line.unicodeScalars {
            if ch.isASCII, ch >= "0", ch <= "9" {
                digits += 1
                pendingSep = false
            } else if (ch == " " || ch == "-") && digits > 0 && !pendingSep {
                pendingSep = true
            } else {
                best = max(best, digits)
                digits = 0
                pendingSep = false
            }
        }
        best = max(best, digits)
        return (13...19).contains(best)
    }
}
