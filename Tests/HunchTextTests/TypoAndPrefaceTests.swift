import Foundation
import HunchCore
import Testing
@testable import HunchText

/// Fake dictionary: words in `valid` are correct; prefixes of valid words are known prefixes.
final class FakeSpell: SpellChecking, @unchecked Sendable {
    let valid: Set<String>
    private let lock = NSLock()
    private(set) var misspellCalls = 0
    init(_ valid: [String]) { self.valid = Set(valid) }
    func isMisspelled(_ word: String, languages: [String]) -> Bool {
        lock.lock(); misspellCalls += 1; lock.unlock()
        return !valid.contains(word.lowercased())
    }
    func isKnownPrefix(_ partial: String, languages: [String]) -> Bool {
        valid.contains { $0.hasPrefix(partial.lowercased()) && $0.count > partial.count }
    }
}

private let dictionary = FakeSpell(["the", "received", "receive", "meeting", "tomorrow", "please", "hello", "world",
                                    "don't", "going", "about", "with", "this", "that", "from", "have"])

private func run(_ raw: String, before: String, known: Set<String> = [], checker: (any SpellChecking)? = dictionary,
                 prefaceTexts: [String] = []) -> PostOutcome {
    DefaultPostProcessor(spellChecker: checker, knownWords: known, prefaceTexts: prefaceTexts)
        .process(raw, meanLogProb: nil,
                 context: PostContext(before: before, after: "", requiredPrefix: "", allowNewlines: false, maxWords: 6))
}

struct StubGuesser: LanguageGuessing {
    let table: [String: (String, Double)]
    let fallback: (String, Double)
    init(_ table: [String: (String, Double)], default fallback: (String, Double)) {
        self.table = table
        self.fallback = fallback
    }
    func guess(_ text: String) -> (language: String, confidence: Double)? {
        let hit = table[text] ?? fallback
        return (hit.0, hit.1)
    }
}

/// Answers "unknown" like a timed-out main-thread hop.
final class UnsureSpell: UncertainSpellChecking, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    var answer: Bool?
    init(answer: Bool?) { self.answer = answer }
    func isMisspelled(_ word: String, languages: [String]) -> Bool { lookupMisspelled(word, languages: languages) ?? false }
    func isKnownPrefix(_ partial: String, languages: [String]) -> Bool { lookupKnownPrefix(partial, languages: languages) ?? true }
    func lookupMisspelled(_ word: String, languages: [String]) -> Bool? {
        lock.lock(); calls += 1; let a = answer; lock.unlock(); return a
    }
    func lookupKnownPrefix(_ partial: String, languages: [String]) -> Bool? { nil }
}

@Suite(.serialized) struct LikelyTypoTests {
    @Test func completedMisspelledWordSuppresses() {
        #expect(run(" the meeting", before: "I recieved") == .suppress(.likelyTypo))
        #expect(run("the meeting", before: "I recieved ") == .suppress(.likelyTypo))
        #expect(run(" tomorrow", before: "see you tomrrow.") == .suppress(.likelyTypo))
        #expect(run(" tomorrow", before: "(recieved)") == .suppress(.likelyTypo))
    }

    @Test func correctWordShows() {
        #expect(run(" the meeting", before: "I received") == .show(" the meeting"))
    }

    @Test func midWordCompletingToTypoSuppresses() {
        // "recie" is not a prefix of any valid word; "recieved" is not valid.
        #expect(run("ved the", before: "I recie") == .suppress(.likelyTypo))
    }

    @Test func midWordWithLegitPrefixShows() {
        // "rece" is a prefix of valid words, so the suggestion shows even though "recex..." is unknown.
        #expect(run("xxed the", before: "I rece") == .show("xxed the"))
    }

    @Test func midWordCompletingToValidWordShows() {
        #expect(run("ived the", before: "I rece") == .show("ived the"))
    }

    @Test func contractionHandled() {
        #expect(run("'t go", before: "I don") == .show("'t go"))
    }

    @Test func properNounsAndAcronymsAreSkipped() {
        #expect(run(" is here", before: "Xiaomi") == .show(" is here"))
        #expect(run(" is here", before: "NASA") == .show(" is here"))
        #expect(run(" is here", before: "I met Zhangwei") == .show(" is here"))
        #expect(run(" is here", before: "the iPhone") == .show(" is here"))
    }

    @Test func codeAndLinkTokensAreSkipped() {
        for before in ["see https://exmple.com", "mail bob@exmple", "ping @vinc", "tag #swiftui", "run foo_bar",
                       "call getData", "open src/utls", "set x=zzq", "version v2beta", "file name.txt", "well-knwn"] {
            #expect(run(" now", before: before) == .show(" now"), "\(before)")
        }
    }

    @Test func shortAndNumericWordsSkipped() {
        #expect(run(" now", before: "go to xq") == .show(" now"))
        #expect(run(" now", before: "room b12") == .show(" now"))
    }

    @Test func chineseAndMixedTextSkipped() {
        #expect(run("很好", before: "今天天气") == .show("很好"))
        #expect(run("很好", before: "我喜欢 recieved 这个") == .show("很好"))  // caret after CJK: last token is CJK
        #expect(run(" 很好", before: "你好 世界") == .show(" 很好"))
    }

    @Test func learnedWordsAreNeverTypos() {
        #expect(run(" is here", before: "talk to zhangwei", known: ["Zhangwei"]) == .show(" is here"))
        #expect(run("ved the", before: "I recie", known: ["recieved"]) == .show("ved the"))
        #expect(run(" is here", before: "talk to zhangwei") == .suppress(.likelyTypo))
    }

    @Test func noCheckerMeansRuleOff() {
        #expect(run(" the meeting", before: "I recieved", checker: nil) == .show(" the meeting"))
    }

    @Test func slangAndAbbreviationsNeverSuppress() {
        for word in ["tbh", "imo", "lol", "btw", "idk", "omg", "pls", "thx", "gonna", "wanna", "kinda", "ok", "yeah", "nah"] {
            #expect(run(" the meeting", before: "I think \(word)") == .show(" the meeting"), Comment(rawValue: word))
        }
    }

    @Test func onlyForeignSentencesDoNotSuppress() {
        // A single word is judged by the spell checker alone, like the system underline: "amigo"
        // for an English-only writer counts; for a writer who lists Spanish it doesn't.
        let guesser = StubGuesser(["amigo": ("es", 0.9), "recieved": ("es", 0.9)], default: ("en", 0.9))
        let bilingual = LanguageSpell(["en": ["the", "meeting", "my", "i"], "es": ["amigo"]])
        func result(_ before: String) -> Bool {
            TypoDetector.shouldSuppress(before: before, suggestion: " the meeting", checker: bilingual,
                                        languages: ["en"], knownWords: [], guesser: guesser)
        }
        #expect(result("my amigo") == true)
        #expect(result("I recieved") == true)
        #expect(TypoDetector.shouldSuppress(before: "my amigo", suggestion: " the meeting", checker: bilingual,
                                            languages: ["en", "es"], knownWords: [], guesser: guesser) == false)
        // Recent text confidently in a language the checker lacks.
        let spanish = StubGuesser([:], default: ("es", 0.95))
        #expect(TypoDetector.shouldSuppress(before: "Hola, me gustaria hablar sobre el proyecto recieved",
                                            suggestion: " the", checker: dictionary, languages: ["en"],
                                            knownWords: [], guesser: spanish) == false)
    }

    @Test func otherSuppressionsStillWin() {
        #expect(run(" bot.", before: "I recieved it. I am a") == .suppress(.aiVoice))
    }

    @Test func cacheAvoidsRepeatedChecks() {
        let fake = FakeSpell(["hello"])
        let cached = CachedSpellChecker(fake, capacity: 8)
        for _ in 0..<5 { _ = cached.isMisspelled("helo", languages: ["en"]) }
        #expect(fake.misspellCalls == 1)
        _ = cached.isMisspelled("helo", languages: ["fr"])
        #expect(fake.misspellCalls == 2)
    }

    @Test func unknownAnswersAreNotCachedAndNeverSuppress() {
        let unsure = UnsureSpell(answer: nil)
        let cached = CachedSpellChecker(unsure, capacity: 8)
        #expect(cached.isMisspelled("helo", languages: ["en"]) == false)
        #expect(cached.isKnownPrefix("hel", languages: ["en"]) == true)
        _ = cached.isMisspelled("helo", languages: ["en"])
        #expect(unsure.calls == 2)  // asked again: the timeout was not memoized
        unsure.answer = true
        #expect(cached.isMisspelled("helo", languages: ["en"]) == true)
    }

    @Test func unknownAnswerIsNotSurelySpelled() {
        // A timed-out lookup must never approve a candidate fix ("ghostype" → "ghosty pe").
        let unsure = UnsureSpell(answer: nil)
        let cached = CachedSpellChecker(unsure, capacity: 8)
        #expect(cached.lookupMisspelled("pe", languages: ["en"]) == nil)
        #expect(cached.isSurelySpelled("pe", languages: ["en"]) == false)
        unsure.answer = false
        #expect(cached.isSurelySpelled("pe", languages: ["en"]) == true)
    }

    @Test func systemCheckerDoesNotDeadlockWhenMainIsBlocked() {
        // The calling thread holds the main thread hostage (as an unmount handler waiting on the
        // executor would): the bounded wait must return instead of hanging.
        let checker = SystemSpellChecker()
        let finished = DispatchSemaphore(value: 0)
        let answer = ResultSlot()
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { release.wait() }  // main is busy until released
        Thread.detachNewThread {
            answer.value = checker.lookupMisspelled("recieved", languages: ["en"])
            finished.signal()
        }
        let ok = finished.wait(timeout: .now() + 5) == .success
        release.signal()
        #expect(ok)
        #expect(answer.value == nil)
    }

    @Test func lruEvictsOldest() {
        var cache = BoundedLRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a"); cache.insert(2, for: "b")
        _ = cache.value(for: "a")
        cache.insert(3, for: "c")
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.count == 2)
    }

    @Test func languageResolutionDropsCJK() {
        #expect(SystemSpellChecker.resolve(["zh-Hans", "ja"], available: ["en_US"]).isEmpty)
        #expect(SystemSpellChecker.resolve(["en", "zh-Hans"], available: ["en_US", "fr"]) == ["en_US"])
    }

    @Test func systemCheckerSmoke() async {
        // Real NSSpellChecker; runs off the main thread, so this also exercises the main-thread hop.
        var system = SystemSpellChecker()
        system.mainWaitTimeout = .seconds(5)
        let checker = CachedSpellChecker(system)
        let result = await Task.detached { (checker.isMisspelled("recieved", languages: ["en"]),
                                           checker.isMisspelled("received", languages: ["en"])) }.value
        #expect(result.0 == true)
        #expect(result.1 == false)
    }
}

@Suite struct PrefaceEchoTests {
    @Test func englishHeaderEchoSuppressed() {
        #expect(run("A personal piece of writing, reproduced exactly as its author", before: "我今天", checker: nil) == .suppress(.metaReply))
        #expect(run("Written by one person in their own words", before: "ok", checker: nil) == .suppress(.metaReply))
    }

    @Test func caseAndPunctuationInsensitive() {
        #expect(run("WRITTEN BY ONE PERSON, in their own words!", before: "你好", checker: nil) == .suppress(.metaReply))
    }

    @Test func chineseTranslationSuppressed() {
        #expect(run("一篇个人写作，完全按照作者键入的原样复制。", before: "我今天", checker: nil) == .suppress(.metaReply))
        #expect(run("作者原样输入的个人文章", before: "我", checker: nil) == .suppress(.metaReply))
    }

    @Test func ordinaryChineseMentioningAuthorShows() {
        #expect(run("作者是一个很好的人", before: "这本书的", checker: nil) == .show("作者是一个很好的人"))
        #expect(run("写作需要耐心", before: "我觉得", checker: nil) == .show("写作需要耐心"))
    }

    @Test func ordinaryEnglishShows() {
        #expect(run(" the author wrote it in one piece", before: "Remember that", checker: nil) == .show(" the author wrote it in one"))
        #expect(run(" exactly as planned", before: "It went", checker: nil) == .show(" exactly as planned"))
    }

    @Test func extraPhrasesFromTheFramerAreHonored() {
        let phrases = ["Quarterly ledger of dragon sightings"]
        #expect(run(" quarterly ledger of dragon", before: "x", checker: nil, prefaceTexts: phrases) == .suppress(.metaReply))
        #expect(run(" quarterly ledger of dragon", before: "x", checker: nil) == .show(" quarterly ledger of dragon"))
    }

    @Test func writerQuotingTheSameWordingIsNotALeak() {
        let before = "The header says: written by one person in their own words and I want to change"
        #expect(run("written by one person in their own words", before: before, checker: nil) == .show("written by one person in their"))
    }
}

final class ResultSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool??
    var value: Bool? {
        get { lock.lock(); defer { lock.unlock() }; return stored ?? nil }
        set { lock.lock(); stored = .some(newValue); lock.unlock() }
    }
}


/// Spell checker with per-language word lists (a word is correct if any requested language has it).
final class LanguageSpell: SpellChecking, @unchecked Sendable {
    let lists: [String: Set<String>]
    init(_ lists: [String: [String]]) { self.lists = lists.mapValues(Set.init) }
    func isMisspelled(_ word: String, languages: [String]) -> Bool {
        !languages.contains { lists[$0]?.contains(word.lowercased()) == true }
    }
    func isKnownPrefix(_ partial: String, languages: [String]) -> Bool { false }
}
