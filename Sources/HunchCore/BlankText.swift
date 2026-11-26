import Foundation

/// Text with what an editor shows as nothing taken away: whitespace, and invisible format
/// characters (zero-width spaces and joiners, U+FEFF, word joiners) that web editors put in an
/// empty box to hold the caret.
public enum BlankText {
    public static func isInvisible(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || s.properties.generalCategory == .format
    }

    /// `text` without leading and trailing whitespace or format characters.
    public static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isInvisible($0) }),
              let last = scalars.lastIndex(where: { !isInvisible($0) }) else { return "" }
        return String(scalars[first...last])
    }
}

extension TextContext {
    /// Nothing typed in the field: only whitespace and invisible format characters, or exactly the
    /// text a web editor shows while empty. Some report it as the value: Discord's empty box holds
    /// U+FEFF and a newline; ChatGPT's holds "Ask ChatGPT\n", named only in its label
    /// (AXTitle/AXDescription), with the caret at the start.
    public var looksEmpty: Bool {
        let text = BlankText.trimmed(before + after)
        if text.isEmpty { return true }
        guard BlankText.trimmed(before).isEmpty else { return false }
        if let p = metadata.placeholder.map(BlankText.trimmed), p == text { return true }
        guard let label = metadata.label.map(BlankText.trimmed), !label.isEmpty else { return false }
        // The label joins title and description ("Ask ChatGPT Ask ChatGPT").
        return label == text || label.hasPrefix(text + " ") || label.hasSuffix(" " + text)
    }
}
