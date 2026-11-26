// M3 report sections: short-Chinese header leaks, traditional-script rate, typo suppression precision/recall.
import Foundation
import HunchCore
import HunchPrompt
import HunchText

/// True when the raw text repeats the document framer's own header wording.
func rawLeaksHeader(_ raw: String) -> Bool {
    let checker = DefaultPostProcessor(classifier: NeverAIVoice(), prefaceTexts: DocumentFramer.prefacePhrases)
    let ctx = PostContext(before: "", after: "", requiredPrefix: "", allowNewlines: true, maxWords: 200)
    return checker.process(raw, meanLogProb: nil, context: ctx) == .suppress(.metaReply)
}

func renderM3Sections(rows: [ResultRow], cells: [CellInfo]) -> String {
    var md = ""
    for cell in cells {
        let cold = rows.filter { $0.model == cell.model && $0.config == cell.config && $0.pass == "cold"
            && $0.repeatIndex == 0 && $0.error == nil }
        var section = ""

        let short = cold.filter { $0.tags.contains("zhshort") }
        if !short.isEmpty {
            let leaks = short.filter { rawLeaksHeader($0.raw) }.count
            let meta = short.filter { $0.suppressReason == SuppressReason.metaReply.rawValue }.count
            let empty = short.filter { $0.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            section += "- short Chinese prefixes (2-6 chars, \(short.count) cases): raw header leaks \(leaks), "
                + "suppressed as metaReply \(meta), empty raw \(empty), shown \(short.filter { !$0.suppressed }.count)\n"
        }

        let trad = cold.filter { $0.tags.contains("zhtrad") }
        // Inputs with a traditional-only character make the script unambiguous (the app converts only then).
        let tradClear = trad.filter { HanScript.usesTraditional($0.before) }
        func tradRates(_ set: [ResultRow]) -> String {
            let rawHan = set.compactMap { isTraditionalText($0.raw) }
            let shownHan = set.compactMap { $0.shown.flatMap(isTraditionalText) }
            return "raw traditional \(fmtPct(rawHan.filter { $0 }.count, rawHan.count)) (of \(rawHan.count) with Han text), "
                + "shown traditional \(fmtPct(shownHan.filter { $0 }.count, shownHan.count)) (of \(shownHan.count))"
        }
        if !trad.isEmpty {
            section += "- traditional inputs, all \(trad.count): \(tradRates(trad))\n"
            section += "- traditional inputs with unambiguous script (a traditional-only character typed), \(tradClear.count): \(tradRates(tradClear))\n"
            for t in tradClear where t.shown.flatMap(isTraditionalText) == false {
                section += "  - simplified shown: \(t.phraseID) `\(mdEscape(t.before))` -> `\(mdEscape(t.shown ?? ""))`\n"
            }
        }

        let typos = cold.filter { $0.tags.contains("typo") }
        let rare = cold.filter { $0.tags.contains("rare") }
        if !typos.isEmpty || !rare.isEmpty {
            let isTypoSuppress: (ResultRow) -> Bool = { $0.suppressReason == SuppressReason.likelyTypo.rawValue }
            let tp = typos.filter(isTypoSuppress).count
            let fpRare = rare.filter(isTypoSuppress).count
            let fpOther = cold.filter { !$0.tags.contains("typo") && !$0.tags.contains("rare") }.filter(isTypoSuppress).count
            let others = cold.count - typos.count - rare.count
            let notShown = typos.filter { $0.suppressed }.count
            let flagged = tp + fpRare + fpOther
            section += "- typo suppression: recall \(tp)/\(typos.count) misspelled-last-word cases (nothing shown for any reason: \(notShown)/\(typos.count)); "
                + "false suppressions on correctly spelled rare words \(fpRare)/\(rare.count), on the other \(others) phrases \(fpOther); "
                + "precision \(fmtPct(tp, flagged))\n"
            for t in typos where !isTypoSuppress(t) {
                section += "  - missed: \(t.phraseID) `\(mdEscape(t.before))` -> \(t.suppressReason.map { "suppressed (\($0))" } ?? "shown") raw `\(mdEscape(t.raw))`\n"
            }
            for t in rare where isTypoSuppress(t) { section += "  - false positive: \(t.phraseID) `\(mdEscape(t.before))`\n" }
        }
        if !section.isEmpty { md += "\n### M3 checks: \(cell.model) x \(cell.config)\n\n" + section }
    }
    return md.isEmpty ? "" : "\n## M3 checks\n" + md
}
