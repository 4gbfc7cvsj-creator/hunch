import Foundation
import HunchCore

/// Where each active learned word was used (its app keys and amounts), for autocorrect: a learned
/// word offered as a fix comes from the words used in the current app or its category first
/// (`CorrectionFinder.learnedHere`). "Here" is autocomplete's rule (`BiasBuilder.useHere`): any use
/// in this app or an app in its category. A word with no app data (added by hand, from a dictation
/// fix, or learned before apps were recorded) counts as used everywhere.
public struct LearnedWordPlaces: Sendable, Equatable {
    /// Lowercased word -> app key -> amount of use.
    public var apps: [String: [String: Float]]

    public init(apps: [String: [String: Float]] = [:]) { self.apps = apps }

    public static let empty = LearnedWordPlaces()

    public var words: Set<String> { Set(apps.keys) }

    /// The learned words that count as this place's (lowercased). Nil without an app key: no
    /// preference, every learned word is equal.
    public func here(appKey: String?, categories: AppCategories = AppCategories()) -> Set<String>? {
        guard let appKey else { return nil }
        return Set(apps.compactMap { word, uses in
            let total = uses.values.reduce(0, +)
            return total <= 0 || BiasBuilder.useHere(apps: uses, appKey: appKey, categories: categories) > 0 ? word : nil
        })
    }
}
