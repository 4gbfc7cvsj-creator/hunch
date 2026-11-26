import Foundation

/// How far autocorrect goes: which kinds of fix it tries, and how sure it must be. A global setting
/// (Settings → Autocorrect) that apps, sites and categories can override.
public enum AutocorrectStrength: String, Codable, Sendable, CaseIterable, Equatable {
    /// Only fixes the system spell checker is sure of, one obvious fix per word ("teh" → "the").
    /// Never runs the language model: no model choices, no scoring, no load or prewarm.
    case light
    /// Today's behaviour (the default): the model chooses among likely fixes, scores real-word slips
    /// and confused words.
    case balanced
    /// Balanced, plus the whole-field rewrite: at pauses the model rereads the paragraph being typed and
    /// fixes the words it thinks are wrong (missing or doubled words and grammar slips too), keeping the
    /// writer's wording.
    case strong

    /// The strength that can take effect: Strong's reread changes text by itself, so without Apply
    /// Corrections Automatically Strong acts (and is shown) as Balanced.
    public static func allowed(_ strength: AutocorrectStrength, automatic: Bool) -> AutocorrectStrength {
        !automatic && strength == .strong ? .balanced : strength
    }

    /// The highest slider stop that may be picked.
    public static func maxIndex(automatic: Bool) -> Int {
        allCases.firstIndex(of: automatic ? .strong : .balanced) ?? allCases.count - 1
    }

    public var title: String {
        switch self {
        case .light: "Light"
        case .balanced: "Balanced"
        case .strong: "Strong"
        }
    }

    public var summary: String {
        switch self {
        case .light: "Only obvious spelling fixes the system spell checker is sure of. Never uses the model."
        case .balanced: "Spelling fixes, with the model choosing between likely words and catching slips that are real words."
        case .strong: "Everything in Balanced. When you pause, the model also rereads what you're writing and fixes missing words, doubled words and grammar slips, keeping your wording."
        }
    }
}

/// What autocorrect does right now, after the chosen strength and the power mode are combined.
public struct CorrectionMode: Sendable, Equatable {
    /// The strength in effect (efficiency power mode counts as `light`).
    public var strength: AutocorrectStrength
    /// Whether any autocorrect work may use the language model (scoring, choices, load, prewarm).
    public var usesModel: Bool { strength != .light }
    /// Whether the whole-field rewrite runs at pauses (Strong in power mode only).
    public var rewritesAtPauses: Bool { strength == .strong }

    public init(strength: AutocorrectStrength) { self.strength = strength }

    /// `chosen`: the app's strength (its own, else the general one). `efficiency`: Dynamic Power Mode
    /// is on and currently in Efficiency; autocorrect then acts like Light (spell checker only).
    /// This is the single place where a strength turns into behaviour: the finder's model-free mode and
    /// every model call in the coordinator follow `usesModel`, and the whole-field rewrite follows
    /// `rewritesAtPauses` (never in Light or Efficiency).
    public static func resolve(chosen: AutocorrectStrength, efficiency: Bool) -> CorrectionMode {
        if efficiency { return CorrectionMode(strength: .light) }
        return CorrectionMode(strength: chosen)
    }
}
