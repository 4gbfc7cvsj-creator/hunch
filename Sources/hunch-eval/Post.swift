// The post-processor the eval engines use: identical to the app's (ModelController), with an A/B switch for the typo check.
import Foundation
import HunchCore
import HunchPrompt
import HunchText

/// Mirrors `ModelController.loadModel`: system spell checker (cached), the writer's preferred languages,
/// and the document framer's header phrases for the preface-echo check. `typoCheck: false` drops only the
/// spell checker.
func makeEvalPostProcessor(typoCheck: Bool, knownWords: Set<String> = []) -> DefaultPostProcessor {
    DefaultPostProcessor(spellChecker: typoCheck ? SystemSpellChecker.cached() : nil,
                         spellLanguages: Locale.preferredLanguages,
                         knownWords: knownWords,
                         prefaceTexts: DocumentFramer.prefacePhrases)
}

/// Never flags anything; isolates the preface check from the AI-voice rules in tests.
struct NeverAIVoice: AIVoiceClassifying {
    func isAIVoice(before: String, completion: String) -> Bool { false }
}

/// Phrases of `DocumentFramer.prefacePhrases` that `PrefaceEcho`'s built-in list (internal to HunchText) does
/// NOT already catch when no extra phrases are passed. Empty = the two lists are in step.
/// (HunchText keeps its own copy because it cannot import HunchPrompt; the built-ins are not visible from here,
/// so this checks behavior: every framer header must be suppressed as a preface echo without help.)
func prefaceDrift() -> [String] {
    let processor = DefaultPostProcessor(classifier: NeverAIVoice(), prefaceTexts: [])
    let context = PostContext(before: "", after: "", requiredPrefix: "", allowNewlines: false, maxWords: 50)
    return DocumentFramer.prefacePhrases.filter { phrase in
        // The detector only considers suggestions of 4+ words, so shorter labels cannot be covered by built-ins.
        phrase.split(whereSeparator: \.isWhitespace).count >= 4 &&
        processor.process(phrase, meanLogProb: nil, context: context) != .suppress(.metaReply)
    }
}

/// True when the typed word is Han text written in the traditional script (no simplified-only characters).
func isTraditionalText(_ text: String) -> Bool? {
    guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
    return !HanScript.usesSimplified(text)
}
