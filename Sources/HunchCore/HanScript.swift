import Foundation

/// Traditional ↔ simplified Chinese via the system's ICU transforms. Word lists and keyword checks
/// are written once (simplified) and compared against `simplified(_:)` of the input, so they work
/// for both scripts; output can be matched to the script the user writes in.
public enum HanScript {
    public static func simplified(_ text: String) -> String {
        guard hasHan(text) else { return text }
        return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    public static func traditional(_ text: String) -> String {
        guard hasHan(text) else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    /// Characters that exist only in the traditional script appear in `text`.
    public static func usesTraditional(_ text: String) -> Bool {
        let han = String(text.unicodeScalars.filter(isHan).map(Character.init))
        return !han.isEmpty && simplified(han) != han
    }

    /// Characters that exist only in the simplified script appear in `text`.
    public static func usesSimplified(_ text: String) -> Bool {
        let han = String(text.unicodeScalars.filter(isHan).map(Character.init))
        return !han.isEmpty && traditional(han) != han
    }

    static func hasHan(_ text: String) -> Bool { text.unicodeScalars.contains(where: isHan) }

    static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}
