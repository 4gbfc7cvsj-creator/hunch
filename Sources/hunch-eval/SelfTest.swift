// `selftest`: assertions for the harness's pure helpers (the executable has no XCTest target).
import Foundation
import HunchCore
import HunchPrompt
import HunchText

func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; printErr("FAIL: \(what)") }
    }
    check(percentile([], 0.5) == nil, "empty percentile")
    do {
        let long = String(repeating: "x", count: 30)
        func cap(_ text: String, _ screen: String) -> ReplayCase {
            ReplayCase(id: "cap-1", surface: .agentPrompt, tags: ["capture"], screen: screen, text: text)
        }
        let picked = captureCases([cap("first", long), cap("short screen", "x"), cap("first", long + "y")], minScreen: 20)
        check(picked.map(\.id) == ["real-01"] && picked.first?.screen == long + "y", "capture-cases keeps long, dedupes")
        check(picked.first?.tags == ["capture", "long", "real"], "capture-cases tags")
    }
    check(percentile([5, 1, 3, 2, 4], 0.5) == 3, "p50 of five")
    check(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95) == 10, "p95 of ten")
    check(percentile([7], 0.95) == 7, "single sample")

    check(firstWordMatches(expect: ["hearing"], before: "Looking forward to hea", completion: "ring from you"), "mid-word join")
    check(!firstWordMatches(expect: ["hearing"], before: "Looking forward to hea", completion: "d to"), "mid-word mismatch")
    check(firstWordMatches(expect: ["Student"], before: "I am a", completion: " student at"), "case-insensitive first word")
    check(!firstWordMatches(expect: ["stud"], before: "I am a", completion: " student"), "whole word only")
    check(firstWordMatches(expect: ["公园"], before: "我们一起去", completion: "公园玩"), "CJK prefix")
    check(!firstWordMatches(expect: ["x"], before: "a", completion: ""), "empty completion never matches")
    check(firstWord("  Hello, world") == "hello", "firstWord strips punctuation")

    let snips = [StyleSnippet(id: "a", text: "the kiln is booked saturday"), StyleSnippet(id: "b", text: "pushed the tidepool fix"),
                 StyleSnippet(id: "c", text: "nothing relevant here")]
    check(selectSnippets(StyleSetting(snippets: snips, k: 2, fill: false), before: "booked the kiln").map(\.id) == ["a"], "snippet overlap select")
    check(selectSnippets(StyleSetting(snippets: snips, k: 2, fill: true), before: "booked the kiln").map(\.id) == ["a", "b"], "snippet fill")
    check(selectSnippets(StyleSetting(snippets: snips, k: 0, fill: true), before: "kiln").isEmpty, "k=0 selects none")
    check(copiesSnippet("so the kiln is booked", snips) && !copiesSnippet("the kiln is", snips), "snippet copy detector")

    check(csvEscape("a,b") == "\"a,b\"", "csv comma quoting")
    check(csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"", "csv quote doubling")
    check(csvEscape("a\nb") == "a\\nb", "csv newline flattening")

    do {
        let cfg = try EvalConfig.parse(["length": "short", "decode": ["maxTokens": 9, "scoring": "mean"], "addBOS": false],
                                       fallbackName: "t")
        check(cfg.decode.maxWords == 2 && cfg.decode.minWords == 1, "length preset applied")
        check(cfg.decode.maxTokens == 9 && cfg.decode.scoring == .mean, "decode overrides applied")
        check(cfg.addBOS == false && cfg.framerOverride == nil, "addBOS and auto framer")
    } catch {
        check(false, "config parse threw \(error)")
    }
    check((try? EvalConfig.parse(["decode": ["bogus": 1]], fallbackName: "t")) == nil, "unknown decode key rejected")
    check((try? EvalConfig.parse(["wat": 1], fallbackName: "t")) == nil, "unknown top-level key rejected")

    let args = ParsedArgs(["--models", "a", "b", "--configs", "c", "--quick", "pos"], valueOptions: ["--models", "--configs"])
    check(args.values("--models") == ["a", "b"] && args.values("--configs") == ["c"], "multi-value options")
    check(args.flags.contains("--quick") && args.positionals == ["pos"], "flags and positionals")

    // PrefaceEcho (HunchText) keeps a copy of the framer header wording; fail when the framer gains/changes a phrase.
    let drift = prefaceDrift()
    check(drift.isEmpty, "PrefaceEcho built-ins out of step with DocumentFramer.prefacePhrases: \(drift.count) phrase(s) not caught : \(drift.joined(separator: " | "))")
    check(!DocumentFramer.prefacePhrases.isEmpty, "framer exposes preface phrases")
    let ctx = PostContext(before: "", after: "", requiredPrefix: "", allowNewlines: false, maxWords: 50)
    check(DefaultPostProcessor(classifier: NeverAIVoice(), prefaceTexts: [])
        .process("see you at the station tomorrow", meanLogProb: nil, context: ctx) == .show("see you at the station tomorrow"),
          "ordinary text is not a preface echo")
    check(isTraditionalText("謝謝你") == true && isTraditionalText("谢谢你") == false && isTraditionalText("hello") == nil,
          "traditional detection")

    // Replay typist: accepting matching words, shrinking on typed matches, hiding on a mismatch.
    var typist = Typist(prefix: "", text: "see you at the station tomorrow")
    for _ in 0..<7 { typist.typeNext() }                       // "see you"
    typist.show(" at the airport")
    check(typist.acceptMatching() == 2 && typist.before == "see you at the", "accepts matching words, stops at a mismatch")
    check(typist.ghost == " airport" && typist.keys == 9, "ghost keeps the rest; one key per accepted word")
    typist.typeNext()                                          // " " continues the ghost
    check(typist.ghost == "airport", "typed character shrinks the ghost")
    typist.typeNext()                                          // "s" ≠ "a"
    check(typist.ghost == nil, "mismatch hides the ghost")
    typist.show("tation tomorrow")
    check(typist.acceptMatching() == 2 && typist.done, "mid-word suggestion accepted to the end")
    check(typist.eventUnits == [2, 2] && typist.acceptKeys == 4, "accepted words counted per suggestion")
    check(abs(keystrokesSaved(characters: 31, keys: typist.keys) - Double(31 - typist.keys) / 31) < 1e-9,
          "keystrokes saved formula")
    var punct = Typist(prefix: "", text: "ok, sure")
    punct.typeNext(); punct.typeNext()
    punct.show(", sure thing")
    check(punct.acceptMatching() == 2 && punct.done, "punctuation is its own accept unit")
    var cjk = Typist(prefix: "", text: "我們明天見")
    cjk.typeNext(); cjk.typeNext()
    cjk.show("明天見面")
    check(cjk.acceptMatching() >= 1 && cjk.before.hasPrefix("我們明天"), "CJK words accepted")
    var blank = Typist(prefix: "", text: "abc")
    blank.show("   ")
    check(blank.ghost == nil && blank.acceptMatching() == 0, "blank suggestion shows nothing")
    let probeCases = (0..<10).map { ReplayCase(id: "c\($0)", surface: .chat, text: "one two three four five six seven eight") }
        + [ReplayCase(id: "code", surface: .code, text: "let names = users.map { $0.name }"),
           ReplayCase(id: "zh", surface: .chat, text: "好啊，那我們週六下午兩點在捷運站門口見")]
    let points = ratingPoints(probeCases, count: 6, seed: 2)
    let chars = { (i: Int) in Array(probeCases[i].text) }
    check(points.count == 6 && !points.contains { probeCases[$0.caseIndex].surface == .code }, "rating points skip code")
    check(points.filter { probeCases[$0.caseIndex].id == "zh" }.count == 1, "every Chinese case is in")
    check(points.filter { probeCases[$0.caseIndex].id != "zh" }.allSatisfy { chars($0.caseIndex)[$0.cut] == " " },
          "English cuts land on a space")
    check(ratingPoints(probeCases, count: 30, seed: 2).filter { probeCases[$0.caseIndex].id == "zh" }.count == 2,
          "two cuts per Chinese case on a full page")
    check(ratingPoints(probeCases, count: 6, seed: 2).map(\.cut) == points.map(\.cut), "rating points repeat for a seed")
    check(surfaceGuess(appKey: "com.tinyspeck.slackmacgap") == .chat && surfaceGuess(appKey: "mail.google.com") == .email
          && surfaceGuess(appKey: "claude.ai") == .agentPrompt, "history surface guess")

    if failures == 0 { printOut("selftest: all checks passed") }
    return failures == 0 ? ExitCode.ok : ExitCode.failure
}
