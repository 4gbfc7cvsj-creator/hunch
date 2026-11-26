// Style-example experiment (design decision 7): background snippets of the writer's own past text,
// chosen by word overlap with the text before the caret. Eval-only; the snippets are synthetic.
// The chosen snippets travel in `PromptInput.styleExamples`; the framers own the label.
import Foundation

struct StyleSnippet: Codable, Sendable {
    var id: String
    var text: String
}

struct StyleSetting: Sendable {
    var snippets: [StyleSnippet]
    var k: Int
    /// Pad with unrelated snippets (file order) when fewer than k overlap: a worst case for irrelevant context.
    var fill: Bool
}

func loadSnippets(path: String) throws -> [StyleSnippet] {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
        throw EvalError("cannot read snippets file \(path)")
    }
    return try text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { return nil }
        return try JSONDecoder().decode(StyleSnippet.self, from: Data(t.utf8))
    }
}

private let styleStopWords: Set<String> = [
    "the", "and", "to", "of", "a", "an", "in", "is", "it", "i", "my", "for", "on", "at", "be", "we", "you", "that",
    "this", "with", "was", "are", "me", "so", "but", "or", "if", "do", "did", "im", "its",
]

/// Content words of a text for the overlap score.
func styleWords(_ text: String) -> Set<String> {
    wordSet(text).subtracting(styleStopWords)
}

/// Up to `k` snippets ranked by distinct shared content words with the tail of `before`; ties keep file order.
func selectSnippets(_ setting: StyleSetting, before: String) -> [StyleSnippet] {
    guard setting.k > 0 else { return [] }
    let tail = before.split(whereSeparator: \.isWhitespace).suffix(60).joined(separator: " ")
    let target = styleWords(tail)
    let scored = setting.snippets.enumerated().map { ($0.offset, $0.element, styleWords($0.element.text).intersection(target).count) }
    var picked = scored.filter { $0.2 > 0 }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }.prefix(setting.k).map(\.1)
    if setting.fill && picked.count < setting.k {
        for item in scored where picked.count < setting.k && !picked.contains(where: { $0.id == item.1.id }) {
            picked.append(item.1)
        }
    }
    return Array(picked)
}

/// True when the completion repeats a run of four or more words from a snippet (verbatim copying).
func copiesSnippet(_ completion: String, _ snippets: [StyleSnippet]) -> Bool {
    let words = completion.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    guard words.count >= 4 else { return false }
    let runs = Set((0...(words.count - 4)).map { words[$0..<($0 + 4)].joined(separator: " ") })
    for s in snippets {
        let sw = s.text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
        guard sw.count >= 4 else { continue }
        for i in 0...(sw.count - 4) where runs.contains(sw[i..<(i + 4)].joined(separator: " ")) { return true }
    }
    return false
}
