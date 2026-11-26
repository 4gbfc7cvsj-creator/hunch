import Foundation
import Testing
@testable import HunchText

/// A rewrite pass over Hunch's own fixes: the model sees what was typed, and its answer is mapped
/// onto the field as it is.
struct RewriteOwnFixesTests {
    /// An own fix of `typed` to the first `fixed` in `text` (at or after `from`).
    private func fix(_ fixed: String, typed: String, in text: String, from: Int = 0, id: Int? = nil) -> OwnFix {
        let ns = text as NSString
        let r = ns.range(of: fixed, range: NSRange(location: from, length: ns.length - from))
        return OwnFix(range: r.location..<(r.location + r.length), typed: typed, fixed: fixed, id: id)
    }

    private func pass(_ text: String, fixes: [OwnFix], revised: String, options: RewriteOptions = .init(),
                      kept: RewriteOwnFixes.KeptTyped = .keepFix, finished: Bool = true)
        -> (sent: String, out: String, edits: [OwnFixEdit]) {
        let target = RewriteTarget.find(before: text, finished: finished)!
        let typed = RewriteOwnFixes.asTyped(target, fixes: fixes)
        let result = FieldRewrite.edits(target: typed.target, revised: revised, options: options)
        let edits = RewriteOwnFixes.mapBack(result, revised: revised, on: typed, options: options, kept: kept)
        return (typed.target.text, FieldRewrite.apply(edits.map(\.edit), to: text), edits)
    }

    @Test func sendsTheTypedForm() {
        let text = "it went quietly well today"
        let r = pass(text, fixes: [fix("quietly", typed: "quialty", in: text)], revised: "it went quality well today")
        #expect(r.sent == "it went quialty well today")
    }

    @Test func modelsOtherWordReplacesTheFix() {
        let text = "the quietly of it is fine"
        let r = pass(text, fixes: [fix("quietly", typed: "quialty", in: text, id: 7)], revised: "the quality of it is fine")
        #expect(r.out == "the quality of it is fine")
        #expect(r.edits.count == 1)
        #expect(r.edits[0].edit.original == "quietly")
        #expect(r.edits[0].typed == "quialty")
        #expect(r.edits[0].undoText == "quialty")
        #expect(r.edits[0].replacesFixes == [7])
    }

    @Test func theFixGivesWayOnlyToKnownWords() {
        let text = "Could you check it"
        let f = fix("Could", typed: "coudl", in: text)
        let target = RewriteTarget.find(before: text, finished: true)!
        let typed = RewriteOwnFixes.asTyped(target, fixes: [f])
        let known: (String) -> Bool = { ["could", "you", "check", "it", "cold"].contains($0.lowercased()) }
        for (revised, changes) in [("couldl you check it", false), ("cold you check it", true)] {
            let result = FieldRewrite.edits(target: typed.target, revised: revised)
            let edits = RewriteOwnFixes.mapBack(result, revised: revised, on: typed, isKnownWord: known, rules: [])
            #expect(edits.isEmpty != changes, "\(revised)")
        }
    }

    @Test func modelAgreeingWithTheFixChangesNothing() {
        let text = "I think the plan is good"
        let r = pass(text, fixes: [fix("think", typed: "thnik", in: text)], revised: "I think the plan is good")
        #expect(r.edits.isEmpty)
        #expect(r.out == text)
    }

    @Test func otherChangesMoveWithTheFixesBeforeThem() {
        // The fix is longer than what was typed: a change after it lands at the right place.
        let text = "the quietly of it is form here"
        let r = pass(text, fixes: [fix("quietly", typed: "qulty", in: text)], revised: "the quality of it is from here")
        #expect(r.out == "the quality of it is from here")
        let plain = r.edits.first { $0.typed == nil }!
        #expect(plain.edit.original == "form")
    }

    @Test func changeNextToAFixAgreeingKeepsTheFix() {
        let text = "I think the the plan is good"
        let r = pass(text, fixes: [fix("think", typed: "thnik", in: text)], revised: "I think the plan is good")
        #expect(r.out == "I think the plan is good")
        #expect(r.edits.allSatisfy { $0.typed == nil })
    }

    @Test func keptTypedFormKeepsOrRevertsByPolicy() {
        let text = "load the gruff file now"
        let f = fix("gruff", typed: "gguf", in: text, id: 3)
        let keep = pass(text, fixes: [f], revised: "load the gguf file now")
        #expect(keep.out == text)
        let revert = pass(text, fixes: [f], revised: "load the gguf file now", kept: .revert)
        #expect(revert.out == "load the gguf file now")
        #expect(revert.edits.first?.revertsFix == true)
        #expect(revert.edits.first?.replacesFixes == [3])
    }

    @Test func guardRejectedChangeIsNotAKeptTypedForm() {
        // The model wrote something the guard throws out (a different word): the fix stays.
        let text = "load the gruff file now"
        let r = pass(text, fixes: [fix("gruff", typed: "gguf", in: text)], revised: "load the model file now", kept: .revert)
        #expect(r.out == text)
    }

    @Test func capitalAndPunctuationFixesStayAsTheyAre() {
        let text = "I don't know"
        let fixes = [fix("I", typed: "i", in: text), fix("don't", typed: "dont", in: text)]
        let target = RewriteTarget.find(before: text, finished: true)!
        #expect(RewriteOwnFixes.asTyped(target, fixes: fixes).target.text == text)
    }

    @Test func capitalsOffComparesWithoutCase() {
        var chat = RewriteOptions()
        chat.fixesCapitals = false
        let text = "The plan is good"
        // Fix-as-you-type fixed "teh" with a sentence capital; the model's "The" styled as typed is "the".
        let r = pass(text, fixes: [fix("The", typed: "teh", in: text)], revised: "The plan is good", options: chat)
        #expect(r.out == text)
    }

    @Test func fixesOutsideTheTargetOrInTheHeldTailStay() {
        let text = "First one is done. Then the secnod one is goign"
        let target = RewriteTarget.find(before: text, checked: "First one is done. ")!
        let fixes = [fix("First", typed: "Frist", in: text), fix("goign", typed: "going", in: text)]
        let typed = RewriteOwnFixes.asTyped(target, fixes: fixes)
        #expect(typed.placed.isEmpty)
        #expect(typed.target == target)
    }

    @Test func aFixNoLongerInTheTextIsSkipped() {
        let text = "the quality of it"
        let stale = OwnFix(range: 4..<11, typed: "quialty", fixed: "quietly")
        let target = RewriteTarget.find(before: text, finished: true)!
        #expect(RewriteOwnFixes.asTyped(target, fixes: [stale]).placed.isEmpty)
    }

    @Test func typedFormWithASpaceMapsBack() {
        // Fix-as-you-type joined "wtih me" into "with"; the model reads it as "with me": that replaces the fix.
        let text = "come with now"
        let r = pass(text, fixes: [fix("with", typed: "wtih me", in: text)], revised: "come with me now")
        #expect(r.sent == "come wtih me now")
        #expect(r.out == "come with me now")
        #expect(r.edits.first?.typed == "wtih me")
    }

    @Test func aJoinOrSplitStaysAsFixed() {
        // Only spacing changed ("w ith" → "with"): not sent as typed.
        let text = "come with me now"
        let target = RewriteTarget.find(before: text, finished: true)!
        #expect(RewriteOwnFixes.asTyped(target, fixes: [fix("with", typed: "w ith", in: text)]).placed.isEmpty)
    }

    @Test func twoFixesAndAChangeBetween() {
        let text = "the quietly and fever of it"
        let fixes = [fix("quietly", typed: "quialty", in: text), fix("fever", typed: "rever", in: text)]
        let r = pass(text, fixes: fixes, revised: "the quality and fever of it")
        #expect(r.sent == "the quialty and rever of it")
        #expect(r.out == "the quality and fever of it")
        #expect(r.edits.count == 1)
    }

    @Test func aModelThatKeepsPartOfTheSlipLeavesTheFix() {
        let text = "Yes please do it"
        let r = pass(text, fixes: [fix("Yes please", typed: "ye spklease", in: text)], revised: "ye please do it")
        #expect(r.out == text)
    }

    @Test func keepingAllOfATypedNameReplacesTheFix() {
        let text = "I watched Frier last night"
        let r = pass(text, fixes: [fix("Frier", typed: "frieren", in: text)], revised: "I watched Frieren last night",
                     options: { var o = RewriteOptions(); o.fixesCapitals = true; return o }())
        #expect(r.out == "I watched Frieren last night")
    }

    @Test func anAddedWordMustComeFromTheKeys() {
        let added = "I set it up"
        #expect(pass(added, fixes: [fix("set", typed: "siet", in: added)], revised: "I i set it up").out == added)
        let split = "please send the file"
        let r = pass(split, fixes: [fix("send", typed: "sendme", in: split)], revised: "please send me the file")
        #expect(r.out == "please send me the file")
    }

    @Test func aCostlierReadingThanTheFixLeavesIt() {
        // "3hen": "when" is one key off, "then" is further.
        let text = "tell me when you are back"
        let r = pass(text, fixes: [fix("when", typed: "3hen", in: text)], revised: "tell me then you are back")
        #expect(r.out == text)
        let target = RewriteTarget.find(before: text, finished: true)!
        let typed = RewriteOwnFixes.asTyped(target, fixes: [fix("when", typed: "3hen", in: text)])
        let result = FieldRewrite.edits(target: typed.target, revised: "tell me then you are back")
        let loose = RewriteOwnFixes.mapBack(result, revised: "tell me then you are back", on: typed, rules: [])
        #expect(loose.count == 1)
    }

    private func mapped(_ text: String, _ f: OwnFix, revised: String, known: Set<String>, common: Set<String>?)
        -> (out: String, edits: [OwnFixEdit]) {
        let target = RewriteTarget.find(before: text, finished: true)!
        let typed = RewriteOwnFixes.asTyped(target, fixes: [f])
        let result = FieldRewrite.edits(target: typed.target, revised: revised)
        let edits = RewriteOwnFixes.mapBack(result, revised: revised, on: typed, isKnownWord: { known.contains($0.lowercased()) },
                                            isCommonWord: common.map { c in { c.contains($0) } })
        return (FieldRewrite.apply(edits.map(\.edit), to: text), edits)
    }

    @Test func aRareFixGivesWayToACostlierReading() {
        // "anthin" → "xanthin" (one added key) vs the model's "anything" (two): the fix was a stretch.
        let text = "see if you can catch xanthin"
        let f = fix("xanthin", typed: "anthin", in: text)
        let words: Set = ["see", "if", "you", "can", "catch", "anything", "xanthin", "tell", "me", "when", "then", "are", "back"]
        let common: Set = ["see", "if", "you", "can", "catch", "anything", "tell", "me", "when", "then", "are", "back"]
        #expect(mapped(text, f, revised: "see if you can catch anything", known: words, common: common).out
                == "see if you can catch anything")
        #expect(mapped(text, f, revised: "see if you can catch anything", known: words, common: nil).out == text)
        // A common word as the fix keeps the cost rule: "3hen" stays "when".
        let t2 = "tell me when you are back"
        #expect(mapped(t2, fix("when", typed: "3hen", in: t2), revised: "tell me then you are back",
                       known: words, common: common).out == t2)
    }

    @Test func aFixThatIsNoWordIsTakenBackWhenTheModelKeepsTheTypedForm() {
        let text = "but olmqk when you are here"
        let f = fix("olmqk", typed: "olmk", in: text, id: 4)
        let known: Set = ["but", "when", "you", "are", "here", "gruff", "load", "the", "file", "now"]
        let r = mapped(text, f, revised: "but olmk when you are here", known: known, common: nil)
        #expect(r.out == "but olmk when you are here")
        #expect(r.edits.first?.revertsFix == true && r.edits.first?.replacesFixes == [4])
        // A fix that is a real word stays (the model may just have missed the slip).
        let t2 = "load the gruff file now"
        #expect(mapped(t2, fix("gruff", typed: "gguf", in: t2), revised: "load the gguf file now", known: known, common: nil).out == t2)
    }

    private func kept(_ text: String, _ fixes: [OwnFix], revised: String, known: Set<String>,
                      rules: RewriteOwnFixes.KeptTypedRules, terms: Set<String> = []) -> (out: String, edits: [OwnFixEdit]) {
        let target = RewriteTarget.find(before: text, finished: true)!
        let typed = RewriteOwnFixes.asTyped(target, fixes: fixes)
        let result = FieldRewrite.edits(target: typed.target, revised: revised)
        let edits = RewriteOwnFixes.mapBack(result, revised: revised, on: typed, isKnownWord: { known.contains($0.lowercased()) },
                                            keptRules: rules, writerTerms: terms)
        return (FieldRewrite.apply(edits.map(\.edit), to: text), edits)
    }

    @Test func aTypedRealWordIsTakenBackWhenTheModelKeepsIt() {
        // "dock" → "rock": a real word for a real word, and the model sides with the typed one.
        let text = "put it in the rock now"
        let f = fix("rock", typed: "dock", in: text, id: 2)
        let known: Set = ["put", "it", "in", "the", "rock", "dock", "now", "from", "form", "a", "their", "there", "is"]
        #expect(kept(text, [f], revised: "put it in the dock now", known: known, rules: []).out == text)
        let r = kept(text, [f], revised: "put it in the dock now", known: known, rules: .realWord)
        #expect(r.out == "put it in the dock now")
        #expect(r.edits.first?.revertsFix == true && r.edits.first?.replacesFixes == [2])
        // The model changed the word some other way: not a kept typed form, the fix stays.
        #expect(kept(text, [f], revised: "put it in the dick now", known: known, rules: .realWord).out == text)
        // A typed non-word is not this rule's ("gguf" → "gruff").
        let t2 = "put it in the rock now"
        #expect(kept(t2, [fix("rock", typed: "rcok", in: t2)], revised: "put it in the rcok now", known: known,
                     rules: .realWord).out == t2)
    }

    @Test func aKnownConfusionStaysUnderTheRealWordRule() {
        let known: Set = ["it", "is", "from", "form", "a", "their", "there", "on", "no", "way", "here", "car"]
        // Two neighbouring letters swapped ("form" → "from"): the model echoing the slip is likely.
        let text = "it is from a car"
        let f = fix("from", typed: "form", in: text)
        #expect(kept(text, [f], revised: "it is form a car", known: known, rules: .realWord).out == text)
        #expect(kept(text, [f], revised: "it is form a car", known: known, rules: [.realWord, .anyRealWord]).out
                == "it is form a car")
        // Confused-word rivals.
        let t2 = "their is no way"
        #expect(kept(t2, [fix("their", typed: "there", in: t2)], revised: "there is no way", known: known,
                     rules: .realWord).out == t2)
        #expect(RewriteOwnFixes.isKnownConfusion(typed: "on", fixed: "no"))
        #expect(RewriteOwnFixes.isKnownConfusion(typed: "There", fixed: "their"))
        #expect(!RewriteOwnFixes.isKnownConfusion(typed: "dock", fixed: "rock"))
        #expect(!RewriteOwnFixes.isKnownConfusion(typed: "abc", fixed: "cba"))
    }

    @Test func aDroppedLetterFixStaysUnderTheRealWordRule() {
        // "gain" → "again": the commonest slip; the model echoing "gain" is no second judge.
        let known: Set = ["trying", "again", "gain", "to", "see", "put", "it", "in", "the", "dock", "rock", "now"]
        let text = "trying again to see"
        let f = fix("again", typed: "gain", in: text)
        #expect(kept(text, [f], revised: "trying gain to see", known: known, rules: .realWord).out == "trying gain to see")
        #expect(kept(text, [f], revised: "trying gain to see", known: known, rules: [.realWord, .droppedLetterStays]).out == text)
        // A swapped letter is still taken back.
        let t2 = "put it in the rock now"
        #expect(kept(t2, [fix("rock", typed: "dock", in: t2)], revised: "put it in the dock now", known: known,
                     rules: [.realWord, .droppedLetterStays]).out == "put it in the dock now")
        #expect(RewriteOwnFixes.putsBackOneLetter(typed: "th", fixed: "The"))
        #expect(!RewriteOwnFixes.putsBackOneLetter(typed: "dock", fixed: "rock"))
        #expect(!RewriteOwnFixes.putsBackOneLetter(typed: "awe", fixed: "we"))
    }

    @Test func fixConfidenceIsUnsureForARareWordTheWriterNeverLearned() {
        let everyday: Set = ["the", "file", "we", "can", "be", "me", "points", "lets"]
        let learned: Set = ["autocorrect"]
        func c(_ typed: String, _ fixed: String) -> FixConfidence {
            FixConfidence.of(typed: typed, fixed: fixed, isEveryday: { everyday.contains($0) }, isLearned: { learned.contains($0) })
        }
        #expect(c("gguf", "gruff") == .unsure)
        #expect(c("worktree", "corktree") == .unsure)
        #expect(c("teh", "the") == .sure)
        #expect(c("md", "Me") == .sure)
        // A learned word is the writer's own: sure ("autocreect" → "autocorrect").
        #expect(c("autocreect", "autocorrect") == .sure)
        #expect(c("autocreect", "Autocorrect") == .sure)
        // Only words the fix put in count: a capital or a kept typed word is no new word.
        #expect(c("gruff", "Gruff") == .sure)
        #expect(c("gruff fiel", "gruff file") == .sure)
        #expect(c("thefile", "the file") == .sure)
        #expect(c("thefile", "the fiel") == .unsure)
        #expect(c("cna be", "can be") == .sure)
        // Words with digits are not words put in.
        #expect(c("teh2", "the2") == .sure)
    }

    @Test func anUnsureFixIsTakenBackWhenTheModelKeepsTheTypedForm() {
        let known: Set = ["load", "the", "gruff", "file", "now"]
        let text = "load the gruff file now"
        var f = fix("gruff", typed: "gguf", in: text, id: 4)
        f.confidence = .unsure
        // Without the rule: the fix is a known word and stays.
        #expect(kept(text, [f], revised: "load the gguf file now", known: known, rules: .app).out == text)
        let r = kept(text, [f], revised: "load the gguf file now", known: known, rules: [.app, .unsureFix])
        #expect(r.out == "load the gguf file now")
        #expect(r.edits.first?.revertsFix == true && r.edits.first?.replacesFixes == [4])
        // A sure fix the model echoes the slip over stays ("autocreect" → "autocorrect").
        var sure = f
        sure.confidence = .sure
        #expect(kept(text, [sure], revised: "load the gguf file now", known: known, rules: [.app, .unsureFix]).out == text)
        // No recorded confidence (a pass's own fix): stays.
        var none = f
        none.confidence = nil
        #expect(kept(text, [none], revised: "load the gguf file now", known: known, rules: [.app, .unsureFix]).out == text)
        // The model agreeing with the fix changes nothing.
        #expect(kept(text, [f], revised: "load the gruff file now", known: known, rules: [.app, .unsureFix]).out == text)
        // Confidence follows a fix moved by an earlier change.
        let moved = RewriteOwnFixes.fixesAfter([f], edits: [OwnFixEdit(edit: RewriteEdit(range: 0..<4, original: "load", replacement: "loads", kind: .word))],
                                               in: text)
        #expect(moved.first?.confidence == .unsure)
    }

    @Test func aTypedTermIsTakenBackWhenTheWriterUsesIt() {
        let known: Set = ["load", "the", "gruff", "file", "now", "and", "keep", "it", "corktree", "in", "a", "new"]
        // Typed the same way elsewhere in the field and left as typed there.
        let text = "load the gguf file now and keep the gruff"
        let f = fix("gruff", typed: "gguf", in: text, from: 20, id: 7)
        #expect(kept(text, [f], revised: "load the gguf file now and keep the gguf", known: known, rules: []).out == text)
        let r = kept(text, [f], revised: "load the gguf file now and keep the gguf", known: known, rules: .term)
        #expect(r.out == "load the gguf file now and keep the gguf")
        #expect(r.edits.first?.revertsFix == true && r.edits.first?.replacesFixes == [7])
        // Only once in the field: not a term unless the writer's words have it (screen, learned).
        let t2 = "keep it in a new corktree"
        let g = fix("corktree", typed: "worktree", in: t2)
        #expect(kept(t2, [g], revised: "keep it in a new worktree", known: known, rules: .term).out == t2)
        #expect(kept(t2, [g], revised: "keep it in a new worktree", known: known, rules: .term, terms: ["worktree"]).out
                == "keep it in a new worktree")
        // Fixed both times: the typed form is not left anywhere, so no evidence.
        let t3 = "load the gruff file now and keep the gruff"
        let both = [fix("gruff", typed: "gguf", in: t3), fix("gruff", typed: "gguf", in: t3, from: 20)]
        #expect(kept(t3, both, revised: "load the gguf file now and keep the gguf", known: known, rules: .term).out == t3)
        // The model must keep the typed form: a change elsewhere doesn't count.
        #expect(kept(t2, [g], revised: "keep it in a new workflow", known: known, rules: .term, terms: ["worktree"]).out
                != "keep it in a new worktree")
    }

    // MARK: Arbiter

    private func arbitrated(_ text: String, _ fixes: [OwnFix], revised: String, known: Set<String>,
                            kinds: Set<OwnFixDispute.Kind> = OwnFixDispute.Kind.blocked.union([.keptTyped]),
                            keptRules: RewriteOwnFixes.KeptTypedRules = [], verdicts: [Range<Int>: String] = [:])
        -> (out: String, edits: [OwnFixEdit], disputes: [OwnFixDispute]) {
        let target = RewriteTarget.find(before: text, finished: true)!
        let typed = RewriteOwnFixes.asTyped(target, fixes: fixes)
        let result = FieldRewrite.edits(target: typed.target, revised: revised)
        var disputes: [OwnFixDispute] = []
        let edits = RewriteOwnFixes.mapBack(result, revised: revised, on: typed, isKnownWord: { known.contains($0.lowercased()) },
                                            keptRules: keptRules, arbitrated: kinds, verdicts: verdicts,
                                            disputes: { disputes.append($0) })
        return (FieldRewrite.apply(edits.map(\.edit), to: text), edits, disputes)
    }

    private let arbiterWords: Set<String> = ["what", "toes", "does", "it", "mean", "tell", "me", "when", "then", "you", "are",
                                             "back", "so", "fix", "the", "got", "goes", "on", "how", "he", "rock", "dock",
                                             "put", "in", "now", "i", "can"]

    @Test func aBlockedChangeIsADisputeWithItsReadings() {
        // "teos": the fix "toes" is one swap away, the model's "does" costlier: the slip-cost rule keeps "toes".
        let text = "what toes it mean"
        let f = fix("toes", typed: "teos", in: text, id: 1)
        let r = arbitrated(text, [f], revised: "what does it mean", known: arbiterWords)
        #expect(r.out == text)
        #expect(r.disputes.count == 1)
        let d = r.disputes[0]
        #expect(d.kind == .noCostlier)
        // The rule's choice first; the typed non-word is no reading.
        #expect(d.readings == ["toes", "does"])
        #expect(d.head == "what ")
        #expect(d.tail == " it mean")
        #expect(d.scoring.head == "what")
        #expect(d.scoring.continuations == [" toes it mean", " does it mean"])
        #expect(d.range == f.range)
        // A verdict for the model's word puts it in, as an own-fix change (undo gives back the typed form).
        let v = arbitrated(text, [f], revised: "what does it mean", known: arbiterWords, verdicts: [f.range: "does"])
        #expect(v.out == "what does it mean")
        #expect(v.edits.first?.undoText == "teos" && v.edits.first?.replacesFixes == [1])
        // Not arbitrated: no dispute, the rule decides.
        #expect(arbitrated(text, [f], revised: "what does it mean", known: arbiterWords, kinds: []).disputes.isEmpty)
    }

    @Test func aKeptTypedFormIsADispute() {
        let text = "put it in the rock now"
        let f = fix("rock", typed: "dock", in: text, id: 2)
        // Rule 1 takes the fix back: the typed word is the rule's choice.
        let r = arbitrated(text, [f], revised: "put it in the dock now", known: arbiterWords, keptRules: .realWord)
        #expect(r.out == "put it in the dock now")
        #expect(r.disputes.first?.kind == .keptTyped)
        #expect(r.disputes.first?.readings == ["dock", "rock"])
        // A verdict for the fix keeps it.
        let keep = arbitrated(text, [f], revised: "put it in the dock now", known: arbiterWords, keptRules: .realWord,
                              verdicts: [f.range: "rock"])
        #expect(keep.out == text)
        // Without rule 1 the fix is the choice; a verdict for the typed word takes it back.
        let none = arbitrated(text, [f], revised: "put it in the dock now", known: arbiterWords)
        #expect(none.out == text && none.disputes.first?.readings == ["rock", "dock"])
        let back = arbitrated(text, [f], revised: "put it in the dock now", known: arbiterWords, verdicts: [f.range: "dock"])
        #expect(back.out == "put it in the dock now")
        // A typed non-word kept: one real reading, no dispute.
        let t2 = "put it in the rock now"
        #expect(arbitrated(t2, [fix("rock", typed: "rcok", in: t2)], revised: "put it in the rcok now",
                           known: arbiterWords).disputes.isEmpty)
    }

    @Test func arbitrateNeedsAClearMarginAfterTheSlipCost() {
        let d = OwnFixDispute(kind: .noCostlier, range: 5..<9, typed: "teos", fixed: "toes", model: "does",
                              readings: ["toes", "does"], head: "what ", tail: " it mean")
        #expect(d.slipCost(0) < d.slipCost(1))
        let gap = d.slipCost(1) - d.slipCost(0)
        // The model's word must beat the fix by the margin after its extra slip cost.
        #expect(RewriteOwnFixes.arbitrate(d, scores: [-10, -10 + gap * 1.5 + 2.5], margin: 2, slipWeight: 1.5) == "does")
        #expect(RewriteOwnFixes.arbitrate(d, scores: [-10, -10 + gap * 1.5 + 1.5], margin: 2, slipWeight: 1.5) == nil)
        #expect(RewriteOwnFixes.arbitrate(d, scores: [-10, -1], margin: 2, slipWeight: 1.5) == "does")
        #expect(RewriteOwnFixes.arbitrate(d, scores: [-.infinity, -1]) == nil)
        #expect(RewriteOwnFixes.arbitrate(d, scores: [-1]) == nil)
        // An added word costs a space.
        let added = OwnFixDispute(kind: .sameWordCount, range: 0..<3, typed: "can", fixed: "can", model: "I can",
                                  readings: ["can", "I can"], head: "", tail: " do it")
        #expect(added.slipCost(1) > 0)
    }

    @Test func theTailStopsAtTheSentenceEnd() {
        #expect(RewriteOwnFixes.sentenceTail(" it mean. Then more") == " it mean.")
        #expect(RewriteOwnFixes.sentenceTail(" a b c d e f g h i j") == " a b c d e f g h")
        #expect(RewriteOwnFixes.sentenceTail(" line\nnext") == " line")
    }

    @Test func fixesAfterAPass() {
        let text = "the quietly of it is form here, thnik so"
        let fixes = [fix("quietly", typed: "quialty", in: text)]
        let r = pass(text, fixes: [fixes[0]], revised: "the quality of it is from here, thnik so")
        let after = RewriteOwnFixes.fixesAfter([fixes[0]], edits: r.edits, in: text)
        #expect(after.count == 2)
        for f in after {
            let ns = r.out as NSString
            #expect(ns.substring(with: NSRange(location: f.range.lowerBound, length: f.range.count)) == f.fixed)
        }
        #expect(after.contains { $0.typed == "quialty" && $0.fixed == "quality" })
        #expect(after.contains { $0.typed == "form" && $0.fixed == "from" })
    }

    @Test func untouchedFixesShiftAfterAPass() {
        let text = "I realy like the good one"
        let f = fix("good", typed: "goood", in: text)
        let r = pass(text, fixes: [f], revised: "I really like the good one")
        let after = RewriteOwnFixes.fixesAfter([f], edits: r.edits, in: text)
        let moved = after.first { $0.typed == "goood" }!
        #expect((r.out as NSString).substring(with: NSRange(location: moved.range.lowerBound, length: moved.range.count)) == "good")
    }

    @Test func recordableKeepsTheTypedForm() {
        let e = OwnFixEdit(edit: RewriteEdit(range: 4..<11, original: "quietly", replacement: "quality", kind: .word),
                           typed: "quialty")
        let r = e.recordable(in: "the quietly of it")!
        #expect(r.undo == "quialty")
        #expect(r.edit.original == "quietly")
    }
}
