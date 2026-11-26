import Foundation
import HunchCore

/// The writer's last sent messages per app, kept only in memory (never saved; gone when Hunch
/// quits), as evidence for who wrote what on screen (`ChatSides.assign`'s `sent`). A message counts
/// as sent when the box that held it empties at once. Deleting it a little at a time is not sending,
/// and neither is focus moving away.
public struct SentMessages: Sendable {
    /// Messages kept per app, newest last.
    public static let perApp = 10

    private var byApp: [String: [String]] = [:]
    /// The text the focused box holds now, and the longest it held since it was last empty.
    private var current: (app: String, field: FieldID, text: String, peak: Int)?

    public init() {}

    /// A read of the focused box's whole text (`before + after`). Returns the message when this read
    /// shows it was just sent. A box holding only invisible characters, or exactly its `placeholder`
    /// (`SuggestedRepliesGate.isEmpty`), is empty.
    @discardableResult
    public mutating func note(app: String, field: FieldID, text: String, placeholder: String? = nil) -> String? {
        var trimmed = BlankText.trimmed(text)
        if let placeholder, !placeholder.isEmpty, trimmed == BlankText.trimmed(placeholder) { trimmed = "" }
        guard let c = current, c.field == field else {
            current = trimmed.isEmpty ? nil : (app, field, trimmed, trimmed.count)
            return nil
        }
        if trimmed.isEmpty {
            current = nil
            // Emptied at once (at least half of its longest text was still there): sent.
            if c.text.count * 2 >= c.peak, c.text.contains(where: { $0.isLetter || $0.isNumber }) {
                record(c.text, app: c.app)
                return c.text
            }
            return nil
        }
        current = (app, field, trimmed, max(c.peak, trimmed.count))
        return nil
    }

    /// Focus left the box: what it holds was not sent.
    public mutating func focusEnded() { current = nil }

    /// The app's remembered messages, oldest first.
    public func messages(app: String) -> [String] { byApp[app] ?? [] }

    mutating func record(_ text: String, app: String) {
        var list = byApp[app] ?? []
        list.removeAll { $0 == text }
        list.append(text)
        byApp[app] = Array(list.suffix(Self.perApp))
    }
}
