// Detects suggestions that sound like an AI assistant instead of the person writing. Pure.
import Foundation
import HunchCore

/// Why a completion was judged to be in an assistant's voice.
public enum AIVoiceVerdict: Sendable, Equatable {
    /// The writer is made to claim to be an AI, bot, assistant, or language model.
    case selfIdentification
    /// The completion opens like a chat reply or refusal ("Sure,", "Here's a", "I can't help").
    case chatReply
    /// The completion talks about the task itself ("the user", "your text", "continuation").
    case metaTalk
}

/// Hunch's own heuristic classifier (word lists authored for Hunch).
///
/// The completion is always judged in context: `before + completion` is scanned, and a pattern
/// only counts when the completion introduced it (the key words end after the caret). With
/// token healing the completion may start mid-word ("I am a" + "n AI").
///
/// Rules:
/// 1. Self-identification (always checked): a first-person frame ("I am", "I'm", "as", "being",
///    optionally "just"/"only"), an optional article, then an AI noun phrase ("bot", "AI",
///    "chatbot", "language model", "virtual assistant", "helpful assistant", ...) that ends the
///    clause (end of text, punctuation, or a predicate word like "trained"/"here"/"that").
///    "I am an AI researcher" and "I'm a research assistant" are human and not flagged.
///    Chinese phrasings (我是一个人工智能, 作为一个AI, 我是AI助手, 我是语言模型, ...) likewise.
/// 2. Chat-reply openers: only when the completion starts a new sentence, `before` does not
///    already read like a reply (greeting, thanks, or an opener of its own), and `before` does
///    not discuss AI.
/// 3. Meta talk ("the user", "your text", "continuation", ...): only when `before` neither
///    discusses AI nor already uses the same words.
public struct DefaultAIVoiceClassifier: AIVoiceClassifying {
    public init() {}

    public func isAIVoice(before: String, completion: String) -> Bool {
        verdict(before: before, completion: completion) != nil
    }

    public func verdict(before: String, completion: String) -> AIVoiceVerdict? {
        guard completion.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        // Only the recent tail of `before` matters for these patterns.
        let tail = String(before.suffix(240))
        if Self.englishSelfIdentification(before: tail, completion: completion)
            || Self.englishIntroduction(before: tail, completion: completion)
            || Self.chineseSelfIdentification(before: tail, completion: completion)
            || Self.chineseIntroduction(before: tail, completion: completion) {
            return .selfIdentification
        }
        if Self.discussesAI(before) { return nil }
        if Self.opensLikeReply(before: tail, completion: completion) { return .chatReply }
        if Self.talksAboutTask(before: before, completion: completion) { return .metaTalk }
        return nil
    }

    // MARK: - Word lists (Hunch's own)

    /// Nouns that by themselves name an AI system.
    static let strongNouns: Set<String> = ["ai", "bot", "chatbot", "llm", "robot", "gpt", "chatgpt"]
    /// Two-word nouns naming an AI system.
    static let strongPairs: Set<String> = [
        "language model", "artificial intelligence", "chat bot", "virtual assistant", "digital assistant",
        "ai assistant", "ai model", "ai system", "ai program", "computer program", "neural network",
    ]
    /// Nouns that name an AI only with an AI-ish modifier ("language model", "helpful assistant").
    static let weakNouns: Set<String> = ["assistant", "model", "program", "system", "machine", "agent"]
    /// Modifiers that make a weak noun an AI self-description.
    static let aiModifiers: Set<String> = [
        "helpful", "friendly", "large", "virtual", "digital", "conversational", "artificial", "chat",
        "computer", "language", "automated", "intelligent", "smart", "harmless", "honest", "text", "based",
        "powered", "generative", "advanced", "ai", "neural", "multimodal", "superintelligent",
        "open", "weights", "weight", "source",
    ]
    /// Words that may follow the AI noun and still end the self-description.
    static let predicateWords: Set<String> = [
        "that", "which", "who", "and", "but", "so", "created", "trained", "designed", "developed", "made",
        "built", "programmed", "here", "with", "by", "from", "for", "to", "without", "running", "i",
        "powered", "based", "able", "capable", "can", "cannot", "can't", "don't", "do", "not", "or", "like",
        "named", "called", "known",
    ]
    /// Qualifiers allowed between the frame and the article ("I am just a ...").
    static let qualifiers: Set<String> = [
        "just", "only", "merely", "simply", "really", "actually", "basically", "essentially", "but",
        "still", "nothing", "more", "than", "a", "an", "the", "your", "one", "of", "kind",
    ]

    /// Lowercased phrases that open a chat reply or refusal.
    static let replyOpeners: [String] = [
        "sure", "certainly", "of course", "absolutely!", "absolutely,", "here is", "here's", "here are",
        "great question", "good question", "i'd be happy to", "i would be happy to", "happy to help",
        "i'd be glad to", "as requested", "below is", "i'm sorry", "i am sorry", "i apologize",
        "i can't help", "i cannot help", "i can't assist", "i cannot assist", "i'm unable to",
        "i am unable to", "i'm not able to help", "okay, here", "ok, here", "alright, here",
        "as an ai", "as a language model", "i hope this helps", "let me know if",
        "当然", "好的，", "以下是", "很抱歉", "抱歉，我", "我无法", "我不能帮",
    ]
    /// Words in `before` that make it read like the writer's own reply (so openers are natural).
    static let replyMarkers: [String] = [
        "hi", "hello", "hey", "dear", "thanks", "thank", "thx", "re", "cheers", "sure", "yes", "yeah",
        "ok", "okay", "certainly", "absolutely", "你好", "谢谢", "好的", "收到",
    ]
    /// Phrases about the autocomplete task itself.
    static let metaPhrases: [String] = [
        "the user", "your text", "the text you", "continuation", "autocomplete", "auto-complete",
        "the prompt", "complete the sentence", "completing the", "the following text", "the input text",
        "用户", "你的文本", "续写", "补全",
    ]
    /// Words in `before` that mean the writer is discussing AI or bots.
    static let aiTopicWords: Set<String> = [
        "ai", "bot", "bots", "chatbot", "chatbots", "llm", "llms", "gpt", "chatgpt", "assistant",
        "assistants", "robot", "robots", "openai", "claude", "gemini", "copilot",
    ]
    static let aiTopicPhrases: [String] = [
        "a.i.", "language model", "artificial intelligence", "machine learning", "neural net",
        "人工智能", "机器人", "语言模型", "助手", "大模型",
    ]

    // MARK: - English self-identification

    struct WordSpan {
        var word: String
        var range: Range<Int>  // character offsets in the joined text
    }

    static func words(_ text: [Character]) -> [WordSpan] {
        var spans: [WordSpan] = []
        var start: Int?
        var current = ""
        for (offset, character) in text.enumerated() {
            let isWordChar = (character.isLetter || character.isNumber) && !TextMeasure.isCJK(character)
            let isApostrophe = (character == "'" || character == "\u{2019}") && start != nil
            if isWordChar || isApostrophe {
                if start == nil { start = offset }
                current.append(isApostrophe ? "'" : Character(character.lowercased()))
            } else if let s = start {
                spans.append(WordSpan(word: current, range: s..<offset))
                start = nil
                current = ""
            }
        }
        if let s = start { spans.append(WordSpan(word: current, range: s..<text.count)) }
        // "a.i." reads as one word.
        var merged: [WordSpan] = []
        var i = 0
        while i < spans.count {
            if i + 1 < spans.count, spans[i].word == "a", spans[i + 1].word == "i",
               spans[i + 1].range.lowerBound == spans[i].range.upperBound + 1,
               text[spans[i].range.upperBound] == "." {
                merged.append(WordSpan(word: "ai", range: spans[i].range.lowerBound..<spans[i + 1].range.upperBound))
                i += 2
            } else {
                merged.append(spans[i])
                i += 1
            }
        }
        return merged
    }

    static func englishSelfIdentification(before: String, completion: String) -> Bool {
        let joined = Array(before + completion)
        let boundary = before.count
        let spans = words(joined)
        guard !spans.isEmpty else { return false }

        for start in spans.indices {
            // Frame.
            var index: Int
            var needsArticle = false
            switch spans[start].word {
            case "i" where start + 1 < spans.count && ["am", "was"].contains(spans[start + 1].word):
                index = start + 2
            case "i'm", "im":
                index = start + 1
            case "as", "being":
                index = start + 1
                needsArticle = true
            default:
                continue
            }
            // Qualifiers and article.
            var sawArticle = false
            var skipped = 0
            while index < spans.count, qualifiers.contains(spans[index].word), skipped < 4 {
                if ["a", "an", "the", "your", "one"].contains(spans[index].word) { sawArticle = true }
                index += 1
                skipped += 1
            }
            if needsArticle && !sawArticle { continue }
            if matchAINounPhrase(spans, from: index, joined: joined, boundary: boundary) { return true }
        }
        return false
    }

    /// Matches `(modifier)* noun` starting at `from`, ending the clause, introduced after `boundary`.
    static func matchAINounPhrase(_ spans: [WordSpan], from: Int, joined: [Character], boundary: Int) -> Bool {
        var index = from
        var hasModifier = false
        var strong = false
        var headEnd: Int?
        var headIsWeakAlone = false
        var consumed = 0
        while index < spans.count, consumed < 5 {
            let word = spans[index].word
            let pair = index + 1 < spans.count ? word + " " + spans[index + 1].word : ""
            if strongPairs.contains(pair) {
                strong = true
                headEnd = spans[index + 1].range.upperBound
                index += 2
                consumed += 2
                continue
            }
            if strongNouns.contains(word) {
                strong = true
                headEnd = spans[index].range.upperBound
            } else if weakNouns.contains(word) {
                headIsWeakAlone = !hasModifier && !strong
                headEnd = spans[index].range.upperBound
            } else if aiModifiers.contains(word), headEnd == nil {
                hasModifier = true
            } else {
                break
            }
            index += 1
            consumed += 1
        }
        guard let end = headEnd, end > boundary else { return false }
        // The noun phrase must end the clause.
        var clauseEnds = true
        if index < spans.count {
            let gap = joined[end..<spans[index].range.lowerBound]
            let punctuated = gap.contains { $0.isPunctuation && $0 != "-" && $0 != "'" }
            clauseEnds = punctuated || predicateWords.contains(spans[index].word)
        }
        // A modifier that is not followed by a noun ("I am a large person") does not count.
        let lastConsumedIsNoun = index > from && {
            let last = spans[index - 1].word
            let lastPair = index - 2 >= from ? spans[index - 2].word + " " + last : ""
            return strongNouns.contains(last) || weakNouns.contains(last) || strongPairs.contains(lastPair)
        }()
        guard clauseEnds, lastConsumedIsNoun else { return false }
        if strong || hasModifier { return true }
        // A bare weak noun: only "assistant", and only when it ends the text or a sentence.
        if headIsWeakAlone, spans[index - 1].word == "assistant" {
            if index >= spans.count { return true }
            let gap = joined[end..<spans[index].range.lowerBound]
            return gap.contains { ".!?,;:".contains($0) }
        }
        return false
    }

    // MARK: - Chinese self-identification

    private static let chinesePattern: NSRegularExpression = {
        let frame = "(?:我是|我只是|我就是|我只不过是|作为|身为|我乃)"
        let measure = "(?:一个|一款|一名|一种|一位|个|款|名)?"
        let maker = "(?:由.{1,20}?(?:开发|训练|创建|打造|研发|设计)的)?"
        let modifier = "(?:大型|基于|智能|虚拟|通用|友好的|有用的)?"
        let noun = "(开放权重(?:的)?(?:大)?(?:语言)?模型|开源(?:大)?语言模型|开放式?权重模型|人工智能语言模型|人工智能助手|人工智能模型|人工智能|AI语言模型|AI助手|AI模型|AI|A\\.I\\.|"
            + "大语言模型|大型语言模型|语言模型|聊天机器人|机器人|智能助手|虚拟助手|助手)"
        let end = "(?=$|[\\s，。！？,.!?、；;：:…）)~]|由|可以|能够|能|无法|不能|没有|并|而|，)"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: frame + measure + maker + modifier + noun + end,
                                        options: [.caseInsensitive])
    }()

    static func chineseSelfIdentification(before: String, completion: String) -> Bool {
        // Patterns are simplified; the conversion is one-to-one per character, so offsets hold.
        let before = HanScript.simplified(before), completion = HanScript.simplified(completion)
        let joined = before + completion
        let boundary = (before as NSString).length
        let ns = joined as NSString
        for match in chinesePattern.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
            let noun = match.range(at: 1)
            if noun.location != NSNotFound, noun.location + noun.length > boundary { return true }
        }
        return false
    }

    // MARK: - Introductions that name the model or its maker

    private static let aiNames = "gemma|gemini|chatgpt|llama|qwen|deepseek|bard|copilot|mistral"
    private static let aiMakers = "google deepmind|deepmind|openai|anthropic|meta ai|alibaba cloud|mistral ai|deepseek"
    private static let modelNoun = "(?:language model|llm|ai model|ai assistant|chatbot|virtual assistant|"
        + "(?:open[- ]?weights?|open[- ]source) (?:large )?(?:language )?model|large language model)"
    private static let clauseEnd = "(?=\\s*$|\\s*[,.;:!?(]|\\s+(?:trained|developed|created|built|made|designed|by|from|that|which|here)\\b)"

    private static let englishIntroPatterns: [NSRegularExpression] = [
        // "I'm Gemma, an open weights model", "I am Sam, a large language model".
        "\\b(?:i'm|i am|im)\\s+[a-z][a-z-]*,?\\s+(?:an?|the|your)\\s+(?:[a-z-]+\\s+){0,4}?" + modelNoun + clauseEnd,
        // "I'm Gemma, developed by Google", "my name is Gemini, trained by Google".
        "\\b(?:i'm|i am|im|my name is|this is)\\s+(?:" + aiNames + ")\\s*,?\\s+(?:an?\\s+(?:[a-z-]+\\s+){0,4}?"
            + "(?:model|assistant|ai|llm|chatbot|bot)\\b|(?:developed|trained|created|built|made) by\\b)",
        // "I was developed by Google", "I'm trained by OpenAI".
        "\\b(?:i was|i am|i'm|i have been|i've been)\\s+(?:developed|trained|created|built|made) by\\s+(?:"
            + aiMakers + ")\\b",
        "\\b(?:i was|i am|i'm|i have been|i've been)\\s+developed by google\\b",
    ].map { try! NSRegularExpression(pattern: $0, options: []) }  // swiftlint:disable:this force_try

    static func englishIntroduction(before: String, completion: String) -> Bool {
        func normalized(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        }
        let head = normalized(before)
        let joined = head + normalized(completion)
        let boundary = (head as NSString).length
        let range = NSRange(location: 0, length: (joined as NSString).length)
        for pattern in englishIntroPatterns {
            for match in pattern.matches(in: joined, range: range) where match.range.location + match.range.length > boundary {
                return true
            }
        }
        return false
    }

    private static let chineseIntroPattern: NSRegularExpression = {
        let names = "(?:Gemma|Gemini|ChatGPT|Llama|Qwen|DeepSeek|通义千问|文心一言|Kimi)"
        let maker = "(?:由.{1,20}?(?:开发|训练|创建|打造|研发|设计)的)?"
        let noun = "(?:开放权重|开源|大型?语言|语言|人工智能|AI)?(?:模型|助手)"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "(?:我是|我叫)\\s*" + names + "[，,]\\s*(?:是)?(?:一个|一款|一种)?" + maker + noun,
                                        options: [.caseInsensitive])
    }()

    static func chineseIntroduction(before: String, completion: String) -> Bool {
        let before = HanScript.simplified(before), completion = HanScript.simplified(completion)
        let joined = before + completion
        let boundary = (before as NSString).length
        for match in chineseIntroPattern.matches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length))
        where match.range.location + match.range.length > boundary {
            return true
        }
        return false
    }

    // MARK: - Context checks

    static func discussesAI(_ before: String) -> Bool {
        let lower = before.lowercased()
        if aiTopicPhrases.contains(where: { lower.contains($0) }) { return true }
        // Word-level check; CJK characters are word separators, so "作为AI" still yields "ai".
        return words(Array(before)).contains { aiTopicWords.contains($0.word) }
    }

    static func readsLikeReply(_ before: String) -> Bool {
        let tokens = TextMeasure.normalizedWords(before)
        let lower = before.lowercased()
        if replyMarkers.contains(where: { marker in
            marker.unicodeScalars.contains(where: TextMeasure.isCJK) ? lower.contains(marker) : tokens.contains(marker)
        }) { return true }
        let trimmed = lower.drop { $0.isWhitespace }
        return replyOpeners.contains { trimmed.hasPrefix($0) }
    }

    static let sentenceTerminators: Set<Character> = [".", "!", "?", ":", "。", "！", "？", "：", "\n"]

    static func opensLikeReply(before: String, completion: String) -> Bool {
        if readsLikeReply(before) { return false }
        // The current sentence: the part of `before` after its last terminator, plus the completion.
        let sentenceStart = before.lastIndex(where: { sentenceTerminators.contains($0) })
            .map { before.index(after: $0) } ?? before.startIndex
        let lead = String(before[sentenceStart...])
        // The completion must start the sentence, or continue a single started word ("I" + "'m sorry").
        let leadWords = TextMeasure.normalizedWords(lead)
        guard leadWords.count <= 1 else { return false }
        let leadTrimmed = lead.drop { $0.isWhitespace }
        let sentence = (leadTrimmed + completion.drop(while: { leadTrimmed.isEmpty && $0.isWhitespace }))
            .lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let leadLength = leadTrimmed.count
        for opener in replyOpeners where sentence.hasPrefix(opener) && opener.count > leadLength {
            // Word-bounded end ("sure" must not match "surely").
            let after = sentence.dropFirst(opener.count).first
            if let after, after.isLetter, !opener.unicodeScalars.contains(where: TextMeasure.isCJK) { continue }
            return true
        }
        return false
    }

    static func talksAboutTask(before: String, completion: String) -> Bool {
        taskTalkStart(before: before, completion: completion) != nil
    }

    /// Where the first task-talk phrase starts in `completion`, moved back to the start of the word
    /// it begins in. Nil when the completion has none (rule 3 alone, without its `discussesAI` guard).
    public static func taskTalkStart(before: String, completion: String) -> String.Index? {
        let lowerBefore = before.lowercased()
        var first: String.Index?
        for phrase in metaPhrases {
            let key = phrase.split(separator: " ").last.map(String.init) ?? phrase
            guard !lowerBefore.contains(key),
                  let range = completion.range(of: phrase, options: .caseInsensitive) else { continue }
            if first.map({ range.lowerBound < $0 }) ?? true { first = range.lowerBound }
        }
        guard var start = first else { return nil }
        func isLatinWordChar(_ c: Character) -> Bool { (c.isLetter || c.isNumber) && !TextMeasure.isCJK(c) }
        while start > completion.startIndex, isLatinWordChar(completion[start]),
              isLatinWordChar(completion[completion.index(before: start)]) {
            start = completion.index(before: start)
        }
        return start
    }
}
