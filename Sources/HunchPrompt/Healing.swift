import HunchCore

/// Token healing (design §5.2): the trailing horizontal whitespace plus any trailing partial word
/// leave the prompt and become the decoder's required prefix, so the model picks its own natural
/// token boundary (SentencePiece/BPE vocabularies put the space inside the word token).
///
/// Rules:
/// - A partial word is a run of letters, digits, combining marks, and apostrophes (Unicode-aware).
/// - CJK characters are never part of the healed span (those scripts have no word spaces).
/// - Line breaks always stay in the prompt; only spaces/tabs are healed.
/// - A run longer than `maxPartialWordLength` characters (an identifier, a pasted token, ...) is
///   not healed, so the decoder is never forced through a long byte string.
public enum Healing {
    public static let maxPartialWordLength = 40

    public static func split(before: String) -> HealingSplit {
        let chars = Array(before)
        var wordStart = chars.count
        while wordStart > 0, TextClass.isWordCharacter(chars[wordStart - 1]) {
            wordStart -= 1
        }
        if chars.count - wordStart > maxPartialWordLength {
            return HealingSplit(promptText: before, requiredPrefix: "")
        }
        var spanStart = wordStart
        while spanStart > 0, TextClass.isHorizontalSpace(chars[spanStart - 1]) {
            spanStart -= 1
        }
        return HealingSplit(promptText: String(chars[..<spanStart]), requiredPrefix: String(chars[spanStart...]))
    }
}
