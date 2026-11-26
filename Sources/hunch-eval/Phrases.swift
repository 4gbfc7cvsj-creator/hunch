// Learned phrases experiment (`replay`/`rate` with `--phrases history --phrase-strength S`): each
// request carries continuations from a `PhraseModel` built from the sentences Hunch saved from
// your typing (the encrypted local history, read only), as the app does with the experimental
// toggle on.
//
// No test text is ever in the model it is tested with:
// - a case with a time (`capturedAt`: eval captures, and history cases) only gets sentences saved
//   strictly before it;
// - any sentence that contains the case's text, or is contained in it, is left out as well.
// Cases without a time (the synthetic sets) get every saved sentence, as the app would.
import Foundation
import HunchCore
import HunchDecode
import HunchHistory

final class PhraseSource: @unchecked Sendable {
    let strength: Float
    private let snippets: [HunchHistory.StyleSnippet]   // oldest first
    private var models: [Int: PhraseModel] = [:]
    private let lock = NSLock()
    private(set) var requests = 0
    private(set) var withPhrases = 0
    private let debug = ProcessInfo.processInfo.environment["GT_PHRASE_DEBUG"] != nil

    init(strength: Float) throws {
        let (model, state) = EncryptedHistoryStore().loadResult()
        snippets = model.style.snippets.sorted { $0.createdAt < $1.createdAt }
        guard !snippets.isEmpty else { throw EvalError("--phrases history: no saved sentences (load state: \(state))") }
        self.strength = strength
        printErr("learned phrases: \(snippets.count) saved sentences, strength \(strength), curve \(PhraseBiasTuning.exponent)")
    }

    static func make(_ parsed: ParsedArgs) throws -> PhraseSource? {
        guard let source = parsed.value("--phrases") else { return nil }
        guard source == "history" else { throw EvalError("--phrases: only `history` is supported") }
        let strength = parsed.value("--phrase-strength").flatMap(Float.init) ?? LearnedBias.defaultPhraseStrength
        if let curve = parsed.value("--phrase-curve").flatMap(Float.init) { PhraseBiasTuning.exponent = curve }
        return try PhraseSource(strength: strength)
    }

    static let usage = "[--phrases history [--phrase-strength 2] [--phrase-curve 0.5]] "

    private static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private let iso = ISO8601DateFormatter()

    /// The phrase model for one case: sentences saved before it, never one overlapping its text.
    func model(for replayCase: ReplayCase) -> PhraseModel {
        let cutoff = replayCase.capturedAt.flatMap { iso.date(from: $0) }
        let end = cutoff.map { c in snippets.firstIndex { $0.createdAt >= c } ?? snippets.count } ?? snippets.count
        let target = Self.normalized((replayCase.prefix ?? "") + " " + replayCase.text)
        let key = end &* 31 &+ target.hashValue
        lock.lock()
        defer { lock.unlock() }
        if let m = models[key] { return m }
        let texts = snippets[..<end].map(\.text).filter { s in
            let n = Self.normalized(s)
            return !target.contains(n) && !n.contains(Self.normalized(replayCase.text))
        }
        let m = PhraseModel(sentences: texts)
        models[key] = m
        return m
    }

    /// The request's bias with the case's phrases for `before`.
    func bias(for replayCase: ReplayCase, before: String) -> LearnedBias {
        let found = model(for: replayCase).continuations(after: before)
        lock.lock()
        requests += 1
        if !found.isEmpty { withPhrases += 1 }
        lock.unlock()
        // Personal text: only for runs whose logs stay under eval/local/.
        if debug, !found.isEmpty {
            printErr("PHRASES …\(before.suffix(40).debugDescription) -> "
                     + found.map { String(format: "%@ %.2f/%d", $0.text.debugDescription, $0.weight, $0.support) }
                        .joined(separator: " | "))
        }
        return LearnedBias(phrases: found.map { .init(text: $0.text, weight: $0.weight) },
                           phraseStrength: found.isEmpty ? 0 : strength)
    }

    var summary: String {
        String(format: "learned phrases: %d of %d requests had phrases (%.0f %%)", withPhrases, requests,
               requests == 0 ? 0 : Double(withPhrases) * 100 / Double(requests))
    }
}
