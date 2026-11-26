import HunchCore
import Synchronization

/// Redacts the user-derived parts of a `PromptInput` with `SecretSanitizer` before a framer lays
/// them out. The background (after-caret, screen, clipboard, style, place) changes about once per
/// field, so it is redacted once and reused; the before-caret text keeps its last `exactBefore`
/// characters as typed so healing and anchor matching see exactly what is in the field.
/// Each framer owns one; the caches hold a handful of entries and live only in memory.
final class PromptRedactor: Sendable {
    /// Characters right before the caret that are never rewritten.
    static let exactBefore = 200
    static let capacity = 4

    /// The per-field background of an input, as one cache key (and, redacted, as its value).
    private struct Background: Equatable, Sendable {
        var after: String
        var screenContext: String?
        var clipboard: String?
        var styleExamples: [String]
        var appName: String?
        var domain: String?
        var windowTitle: String?
        var fieldLabel: String?
        var surface: SurfaceKind

        init(_ input: PromptInput) {
            after = input.after
            screenContext = input.screenContext
            clipboard = input.clipboard
            styleExamples = input.styleExamples
            appName = input.appName
            domain = input.domain
            windowTitle = input.windowTitle
            fieldLabel = input.fieldLabel
            surface = input.surface
        }

        func redacted() -> Background {
            func r(_ text: String) -> String { SecretSanitizer.redact(text, surface: surface) }
            var out = self
            out.after = r(after)
            out.screenContext = screenContext.map(r)
            out.clipboard = clipboard.map(r)
            out.styleExamples = styleExamples.map(r)
            out.appName = appName.map(r)
            out.domain = domain.map(r)
            out.windowTitle = windowTitle.map(r)
            out.fieldLabel = fieldLabel.map(r)
            return out
        }

        func apply(to input: inout PromptInput) {
            input.after = after
            input.screenContext = screenContext
            input.clipboard = clipboard
            input.styleExamples = styleExamples
            input.appName = appName
            input.domain = domain
            input.windowTitle = windowTitle
            input.fieldLabel = fieldLabel
        }
    }

    private struct BeforeKey: Equatable, Sendable {
        var text: String
        var surface: SurfaceKind
    }

    private let backgrounds = Mutex<[(key: Background, value: Background)]>([])
    private let befores = Mutex<[(key: BeforeKey, value: String)]>([])

    init() {}

    func redacted(_ input: PromptInput) -> PromptInput {
        var out = input
        let background = Self.cached(Background(input), in: backgrounds) { $0.redacted() }
        background.apply(to: &out)
        out.before = Self.cached(BeforeKey(text: input.before, surface: input.surface), in: befores) {
            SecretSanitizer.redact($0.text, keepingLast: Self.exactBefore, surface: $0.surface)
        }
        return out
    }

    /// Most-recently-used lookup; `make` runs outside the lock.
    private static func cached<Key: Equatable & Sendable, Value: Sendable>(
        _ key: Key, in cache: borrowing Mutex<[(key: Key, value: Value)]>, make: (Key) -> Value
    ) -> Value {
        let hit: Value? = cache.withLock { entries in
            guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: i)
            entries.insert(entry, at: 0)
            return entry.value
        }
        if let hit { return hit }
        let value = make(key)
        cache.withLock { entries in
            entries.insert((key, value), at: 0)
            if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        }
        return value
    }
}
