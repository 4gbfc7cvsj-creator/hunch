/// How the selected keyboard input source handles composed text, which decides whether Tab-accept
/// has to finish a composition first. Pure: classified from the source's ID and type.
public enum InputMethodKind: Sendable, Equatable {
    /// A plain keyboard layout: nothing is ever composed.
    case plainLayout
    /// Keeps chosen characters in its own buffer until Return or Escape (Zhuyin, Japanese). A host
    /// that doesn't mark that buffer shows it as ordinary text, so it must be finished before an
    /// accept. Also the guess for input methods not listed here.
    case buffering
    /// Hands each character to the app as soon as it's chosen (Pinyin, Shuangpin, Cangjie, Sucheng,
    /// Wubi commit on Space or a number key; Korean commits each syllable as the next one starts).
    /// Only a Hangul syllable still being built can be pending.
    case commitsAsTyped

    public var isInputMethod: Bool { self != .plainLayout }

    /// Source ID prefixes of input methods that commit as they go. Matched on the input mode ID
    /// (`com.apple.inputmethod.TCIM.Cangjie`), which is what the current source reports.
    static let committingPrefixes = [
        "com.apple.inputmethod.SCIM.ITABC", "com.apple.inputmethod.SCIM.Shuangpin",
        "com.apple.inputmethod.SCIM.WBX", "com.apple.inputmethod.SCIM.WBH",
        "com.apple.inputmethod.TCIM.Pinyin", "com.apple.inputmethod.TCIM.Shuangpin",
        "com.apple.inputmethod.TCIM.Cangjie", "com.apple.inputmethod.TCIM.Jianyi",
        "com.apple.inputmethod.TCIM.WBH", "com.apple.inputmethod.Korean",
    ]

    /// `type` is the source's `kTISPropertyInputSourceType` value.
    public static func classify(id: String?, type: String?) -> InputMethodKind {
        let isMethod = (id?.hasPrefix("com.apple.inputmethod.") ?? false)
            || type == "TISTypeKeyboardInputMode" || type == "TISTypeKeyboardInputMethodModeEnabled"
        guard isMethod else { return .plainLayout }
        if let id, committingPrefixes.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) {
            return .commitsAsTyped
        }
        return .buffering
    }
}
