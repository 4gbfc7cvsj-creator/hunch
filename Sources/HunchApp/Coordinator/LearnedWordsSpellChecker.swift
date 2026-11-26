import HunchCore
import HunchHistory
import HunchText
import os

/// Spell checker that treats the user's learned vocabulary as correctly spelled, so a name or term
/// they write often never counts as a typo. The learned set is refreshed by `LearningController`.
final class LearnedWordsSpellChecker: UncertainSpellChecking {
    private let base: any SpellChecking
    private let words = OSAllocatedUnfairLock(initialState: Set<String>())

    init(base: any SpellChecking) { self.base = base }

    private let wordPlaces = OSAllocatedUnfairLock(initialState: LearnedWordPlaces.empty)

    /// The learned words (all count as spelled right) and the apps each was used in.
    func setLearnedWords(_ places: LearnedWordPlaces) {
        words.withLock { $0 = places.words }
        wordPlaces.withLock { $0 = places }
    }

    var learnedWords: Set<String> { words.withLock { $0 } }

    /// The learned words used in this app or its category (`LearnedWordPlaces.here`): offered as
    /// fixes first. Nil without an app key.
    func learnedWords(here appKey: String?, categories: AppCategories) -> Set<String>? {
        wordPlaces.withLock { $0 }.here(appKey: appKey, categories: categories)
    }

    private let profile = OSAllocatedUnfairLock<SlipProfile?>(initialState: nil)

    /// Words the user often mistypes (`HistoryService.troubleWords`), for autocorrect.
    func setTroubleWords(_ trouble: [TroubleWord]) {
        let p = trouble.isEmpty ? nil : SlipProfile(words: Dictionary(trouble.map { ($0.word, $0.knownSlips) },
                                                                    uniquingKeysWith: { $0.union($1) }))
        profile.withLock { $0 = p }
    }

    var slipProfile: SlipProfile? { profile.withLock { $0 } }

    func isMisspelled(_ word: String, languages: [String]) -> Bool {
        if words.withLock({ $0.contains(word.lowercased()) }) { return false }
        return base.isMisspelled(word, languages: languages)
    }

    func lookupMisspelled(_ word: String, languages: [String]) -> Bool? {
        if words.withLock({ $0.contains(word.lowercased()) }) { return false }
        if let uncertain = base as? any UncertainSpellChecking { return uncertain.lookupMisspelled(word, languages: languages) }
        return base.isMisspelled(word, languages: languages)
    }

    func lookupKnownPrefix(_ partial: String, languages: [String]) -> Bool? {
        isKnownPrefix(partial, languages: languages)
    }

    func isKnownPrefix(_ partial: String, languages: [String]) -> Bool {
        let lower = partial.lowercased()
        if words.withLock({ $0.contains { $0.hasPrefix(lower) } }) { return true }
        return base.isKnownPrefix(partial, languages: languages)
    }
}
