// hunch-eval: prompt/decoding evaluation harness (design §8).
import Foundation

let usageText = """
usage: hunch-eval <command> [options]
  inspect <folder>        list .gguf files: validity, arch, name, base/instruct, framer
  run --models <file>... --configs <config.json>... [--phrases eval/phrases.jsonl]
      [--subset tag] [--repeat N] [--quick] [--no-typo-check] [--out dir]
                          phrase x model x config; cold + replay passes; writes report.md and results.csv
  bias --model <file> --config <config.json> [--vocab eval/bias/vocab.json] [--cases eval/bias/cases.jsonl]
       [--phrases eval/phrases.jsonl] [--strengths 0,1.5,3] [--no-typo-check] [--out dir]
                          learned-vocabulary bias experiment (fit / intrusion / first-word delta / latency)
  typing --model <file> [--cases eval/typing/cases.jsonl] [--cps 6] [--budget N] [--seed N] [--out dir]
                          keystroke-by-keystroke replay through the engine: latency, wasted GPU work,
                          GPU busy %, memory; writes typing-report.md and typing-results.csv
  write --model <file> [--cases eval/write/cases.jsonl] [--out dir]
                          write-for-me drafts and polishes: time, facts kept, unwanted text; writes write-report.md
  copy --model <file> [--config c.json] [--cases eval/copy/cases.jsonl] [--variants old new6] [--screen-limits 3500 800] [--screen-lines 0 6]
       [--steps 4] [--out dir]
                          accepts suggestions repeatedly; how much screen text or saved sentences get copied
  trim-grid --drops -2.5,-3 --windows 1,2 --in <confidence.jsonl>...
                          confidence trim over recorded suggestions (replay/rate --trim off) for tuning
  autocorrect [--model <file>] [--variants 2] [--rate 0.25] [--reads 1 0.35] [--cps 11] [--seed 1] [--limit N] [--out dir]
              [--settle-return] [--leave-shorthand] [--no-timing] [--no-timed-swaps] [--fixed-ms 150]
              [--slip-profile <file.json>]
                          fast typing with slips (real samples + synthetic) replayed through autocorrect with
                          Fix automatically on; slips fixed, clean words broken; writes autocorrect-report.md.
  rewrite --model <file> [--sets a.jsonl,b.jsonl] [--synthetic 40] [--after autocorrect-results.csv] [--out dir]
                          whole-field rewrite (Top strength) at each sentence end; slips fixed, words broken,
                          extra words; writes rewrite-report.md and judge-set.jsonl for blind Opus judges.
                          --switches app,on,caps-off,punct-off,shorthand,all-off: the same style switches for
                          every text, with spelling slips left unfixed per switch.
                          A line break or the end of the text sends what is shown (the app doesn't settle waiting
                          words at Return; --settle-return: the old way); --leave-shorthand: chat shorthand (ofc, id, tbh…) left alone.
                          Key timing: synthetic per keystroke (or recorded with a saved sample); --no-timing: none,
                          --no-timed-swaps: everyday words are never asked. --fixed-ms N: no timeouts, every decision
                          takes N ms on the simulated clock (load-independent A/B). --slip-profile: the user's
                          personal slip list, JSON {"strength": ["strenght"], …} (trouble word → known slips)
  live [--in live-outcomes.jsonl] [--by build|config|model|app|surface] [--since 2026-11-18] [--out report.md]
                          real-use numbers from the app's live acceptance log (Save typing samples and
                          suggestion outcomes): acceptance, chars accepted per 100 typed, regret, unseen,
                          acceptance by confidence band, automatic fixes kept / undone
  kvcheck <model.gguf>    KV append/trim/shift reuse vs cold prefill log-prob equivalence
  selftest                check the harness's own pure helpers
exit codes: 0 ok, 1 failure (or kvcheck FAIL), 2 usage
"""

func entry() async -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        printErr(usageText)
        return ExitCode.usage
    }
    let rest = Array(args.dropFirst())
    switch command {
    case "inspect": return runInspect(rest)
    case "run": return await runCommand(rest)
    case "bias": return await runBiasCommand(rest)
    case "kvcheck": return await runKVCheck(rest)
    case "typing": return await runTypingCommand(rest)
    case "replay": return await runReplayCommand(rest)
    case "app-screen": return runAppScreenCommand(rest)
    case "screen-log": return runScreenLogCommand(rest)
    case "interface-review": return runInterfaceReviewCommand(rest)
    case "history-cases": return await runHistoryCasesCommand(rest)
    case "capture-cases": return await runCaptureCasesCommand(rest)
    case "rate": return await runRateCommand(rest)
    case "judge-export": return await runJudgeExportCommand(rest)
    case "judge-report": return await runJudgeReportCommand(rest)
    case "memory": return await runMemoryCommand(rest)
    case "write": return await runWriteCommand(rest)
    case "copy": return await runCopyCommand(rest)
    case "trim-grid": return runTrimGridCommand(rest)
    case "autocorrect": return await runAutocorrectCommand(rest)
    case "rewrite": return await runRewriteCommand(rest)
    case "styles": return await runStylesCommand(rest)
    case "live": return runLiveCommand(rest)
    case "selftest": return runSelfTest()
    case "-h", "--help", "help":
        printOut(usageText)
        return ExitCode.ok
    default:
        printErr("unknown command '\(command)'\n" + usageText)
        return ExitCode.usage
    }
}

exit(await entry())
