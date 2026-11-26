import Foundation

/// Interface text next to the text field (status boxes, toolbars, model pickers): lines that read
/// like labels, not writing. Screen cleanup drops the run of them nearest the field, so the newest
/// message is the last screen line before the writer's text. Pure.
///
/// Scanning outward from the field, a line is
/// - interface (dropped): mostly digits, symbols or separators ("53%", "©2d13h", "+0 −0"); short
///   segments joined by separators ("Opus 5.5 · Medium · Auto", "last turn 1m • session 8h00"); or a
///   short row of capitalized words with a number ("Opus 5.5 Medium Auto");
/// - writing (ends the scan, kept): a chat sender header, a line of four or more words, or one ending
///   in sentence punctuation;
/// - anything else (kept, scan goes on): short plain words like "Idle", "cache" or a quick "ok".
public enum InterfaceLines {
    enum Kind: Equatable { case interface, writing, other }

    /// Characters that join label segments in toolbars and status lines.
    static let separators: Set<Character> = ["·", "•", "|", "‧", "∙", "⋅", "◦"]
    /// Most words a segment between separators may have.
    static let segmentWords = 3
    /// Words from which a line reads as writing.
    static let writingWords = 4
    static let sentenceEnd: Set<Character> = [".", "?", "!", ":", "。", "？", "！", "：", "…"]

    static func kind(_ line: String) -> Kind {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .other }
        if ChatHeader.isHeader(text) { return .writing }
        if isInterface(text) { return .interface }
        if let last = text.last, sentenceEnd.contains(last) { return .writing }
        if words(text).count >= writingWords { return .writing }
        if text.contains(where: isCJKCharacter), text.count >= 4 { return .writing }
        return .other
    }

    static func isInterface(_ text: String) -> Bool {
        let visible = text.filter { !$0.isWhitespace }
        guard !visible.isEmpty else { return false }
        // Mostly digits and symbols.
        let letters = visible.filter { $0.isLetter }.count
        if letters * 2 <= visible.count { return true }
        // One short token mixing letters and digits: a counter or timer, often misread by OCR ("C5d13H").
        if visible.count == text.count, visible.count <= 8, visible.contains(where: \.isNumber),
           visible.contains(where: \.isLetter) {
            return true
        }
        // Short segments joined by separators; a leading bullet alone is a list item, not a join.
        let segments = text.split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if segments.count >= 2, segments.allSatisfy({ words($0).count <= segmentWords }) { return true }
        // A short row of capitalized words with a number in it ("Opus 5.5 Medium Auto").
        let ws = words(text)
        if ws.count >= 2, ws.count <= 6, ws.contains(where: { $0.contains(where: \.isNumber) }),
           ws.allSatisfy({ w in w.first.map { $0.isUppercase || $0.isNumber || !$0.isLetter } ?? true }),
           !(text.last.map(sentenceEnd.contains) ?? false) {
            return true
        }
        return false
    }

    /// Indices of `lines` (nearest the field first) that belong to the interface run: the interface
    /// lines met before the first line that reads as writing.
    static func run(_ lines: [String]) -> [Int] {
        var dropped: [Int] = []
        for (index, line) in lines.enumerated() {
            switch kind(line) {
            case .interface: dropped.append(index)
            case .writing: return dropped
            case .other: continue
            }
        }
        return dropped
    }

    /// For text in reading order with the field below it (eval captures, which keep no positions):
    /// the text without the interface run at its end.
    public static func droppingTrailingRun(_ text: String) -> (text: String, dropped: [String]) {
        var lines = text.components(separatedBy: "\n")
        let nearestFirst = Array(lines.indices.reversed())
        let run = Set(InterfaceLines.run(nearestFirst.map { lines[$0] }).map { nearestFirst[$0] })
        let dropped = lines.indices.filter(run.contains).map { lines[$0] }
        lines = lines.indices.filter { !run.contains($0) }.map { lines[$0] }
        return (lines.joined(separator: "\n"), dropped)
    }

    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    static func isCJKCharacter(_ c: Character) -> Bool {
        c.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
                || (0xAC00...0xD7AF).contains($0.value)
        }
    }
}
