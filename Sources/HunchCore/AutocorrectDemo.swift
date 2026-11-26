/// The welcome tour's Autocorrect demo, as data: sentences with typical slips, and what each word
/// becomes for a given set of switches. Pure, so the rules are testable without the UI.
public enum AutocorrectDemo {
    /// The kinds of slip the demo shows, one per switch (a misspelling has none: it is always fixed).
    public enum Slip: Sendable, Equatable, CaseIterable {
        case misspelling, capital, apostrophe, confused, shorthand
    }

    /// A word as typed (with its trailing punctuation), the fix, and what kind of slip it is.
    /// `fix == nil`: nothing is wrong with it.
    public struct Word: Sendable, Equatable {
        public let typed: String
        public let fix: String?
        public let slip: Slip?

        public init(_ typed: String, fix: String? = nil, _ slip: Slip? = nil) {
            self.typed = typed
            self.fix = fix
            self.slip = slip
        }
    }

    /// The six autocorrect switches, as the Settings pane has them.
    public struct Switches: Sendable, Equatable {
        public var suggestCorrections: Bool
        public var applyAutomatically: Bool
        public var capitalization: Bool
        public var punctuation: Bool
        public var confusedWords: Bool
        public var allowChatShorthand: Bool

        public init(suggestCorrections: Bool = true, applyAutomatically: Bool = true, capitalization: Bool = true,
                    punctuation: Bool = true, confusedWords: Bool = true, allowChatShorthand: Bool = true) {
            self.suggestCorrections = suggestCorrections
            self.applyAutomatically = applyAutomatically
            self.capitalization = capitalization
            self.punctuation = punctuation
            self.confusedWords = confusedWords
            self.allowChatShorthand = allowChatShorthand
        }
    }

    /// What a word becomes: `shown` is the final text; `changed` says whether it was fixed.
    public struct Resolved: Sendable, Equatable {
        public let typed: String
        public let shown: String
        public var changed: Bool { typed != shown }
    }

    /// Whether this kind of slip is fixed under these switches.
    public static func fixes(_ slip: Slip, _ s: Switches) -> Bool {
        guard s.suggestCorrections else { return false }
        return switch slip {
        case .misspelling: true
        case .capital: s.capitalization
        case .apostrophe: s.punctuation
        case .confused: s.confusedWords
        case .shorthand: !s.allowChatShorthand
        }
    }

    public static func resolve(_ word: Word, _ s: Switches) -> Resolved {
        guard let fix = word.fix, let slip = word.slip, fixes(slip, s) else {
            return Resolved(typed: word.typed, shown: word.typed)
        }
        return Resolved(typed: word.typed, shown: fix)
    }

    public static func resolve(_ sentence: [Word], _ s: Switches) -> [Resolved] {
        sentence.map { resolve($0, s) }
    }

    /// The index of the word whose completion (its space typed, or the sentence's end) makes the fix of
    /// word `index` land. A confused word needs the word after it to show what the sentence calls for;
    /// every other slip is fixed as soon as its own word is finished.
    public static func landingIndex(of index: Int, in sentence: [Word]) -> Int {
        guard sentence[index].slip == .confused, index + 1 < sentence.count else { return index }
        return index + 1
    }

    /// The sentence as the user typed it, and as it reads after the fixes.
    public static func text(_ sentence: [Word], _ s: Switches) -> (before: String, after: String) {
        let resolved = resolve(sentence, s)
        return (resolved.map(\.typed).joined(separator: " "), resolved.map(\.shown).joined(separator: " "))
    }

    /// The looping script: across the three sentences every kind of slip appears.
    public static let script: [[Word]] = [
        [Word("i", fix: "I", .capital), Word("recieved", fix: "received", .misspelling), Word("your"),
         Word("email,"), Word("thx", fix: "thanks", .shorthand)],
        [Word("monday", fix: "Monday", .capital), Word("works,"), Word("but"), Word("we"),
         Word("dont", fix: "don\u{2019}t", .apostrophe), Word("think"), Word("their", fix: "they\u{2019}re", .confused),
         Word("ready"), Word("tomorow", fix: "tomorrow", .misspelling)],
        [Word("can"), Word("u", fix: "you", .shorthand), Word("send"), Word("the"),
         Word("adress,", fix: "address,", .misspelling), Word("the"), Word("office"), Word("is"), Word("over"),
         Word("their.", fix: "there.", .confused)],
    ]
}
