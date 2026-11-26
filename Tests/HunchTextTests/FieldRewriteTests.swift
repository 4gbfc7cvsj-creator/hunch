import Foundation
import Testing
@testable import HunchText

/// Whole-field rewrite: which text a pass sends, and which of the model's changes may go in.
struct FieldRewriteTests {
    private func run(_ typed: String, _ revised: String, options: RewriteOptions = .init(), finished: Bool = true,
                     locked: [Range<Int>] = []) -> (String, FieldRewrite.Result) {
        let target = RewriteTarget.find(before: typed, finished: finished)!
        let result = FieldRewrite.edits(target: target, revised: revised, options: options, locked: locked)
        return (FieldRewrite.apply(result.edits, to: typed), result)
    }

    @Test func fixesSpellingRealWordsAndGrammar() {
        let (out, r) = run("i realy think he go form here", "i really think he goes from here")
        #expect(out == "i really think he goes from here")
        #expect(r.edits.map(\.kind) == [.word, .word, .word])
    }

    @Test func addsAndDropsShortWords() {
        #expect(run("I going to the the store", "I am going to the store").0 == "I am going to the store")
        #expect(run("send it me tomorrow", "send it to me tomorrow").0 == "send it to me tomorrow")
    }

    @Test func contractionAddsAWord() {
        var chat = RewriteOptions()
        chat.fixesPunctuation = false
        chat.fixesCapitals = false
        #expect(run("I going to the store", "I'm going to the store", options: chat).0 == "I going to the store")
        chat.fixesPunctuation = true
        #expect(run("I going to the store", "I'm going to the store", options: chat).0 == "I'm going to the store")
    }

    @Test func irregularVerbsAndNoAddedFullStop() {
        #expect(run("did you saw the email", "did you see the email").0 == "did you see the email")
        #expect(run("See you then, Alex", "See you then, Alex.").0 == "See you then, Alex")
    }

    @Test func addedAndDroppedWordsJoinANeighbour() {
        let typed = "send me the link the doc"
        let (_, r) = run(typed, "send me the link to the doc")
        let rec = r.edits[0].recordable(in: typed)!
        #expect(rec.original == "link " && rec.replacement == "link to ")
        let typed2 = "the the doc"
        let (_, r2) = run(typed2, "the doc")
        let rec2 = r2.edits[0].recordable(in: typed2)!
        #expect(FieldRewrite.apply([rec2], to: typed2) == "the doc")
        #expect(!rec2.original.isEmpty && !rec2.replacement.isEmpty)
    }

    @Test func keptWordsStay() {
        var o = RewriteOptions()
        o.keptWords = ["kubctl"]
        #expect(run("run kubctl and teh rest", "run kubectl and the rest", options: o).0 == "run kubctl and the rest")
    }

    @Test func joinsAndSplits() {
        #expect(run("if we canfix it", "if we can fix it").0 == "if we can fix it")
        #expect(run("just a s one more", "just as one more").0 == "just as one more")
    }

    @Test func rewordingIsThrownOut() {
        let (out, r) = run("the meeting was nice", "the meeting was great")
        #expect(out == "the meeting was nice")
        #expect(r.rejected.first?.reason == .reworded)
        // A whole new sentence: nothing goes in, even the fix in it.
        let (out2, _) = run("we shoud talk about the plan", "let us discuss the plan soon, we should")
        #expect(out2 == "we shoud talk about the plan")
    }

    @Test func tooManyAddedWordsInASentence() {
        let (out, r) = run("we go store after work today", "we will go to the store after work today")
        #expect(out == "we go store after work today")
        #expect(r.rejected.contains { $0.reason == .tooManyWords })
    }

    @Test func keepsVoiceSwitches() {
        var chat = RewriteOptions()
        chat.fixesCapitals = false
        chat.fixesPunctuation = false
        chat.leavesShorthand = true
        let (out, _) = run("i dont think so tbh, im tired", "I don't think so, to be honest, I'm tired", options: chat)
        #expect(out == "i dont think so tbh, im tired")
        let (fixed, _) = run("i dont thnik so", "I don't think so", options: chat)
        #expect(fixed == "i dont think so")
    }

    @Test func neverTouchesProtectedOrLockedWords() {
        #expect(run("see exmaple.com/docs and teh rest", "see example.com/docs and the rest").0
            == "see exmaple.com/docs and the rest")
        #expect(run("call `getUsr` for teh name", "call `getUser` for the name").0 == "call `getUsr` for the name")
        let typed = "the recieve is teh word"
        #expect(run(typed, "the receive is the word", locked: [4..<11]).0 == "the recieve is the word")
    }

    @Test func unfinishedWordIsHeld() {
        let target = RewriteTarget.find(before: "i thnik it is becau")!
        #expect(target.heldTail == 5)
        let r = FieldRewrite.edits(target: target, revised: "i think it is because")
        #expect(FieldRewrite.apply(r.edits, to: "i thnik it is becau") == "i think it is becau")
    }

    @Test func targetSkipsCheckedSentencesAndOtherParagraphs() {
        let before = "Dear Sam,\nThe frist part is done. And teh second one"
        let checked = "Dear Sam,\nThe first part is done. And"
        let t = RewriteTarget.find(before: before, checked: checked, finished: true)!
        // The first sentence differs from what was checked (the user undid the fix): sent again.
        #expect(t.text == "The frist part is done. And teh second one")
        let t2 = RewriteTarget.find(before: before, checked: "Dear Sam,\nThe frist part is done. A", finished: true)!
        #expect(t2.text == "And teh second one")
        #expect(t2.before == "Dear Sam,\nThe frist part is done. ")
    }

    @Test func skipsChineseText() {
        #expect(RewriteTarget.find(before: "我們明天開會 ok", finished: true) == nil)
    }

    @Test func editsStillApplyWhenTypingWentOn() {
        let typed = "i thnik so. "
        let (_, r) = run(typed, "i think so.")
        #expect(FieldRewrite.stillApplicable(r.edits, original: typed, fresh: typed + "and more").count == 1)
        // The user went back into the word: the fix no longer applies.
        #expect(FieldRewrite.stillApplicable(r.edits, original: typed, fresh: "i thn").isEmpty)
    }

    @Test func modelNotesAreNotText() {
        #expect(FieldRewrite.cleanOutput("Corrected: i think so", target: "i thnik so") == "i think so")
        #expect(FieldRewrite.cleanOutput("", target: "i thnik so") == nil)
        #expect(FieldRewrite.cleanOutput("Here is the corrected version of your message with all fixes", target: "hi") == nil)
    }

    // MARK: Style switches never cost a spelling fix

    private var chat: RewriteOptions {
        var o = RewriteOptions()
        o.fixesCapitals = false
        o.fixesPunctuation = false
        o.leavesShorthand = true
        return o
    }

    @Test func capitalsOffKeepsTheFixInTypedCasing() {
        var o = RewriteOptions()
        o.fixesCapitals = false
        #expect(run("teh cat sat down", "The cat sat down", options: o).0 == "the cat sat down")
        #expect(run("my iphnoe died again", "my iPhone died again", options: o).0 == "my iphone died again")
        #expect(run("Teh plan is fine", "The plan is fine", options: o).0 == "The plan is fine")
    }

    @Test func punctuationOffKeepsTheFixAndTheTypedPunctuation() {
        var o = RewriteOptions()
        o.fixesPunctuation = false
        #expect(run("I stayed becuase, she asked", "I stayed because she asked", options: o).0 == "I stayed because, she asked")
        #expect(run("I think teh end.", "I think the end", options: o).0 == "I think the end.")
        // An apostrophe the writer leaves out stays out, the spelling fix goes in.
        #expect(run("i dnot know yet", "i don't know yet", options: o).0 == "i dont know yet")
        // A contraction needs an apostrophe: not added with punctuation off.
        #expect(run("I going home now", "I'm going home now", options: o).0 == "I going home now")
    }

    @Test func droppedDoubleKeepsTheFullStop() {
        var o = RewriteOptions()
        o.fixesPunctuation = false
        #expect(run("we saw the the.", "we saw the.", options: o).0 == "we saw the.")
        #expect(run("we saw the the.", "we saw the.").0 == "we saw the.")
    }

    @Test func shorthandKeptButTyposFixed() {
        #expect(run("idk waht to do", "I don't know what to do", options: chat).0 == "idk what to do")
        #expect(run("omw, see u at teh park", "On my way, see you at the park", options: chat).0 == "omw, see u at the park")
    }

    @Test func addedWordFollowsTheWritersCasing() {
        #expect(run("i think it fine", "I think it's fine", options: chat).0 == "i think it fine")
        var o = chat
        o.fixesPunctuation = true
        #expect(run("i think it fine", "I think it's fine", options: o).0 == "i think it's fine")
        #expect(run("send it me later", "Send it to me later", options: chat).0 == "send it to me later")
    }

    @Test func sentenceStartFixGetsItsCapital() {
        let (out, r) = run("teh cat is here. teh dog too", "the cat is here. the dog too")
        #expect(out == "The cat is here. The dog too")
        // Undo gives back exactly what was typed.
        #expect(r.edits.allSatisfy { $0.original == "teh" })
        #expect(run("teh cat is here. teh dog too", "the cat is here. the dog too", options: chat).0
            == "the cat is here. the dog too")
    }

    @Test func wordAddedInsideAStretchGoesInPlace() {
        #expect(run("tell them that there invited to dinner", "tell them that they are invited to dinner").0
            == "tell them that they are invited to dinner")
    }

    // MARK: The guard with a spell checker

    /// A small dictionary standing in for the spell checker.
    private var checked: RewriteOptions {
        let words: Set<String> = [
            "the", "my", "day", "all", "at", "is", "a", "to", "see", "as", "long", "it", "and", "pizza", "beer", "you",
            "owe", "i", "we", "make", "meeting", "on", "friday", "refund", "for", "recent", "purchase", "your", "first",
            "monday", "capitalization", "typing", "really", "fast", "well", "known", "feature", "alex", "morgan",
            "met", "today", "cat", "cart", "sat", "down", "into", "in", "looking", "now", "word", "wrote", "twice",
            "thanks", "share", "latest", "numbers", "before", "can", "this", "not", "bad", "actually", "completes",
            "minutes", "twenty", "about", "words", "like", "how", "comes", "out", "sentence", "lol",
            "lot", "set", "shorthand", "chat", "leave", "rename", "fix", "fixed", "things", "are", "testing", "if", "ok", "still", "there", "some", "note", "else",
        ]
        var o = RewriteOptions()
        o.isKnownWord = { words.contains($0.lowercased()) }
        return o
    }

    @Test func notARealWordGetsAKeyboardAwareBudget() {
        let o = checked
        #expect(run("I won't make fh meeting on Friday", "I won't make the meeting on Friday", options: o).0
            == "I won't make the meeting on Friday")
        #expect(run("a refund for kjy recent purchase", "a refund for my recent purchase", options: o).0
            == "a refund for my recent purchase")
        #expect(run("your first dha is Monday", "your first day is Monday", options: o).0 == "your first day is Monday")
        #expect(run("long words like capitlaizoain", "long words like capitalization", options: o).0
            == "long words like capitalization")
        #expect(run("just tyu[piogn really fast", "just typing really fast", options: o).0 == "just typing really fast")
        // Without the spell checker: plain edit distance, as before.
        #expect(run("I won't make fh meeting on Friday", "I won't make the meeting on Friday").0
            == "I won't make fh meeting on Friday")
    }

    @Test func realWordsAndFarGuessesKeepTheStrictRules() {
        let o = checked
        // A real word typed: only the strict rules ("cat" → "cart" is one letter, "sat" → "day" is not).
        #expect(run("the cat sat down", "the cat day down", options: o).0 == "the cat sat down")
        // A long garble the model guessed as a much shorter word stays.
        #expect(run("it comapzliatioses all", "it completes all", options: o).0 == "it comapzliatioses all")
        // Chat shorthand is never a slip.
        #expect(run("lmk today", "let today", options: o).0 == "lmk today")
    }

    @Test func longStretchOfSlipsGoesInWordByWord() {
        let typed = "Thanks, can yuo shrae teh ltest nu,bers befoore tomorow"
        let revised = "Thanks, can you share the latest numbers before tomorrow"
        #expect(run(typed, revised).0 == revised)
        // A long stretch the model reworded stays as typed.
        let typed2 = "we shoud tlak abotu it a bit more latr on today"
        #expect(run(typed2, "let us discuss this topic in more depth some other time").0 == typed2)
    }

    @Test func respacingWithinTheSlipBudget() {
        let o = checked
        #expect(run("fast toose e how it comes out", "fast to see how it comes out", options: o).0
            == "fast to see how it comes out")
        #expect(run("not bad atla la", "not bad at all", options: o).0 == "not bad at all")
        // The typed "as" lines up with the model's first "as": the stretches are joined across it.
        #expect(run("it is ok asling as it works", "it is ok as long as it works", options: o).0
            == "it is ok as long as it works")
        #expect(run("I owe you apizza adn a beer", "I owe you a pizza and a beer", options: o).0
            == "I owe you a pizza and a beer")
        #expect(run("I owe you apizza adn a beer", "I owe you a pizza and a beer").0 == "I owe you a pizza and a beer")
        // A real word in the stretch changes by one slip at most ("teh cat" → "the cart" is two).
        #expect(!FieldRewrite.respaced(["teh", "cat"], ["the", "cart"], options: o))
        #expect(FieldRewrite.respaced(["toose", "e"], ["to", "see"], options: o))
        // As many words, split in the same places: word-for-word fixes, not a respacing.
        #expect(!FieldRewrite.respaced(["twenty", "minutse"], ["twenty", "minutes"], options: o))
        // No sentence end the writer did not type.
        #expect(!FieldRewrite.respaced(["toose", "e"], ["to", "see."], options: o))
        #expect(FieldRewrite.respaced(["else", "."], ["else?"], options: o))
    }

    @Test func realWordsTypedApartAreNotJoined() {
        let o = checked
        #expect(run("it is a well known feature", "it is a well-known feature", options: o).0 == "it is a well known feature")
        #expect(run("met alex morgan today", "met AlexMorgan today", options: o).0 == "met alex morgan today")
        #expect(run("met alex morgan today", "met AlexMorgan today").0 == "met alex morgan today")
        // Function words typed apart may run together; a piece that is no word may too.
        #expect(run("looking in to it now", "looking into it now", options: o).0 == "looking into it now")
        #expect(run("things are fix ed now", "things are fixed now", options: o).0 == "things are fixed now")
        #expect(run("just a s one more", "just as one more", options: o).0 == "just as one more")
    }

    @Test func aWordQuotedOnItsOwnStaysAsTyped() {
        let o = checked
        #expect(run("he wrote \"recieve\" twice, teh word", "he wrote \"receive\" twice, the word", options: o).0
            == "he wrote \"recieve\" twice, the word")
        #expect(run("he wrote 'recieve' twice", "he wrote 'receive' twice", options: o).0 == "he wrote 'recieve' twice")
        // A longer quote (a setting's name) is ordinary text.
        #expect(run("rename \"leave chat shortand\" now", "rename \"leave chat shorthand\" now", options: o).0
            == "rename \"leave chat shorthand\" now")
        #expect(FieldRewrite.quotedTokens(FieldRewrite.Token.split("say \"hi\" and \"two words\" ok")) == [1])
    }

    @Test func stretchesAreNotJoinedAcrossProtectedWords() {
        // The protected identifier stays, and the fix after it still goes in.
        #expect(run("what getUsr i siet then", "what i set then", options: checked).0 == "what getUsr i set then")
    }

    @Test func numbersStuckToWordsStay() {
        let o = checked
        #expect(run("see the first word2. ", "see the first word.", options: o).0 == "see the first word2. ")
        #expect(run("see teh first word2. ", "see the first word.", options: o).0 == "see the first word2. ")
        #expect(!FieldRewrite.respaced(["so:1."], ["so:", "a."], options: o))
    }

    @Test func realWordsInARewordedStretchStay() {
        let o = checked
        // The model dropped "in the box and" and lined "into" up with "its": not a slip.
        let tail = ", then we all went home after a long and quiet day at the lake"
        #expect(run("we looked in the box and  into it" + tail, "we looked its" + tail, options: o).0
            == "we looked in the box and  into it" + tail)
        // A word that is no real word in the same stretch is still fixed.
        #expect(run("we looked in the box and  wrod" + tail, "we looked word" + tail, options: o).0
            == "we looked in the box and  word" + tail)
    }

    @Test func aWordAndItsEndingTypedApartAreJoinedOrLeft() {
        var o = checked
        let words: Set<String> = ["this", "is", "me", "test", "ing", "testing", "the"]
        o.isKnownWord = { words.contains($0.lowercased()) }
        #expect(run("this is me test ing the", "this is me testing the", options: o).0 == "this is me testing the")
        #expect(FieldRewrite.swallowsNeighbour(["test", "ing"], 0, "testing"))
        #expect(!FieldRewrite.swallowsNeighbour(["test", "it"], 0, "tests"))
    }

    @Test func aWordQuotedOnceStaysEverywhere() {
        let o = checked
        let typed = "he wrote \"recieve\". then typing recieve and teh rest"
        #expect(run(typed, "he wrote \"receive\". then typing receive and the rest", options: o).0
            == "he wrote \"recieve\". then typing recieve and the rest")
        // Quoted in text an earlier pass checked.
        let before = "he wrote \"recieve\". "
        let target = RewriteTarget(text: "typing recieve and teh rest", start: before.utf16.count, before: before, heldTail: 0)
        let r = FieldRewrite.edits(target: target, revised: "typing receive and the rest", options: o)
        #expect(r.edits.map(\.replacement) == ["the"])
    }

    @Test func respacingKeepsTheWritersMarks() {
        var o = checked
        o.fixesPunctuation = false
        o.fixesCapitals = false
        #expect(run("there are some words:i can see", "There are some words: I can see", options: o).0
            == "there are some words: i can see")
        // A quote mark moved onto the next word is not a respacing: the quote stays.
        #expect(!FieldRewrite.respaced(["like", "\""], ["like"], options: checked))
    }

    @Test func aNonWordNeverBecomesAnotherNonWord() {
        #expect(run("it bxyz is not bad", "it byz is not bad", options: checked).0 == "it bxyz is not bad")
        // Without the spell checker the old rule stands.
        #expect(run("it bxyz is not bad", "it byz is not bad").0 == "it byz is not bad")
    }

    @Test func optionsCompareWithoutTheChecker() {
        #expect(checked == RewriteOptions())
    }

    @Test func contractionWithTheTypedApostrophe() {
        var o = RewriteOptions()
        o.fixesPunctuation = false
        #expect(run("I', out sick today", "I'm out sick today", options: o).0 == "I'm out sick today")
        #expect(run("it' been a busy week", "it's been a busy week", options: o).0 == "it's been a busy week")
    }
}
