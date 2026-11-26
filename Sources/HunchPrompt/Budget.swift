import Foundation
import HunchCore

/// Token-budget helpers for framers. All truncation happens at word boundaries (or between CJK
/// characters); framer markers are never passed through these, so a marker is never split.
enum Budget {
    /// Character offsets where `text` may be cut: the start, after any whitespace run, and on
    /// either side of a CJK character.
    static func cutPoints(_ chars: [Character]) -> [Int] {
        var points: [Int] = [0]
        if chars.isEmpty { return points }
        for i in 1..<chars.count {
            let prev = chars[i - 1], cur = chars[i]
            if (prev.isWhitespace && !cur.isWhitespace) || TextClass.isCJK(prev) || TextClass.isCJK(cur) {
                points.append(i)
            }
        }
        return points
    }

    /// The longest suffix of `text` starting at a cut point whose token count is ≤ `maxTokens`.
    /// Falls back to a character-level cut when no word boundary fits (one enormous word).
    static func tail(_ text: String, maxTokens: Int, counter: any TokenCounting) -> String {
        if text.isEmpty || maxTokens <= 0 { return maxTokens <= 0 ? "" : text }
        if counter.tokenCount(text) <= maxTokens { return text }
        let chars = Array(text)
        let points = cutPoints(chars)
        if let best = earliestFitting(points, chars: chars, maxTokens: maxTokens, counter: counter) {
            return String(chars[best...])
        }
        let all = Array(0...chars.count)
        if let best = earliestFitting(all, chars: chars, maxTokens: maxTokens, counter: counter) {
            return String(chars[best...])
        }
        return ""
    }

    /// Binary search for the earliest start offset whose suffix fits (token counts shrink as the
    /// start moves right).
    private static func earliestFitting(_ starts: [Int], chars: [Character], maxTokens: Int,
                                        counter: any TokenCounting) -> Int? {
        var lo = 0, hi = starts.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let start = starts[mid]
            if start < chars.count, counter.tokenCount(String(chars[start...])) <= maxTokens {
                found = start
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        return found
    }

    /// The longest prefix of `text` ending at a word boundary whose token count is ≤ `maxTokens`.
    static func head(_ text: String, maxTokens: Int, counter: any TokenCounting) -> String {
        if maxTokens <= 0 || text.isEmpty { return "" }
        if counter.tokenCount(text) <= maxTokens { return text }
        let chars = Array(text)
        // Ends: offsets right before a cut point (excluding 0), trimmed of trailing whitespace.
        let ends = cutPoints(chars).dropFirst().map { $0 }
        var lo = 0, hi = ends.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let piece = trimmedEnd(chars[..<ends[mid]])
            if counter.tokenCount(piece) <= maxTokens {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        if let found { return trimmedEnd(chars[..<ends[found]]) }
        return ""
    }

    private static func trimmedEnd(_ slice: ArraySlice<Character>) -> String {
        var end = slice.endIndex
        while end > slice.startIndex, slice[end - 1].isWhitespace { end -= 1 }
        return String(slice[slice.startIndex..<end])
    }
}

/// Text that came from the user, a field, or the screen, cleaned for a single prompt block.
func cleaned(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
