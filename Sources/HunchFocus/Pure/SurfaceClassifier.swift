import HunchCore
import HunchPolicy

/// Maps an app and field role to a coarse writing surface. A heuristic; `.unknown` is fine.
public enum SurfaceClassifier {
    static let email: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac"]
    static let chat: Set<String> = [
        "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp",
        "desktop.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "com.microsoft.teams2",
    ]
    static let note: Set<String> = ["com.apple.Notes", "md.obsidian", "net.shinyfrog.bear", "notion.id"]
    static let document: Set<String> = [
        "com.apple.iWork.Pages", "com.microsoft.Word", "com.apple.TextEdit", "com.google.Chrome.app.docs",
    ]
    /// The policy seeds' list, so a terminal added there is classified here too.
    static let terminal = Set(Seeds.terminals)
    /// The seeded code editors: one list, so an editor switched on in Settings is framed as code.
    static let code: Set<String> = Set(Seeds.codeEditors)

    /// `ideSurface` is what `IDESurfaceClassifier` made of the field inside a code editor (nil
    /// elsewhere): its prose inputs (chat, commit message) take the ordinary prose pipeline.
    public static func classify(bundleID: String, role: String?, subrole: String?,
                                ideSurface: IDESurface? = nil) -> SurfaceKind {
        if role == "AXSearchField" || subrole == "AXSearchField" { return .search }
        if email.contains(bundleID) { return .email }
        if chat.contains(bundleID) { return .chat }
        if note.contains(bundleID) { return .note }
        if document.contains(bundleID) { return .document }
        if terminal.contains(bundleID) { return .terminal }
        if code.contains(bundleID) {
            switch ideSurface {
            case .proseInput, .aiChat: return .unknown
            case .terminal: return .terminal
            case .codeBuffer, .unknown, nil: return .code
            }
        }
        return .unknown
    }
}

/// Editability rule for the element gate: a settable value or a text-input role.
public enum EditabilityRule {
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    /// `characterCount` (AXNumberOfCharacters) and `caretLine` (AXInsertionPointLineNumber) are
    /// metadata, read without touching the value. Web dropdowns (`<button role="combobox">`, e.g.
    /// Claude's settings) come through Chromium as an AXComboBox with a settable value but no text
    /// behind it: zero characters and no caret. A real combo box input has text or a caret line.
    public static func isEditable(role: String?, subrole: String?, valueSettable: Bool,
                                  characterCount: Int? = nil, caretLine: Int? = nil) -> Bool {
        if isSelectOnlyComboBox(role: role, characterCount: characterCount, caretLine: caretLine) { return false }
        if valueSettable { return true }
        if let role, textRoles.contains(role) { return true }
        if let subrole, textRoles.contains(subrole) { return true }
        return false
    }

    static func isSelectOnlyComboBox(role: String?, characterCount: Int?, caretLine: Int?) -> Bool {
        guard role == "AXComboBox", characterCount == 0 else { return false }
        guard let caretLine else { return true }
        return caretLine < 0 || caretLine >= Int(Int32.max)
    }
}
