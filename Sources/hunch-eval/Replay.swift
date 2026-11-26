// `replay`: a simulated person types realistic messages through the real engine one keystroke at a
// time and accepts suggestion words that are exactly what they meant to write next (one key per
// word, like "accept next word"). The headline is keystrokes saved. Every request is awaited, so a
// run is deterministic; `typing` is the command for timing under real typing speed.
import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import HunchPrompt
import HunchScreen
import HunchSession
import HunchText

/// One message to type, with the place it is typed in.
struct ReplayCase: Codable, Sendable {
    var id: String
    var surface: SurfaceKind
    var tags: [String]?
    var app: String?
    var domain: String?
    var windowTitle: String?
    var fieldLabel: String?
    /// Text on screen near the field (the thread being answered, the surrounding code).
    var screen: String?
    var clipboard: String?
    /// Text already in the field before typing starts.
    var prefix: String?
    /// What the person types.
    var text: String
    /// When it was written (eval captures; history cases): learned phrases only use older sentences.
    var capturedAt: String?
}

/// Which context the app sends: a fresh install sends the app name and surface only.
struct ReplayProfile: Codable, Sendable {
    var name: String
    var screen: Bool
    var windowTitle: Bool
    var clipboard: Bool
    /// "About me" as the app sends it (name and the about-me text).
    var about: String?
    /// Writing samples per request (the app uses 2 when learning is on), picked from other cases.
    var styleExamples: Int
    var languages: [String]
    /// "traditional" or "simplified": the Han script of the writer's input source.
    var preferredHan: String?
    var screenTokenLimit: Int?
    /// A made-up writer's personal context (`eval/replay/persona.json`): instructions, learned words
    /// and phrases, per-app writing samples and a clipboard mix. Replaces `styleExamples`.
    var persona: String?
}

// MARK: - The typist (pure)

/// The person at the keyboard. They type the target text character by character; whenever the
/// visible suggestion's next word is exactly what comes next, they accept it with one key.
/// Typing a character the suggestion predicted shrinks it (the app shows the rest); any other
/// character hides it.
struct Typist {
    let prefix: String
    let target: String
    private(set) var typed = ""
    private(set) var ghost: String?
    private var ghostEvent: Int?
    /// Keys pressed: typed characters plus one per accepted word.
    private(set) var keys = 0
    private(set) var acceptKeys = 0
    private(set) var acceptedChars = 0
    /// Per shown suggestion: words and characters accepted from it.
    private(set) var eventUnits: [Int] = []
    private(set) var eventChars: [Int] = []
    var options = WordUnitOptions()

    init(prefix: String, text: String) {
        self.prefix = prefix
        self.target = text
    }

    var before: String { prefix + typed }
    var position: Int { typed.count }
    var remaining: Substring { target.dropFirst(typed.count) }
    var done: Bool { typed.count >= target.count }

    /// A new suggestion appears; returns its event index.
    @discardableResult
    mutating func show(_ suggestion: String) -> Int {
        eventUnits.append(0)
        eventChars.append(0)
        let index = eventUnits.count - 1
        if suggestion.contains(where: { !$0.isWhitespace }) {
            ghost = suggestion
            ghostEvent = index
        } else {
            ghost = nil
            ghostEvent = nil
        }
        return index
    }

    /// Accepts words from the suggestion while each is exactly the next text. Returns how many.
    mutating func acceptMatching() -> Int {
        var count = 0
        while let current = ghost, let event = ghostEvent {
            let unit = WordUnits.next(in: current, options: options)
            guard !unit.isEmpty, unit.contains(where: { !$0.isWhitespace }), remaining.hasPrefix(unit) else { break }
            typed += unit
            keys += 1
            acceptKeys += 1
            acceptedChars += unit.count
            eventUnits[event] += 1
            eventChars[event] += unit.count
            count += 1
            setGhost(String(current.dropFirst(unit.count)))
        }
        return count
    }

    /// Types the next character of the target.
    mutating func typeNext() {
        guard let character = remaining.first else { return }
        typed.append(character)
        keys += 1
        if let current = ghost, current.first == character {
            setGhost(String(current.dropFirst()))
        } else {
            ghost = nil
            ghostEvent = nil
        }
    }

    private mutating func setGhost(_ rest: String) {
        if rest.contains(where: { !$0.isWhitespace }) {
            ghost = rest
        } else {
            ghost = nil
            ghostEvent = nil
        }
    }
}

/// Share of the message's characters the person did not have to type (accept keys count as typed).
func keystrokesSaved(characters: Int, keys: Int) -> Double {
    characters > 0 ? Double(characters - keys) / Double(characters) : 0
}

/// The moments for the blind rating, the same for every model. Code is left out (it can't be judged
/// from a short excerpt); every Chinese case is in, at two cuts each when the count allows; the
/// rest are English cases picked by `seed`, one random cut each. English cuts land on a space
/// with at least three words before and two after; Chinese cuts keep four characters each side.
/// The 2026-11-04 page's cut (word boundary before the middle) is avoided so the moments are new.
func ratingPoints(_ cases: [ReplayCase], count: Int, seed: UInt64) -> [(caseIndex: Int, cut: Int)] {
    guard count > 0 else { return [] }
    var rng = SplitMix64(seed: seed)
    func isChinese(_ c: ReplayCase) -> Bool {
        c.text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }
    func cuts(_ text: [Character]) -> [Int] {
        let middle = text.count / 2
        var old = middle
        if let space = text[..<max(0, middle)].lastIndex(of: " "), space >= 8 { old = space }
        var found: [Int]
        if text.contains(" ") {
            found = text.indices.filter { i in
                text[i] == " " && text[..<i].split(separator: " ").count >= 3 && text[i...].split(separator: " ").count >= 2
            }
        } else {
            found = text.count > 8 ? Array(4...(text.count - 4)) : []
        }
        return found.count > 1 ? found.filter { $0 != old } : found
    }
    let eligible = cases.indices.filter { cases[$0].surface != .code }
    let chinese = eligible.filter { isChinese(cases[$0]) }
    var english = eligible.filter { !isChinese(cases[$0]) }
    for i in stride(from: english.count - 1, to: 0, by: -1) {
        english.swapAt(i, Int(rng.next() % UInt64(i + 1)))
    }
    var points: [(Int, Int)] = []
    let perChinese = count >= 20 ? 2 : 1
    for index in chinese {
        var options = cuts(Array(cases[index].text))
        for _ in 0..<perChinese where !options.isEmpty && points.count < count {
            let pick = options.remove(at: Int(rng.next() % UInt64(options.count)))
            options.removeAll { abs($0 - pick) < 4 }
            points.append((index, pick))
        }
    }
    for index in english where points.count < count {
        let options = cuts(Array(cases[index].text))
        guard !options.isEmpty else { continue }
        points.append((index, options[Int(rng.next() % UInt64(options.count))]))
    }
    return points.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
}

/// The moments of an earlier rating page, so new models are rated (and judged) on exactly the same
/// moments as earlier ones. Each item's `before` is the case's prefix plus the typed part. A case
/// whose text was edited since the page was made is matched by app and screen, and its text is
/// replaced by the page's typed part, so the moment stays exactly as it was.
func momentsFromPage(_ path: String, cases: [ReplayCase]) throws
    -> (cases: [ReplayCase], points: [(caseIndex: Int, cut: Int)]) {
    guard let html = try? String(contentsOfFile: path, encoding: .utf8),
          let start = html.range(of: #"<script id="data" type="application/json">"#),
          let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
        throw EvalError("cannot read rating data from \(path)")
    }
    let json = html[start.upperBound..<end.lowerBound].replacingOccurrences(of: "<\\/", with: "</")
    struct Page: Decodable { struct Item: Decodable { var app: String; var screen: String; var before: String }
                             var items: [Item] }
    let page = try JSONDecoder().decode(Page.self, from: Data(json.utf8))
    var cases = cases
    let points = try page.items.map { item -> (caseIndex: Int, cut: Int) in
        let place = cases.indices.filter { i in
            let c = cases[i]
            return (c.app ?? c.surface.rawValue) == item.app && String((c.screen ?? "").suffix(400)) == String(item.screen.suffix(400))
                && item.before.hasPrefix(c.prefix ?? "")
        }
        let exact = place.filter { cases[$0].text.hasPrefix(String(item.before.dropFirst((cases[$0].prefix ?? "").count))) }
        guard let index = exact.count == 1 ? exact[0] : (exact.isEmpty && place.count == 1 ? place[0] : nil) else {
            throw EvalError("\(exact.count)/\(place.count) cases match moment \"\(item.before.suffix(40))\" in \(path)")
        }
        let typed = String(item.before.dropFirst((cases[index].prefix ?? "").count))
        if exact.isEmpty {
            printErr("note: case \(cases[index].id) changed since \(path); using the page's text")
            cases[index].text = typed
        }
        return (index, typed.count)
    }
    return (cases, points)
}


/// The case's screen text as the app would read it: each line becomes an OCR line in one column
/// above the field (newest last), run through the app's screen pipeline with the app's cap.
/// Lines may start with a layout marker (`ScreenMarker`), so two-sided chats get their sides.
nonisolated(unsafe) var evalAppScreen = false
/// `--no-sides`: the pipeline labels no speakers (the before side of a speaker-label comparison).
nonisolated(unsafe) var evalScreenSides = true

/// Layout markers at the start of a case's screen line (only `--app-screen` uses the layout; other
/// paths just drop them): `» ` a line of the writer's own right-aligned bubble (consecutive ones are
/// one bubble), `~ ` a sender's name in small type above a bubble, `= ` a centered line (dates,
/// titles). Unmarked lines start at the column's left edge.
enum ScreenMarker {
    enum Place { case left, right, name, center }
    static func parse(_ line: String) -> (place: Place, text: String) {
        for (prefix, place) in [("» ", Place.right), ("~ ", .name), ("= ", .center)] where line.hasPrefix(prefix) {
            return (place, String(line.dropFirst(prefix.count)))
        }
        return (.left, line)
    }
    static func strip(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { parse(String($0)).text }
            .joined(separator: "\n")
    }
}

/// Case app names of bubble apps (`ChatSides.isBubbleApp`), so a screen of only the other side's messages is
/// labeled as the app labels it.
let evalBubbleAppNames: Set<String> = ["Messages", "WhatsApp", "Signal", "Telegram", "LINE", "Claude", "ChatGPT", "LM Studio"]

func pipelineScreen(_ text: String, before: String, surface: SurfaceKind = .unknown, domain: String? = nil,
                    app: String? = nil) -> String? {
    let raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Column 100-700. Each line is its own message (28 pt apart), except consecutive lines of one
    // right-aligned bubble (20 pt apart, sharing the bubble's left edge).
    var lines: [OCRLine] = []
    var y: CGFloat = 100
    var i = 0
    while i < raw.count {
        let (place, line) = ScreenMarker.parse(raw[i])
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { i += 1; y += 28; continue }
        switch place {
        case .right:
            var run: [String] = []
            while i < raw.count, case let (.right, t) = ScreenMarker.parse(raw[i]), !t.isEmpty { run.append(t); i += 1 }
            let widths = run.map { CGFloat(min(420, max(20, $0.count * 7))) }
            let x = 700 - (widths.max() ?? 0)
            for (t, w) in zip(run, widths) {
                lines.append(OCRLine(text: t, confidence: 1, rect: CGRect(x: x, y: y, width: w, height: 16)))
                y += 20
            }
            y += 8
            continue
        case .name:
            lines.append(OCRLine(text: line, confidence: 1, rect: CGRect(x: 100, y: y + 4, width: CGFloat(max(20, line.count * 6)), height: 12)))
            y += 18
        case .center:
            let w = CGFloat(min(600, max(20, line.count * 7)))
            lines.append(OCRLine(text: line, confidence: 1, rect: CGRect(x: 400 - w / 2, y: y, width: w, height: 16)))
            y += 28
        case .left:
            let width = CGFloat(min(600, max(20, line.count * 7)))
            lines.append(OCRLine(text: line, confidence: 1, rect: CGRect(x: 100, y: y, width: width, height: 16)))
            y += 28
        }
        i += 1
    }
    let top = y + 8
    let field = CGRect(x: 100, y: top, width: 600, height: 36)
    let sides = evalScreenSides && ChatSides.applies(surface: surface, bundleID: "", urlHost: domain)
    return ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: 110, y: top + 18), field: field, fieldBefore: before,
                                      fieldAfter: "", maxCharacters: 16000, chatSides: sides,
                                      bubbleApp: app.map(evalBubbleAppNames.contains) ?? false,
                                      senderNames: surface != .agentPrompt && !["Claude", "ChatGPT", "LM Studio"].contains(app ?? ""))?.text
}

/// `app-screen --cases f.jsonl [--no-sides]`: prints each case's screen as `--app-screen` sends it.
func runAppScreenCommand(_ args: [String]) -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--cases"])
    guard let path = parsed.value("--cases"), let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else {
        printErr("usage: hunch-eval app-screen --cases <cases.jsonl> [--no-sides]")
        return ExitCode.usage
    }
    evalScreenSides = !parsed.flags.contains("--no-sides")
    for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        guard let c = try? JSONDecoder().decode(ReplayCase.self, from: Data(line.utf8)) else { continue }
        print("== \(c.id) (\(c.app ?? c.surface.rawValue))")
        print(c.screen.flatMap { pipelineScreen($0, before: c.prefix ?? "", surface: c.surface, domain: c.domain, app: c.app) } ?? "(none)")
        print("")
    }
    return 0
}

// MARK: - Running

struct ReplayEvent: Sendable {
    var model: String
    var profile: String
    var caseID: String
    var before: String
    var suggestion: String
    var next: String
    var units: Int
    var chars: Int
    var aiVoice: Bool
    var confidence: ConfidenceRecord?
}

struct ReplayCaseResult: Sendable {
    var model: String
    var profile: String
    var caseID: String
    var surface: SurfaceKind
    var tags: [String]
    var characters: Int
    var keys: Int
    var acceptKeys: Int
    var acceptedChars: Int
    var requests: Int
    var shown: Int
    var helped: Int
    var firstMs: Double?
    var requestMs: [Double]
    var aiShown: Int
    /// Prompt tokens each request had to decode (the rest came from the KV cache), after the field's first.
    var decodedPrompt: [Int] = []
}

struct ReplayProbe: Sendable {
    var caseID: String
    var before: String
    var suggestion: String?
    var confidence: ConfidenceRecord?
}

struct ReplayModelRun: Sendable {
    var model: String
    var results: [ReplayCaseResult]
    var events: [ReplayEvent]
    var probes: [ReplayProbe]
    var footprintMB: Double
    var residentMB: Double
}

struct ReplayOptions {
    var models: [String] = []
    var casesPath = "eval/replay/cases.jsonl"
    /// Drop the interface run at the end of each case's screen text, as the app does next to the field.
    var dropInterface = false
    var profilePaths = ["eval/replay/profiles/fresh.json", "eval/replay/profiles/full.json"]
    var outDir = ""
    var limit: Int?
    var probes = 40
    var seed: UInt64 = 2
    var minWords = 2
    /// Framer id for every model (as the app's per-model override), e.g. `chat-prefill-v5` for a chat
    /// model whose name doesn't say "instruct"; nil = the app's own choice.
    var framer: String?
    /// Confidence trim and floor overrides (nil fields keep the app's defaults).
    var confidence = ConfidenceOverrides()
    /// Suggestion length setting (the app's word range per preset).
    var length: LengthPreset = .medium
    /// Learned phrases from the local history (`--phrases history`); nil = off, as the app's default.
    var phrases: PhraseSource?

    static let lengthUsage = "[--length short|medium|long|veryLong|ultra] "
    /// Reads `--length`; nil (with a message) when the value isn't a preset.
    static func length(_ parsed: ParsedArgs, command: String) -> LengthPreset? {
        guard let raw = parsed.value("--length") else { return .medium }
        guard let preset = LengthPreset(rawValue: raw) else {
            printErr("\(command): unknown --length \(raw) (short, medium, long, veryLong, ultra)")
            return nil
        }
        return preset
    }
}

func runReplayCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: Set(["--models", "--cases", "--profiles", "--out", "--limit", "--probes", "--seed",
                                                     "--framer", "--length", "--phrases", "--phrase-strength", "--phrase-curve"])
        .union(ConfidenceOverrides.options))
    var options = ReplayOptions()
    do {
        options.confidence = try ConfidenceOverrides(parsed)
        options.phrases = try PhraseSource.make(parsed)
    } catch {
        printErr("replay: \(error)")
        return ExitCode.usage
    }
    guard let length = ReplayOptions.length(parsed, command: "replay") else { return ExitCode.usage }
    options.length = length
    options.framer = parsed.value("--framer")
    options.models = parsed.values("--models")
    if let cases = parsed.value("--cases") { options.casesPath = cases }
    if !parsed.values("--profiles").isEmpty { options.profilePaths = parsed.values("--profiles") }
    options.outDir = parsed.value("--out") ?? ""
    options.limit = parsed.value("--limit").flatMap(Int.init)
    if let probes = parsed.value("--probes").flatMap(Int.init) { options.probes = probes }
    if let seed = parsed.value("--seed").flatMap(UInt64.init) { options.seed = seed }
    options.dropInterface = parsed.flags.contains("--drop-interface")
    evalAppScreen = parsed.flags.contains("--app-screen")
    evalScreenSides = !parsed.flags.contains("--no-sides")
    guard !options.models.isEmpty, parsed.positionals.isEmpty else {
        printErr("usage: hunch-eval replay --models <file.gguf>... [--cases eval/replay/cases.jsonl] "
            + "[--profiles p.json...] [--limit N] [--probes 40] [--seed 2] [--framer id] [--out dir] [--drop-interface] [--app-screen] [--no-sides] "
            + ReplayOptions.lengthUsage + PhraseSource.usage + ConfidenceOverrides.usage)
        return ExitCode.usage
    }
    do {
        try await replay(options)
        return ExitCode.ok
    } catch {
        printErr("replay: \(error)")
        return ExitCode.failure
    }
}

func loadReplayCases(_ path: String) throws -> [ReplayCase] {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
        throw EvalError("cannot read cases file \(path)")
    }
    var cases: [ReplayCase] = []
    for (number, line) in text.split(separator: "\n").enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        do {
            cases.append(try JSONDecoder().decode(ReplayCase.self, from: Data(trimmed.utf8)))
        } catch {
            throw EvalError("\(path) line \(number + 1): \(error)")
        }
    }
    return cases
}

private func replay(_ options: ReplayOptions) async throws {
    var cases = try loadReplayCases(options.casesPath)
    if let limit = options.limit { cases = Array(cases.prefix(limit)) }
    if options.dropInterface {
        var dropped = 0
        cases = cases.map { replayCase in
            var c = replayCase
            if let screen = c.screen {
                let out = InterfaceLines.droppingTrailingRun(screen)
                c.screen = out.text
                dropped += out.dropped.count
            }
            return c
        }
        printErr("replay: --drop-interface left out \(dropped) interface lines across \(cases.count) cases")
    }
    let profiles = try options.profilePaths.map { path -> ReplayProfile in
        guard let data = FileManager.default.contents(atPath: path) else { throw EvalError("cannot read profile \(path)") }
        return try JSONDecoder().decode(ReplayProfile.self, from: data)
    }
    let outDir = options.outDir.isEmpty
        ? "eval/reports/replay-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        : options.outDir
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    let points = ratingPoints(cases, count: options.probes, seed: options.seed)
    var runs: [ReplayModelRun] = []
    for path in options.models {
        let entry = makeEntry(path: path)
        guard entry.validity == .valid, entry.summary != nil else {
            printErr("skipping \(path): not a usable model")
            continue
        }
        runs.append(try await replayModel(entry: entry, cases: cases, profiles: profiles, probeProfile: profiles.last,
                                          points: points, options: options))
    }
    guard !runs.isEmpty else { throw EvalError("no usable model") }

    try replayCSV(runs).write(toFile: outDir + "/replay-results.csv", atomically: true, encoding: .utf8)
    try replayEventsCSV(runs).write(toFile: outDir + "/replay-suggestions.csv", atomically: true, encoding: .utf8)
    try confidenceJSONL(runs, probeProfile: profiles.last?.name ?? "")
        .write(toFile: outDir + "/confidence.jsonl", atomically: true, encoding: .utf8)
    let report = replayReport(runs: runs, cases: cases, profiles: profiles, casesPath: options.casesPath,
                              length: options.length)
    try report.write(toFile: outDir + "/replay-report.md", atomically: true, encoding: .utf8)
    let page = ratingPage(runs: runs, cases: cases, profileName: profiles.last?.name ?? "",
                          runID: (outDir as NSString).lastPathComponent)
    try page.write(toFile: outDir + "/rate.html", atomically: true, encoding: .utf8)
    printOut(report)
    printErr("report: \(outDir)/replay-report.md")
    printErr("blind rating page: \(outDir)/rate.html")
}

/// Replays every case under `profiles`, then asks for one suggestion at each rating point under
/// `probeProfile` (empty `profiles`: rating points only).
private func replayModel(entry: ModelEntry, cases: [ReplayCase], profiles: [ReplayProfile], probeProfile: ReplayProfile?,
                         points: [(caseIndex: Int, cut: Int)], options: ReplayOptions) async throws -> ReplayModelRun {
    let name = entry.url.lastPathComponent
    for path in Set((profiles + [probeProfile].compactMap { $0 }).compactMap(\.persona)) { _ = try await Persona.load(path) }
    let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
    await host.load(entry, options: evalRuntimeOptions)
    guard case .ready = await host.state() else { throw EvalError("load failed for \(name): \(await host.state())") }
    // The app's prompt budget: the context minus room for the suggestion.
    let recorder = RecordingSearch()
    let engine = LocalCompletionEngine(host: host, search: { recorder },
                                       postProcessor: makeEvalPostProcessor(typoCheck: true),
                                       framerOverride: options.framer,
                                       promptTokenBudget: RuntimeOptions.defaultContextTokens - RuntimeOptions.decodeHeadroom,
                                       resultCacheCapacity: 32)
    var decode = DecodeConfig()
    // As the app: the length setting's word range.
    decode.maxWords = options.length.maxWords
    decode.minWords = min(options.length.minWords, decode.maxWords)
    decode.maxTokens = max(decode.maxTokens, options.length.maxTokens)
    decode.holdEndBelowMinWords = options.length.holdsEnd
    decode.allowNewline = false
    options.confidence.apply(to: &decode)
    let counter = RequestCounter()
    let classifier = DefaultAIVoiceClassifier()

    var results: [ReplayCaseResult] = []
    var events: [ReplayEvent] = []
    for profile in profiles {
        let start = ContinuousClock.now
        for (index, replayCase) in cases.enumerated() {
            let pool = stylePool(cases, excluding: index)
            let (result, caseEvents) = await replayOne(replayCase, profile: profile, model: name, engine: engine,
                                                       recorder: recorder, counter: counter, decode: decode, pool: pool,
                                                       classifier: classifier, minWords: options.minWords,
                                                       phrases: options.phrases)
            results.append(result)
            events += caseEvents
        }
        let mine = results.filter { $0.profile == profile.name }
        let saved = keystrokesSaved(characters: mine.reduce(0) { $0 + $1.characters }, keys: mine.reduce(0) { $0 + $1.keys })
        printErr(String(format: "%@ x %@: keystrokes saved %.1f %% (%.0f s)", name, profile.name, saved * 100,
                        milliseconds(ContinuousClock.now - start) / 1000))
    }

    // Blind-rating probes (full context): the same points for every model.
    var probes: [ReplayProbe] = []
    if let profile = probeProfile {
        for point in points {
            let replayCase = cases[point.caseIndex]
            let before = (replayCase.prefix ?? "") + String(replayCase.text.prefix(point.cut))
            let pool = stylePool(cases, excluding: point.caseIndex)
            let style = profile.persona == nil ? styleFor(profile: profile, before: before, pool: pool) : []
            var request = replayRequest(replayCase, profile: profile, before: before, style: style, decode: decode,
                                        id: counter.next())
            if let phrases = options.phrases { request.bias = phrases.bias(for: replayCase, before: before) }
            if let path = profile.persona, let persona = Persona.cached(path) {
                await persona.personalize(&request, case: replayCase, before: before)
            }
            var text: String?
            _ = recorder.take()
            if let result = try? await engine.complete(request, partial: { _ in }), case .show(let shown) = result.outcome,
               shown.contains(where: { !$0.isWhitespace }) {
                text = shown
            }
            probes.append(ReplayProbe(caseID: replayCase.id, before: before, suggestion: text,
                                      confidence: recorder.take().map(ConfidenceRecord.init)))
        }
    }
    if let phrases = options.phrases { printErr(phrases.summary) }
    let memory = ProcessMemory.snapshot()
    await host.unload()
    return ReplayModelRun(model: name, results: results, events: events, probes: probes,
                          footprintMB: Double(memory?.physFootprint ?? 0) / 1_048_576,
                          residentMB: Double(memory?.residentSize ?? 0) / 1_048_576)
}

/// Writing samples come from the other messages typed in the same kind of place, like the app's
/// per-category sentence library.
private func stylePool(_ cases: [ReplayCase], excluding index: Int) -> [StyleSnippet] {
    let surface = cases[index].surface
    return cases.enumerated().compactMap { offset, other in
        offset != index && other.surface == surface ? StyleSnippet(id: other.id, text: other.text) : nil
    }
}

private func styleFor(profile: ReplayProfile, before: String, pool: [StyleSnippet]) -> [String] {
    guard profile.styleExamples > 0 else { return [] }
    return selectSnippets(StyleSetting(snippets: pool, k: profile.styleExamples, fill: false), before: before).map(\.text)
}

/// The case's clipboard: its own, else the profile persona's mix.
func replayClipboard(_ replayCase: ReplayCase, profile: ReplayProfile) -> String? {
    if let path = profile.persona, let p = Persona.cached(path) { return p.clipboard(for: replayCase) }
    return replayCase.clipboard
}

/// The keyboard the simulated typist uses for a case, as the app reads it from the input source:
/// Zhuyin ("zh-Hant") for a message with Chinese characters, the ABC layout ("en") otherwise.
func replayKeyboardLanguage(_ replayCase: ReplayCase) -> String {
    replayCase.text.contains { TextMeasure.isCJK($0) } ? "zh-Hant" : "en"
}

func replayInput(_ replayCase: ReplayCase, profile: ReplayProfile, before: String, style: [String],
                 maxWords: Int) -> PromptInput {
    var input = PromptInput(
        before: before, after: "", surface: replayCase.surface, aboutWriter: profile.about,
        preferredLanguages: InputLanguage.promptLanguages(inputSource: replayKeyboardLanguage(replayCase),
                                                          preferred: profile.languages),
        maxWords: maxWords, allowNewlines: false,
        screenContext: profile.screen ? (evalAppScreen ? replayCase.screen.flatMap { pipelineScreen($0, before: before, surface: replayCase.surface, domain: replayCase.domain, app: replayCase.app) } : replayCase.screen.map(appScreenLines)) : nil,
        clipboard: profile.clipboard ? replayClipboard(replayCase, profile: profile) : nil,
        appName: replayCase.app, domain: replayCase.domain,
        windowTitle: profile.windowTitle ? replayCase.windowTitle : nil,
        styleExamples: style,
        preferredHanScript: profile.preferredHan.flatMap(HanVariant.init(rawValue:)),
        fieldLabel: replayCase.surface == .code ? nil : replayCase.fieldLabel,
        quoteStyle: .straight)
    input.screenTokenLimit = profile.screenTokenLimit ?? 3500
    return input
}

private func replayRequest(_ replayCase: ReplayCase, profile: ReplayProfile, before: String, style: [String],
                           decode: DecodeConfig, id: RequestID) -> CompletionRequest {
    let context = TextContext(app: AppIdentity(bundleID: "eval.replay", pid: 1, localizedName: replayCase.app),
                              field: FieldID(pid: 1, elementHash: replayCase.id.hashValue, generation: 1),
                              before: before, after: "", contentSignature: 0)
    return CompletionRequest(id: id, context: context,
                             input: replayInput(replayCase, profile: profile, before: before, style: style,
                                                maxWords: decode.maxWords),
                             decode: decode)
}

private func replayOne(_ replayCase: ReplayCase, profile: ReplayProfile, model: String, engine: LocalCompletionEngine,
                       recorder: RecordingSearch, counter: RequestCounter, decode: DecodeConfig, pool: [StyleSnippet],
                       classifier: DefaultAIVoiceClassifier, minWords: Int,
                       phrases: PhraseSource? = nil) async -> (ReplayCaseResult, [ReplayEvent]) {
    var typist = Typist(prefix: replayCase.prefix ?? "", text: replayCase.text)
    var result = ReplayCaseResult(model: model, profile: profile.name, caseID: replayCase.id, surface: replayCase.surface,
                                  tags: replayCase.tags ?? [], characters: replayCase.text.count, keys: 0, acceptKeys: 0,
                                  acceptedChars: 0, requests: 0, shown: 0, helped: 0, firstMs: nil, requestMs: [],
                                  aiShown: 0)
    var events: [ReplayEvent] = []
    // The app pins a field's writing samples once it has picked some.
    var pinnedStyle: [String] = []
    // Focus: the app prewarms the field's prompt before the first keystroke.
    await engine.prewarm(replayRequest(replayCase, profile: profile, before: typist.before, style: [], decode: decode,
                                       id: counter.next()))
    var lastRequested = -1
    while !typist.done {
        if typist.ghost == nil, typist.position != lastRequested,
           TypedWords.onCurrentLine(typist.before, surface: replayCase.surface) >= minWords {
            lastRequested = typist.position
            if pinnedStyle.isEmpty, profile.persona == nil {
                pinnedStyle = styleFor(profile: profile, before: typist.before, pool: pool)
            }
            var request = replayRequest(replayCase, profile: profile, before: typist.before, style: pinnedStyle,
                                        decode: decode, id: counter.next())
            if let phrases { request.bias = phrases.bias(for: replayCase, before: typist.before) }
            if let path = profile.persona, let persona = Persona.cached(path) {
                await persona.personalize(&request, case: replayCase, before: typist.before)
            }
            _ = recorder.take()
            let start = ContinuousClock.now
            let outcome = try? await engine.complete(request, partial: { _ in })
            let ms = milliseconds(ContinuousClock.now - start)
            let scores = recorder.take().map(ConfidenceRecord.init)
            result.requests += 1
            if result.firstMs != nil, let outcome { result.decodedPrompt.append(outcome.timings.decodedPromptTokens) }
            result.requestMs.append(ms)
            if result.firstMs == nil { result.firstMs = ms }
            if let outcome, case .show(let text) = outcome.outcome, text.contains(where: { !$0.isWhitespace }) {
                let before = typist.before
                typist.show(text)
                let ai = classifier.isAIVoice(before: before, completion: text)
                if ai { result.aiShown += 1 }
                events.append(ReplayEvent(model: model, profile: profile.name, caseID: replayCase.id,
                                          before: String(before.suffix(80)), suggestion: text,
                                          next: String(typist.remaining.prefix(text.count + 12)), units: 0, chars: 0,
                                          aiVoice: ai, confidence: scores))
            }
        }
        if typist.acceptMatching() > 0 { continue }
        typist.typeNext()
    }
    for index in events.indices where index < typist.eventUnits.count {
        events[index].units = typist.eventUnits[index]
        events[index].chars = typist.eventChars[index]
    }
    result.keys = typist.keys
    result.acceptKeys = typist.acceptKeys
    result.acceptedChars = typist.acceptedChars
    result.shown = events.count
    result.helped = events.filter { $0.units > 0 }.count
    return (result, events)
}

// MARK: - Rating page only

/// `rate`: the blind rating page alone. Each model answers the rating points once under the full
/// profile (a couple of minutes per model); no replay, so the page shows no keystrokes saved.
func runRateCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: Set(["--models", "--cases", "--profile", "--count", "--seed", "--out",
                                                     "--moments-from", "--framer", "--length", "--phrases",
                                                     "--phrase-strength", "--phrase-curve"]).union(ConfidenceOverrides.options))
    var options = ReplayOptions()
    do {
        options.confidence = try ConfidenceOverrides(parsed)
        options.phrases = try PhraseSource.make(parsed)
    } catch {
        printErr("rate: \(error)")
        return ExitCode.usage
    }
    guard let length = ReplayOptions.length(parsed, command: "rate") else { return ExitCode.usage }
    options.length = length
    options.framer = parsed.value("--framer")
    options.models = parsed.values("--models")
    if let cases = parsed.value("--cases") { options.casesPath = cases }
    let profilePath = parsed.value("--profile") ?? "eval/replay/profiles/full.json"
    if let count = parsed.value("--count").flatMap(Int.init) { options.probes = count }
    if let seed = parsed.value("--seed").flatMap(UInt64.init) { options.seed = seed }
    guard !options.models.isEmpty, parsed.positionals.isEmpty else {
        printErr("usage: hunch-eval rate --models <file.gguf>... [--cases eval/replay/cases.jsonl] "
            + "[--profile eval/replay/profiles/full.json] [--count 40] [--seed 2] [--moments-from rate.html] [--out dir] [--drop-interface] [--app-screen] [--no-sides] "
            + ReplayOptions.lengthUsage + PhraseSource.usage + ConfidenceOverrides.usage)
        return ExitCode.usage
    }
    do {
        var cases = try loadReplayCases(options.casesPath)
        guard let data = FileManager.default.contents(atPath: profilePath) else { throw EvalError("cannot read profile \(profilePath)") }
        let profile = try JSONDecoder().decode(ReplayProfile.self, from: data)
        let outDir = parsed.value("--out") ?? "eval/reports/rate-"
            + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var points = ratingPoints(cases, count: options.probes, seed: options.seed)
        if let page = parsed.value("--moments-from") { (cases, points) = try momentsFromPage(page, cases: cases) }
        evalAppScreen = parsed.flags.contains("--app-screen")
        evalScreenSides = !parsed.flags.contains("--no-sides")
        if parsed.flags.contains("--drop-interface") {
            // After the moments are matched (they match on the raw screen), as the app reads the screen.
            cases = cases.map { replayCase in
                var c = replayCase
                if let screen = c.screen { c.screen = InterfaceLines.droppingTrailingRun(screen).text }
                return c
            }
        }
        var runs: [ReplayModelRun] = []
        for path in options.models {
            let entry = makeEntry(path: path)
            guard entry.validity == .valid, entry.summary != nil else {
                printErr("skipping \(path): not a usable model")
                continue
            }
            runs.append(try await replayModel(entry: entry, cases: cases, profiles: [], probeProfile: profile,
                                              points: points, options: options))
            printErr("rated moments from \(entry.url.lastPathComponent)")
        }
        guard !runs.isEmpty else { throw EvalError("no usable model") }
        let page = ratingPage(runs: runs, cases: cases, profileName: profile.name,
                              runID: (outDir as NSString).lastPathComponent)
        try page.write(toFile: outDir + "/rate.html", atomically: true, encoding: .utf8)
        try confidenceJSONL(runs, probeProfile: profile.name)
            .write(toFile: outDir + "/confidence.jsonl", atomically: true, encoding: .utf8)
        printOut("blind rating page: \(outDir)/rate.html (\(points.count) moments, \(runs.count) models)")
        return ExitCode.ok
    } catch {
        printErr("rate: \(error)")
        return ExitCode.failure
    }
}
