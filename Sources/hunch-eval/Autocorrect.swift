// `autocorrect`: fast typing with slips, replayed key by key through autocorrect ("Fix automatically"
// on), scored against the clean text. Cases: the user's real fast-typing samples, plus the replay
// corpus's English texts with seeded synthetic slips (TypoNoise). Reads come at a random subset of
// keystrokes, as when typing fast; a model decision keeps autocorrect busy for as long as it took.
import Foundation
import HunchCore
import HunchEngine
import HunchHistory
import HunchLlama
import HunchModels
import HunchPrompt
import HunchText

/// A real fast-typing sample with its slips marked (eval/autocorrect/samples.jsonl).
struct AutocorrectSample: Codable, Sendable {
    struct Slip: Codable, Sendable { var kind: TypoSlip.Kind; var words: [Int] }
    var id: String
    var surface: SurfaceKind?
    var app: String?
    var clean: String
    var typed: String
    var slips: [Slip]
    /// Key presses saved with the typing sample (`RecordedKey`), when there are any.
    var keys: [RecordedKey]?
    /// Text on the screen while typing (screen words: names and terms there are left alone).
    var screen: String?
}

/// The learned words used in each case's app (or its category), as the app's coordinator gives the finder.
struct LearnedScope: Sendable {
    var places: LearnedWordPlaces
    var categories: AppCategories
    func here(for c: AutocorrectCase) -> Set<String>? { places.here(appKey: evalAppKey(c.app), categories: categories) }
}

struct AutocorrectCase: Sendable {
    var id: String
    var source: String
    var surface: SurfaceKind
    var app: String?
    var noisy: NoisyText
    var keys: [RecordedKey]? = nil
    var screen: String? = nil
}

/// What autocorrect ("Fix automatically") does to a text typed key by key: each read goes to the
/// app's `UnsettledSpan`, and its step is applied the way the app applies it (`SpanFix.edit`,
/// after the model's choice for a waiting word). Optimistic where the app may fail: a fix lands
/// exactly `applyMs` after it was decided.
@MainActor
final class AutocorrectSimulator {
    typealias Scorer = (_ surface: SurfaceKind, _ app: String?, _ head: String, _ continuations: [String]) async -> [Float]?

    struct Decision: Sendable {
        var ms: Double
        var choice: String
        var slots = 1
        var combos = 0
        /// Decided while Return was held (a settling point).
        var atReturn = false
        /// Slots with key-timing evidence.
        var timed = 0
    }

    struct Run: Sendable {
        var output: String
        var decisions: [Decision] = []
        var immediateFixes = 0
        var delayedFixes = 0
        var lostFixes = 0
        var returnSteps = 0
        /// Key timing: recorded with the sample (else synthetic, or none).
        var recordedTiming = false
        /// Hunch's own fixes still in `output` (as the app's fix history keeps them), oldest first.
        var ownFixes: [OwnFix] = []
    }

    let finder: CorrectionFinder
    /// Learned words offered as fixes per case app (`CorrectionFinder.learnedHere`). Nil: all equal.
    var learnedScope: LearnedScope?
    let scorer: Scorer?
    /// Typing speed (characters per second) and the chance that a keystroke gets a read.
    let cps: Double
    let readChance: Double
    /// Time to put a fix into the field, during which reads are skipped.
    static let applyMs = 40.0
    static let timeoutMs = 700.0
    /// Longest a decision may hold Return (`AutocorrectFollowUp.returnBudget`).
    nonisolated static let returnBudgetMs = 200.0
    /// Return settles the words before it (stage 5); false: the stage 4 behaviour.
    let settleAtReturn: Bool
    /// Key timing for the finder (`CorrectionFinder.keyTiming`): nil = none (before key timing).
    let timingModel: KeyTimingModel?
    /// Deterministic replay (`--fixed-ms`): no decision runs out of time, and each one takes this
    /// long on the simulated clock whatever it took, so machine load can't change the outcome.
    let fixedDecisionMs: Double?

    init(finder: CorrectionFinder, scorer: Scorer?, cps: Double, readChance: Double, settleAtReturn: Bool = false,
         timingModel: KeyTimingModel? = nil, fixedDecisionMs: Double? = nil) {
        self.timingModel = timingModel
        self.fixedDecisionMs = fixedDecisionMs
        self.settleAtReturn = settleAtReturn
        self.finder = finder
        self.scorer = scorer
        self.cps = cps
        self.readChance = readChance
    }

    func run(_ c: AutocorrectCase, seed: UInt64) async -> Run {
        var rng = SeededGenerator(seed: seed ^ 0xA5A5)
        var finder = self.finder
        finder.learnedHere = learnedScope?.here(for: c)
        if let screen = c.screen {
            let spell = SystemSpellChecker.cached()
            finder.screenWords = ScreenWords(text: screen) { spell.isMisspelled($0, languages: ["en"]) }
        }
        var run = Run(output: "")
        var buffer = ""
        var span = UnsettledSpan<Int>()
        var clock = 0.0
        var busyUntil = 0.0
        var missedRead = false
        var landing: (fix: SpanFix, at: Double, delayed: Bool)?
        let keyMs = 1000 / cps
        // Key timing: the sample's own when it was saved with one, else the synthetic model.
        var strokes: [KeyStroke]?
        if let timingModel {
            if let keys = c.keys, let recorded = RecordedKey.strokes(for: c.noisy.typed, from: keys) {
                strokes = recorded
                run.recordedTiming = true
            } else {
                strokes = timingModel.strokes(clean: c.noisy.clean, typed: c.noisy.typed, cps: cps, seed: seed)
            }
        }
        var keyLog = KeyTimingLog()
        func finding(_ before: String) -> CorrectionFinding? {
            guard strokes != nil else { return finder.finding(before: before, deferAmbiguous: true) }
            var timed = finder
            timed.keyTiming = keyLog
            return timed.finding(before: before, deferAmbiguous: true)
        }

        func land() {
            guard let l = landing else { return }
            landing = nil
            // The text typed while the fix was on its way follows the fix's text.
            guard let edit = l.fix.edit(now: buffer) else {
                if debugAC { printErr("LOST \(l.fix) now=\(buffer)") }
                run.lostFixes += 1; return
            }
            let at = buffer.utf16.count - edit.original.utf16.count
            // A fix reaching into an earlier one replaces it (the app's history drops that entry);
            // fixes in the text typed after the word (a fix that landed late) stay and move along,
            // as the app's history keeps them (`FixHistory.rewriteEnd`).
            let wordEnd = at + l.fix.word.utf16.count
            let delta = l.fix.replacement.utf16.count - l.fix.word.utf16.count
            run.ownFixes = run.ownFixes.compactMap { f in
                if f.range.upperBound <= at { return f }
                guard f.range.lowerBound >= wordEnd else { return nil }
                var g = f
                g.range = (f.range.lowerBound + delta)..<(f.range.upperBound + delta)
                return g
            }
            run.ownFixes.append(OwnFix(range: at..<(at + l.fix.replacement.utf16.count), typed: l.fix.word,
                                       fixed: l.fix.replacement,
                                       confidence: finder.confidence(typed: l.fix.word, fixed: l.fix.replacement)))
            buffer = edit.after
            span.rewriteEnd(from: edit.original, to: edit.fixed)
            if l.delayed { run.delayedFixes += 1 } else { run.immediateFixes += 1 }
        }

        /// One decision by the model; nil scores when there is no model or it took longer than `limitMs`.
        func decide(_ trigger: StretchTrigger, limitMs: Double, atReturn: Bool) async -> (JointChoice.Resolution, Double) {
            let combos = JointChoice.combos(trigger.slots)
            let start = ContinuousClock.now
            var scores: [Float]?
            if let scorer {
                scores = await scorer(c.surface, c.app, trigger.head,
                                      combos.map { JointChoice.continuation($0, trigger) })
            }
            let ms = scorer == nil ? 0 : milliseconds(ContinuousClock.now - start)
            if fixedDecisionMs == nil, ms > limitMs { scores = nil }
            let resolution = JointChoice.resolve(trigger, combos: combos, scores: scores)
            if debugAC { printErr("CHOOSE\(atReturn ? "@RETURN" : "") \(trigger.slots.map { ($0.misspelled, $0.candidates, $0.preferred ?? "-", $0.timing.map { "T\($0.rolled.map { $0 ? 1 : 0 })\($0.doubleHit.map { $0 ? 1 : 0 })" } ?? "") }) gaps=\(trigger.gaps) → \(resolution.choices) \(Int(ms))ms combos=\(combos.count) len=\(combos.map { JointChoice.continuation($0, trigger).count }.max() ?? 0) head=\(trigger.head.count)") }
            if let scores, confusedGapLog { logConfusedGaps(trigger, combos: combos, scores: scores) }
            let kind = scores == nil ? "no model" : resolution.fix != nil ? "fix"
                : resolution.offer != nil ? "unsure" : "keep"
            run.decisions.append(Decision(ms: ms, choice: kind, slots: trigger.slots.count, combos: combos.count,
                                          atReturn: atReturn, timed: trigger.slots.filter { $0.timing != nil }.count))
            return (resolution, fixedDecisionMs ?? min(ms, limitMs))
        }

        func read() async {
            switch span.read(field: 0, before: buffer, finding: finding) {
            case nil:
                break
            case .fix(let fix)?:
                if debugAC { printErr("FIX \(fix.word) → \(fix.replacement)") }
                landing = (fix, clock + Self.applyMs, false)
                busyUntil = clock + Self.applyMs
            case .choose(let trigger)?:
                let (resolution, ms) = await decide(trigger, limitMs: Self.timeoutMs, atReturn: false)
                if let fix = resolution.fix {
                    landing = (fix, clock + ms + Self.applyMs, true)
                    busyUntil = clock + ms + Self.applyMs
                } else {
                    busyUntil = clock + ms
                }
            }
        }

        /// Return (a line break, or sending at the end of the text): held while the words before the
        /// caret are settled (`UnsettledSpan.settle`), each decision within `returnBudgetMs`.
        func pressReturn() async {
            guard settleAtReturn else { return }
            if let l = landing { clock = max(clock, l.at); land() }
            clock = max(clock, busyUntil)
            for _ in 0..<(UnsettledSpan<Int>.maxSlots + 3) {
                guard let step = span.settle(field: 0, before: buffer, finding: finding) else { break }
                run.returnSteps += 1
                switch step {
                case .fix(let fix):
                    if debugAC { printErr("FIX@RETURN \(fix.word) → \(fix.replacement)") }
                    landing = (fix, clock + Self.applyMs, false)
                case .choose(let trigger):
                    let (resolution, ms) = await decide(trigger, limitMs: Self.returnBudgetMs, atReturn: true)
                    clock += ms
                    if let fix = resolution.fix { landing = (fix, clock + Self.applyMs, true) }
                }
                if let l = landing { clock = l.at; land() }
            }
        }

        let chars = Array(c.noisy.typed)
        for (k, ch) in chars.enumerated() {
            if ch.isNewline { await pressReturn() }
            if let strokes, k < strokes.count { keyLog.append(strokes[k]) }
            buffer.append(ch)
            clock += keyMs
            if let l = landing, clock >= l.at { land() }
            if clock < busyUntil { missedRead = true; continue }
            let isLast = k == chars.count - 1
            if isLast || missedRead || Double.random(in: 0..<1, using: &rng) < readChance {
                missedRead = false
                await read()
            }
        }
        // Typing stopped: what is in flight lands, and reads come in until nothing is left to do.
        for _ in 0..<(UnsettledSpan<Int>.maxWords + 2) {
            if let l = landing { clock = max(clock, l.at); land() }
            clock = max(clock, busyUntil)
            await read()
            if landing == nil, clock >= busyUntil { break }
        }
        if let l = landing { clock = max(clock, l.at); land() }
        await pressReturn()  // sent, or the end of the paragraph
        run.output = buffer
        return run
    }
}

private let debugAC = ProcessInfo.processInfo.environment["GT_DEBUG_AC"] != nil
/// `GT_CONFUSED_GAPS=1`: one `GAP` line per confused word the model scored: the typed word, its best
/// rival, and how far the rival is ahead (negative: behind), for a margin sweep (other slots' slip
/// costs left out).
private let confusedGapLog = ProcessInfo.processInfo.environment["GT_CONFUSED_GAPS"] != nil

private func logConfusedGaps(_ trigger: StretchTrigger, combos: [JointChoice.Combo], scores: [Float]) {
    for (s, slot) in trigger.slots.enumerated() where slot.confusable {
        var best = [Float](repeating: -.infinity, count: slot.candidates.count + 1)
        for (k, combo) in combos.enumerated() where scores[k].isFinite { best[combo[s]] = max(best[combo[s]], scores[k]) }
        guard let r = best.indices.dropFirst().max(by: { best[$0] < best[$1] }), best[r].isFinite else { continue }
        let others = best.indices.filter { $0 != r }.map { best[$0] }.max() ?? -.infinity
        printErr("GAP\t\(slot.misspelled)\t\(slot.candidates[r - 1])\t\(String(format: "%.2f", best[r] - others))\t\(trigger.head.suffix(80).replacingOccurrences(of: "\n", with: " "))")
    }
}

// MARK: Command

func runAutocorrectCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--model", "--cases", "--samples", "--variants", "--seed", "--rate",
                                                 "--reads", "--cps", "--out", "--limit", "--fixed-ms", "--slip-profile", "--confused-margin"])
    do {
        let out = parsed.value("--out") ?? "eval/reports/autocorrect-\(timestampString())"
        let cases = try loadAutocorrectCases(
            corpora: parsed.values("--cases").isEmpty ? ["eval/replay/cases.jsonl", "eval/replay/long-cases.jsonl"]
                : parsed.values("--cases"),
            samples: parsed.value("--samples") ?? "eval/autocorrect/samples.jsonl",
            variants: Int(parsed.value("--variants") ?? "2") ?? 2,
            seed: UInt64(parsed.value("--seed") ?? "1") ?? 1,
            rate: Double(parsed.value("--rate") ?? "0.25") ?? 0.25,
            limit: parsed.value("--limit").flatMap(Int.init))
        let reads = (parsed.values("--reads").isEmpty ? ["1", "0.35"] : parsed.values("--reads")).compactMap(Double.init)
        return try await executeAutocorrect(model: parsed.value("--model"), cases: cases, reads: reads,
                                            cps: Double(parsed.value("--cps") ?? "11") ?? 11, outDir: out,
                                            settleAtReturn: parsed.flags.contains("--settle-return"),
                                            leaveShorthand: parsed.flags.contains("--leave-shorthand"),
                                            fixPunctuation: parsed.flags.contains("--fix-punctuation"),
                                            timing: !parsed.flags.contains("--no-timing"),
                                            timedSwaps: !parsed.flags.contains("--no-timed-swaps"),
                                            fixedMs: parsed.value("--fixed-ms").flatMap(Double.init),
                                            slipProfile: try parsed.value("--slip-profile").map(loadSlipProfile),
                                            confusedWords: !parsed.flags.contains("--no-confused-words"),
                                            confusedMargin: parsed.value("--confused-margin").flatMap(Float.init),
                                            // `--learned`: the user's learned words, as the app (spelled right, and
                                            // candidates for a slip, this case's app's first). `--learned-global`:
                                            // every learned word an equal candidate (before app-aware offers).
                                            learned: parsed.flags.contains("--learned") ? loadLearnedPlaces() : nil,
                                            learnedPerApp: !parsed.flags.contains("--learned-global"))
    } catch {
        printErr("error: \(error)")
        return ExitCode.failure
    }
}

func loadAutocorrectCases(corpora: [String], samples: String, variants: Int, seed: UInt64, rate: Double,
                          limit: Int?) throws -> [AutocorrectCase] {
    var out: [AutocorrectCase] = []
    if FileManager.default.fileExists(atPath: samples) {
        for line in try String(contentsOfFile: samples, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
            let s = try JSONDecoder().decode(AutocorrectSample.self, from: Data(line.utf8))
            let slips = s.slips.map { TypoSlip(kind: $0.kind, words: $0.words[0]..<$0.words[1]) }
            out.append(AutocorrectCase(id: s.id, source: "real", surface: s.surface ?? .chat, app: s.app,
                                       noisy: NoisyText(clean: s.clean, typed: s.typed, slips: slips), keys: s.keys,
                                       screen: s.screen))
        }
    }
    let noise = TypoNoise(rate: rate)
    var texts: [ReplayCase] = []
    for path in corpora {
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
            let c = try JSONDecoder().decode(ReplayCase.self, from: Data(line.utf8))
            // English prose only (autocorrect stays off in code and terminals).
            guard c.surface != .code, c.surface != .terminal, c.surface != .shell,
                  !c.text.contains(where: isCJK) else { continue }
            texts.append(c)
        }
    }
    if let limit { texts = Array(texts.prefix(limit)) }
    for c in texts {
        for v in 0..<variants {
            let s = seed &* 1_000_003 &+ UInt64(v) &* 7919 &+ UInt64(abs(c.id.hashValueStable))
            out.append(AutocorrectCase(id: "\(c.id)#\(v)", source: "synthetic", surface: c.surface, app: c.app,
                                       noisy: noise.apply(to: c.text, seed: s)))
        }
    }
    return out
}

extension String {
    /// FNV-1a: the same on every run (Swift's hashValue is randomized per process).
    var hashValueStable: Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return Int(truncatingIfNeeded: h >> 1)
    }
}

private struct AutocorrectRow {
    var c: AutocorrectCase
    var reads: Double
    var run: AutocorrectSimulator.Run
    var score: TypoScore
}

@MainActor
private func executeAutocorrect(model: String?, cases: [AutocorrectCase], reads: [Double], cps: Double,
                                outDir: String, settleAtReturn: Bool, leaveShorthand: Bool, fixPunctuation: Bool = false, timing: Bool,
                                timedSwaps: Bool, fixedMs: Double?, slipProfile: SlipProfile? = nil,
                                confusedWords: Bool = true, confusedMargin: Float? = nil,
                                learned places: LearnedWordPlaces? = nil, learnedPerApp: Bool = true) async throws -> Int32 {
    let learned = places?.words ?? []
    let checker: any SpellChecking = learned.isEmpty ? SystemSpellChecker.cached()
        : LearnedWordsChecker(base: SystemSpellChecker.cached(), words: learned)
    var finder = CorrectionFinder(spellChecker: checker, suggester: SystemCorrectionSuggester(),
                                  languages: ["en"], knownWords: learned, isCommonWord: { CommonEnglish.contains($0) },
                                  isEverydayWord: { CommonEnglish.isEveryday($0) },
                                  lexicon: FuzzyLexicon(words: CommonEnglish.lexiconWords()))
    finder.leavesShorthand = leaveShorthand
    finder.fixesPunctuation = fixPunctuation
    finder.doubleSpace = fixPunctuation ? .collapse : .off
    finder.fixesCapitals = !CommandLine.arguments.contains("--no-caps")  // on, like the app's default
    finder.flagsTimedSwaps = timedSwaps
    finder.fixesConfusedWords = confusedWords
    if let confusedMargin { finder.confusedWordMargin = confusedMargin }
    printErr("confused words: \(confusedWords ? "on, margin \(finder.confusedWordMargin)" : "off")")
    finder.slipProfile = slipProfile
    if let slipProfile { printErr("slip profile: \(slipProfile.words.count) trouble words") }
    // Each case app's learned words; given to the finder unless `--learned-global` (always used to
    // label the learned fixes in the log).
    let appWords: LearnedScope? = places.flatMap { p in
        guard !p.words.isEmpty else { return nil }
        let categories = loadAppCategories()
        printErr("learned words per app: " + Set(cases.map(\.app)).map { app in
            "\(app ?? "?") \(p.here(appKey: evalAppKey(app), categories: categories).map { String($0.count) } ?? "all")"
        }.sorted().joined(separator: ", ") + (learnedPerApp ? "" : " (not used: --learned-global)"))
        return LearnedScope(places: p, categories: categories)
    }
    let scope = learnedPerApp ? appWords : nil
    var scorer: AutocorrectSimulator.Scorer?
    var host: LlamaModelHost?
    if let model {
        let entry = makeEntry(path: model)
        guard entry.validity == .valid, entry.summary != nil else { throw EvalError("not a usable model: \(model)") }
        let h = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        await h.load(entry, options: evalRuntimeOptions)
        guard case .ready = await h.state() else { throw EvalError("load failed for \(model)") }
        host = h
        let engine = LocalCompletionEngine(host: h)
        let counter = RequestCounter()
        scorer = { surface, app, head, continuations in
            let context = TextContext(app: AppIdentity(bundleID: "eval", pid: 1, localizedName: app),
                                      field: FieldID(pid: 1, elementHash: 1, generation: 1),
                                      before: head, after: "", contentSignature: 0)
            let request = CompletionRequest(id: counter.next(), context: context,
                                            input: PromptInput(before: head, surface: surface, appName: app),
                                            decode: DecodeConfig(maxWords: 6))
            return try? await engine.scoreContinuations(request, continuations: continuations)
        }
    }
    printErr("autocorrect: \(cases.count) cases, reads \(reads), model \(model.map { ($0 as NSString).lastPathComponent } ?? "none")")
    var rows: [AutocorrectRow] = []
    for r in reads {
        let sim = AutocorrectSimulator(finder: finder, scorer: scorer, cps: cps, readChance: r, settleAtReturn: settleAtReturn,
                                       timingModel: timing ? KeyTimingModel() : nil, fixedDecisionMs: fixedMs)
        sim.learnedScope = scope
        for (i, c) in cases.enumerated() {
            let run = await sim.run(c, seed: UInt64(i))
            // A learned word put in that this case's app never used (personal: stderr only).
            if let places, !places.words.isEmpty {
                let here = appWords?.here(for: c)
                func words(_ text: String) -> [String] {
                    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
                }
                let typed = Set(words(c.noisy.typed))
                for w in words(run.output) {
                    guard places.words.contains(w), !typed.contains(w) else { continue }
                    let fromHere = here?.contains(w) ?? true
                    let right = words(c.noisy.clean).contains(w)
                    printErr("learned fix \(fromHere ? "from this app" : "from another app") (\(right ? "right" : "wrong")): "
                             + "\(c.id) (\(c.app ?? "?")) → \(w)")
                }
            }
            rows.append(AutocorrectRow(c: c, reads: r, run: run, score: TypoScore.score(c.noisy, output: run.output)))
        }
    }
    await host?.unload()
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let report = autocorrectReport(rows, model: model, cps: cps)
    try report.write(toFile: outDir + "/autocorrect-report.md", atomically: true, encoding: .utf8)
    try autocorrectCSV(rows).write(toFile: outDir + "/autocorrect-results.csv", atomically: true, encoding: .utf8)
    printOut(report)
    printErr("wrote \(outDir)/autocorrect-report.md")
    return ExitCode.ok
}

/// A personal slip list for `--slip-profile`: JSON `{"strength": ["strenght"], "still": []}`
/// (trouble word → typed forms the user kept the fix of more than once).
func loadSlipProfile(_ path: String) throws -> SlipProfile {
    let words = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    return SlipProfile(words: words.mapValues(Set.init))
}

private func autocorrectReport(_ rows: [AutocorrectRow], model: String?, cps: Double) -> String {
    var lines = ["# Autocorrect eval (Fix automatically on)", "",
                 "Model: \(model.map { ($0 as NSString).lastPathComponent } ?? "none (ambiguous words fall back to not fixing)"); "
                 + "typing \(Int(cps)) characters/s. Reads: share of keystrokes the app reads (1 = every key).", ""]
    let readsList = Array(Set(rows.map(\.reads))).sorted(by: >)
    for r in readsList {
        let rs = rows.filter { $0.reads == r }
        for source in ["real", "synthetic"] {
            let sr = rs.filter { $0.c.source == source }
            guard !sr.isEmpty else { continue }
            let slips = sr.flatMap { row in zip(row.c.noisy.slips, row.score.fixed).map { ($0, $1) } }
            // A word with two slips counts once per slip; group by the clean words touched.
            let fixed = slips.filter(\.1).count
            let damaged = sr.reduce(0) { $0 + $1.score.damaged }
            let untouched = sr.reduce(0) { $0 + $1.score.untouched }
            let wrongTyped = sr.reduce(0) { $0 + TypoScore.score($1.c.noisy, output: $1.c.noisy.typed).wrong }
            let wrongOut = sr.reduce(0) { $0 + $1.score.wrong }
            let total = sr.reduce(0) { $0 + $1.score.total }
            let decisions = sr.flatMap(\.run.decisions)
            lines.append("## reads \(r), \(source) (\(sr.count) texts, \(slips.count) slips)")
            lines.append("")
            lines.append("| measure | value |")
            lines.append("|---|---|")
            lines.append("| slips fixed | \(fmtPct(fixed, slips.count)) |")
            lines.append("| wrong words: typed → after autocorrect | \(wrongTyped) → \(wrongOut) of \(total) |")
            lines.append("| clean words broken | \(damaged) of \(untouched) |")
            lines.append("| texts fully right | \(fmtPct(sr.filter(\.score.exact).count, sr.count)) |")
            lines.append("| fixes: at once / after the next word / lost | \(sr.reduce(0) { $0 + $1.run.immediateFixes }) / "
                + "\(sr.reduce(0) { $0 + $1.run.delayedFixes }) / \(sr.reduce(0) { $0 + $1.run.lostFixes }) |")
            let ms = decisions.map(\.ms).filter { $0 > 0 }
            let counts = Dictionary(grouping: decisions, by: \.choice).mapValues(\.count)
            lines.append("| model decisions | \(decisions.count) (\(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))), "
                + "p50 \(fmtMs(percentile(ms, 0.5))) ms, p95 \(fmtMs(percentile(ms, 0.95))) ms |")
            let atReturn = decisions.filter(\.atReturn)
            let returnMs = atReturn.map(\.ms).filter { $0 > 0 }
            lines.append("| decisions at Return (held ≤ \(Int(AutocorrectSimulator.returnBudgetMs)) ms) | \(atReturn.count), "
                + "over budget \(returnMs.filter { $0 > AutocorrectSimulator.returnBudgetMs }.count), p95 \(fmtMs(percentile(returnMs, 0.95))) ms |")
            let multi = decisions.filter { $0.slots > 1 }
            lines.append("| decisions over 2+ words / continuations per decision (mean, max) | \(multi.count) / "
                + String(format: "%.1f", decisions.isEmpty ? 0 : Double(decisions.map(\.combos).reduce(0, +)) / Double(decisions.count))
                + ", \(decisions.map(\.combos).max() ?? 0) |")
            lines.append("| decisions with key timing (slots with evidence) / texts with recorded timing | "
                + "\(decisions.filter { $0.timed > 0 }.count) (\(decisions.map(\.timed).reduce(0, +))) / "
                + "\(sr.filter(\.run.recordedTiming).count) |")
            lines.append("")
            lines.append("| slip kind | fixed |")
            lines.append("|---|---|")
            for kind in TypoSlip.Kind.allCases {
                let k = slips.filter { $0.0.kind == kind }
                guard !k.isEmpty else { continue }
                lines.append("| \(kind.rawValue) | \(fmtPct(k.filter(\.1).count, k.count)) |")
            }
            lines.append("")
        }
    }
    if let r = readsList.last {
        lines.append("## Real samples (reads \(r))")
        lines.append("")
        for row in rows where row.reads == r && row.c.source == "real" {
            lines.append("- **\(row.c.id)** \(row.score.fixed.filter { $0 }.count)/\(row.score.fixed.count) fixed, \(row.score.damaged) broken")
            lines.append("  - typed: `\(row.c.noisy.typed)`")
            lines.append("  - after: `\(row.run.output)`")
        }
        lines.append("")
        lines.append("## Synthetic examples (reads \(r), first 15)")
        lines.append("")
        for row in rows.filter({ $0.reads == r && $0.c.source == "synthetic" }).prefix(15) {
            lines.append("- **\(row.c.id)** \(row.score.fixed.filter { $0 }.count)/\(row.score.fixed.count) fixed, \(row.score.damaged) broken")
            lines.append("  - typed: `\(row.c.noisy.typed)`")
            lines.append("  - after: `\(row.run.output)`")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Hunch's own fixes in a results row: JSON `[{"at": utf16, "typed": .., "fixed": .., "confidence": ..}]`
/// (the rewrite eval's `--as-typed` mode reads it back).
func ownFixesColumn(_ fixes: [OwnFix]) -> String {
    let items = fixes.map { f -> [String: Any] in
        var d: [String: Any] = ["at": f.range.lowerBound, "typed": f.typed, "fixed": f.fixed]
        if let c = f.confidence { d["confidence"] = c.rawValue }
        return d
    }
    guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

private func autocorrectCSV(_ rows: [AutocorrectRow]) -> String {
    var out = ["id,source,reads,slips,fixed,damaged,wrong,total,exact,immediate,delayed,lost,decisions,decision_ms,clean,typed,output,"
               + "own_fixes"]
    for r in rows {
        let fields: [String] = [r.c.id, r.c.source, String(r.reads), String(r.c.noisy.slips.count), String(r.score.fixed.filter { $0 }.count),
                    String(r.score.damaged), String(r.score.wrong), String(r.score.total), String(r.score.exact),
                    String(r.run.immediateFixes), String(r.run.delayedFixes), String(r.run.lostFixes),
                    String(r.run.decisions.count),
                    r.run.decisions.map { String(format: "%.0f", $0.ms) }.joined(separator: " "), r.c.noisy.clean, r.c.noisy.typed, r.run.output,
                    ownFixesColumn(r.run.ownFixes)]
        out.append(fields.map(csvEscape).joined(separator: ","))
    }
    return out.joined(separator: "\n") + "\n"
}
