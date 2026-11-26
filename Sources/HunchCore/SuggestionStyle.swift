import Foundation

/// A suggestion style (Personalization → About me → Suggestion styles): strong instructions, and
/// optionally a length, that the style keys put on the suggestion for the rest of a text box.
/// A suggestion shows only a few words, so the wording has to make the style show at once.
public struct SuggestionStyle: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var instructions: String
    /// Nil follows the app's length.
    public var length: LengthPreset?
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, instructions: String,
                length: LengthPreset? = nil, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.length = length
        self.enabled = enabled
    }

    /// The built-in styles, in ring order. Ids are stable: saved edits refer to them.
    public static let builtIns: [SuggestionStyle] = [
        SuggestionStyle(id: "casual", name: "Casual", instructions: """
            Write it casually, the way I text a close friend: relaxed everyday words, contractions, \
            short loose phrasing, slang like gonna, kinda, tbh or lol where it fits. \
            Nothing stiff, polite or businesslike.
            """),
        SuggestionStyle(id: "formal", name: "Formal", instructions: """
            Write it formally, like a careful professional letter: polished and precise vocabulary, \
            complete grammatical sentences, no contractions, no slang, abbreviations or emoji. \
            Courteous and businesslike.
            """),
        SuggestionStyle(id: "concise", name: "Concise", instructions: """
            Be as brief as possible: the fewest, plainest words that make the point. \
            No filler, hedging, pleasantries or extra detail; end the sentence as soon as the point is made.
            """, length: .medium),
        SuggestionStyle(id: "detailed", name: "Detailed", instructions: """
            Be thorough and specific: add concrete details such as names, numbers, examples, reasons or \
            next steps. Prefer a fuller, richer continuation over a short, general one.
            """, length: .ultra),
    ]

    public static func builtIn(id: String) -> SuggestionStyle? { builtIns.first { $0.id == id } }

    /// A built-in whose wording or length differs from what ships.
    public var isEditedBuiltIn: Bool {
        guard let original = Self.builtIn(id: id) else { return false }
        return original.name != name || original.instructions != instructions || original.length != length
    }
}

/// The style keys' ring: the app's own instructions (nil), then every enabled style with
/// instructions, in list order. Down goes forward, Up goes back, both wrap around.
public enum SuggestionStyleRing {
    /// The styles the keys step through.
    public static func usable(_ styles: [SuggestionStyle]) -> [SuggestionStyle] {
        styles.filter { $0.enabled && !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The style after (or before) `current` (nil = the app's own); nil = back to the app's own.
    /// A current style that was turned off or deleted counts as the app's own.
    public static func step(from current: String?, forward: Bool, styles: [SuggestionStyle]) -> String? {
        let ring: [String?] = [nil] + usable(styles).map(\.id)
        let index = ring.firstIndex(of: current) ?? 0
        let next = (index + (forward ? 1 : ring.count - 1)) % ring.count
        return ring[next]
    }

    /// What the style tag shows for `current` (nil = the app's own): its name between the styles
    /// one step back and one step forward. `ownName` names the app's own instructions (the app,
    /// site or category they come from). nil when no style is usable (no ring to show).
    public static func tag(for current: String?, styles: [SuggestionStyle], ownName: String) -> StyleTagNames? {
        guard !usable(styles).isEmpty else { return nil }
        let current = style(current, in: styles)?.id
        func name(_ id: String?) -> String { self.style(id, in: styles)?.name ?? ownName }
        return StyleTagNames(previous: name(step(from: current, forward: false, styles: styles)),
                             current: name(current),
                             next: name(step(from: current, forward: true, styles: styles)))
    }

    /// The usable style with this id.
    public static func style(_ id: String?, in styles: [SuggestionStyle]) -> SuggestionStyle? {
        guard let id else { return nil }
        return usable(styles).first { $0.id == id }
    }
}

/// The style tag's three chips: the style in use, with the ones the previous and next keys go to.
public struct StyleTagNames: Equatable, Sendable {
    /// Which way a style key just moved the ring, so the chips can slide; nil = no move.
    public enum Step: Equatable, Sendable { case forward, back }

    /// The own chip's name when the app's own instructions come from nowhere in particular.
    public static let plain = "Default"
    public var previous: String
    public var current: String
    public var next: String
    public var step: Step?
    public init(previous: String, current: String, next: String, step: Step? = nil) {
        self.previous = previous
        self.current = current
        self.next = next
        self.step = step
    }

    /// The own chip's name: the app or site that has instructions of its own, else the category
    /// they come from ("AI"), else `plain`.
    public static func ownName(source: PolicyKey?, appName: String?) -> String {
        switch source {
        case .app(let bundleID): appName ?? bundleID
        case .domain(let pattern): pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
        case .category(let name): name
        case nil: plain
        }
    }
}
