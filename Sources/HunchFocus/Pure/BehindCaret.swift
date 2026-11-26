import CoreGraphics
import Foundation

/// Pure math for autocorrect catch-up: a word that ends some way before a collapsed caret.
public enum BehindCaret {
    /// The range of the word: it starts `span` UTF-16 units before the caret and is `word` long.
    /// Nil when it would start before the field or reach past the caret.
    public static func wordRange(caret: Int, span: Int, word: Int) -> (location: Int, length: Int)? {
        guard caret >= 0, span >= word, word > 0, caret - span >= 0 else { return nil }
        return (caret - span, word)
    }

    /// Where the caret goes back to once the word changed length.
    public static func restoredCaret(caret: Int, word: Int, replacement: Int) -> Int {
        caret - word + replacement
    }

    /// A word's bounds worth highlighting: a real box no taller than a few lines (hosts that answer
    /// with the whole line or field box, or nothing, get no highlight).
    /// Why a word's bounds behind the caret weren't available (logged to find hosts without them).
    public enum BoundsMiss: String, Error, Sendable, Equatable {
        case focusMoved, noCaret, notCollapsed, noBounds, unusable, timedOut
    }

    /// A box that could be one word of `characters` characters on one line: not much wider than the
    /// word could be at its height (a host answering with the whole line or field is rejected).
    public static func fitsWord(_ rect: CGRect, characters: Int) -> Bool {
        rect.width <= max(24, CGFloat(max(1, characters)) * rect.height * 1.2) && rect.height <= 80
    }

    public static func usableWordRect(_ rect: CGRect?, maxHeight: CGFloat = 120) -> CGRect? {
        guard let rect, rect.width > 0.5, rect.height > 2, rect.height <= maxHeight, rect.width <= 1200,
              rect.minX.isFinite, rect.minY.isFinite else { return nil }
        return rect
    }
}
