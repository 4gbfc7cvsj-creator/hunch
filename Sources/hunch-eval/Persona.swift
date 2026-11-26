// A made-up writer's personal context for `replay`/`rate` (profile field `persona`), so the eval sends
// what the app sends for a user who has been typing with Hunch for a while:
// - general and per-app instructions (Settings);
// - learned words and learned phrases, and per-app writing samples, answered by the app's own
//   `HistoryService` from a throwaway store filled with the persona's past sentences and word list
//   (the real local history is never read or written);
// - a clipboard that is usually empty, sometimes unrelated, and only now and then relevant.
// File format: `eval/replay/persona.json` (see eval/README.md, "Personal context").
import CryptoKit
import Foundation
import HunchCore
import HunchHistory

struct PersonaFile: Decodable {
    struct Sentence: Decodable {
        /// The case-style app name ("Slack") and, for a site, its host.
        var app: String
        var domain: String?
        var daysAgo: Double
        var text: String
    }
    struct ClipboardMix: Decodable {
        /// Percent of cases without a clipboard of their own that get an unrelated one.
        var unrelatedPercent: Int
        var unrelated: [String]
        /// Case ID -> text the writer copied for this message.
        var related: [String: String]
    }
    var globalInstructions: String?
    /// App key (bundle ID, or host for a site) -> that app's instructions.
    var appInstructions: [String: String]?
    /// Case app name -> bundle ID, to make app keys and categories as the app does.
    var bundleIDs: [String: String]
    /// Personalize word choice, 0...3 (Settings default 1.5).
    var strength: Float?
    /// false leaves out learned words and learned phrases (writing samples stay), for ablations.
    var learnedBias: Bool?
    /// Which learned-word bias entries to send: "full" (default, as the app), "midword" (only entries
    /// that finish a half-typed word), "off" (none; phrases and vocabulary notes stay).
    var wordBias: String?
    /// How many learned words to offer as vocabulary notes (`PromptInput.vocabulary`, shown only by
    /// framers with a vocabulary label); default 30, 0 = none.
    var vocabularyNotes: Int?
    /// Relevance-gated notes, as the app sends them: the minimum content-word overlap for the topic match
    /// (`VocabularyGate`, default 2, as the app). `vocabularyGateLimit` caps the words (default 4).
    /// `vocabularyList: true` sends the plain per-app list of `vocabularyNotes` words instead (the first
    /// vocabulary-notes study).
    var vocabularyGate: Int?
    var vocabularyList: Bool?
    /// Pick writing samples as typing would (default true; false = from the whole typed text, as before
    /// 2026-11-19). The app pins a field's samples at its first request
    /// with a pick, a few words in; without this a moment cut late in a message picks them from the
    /// whole typed text, lead-in included ("tell" pulls in "tell Emma I said hi").
    var pinSamplesWhileTyping: Bool?
    var vocabularyGateLimit: Int?
    /// Words added by hand in Settings → Learned words (context-free, so weak). Most learned words come
    /// from `sentences` instead: they are typed over a suggestion, as in the app.
    var learnedWords: [String]
    var sentences: [Sentence]
    var clipboard: ClipboardMix?
}

final class Persona: @unchecked Sendable {
    let file: PersonaFile
    private let service: HistoryService
    private let directory: URL
    /// Field ID per case: the app pins a field's writing samples once it picks them.
    private var fields: [String: FieldID] = [:]
    private let lock = NSLock()

    nonisolated(unsafe) private static var loaded: [String: Persona] = [:]   // guarded by loadLock
    private static let loadLock = NSLock()

    /// A persona `load` already built (replay loads every profile's persona before it runs).
    static func cached(_ path: String) -> Persona? { loadLock.withLock { loaded[path] } }

    /// One persona per file per process.
    static func load(_ path: String) async throws -> Persona {
        if let p = loadLock.withLock({ loaded[path] }) { return p }
        guard let data = FileManager.default.contents(atPath: path) else { throw EvalError("cannot read persona \(path)") }
        let p = try await Persona(file: JSONDecoder().decode(PersonaFile.self, from: data))
        loadLock.withLock { loaded[path] = p }
        return p
    }

    private init(file: PersonaFile) async throws {
        self.file = file
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hunch-eval-persona-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = EncryptedHistoryStore(url: directory.appendingPathComponent("history.bin"),
                                          keys: InMemoryKeyProvider(key: SymmetricKey(size: .bits256)))
        let categories = AppCategories(patches: [:])
        let now = Date()
        var model = VocabularyModel()
        for s in file.sentences.sorted(by: { $0.daysAgo > $1.daysAgo }) {
            let key = AppKey.make(bundleID: file.bundleIDs[s.app], urlHost: s.domain)
            _ = model.style.add(text: s.text, at: now.addingTimeInterval(-s.daysAgo * 86_400), appKey: key,
                                categoryOf: { categories.category(of: $0) })
        }
        try store.save(model)
        service = HistoryService(store: store, saveDelay: .seconds(3600))
        await service.setAppCategories { categories }
        for w in file.learnedWords { _ = try await service.add(text: w, now: now) }
        let learned = await Self.typeSentences(file, into: service, now: now)
        printErr("persona: \(file.sentences.count) sentences, \(file.learnedWords.count) words added by hand, "
                 + "\(learned.count) learned from typing: \(learned.sorted().joined(separator: ", "))")
    }

    /// Plays every past sentence through the app's learning path, oldest first, each in its own field on
    /// its own date: at each word a suggestion is showing that the writer types over with their own word
    /// (`OutcomeTracker` → `.typedOver`). So the app's own rules decide which words are learned, with the
    /// two words before them as context, and a word only becomes active once typed often enough on
    /// enough days. The shown suggestion is a placeholder no one types, so no real word is penalized.
    private static func typeSentences(_ file: PersonaFile, into service: HistoryService, now: Date) async -> [String] {
        let placeholder = " qqzx"
        for (n, s) in file.sentences.sorted(by: { $0.daysAgo > $1.daysAgo }).enumerated() {
            let key = AppKey.make(bundleID: file.bundleIDs[s.app], urlHost: s.domain)
            let field = FieldID(pid: 3, elementHash: n + 1, generation: 1)
            var t = now.addingTimeInterval(-s.daysAgo * 86_400)
            var typed = ""
            // Split into words, keeping each word's leading space (none for CJK, which is not learned).
            let words = s.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            for (i, w) in words.enumerated() {
                let before = typed
                await service.record(.suggestionShown(field: field, before: before, suggestion: before.isEmpty ? String(placeholder.dropFirst()) : placeholder,
                                                      scores: [], boosted: []), at: t)
                typed += (i == 0 ? "" : " ") + w
                t = t.addingTimeInterval(1.5)
                await service.record(.textChanged(field: field, before: typed + " ", appKey: key), at: t)
            }
            await service.record(.focusLeft(field: field), at: t.addingTimeInterval(2))
        }
        _ = await service.consolidateIfDue(idle: true, now: now)
        return await service.activeWords().sorted()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func appKey(_ c: ReplayCase) -> String? {
        AppKey.make(bundleID: c.app.flatMap { file.bundleIDs[$0] }, urlHost: c.domain)
    }

    /// The clipboard this case runs with: its own, else the persona's mix (stable per case ID).
    func clipboard(for c: ReplayCase) -> String? {
        if let own = c.clipboard { return own }
        guard let mix = file.clipboard else { return nil }
        if let related = mix.related[c.id] { return related }
        let h = Self.stableHash(c.id)
        guard !mix.unrelated.isEmpty, Int(h % 100) < mix.unrelatedPercent else { return nil }
        return mix.unrelated[Int((h / 100) % UInt64(mix.unrelated.count))]
    }

    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    private func field(_ c: ReplayCase) -> FieldID {
        lock.withLock {
            if let f = fields[c.id] { return f }
            let f = FieldID(pid: 2, elementHash: fields.count + 1, generation: 1)
            fields[c.id] = f
            return f
        }
    }

    /// Instructions, learned words and phrases, and writing samples, as the app adds them
    /// (`SuggestionCoordinator.makeRequest` and `LearningController`), with learning on.
    func personalize(_ request: inout CompletionRequest, case c: ReplayCase, before: String) async {
        let key = appKey(c)
        request.input.globalInstructions = file.globalInstructions
        request.input.appInstructions = key.flatMap { file.appInstructions?[$0] }
        guard c.surface != .code else { request.input.styleExamples = []; return }   // learning not allowed in code
        let strength = file.strength ?? 1.5
        if file.pinSamplesWhileTyping ?? true {
            // Requests start at the second word on the line, as `TypedWords`' floor in the app.
            let words = before.split(separator: " ", omittingEmptySubsequences: false)
            var n = 2
            while n < words.count,
                  await service.styleExamples(for: words.prefix(n).joined(separator: " "), field: field(c), appKey: key, k: 2).isEmpty {
                n += 1
            }
        }
        request.input.styleExamples = await service.styleExamples(for: before, field: field(c), appKey: key, k: 2)
        guard file.learnedBias ?? true else { return }
        if file.vocabularyList != true {
            let overlap = file.vocabularyGate ?? 2
            request.input.vocabulary = await service.gatedVocabulary(before: before, screen: request.input.screenContext,
                                                                     appKey: key, limit: file.vocabularyGateLimit ?? 4,
                                                                     minOverlap: overlap).map(\.text)
        } else {
            request.input.vocabulary = await service.vocabularyNotes(appKey: key, limit: file.vocabularyNotes ?? 30)
        }
        let mode = file.wordBias ?? "full"
        var bias = await service.bias(for: before, strength: strength * 2, appKey: key, midWordOnly: mode == "midword")
        if mode == "off" { bias.entries = [] }
        let phraseStrength = LearnedBias.phraseStrength(personalize: strength)
        if phraseStrength > 0 {
            bias.phrases = await service.phrases(for: before, appKey: key).map { .init(text: $0.text, weight: $0.weight) }
            bias.phraseStrength = bias.phrases.isEmpty ? 0 : phraseStrength
        }
        request.bias = bias
        if debug {
            printErr("PERSONA [\(c.id)] key \(key ?? "-") | app instr: \(request.input.appInstructions ?? "-") | "
                     + "vocab \(request.input.vocabulary) | strength \(bias.strength) words: \(bias.entries.prefix(6).map { "\($0.text)=\(String(format: "%.2f", $0.weight))" }) | phrases: \(bias.phrases.prefix(3).map(\.text)) | "
                     + "style: \(request.input.styleExamples) | clipboard: \(request.input.clipboard ?? "-")")
        }
    }

    private let debug = ProcessInfo.processInfo.environment["GT_PERSONA_DEBUG"] != nil
}
