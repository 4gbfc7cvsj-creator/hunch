// Spell-check seam for the likely-typo rule: a small protocol, a bounded cache, and the AppKit-backed checker.
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Answers "is this word misspelled" without the post-processor knowing about AppKit.
///
/// `languages` are BCP-47-ish identifiers ("en", "fr", "en_US"); a word counts as misspelled only if it
/// is misspelled in every listed language (a bilingual writer's valid word in either language is fine).
/// An empty list means "the checker's default".
public protocol SpellChecking: Sendable {
    func isMisspelled(_ word: String, languages: [String]) -> Bool
    /// True when `partial` is the beginning of at least one correctly spelled word the checker knows.
    func isKnownPrefix(_ partial: String, languages: [String]) -> Bool
}

/// A checker that can fail to answer (e.g. a bounded wait on the main thread timed out). `nil`
/// means "unknown": callers treat it as "not misspelled" / "known prefix" (never suppress), and
/// `CachedSpellChecker` does not memoize it.
public protocol UncertainSpellChecking: SpellChecking {
    func lookupMisspelled(_ word: String, languages: [String]) -> Bool?
    func lookupKnownPrefix(_ partial: String, languages: [String]) -> Bool?
}

extension SpellChecking {
    /// The checker is sure `word` is spelled right. An unknown answer (a timed-out lookup) is not a
    /// yes: a candidate fix must never be approved on a lookup that didn't happen.
    public func isSurelySpelled(_ word: String, languages: [String]) -> Bool {
        if let uncertain = self as? any UncertainSpellChecking {
            return uncertain.lookupMisspelled(word, languages: languages) == false
        }
        return !isMisspelled(word, languages: languages)
    }
}

/// Least-recently-used map with a fixed capacity. Pure value type; callers add their own locking.
public struct BoundedLRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []  // oldest first; capacity is small (hundreds), so linear moves are fine

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public var count: Int { storage.count }

    public mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    public mutating func insert(_ value: Value, for key: Key) {
        storage[key] = value
        touch(key)
        while order.count > capacity {
            storage.removeValue(forKey: order.removeFirst())
        }
    }

    private mutating func touch(_ key: Key) {
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

/// Memoizes another checker per (word, languages). Typing re-asks about the same word on every
/// keystroke, so the underlying checker is hit once per distinct word.
public final class CachedSpellChecker: UncertainSpellChecking, @unchecked Sendable {
    private struct Key: Hashable, Sendable {
        var word: String
        var languages: [String]
        var prefix: Bool
    }

    private let base: any SpellChecking
    private let lock = NSLock()
    private var cache: BoundedLRUCache<Key, Bool>

    public init(_ base: any SpellChecking, capacity: Int = 512) {
        self.base = base
        self.cache = BoundedLRUCache(capacity: capacity)
    }

    public func isMisspelled(_ word: String, languages: [String]) -> Bool {
        lookupMisspelled(word, languages: languages) ?? false
    }

    public func isKnownPrefix(_ partial: String, languages: [String]) -> Bool {
        lookupKnownPrefix(partial, languages: languages) ?? true
    }

    public func lookupMisspelled(_ word: String, languages: [String]) -> Bool? {
        lookup(Key(word: word, languages: languages, prefix: false)) {
            if let uncertain = base as? any UncertainSpellChecking {
                return uncertain.lookupMisspelled(word, languages: languages)
            }
            return base.isMisspelled(word, languages: languages)
        }
    }

    public func lookupKnownPrefix(_ partial: String, languages: [String]) -> Bool? {
        lookup(Key(word: partial, languages: languages, prefix: true)) {
            if let uncertain = base as? any UncertainSpellChecking {
                return uncertain.lookupKnownPrefix(partial, languages: languages)
            }
            return base.isKnownPrefix(partial, languages: languages)
        }
    }

    /// Unknown answers (nil) are passed on and not memoized.
    private func lookup(_ key: Key, compute: () -> Bool?) -> Bool? {
        lock.lock()
        let hit = cache.value(for: key)
        lock.unlock()
        if let hit { return hit }
        guard let result = compute() else { return nil }  // outside the lock: the base may hop to main
        lock.lock()
        cache.insert(result, for: key)
        lock.unlock()
        return result
    }
}

#if canImport(AppKit)
/// `NSSpellChecker`-backed checker.
///
/// Threading rule: Apple does not promise that `NSSpellChecker.shared` is thread-safe, so every call
/// runs on the main thread: directly when already there, otherwise via `DispatchQueue.main.async`
/// with a BOUNDED wait (`mainWaitTimeout`, 50 ms). It must never use `main.sync`: the main thread can
/// itself be blocked on the thread calling us (e.g. waiting on the generation executor), which would
/// deadlock. On timeout the answer is "unknown" (nil from the `lookup*` methods; the plain methods
/// answer "not misspelled" / "known prefix"), so a slow or busy main thread never suppresses a
/// suggestion. Callers must also avoid invoking this from inside executor jobs (the engine
/// post-processes after its job). Wrap in `CachedSpellChecker` so the hop happens once per distinct
/// word, not per keystroke; unknown answers are not cached.
public struct SystemSpellChecker: UncertainSpellChecking {
    public var mainWaitTimeout: DispatchTimeInterval = .milliseconds(50)

    public init() {}

    public static func cached(capacity: Int = 512) -> CachedSpellChecker {
        CachedSpellChecker(SystemSpellChecker(), capacity: capacity)
    }

    public func isMisspelled(_ word: String, languages: [String]) -> Bool {
        lookupMisspelled(word, languages: languages) ?? false
    }

    public func isKnownPrefix(_ partial: String, languages: [String]) -> Bool {
        lookupKnownPrefix(partial, languages: languages) ?? true
    }

    public func lookupMisspelled(_ word: String, languages: [String]) -> Bool? {
        onMain { @Sendable in
            let checker = NSSpellChecker.shared
            let resolved = Self.resolve(languages, available: checker.availableLanguages)
            // Misspelled only if every candidate language rejects it.
            for language in resolved.isEmpty ? [nil] : resolved.map({ Optional($0) }) {
                let range = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                  inSpellDocumentWithTag: 0, wordCount: nil)
                if range.location == NSNotFound { return false }
            }
            return true
        }
    }

    public func lookupKnownPrefix(_ partial: String, languages: [String]) -> Bool? {
        onMain { @Sendable in
            let checker = NSSpellChecker.shared
            let resolved = Self.resolve(languages, available: checker.availableLanguages)
            let lowered = partial.lowercased()
            for language in resolved.isEmpty ? [nil] : resolved.map({ Optional($0) }) {
                let found = checker.completions(forPartialWordRange: NSRange(location: 0, length: (partial as NSString).length),
                                                in: partial, language: language, inSpellDocumentWithTag: 0) ?? []
                if found.contains(where: { $0.lowercased().hasPrefix(lowered) && $0.count > partial.count }) {
                    return true
                }
            }
            return false
        }
    }

    /// Maps "en"/"en-US"/"zh-Hans" to installed dictionary identifiers; drops CJK (no Latin dictionary).
    static func resolve(_ languages: [String], available: [String]) -> [String] {
        var out: [String] = []
        for raw in languages {
            let lang = raw.replacingOccurrences(of: "_", with: "-")
            let base = lang.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
            guard !base.isEmpty, !["zh", "ja", "ko"].contains(base) else { continue }
            let norm = { (s: String) in s.replacingOccurrences(of: "_", with: "-").lowercased() }
            let match = available.first { norm($0) == lang.lowercased() }
                ?? available.first { norm($0).hasPrefix(base) }
            if let match, !out.contains(match) { out.append(match) }
        }
        return out
    }

    /// Runs `body` on the main thread; nil when the main thread did not get to it within the timeout.
    private func onMain<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        if Thread.isMainThread { return body() }
        let box = MainResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.set(body())
            done.signal()
        }
        return done.wait(timeout: .now() + mainWaitTimeout) == .success ? box.get() : nil
    }
}
#endif

private final class MainResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
