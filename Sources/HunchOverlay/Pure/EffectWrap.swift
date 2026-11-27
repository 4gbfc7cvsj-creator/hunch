import CoreGraphics
import Foundation
import HunchCore

/// Pure layout and timing for playing the pop-in effect on text that isn't a suggestion: dictated
/// text drawn at the caret before it is pasted (wrapped like the field will wrap it), and Write for
/// me's draft as it streams.
public enum EffectWrap {
    /// Splits `text` into the lines a field would show: the first starts at the caret with
    /// `firstWidth` left, the rest get `width`. Breaks after spaces; a word wider than a whole line
    /// breaks anywhere; "\n" starts a new line. A first word that doesn't fit after the caret but
    /// fits a whole line moves to the next line (the first line is then empty). Spaces at a break
    /// are dropped from the line's end.
    public static func lines(_ text: String, firstWidth: CGFloat, width: CGFloat,
                             measure: (String) -> CGFloat) -> [String] {
        let width = max(1, width)
        var out: [String] = []
        var line = ""
        var avail = max(0, firstWidth)
        func push() {
            out.append(trimmedEnd(line))
            line = ""
            avail = width
        }
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (p, paragraph) in paragraphs.enumerated() {
            if p > 0 { push() }
            for token in tokens(String(paragraph)) {
                let candidate = line + token
                if measure(trimmedEnd(candidate)) <= avail {
                    line = candidate
                    continue
                }
                if !line.isEmpty {
                    push()
                    // Spaces that end a line are dropped; one alone opens nothing.
                    if token.allSatisfy(\.isWhitespace) { continue }
                    if measure(trimmedEnd(token)) <= avail { line = token; continue }
                } else if out.isEmpty, avail < width, measure(trimmedEnd(token)) <= width {
                    // The caret is too far right for the first word: it starts the next line.
                    push()
                    line = token
                    continue
                }
                // Wider than a whole line: as many characters as fit, then the rest.
                for ch in token {
                    if !line.isEmpty, measure(trimmedEnd(line + String(ch))) > avail, !ch.isWhitespace { push() }
                    line.append(ch)
                }
            }
        }
        out.append(trimmedEnd(line))
        return out
    }

    /// Words with the spaces after them; spaces before the first word are a token of their own.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace = false
        for ch in s {
            if ch.isWhitespace {
                inSpace = true
                current.append(ch)
            } else {
                if inSpace, !current.isEmpty { out.append(current); current = "" }
                inSpace = false
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func trimmedEnd(_ s: String) -> String {
        var s = s
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }

    /// How long one line's sweep runs (typewriter or per-letter effects reaching its last letter),
    /// in seconds; 0 for effects that play on the whole line at once.
    public static func sweep(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        var t = 0.0
        if recipe.typewriterOn { t = max(t, PopIn.typewriterDuration(recipe, characters: characters)) }
        if PopIn.isPerLetter(recipe) {
            t = max(t, PopIn.sweepRate(recipe, characters: characters) * Double(max(1, characters)))
        }
        return t
    }

    /// When each line's pop-in starts: a sweeping effect reaches the next line once it has crossed
    /// the one before, as if it ran through the whole text; all of them together take at most
    /// `maxStagger` seconds (sped up to fit). Whole-line effects start every line at once.
    public static func lineDelays(_ recipe: PopInRecipe, counts: [Int], maxStagger: TimeInterval = 1.2) -> [TimeInterval] {
        var delays: [TimeInterval] = []
        var t = 0.0
        for c in counts {
            delays.append(t)
            t += c > 0 ? sweep(recipe, characters: c) : 0
        }
        let last = delays.last ?? 0
        guard last > maxStagger, last > 0 else { return delays }
        return delays.map { $0 * maxStagger / last }
    }

    /// How long a streamed line plays before the next one may start: a sweeping effect hands over once
    /// it has crossed the line; a whole-line effect once the line has settled. 0 for None.
    public static func streamGap(_ recipe: PopInRecipe, characters: Int) -> TimeInterval {
        guard !recipe.isEmpty, characters > 0 else { return 0 }
        let s = sweep(recipe, characters: characters)
        return s > 0 ? s : PopIn.totalDuration(recipe, characters: characters)
    }

    /// Seconds until every line has settled in its final look.
    public static func settleTime(_ recipe: PopInRecipe, counts: [Int], delays: [TimeInterval]) -> TimeInterval {
        guard !recipe.isEmpty else { return 0 }
        return zip(counts, delays).filter { $0.0 > 0 }
            .map { $1 + PopIn.totalDuration(recipe, characters: $0) }.max() ?? 0
    }

    /// Extra seconds after settling for particles still in the air to finish.
    public static func linger(_ recipe: PopInRecipe) -> TimeInterval {
        recipe.particlesOn ? max(0, recipe.particleLifeMs) / 1000 + 0.1 : 0
    }

    /// The part of streamed text ready to play: up to and including the last space or line break, so a
    /// word still being written (which could still wrap to the next line) waits. All of it once
    /// `finished`.
    public static func readyEnd(_ text: NSString, from start: Int, finished: Bool) -> Int {
        let end = text.length
        guard !finished, start < end else { return max(start, end) }
        var i = end
        while i > start {
            let c = text.character(at: i - 1)
            if c == 0x20 || c == 0x0A || c == 0x09 || c == 0x3000 { return i }
            // Chinese and Japanese wrap between any two characters: each one is ready once written.
            if c >= 0x2E80, !(0xD800...0xDFFF).contains(c) { return i }
            i -= 1
        }
        return start
    }
}
