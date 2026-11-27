import Foundation
import HunchCore
import Synchronization

/// One app or website in Settings → Apps. Places stay listed until the user removes them.
public struct KnownPlace: Codable, Sendable, Equatable {
    public var key: PolicyKey
    /// The app's name when it was added, shown when the app is no longer installed.
    public var name: String?
    public var addedAt: Date
    /// Added with "+" rather than automatically.
    public var manual: Bool

    public init(key: PolicyKey, name: String? = nil, addedAt: Date, manual: Bool) {
        self.key = key
        self.name = name
        self.addedAt = addedAt
        self.manual = manual
    }
}

/// The apps and websites listed in Settings → Apps: added automatically the first time the
/// user types in them, or by hand with "+". Removing one with "−" also stops it from being
/// added automatically again (only "+" brings it back). Thread-safe; writes only on change
/// (the per-keystroke `noteUsed` check is a dictionary lookup).
public final class KnownPlacesStore: Sendable {
    public static let schemaVersion = 1
    /// Posted on the main queue after the list changes.
    public static let didChange = Notification.Name("Hunch.KnownPlacesDidChange")

    private struct State {
        var places: [PolicyKey: KnownPlace] = [:]
        var removed: Set<PolicyKey> = []
    }
    private struct FileFormat: Codable {
        var schemaVersion: Int
        var places: [KnownPlace]
        var removed: [PolicyKey]
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private let url: URL?
    private let state: Mutex<State>
    private let now: @Sendable () -> Date

    /// `fileURL` nil keeps the list in memory (tests). Missing, unreadable, or newer-schema
    /// files load as empty.
    public init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = fileURL
        self.now = now
        var s = State()
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let file = try? Self.decoder.decode(FileFormat.self, from: data),
           file.schemaVersion <= Self.schemaVersion {
            for p in file.places { s.places[p.key] = p }
            s.removed = Set(file.removed)
        }
        state = Mutex(s)
    }

    public var places: [KnownPlace] { state.withLock { Array($0.places.values) } }

    public func contains(_ key: PolicyKey) -> Bool { state.withLock { $0.places[key] != nil } }

    /// The key for a site host: lowercased, without "www.".
    public static func siteKey(_ host: String) -> PolicyKey? {
        var h = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : .domain(pattern: h)
    }

    /// What the user typed under Websites → "+": a host ("example.com"), a subdomain pattern
    /// ("*.example.com") or a pasted URL. Nil when it isn't a site address.
    public static func siteKey(fromInput raw: String) -> PolicyKey? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: text), url.scheme != nil, let host = url.host() { text = host }
        let wildcard = text.hasPrefix("*.")
        let body = wildcard ? String(text.dropFirst(2)) : text
        guard body.contains("."), !body.hasPrefix("."), !body.hasSuffix("."),
              !body.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "*" || $0 == ":" }),
              case .domain(let host)? = siteKey(body) else { return nil }
        return .domain(pattern: wildcard ? "*." + host : host)
    }

    /// Automatic add: the user typed here. Ignored when already listed or removed by the user.
    public func noteUsed(_ key: PolicyKey, name: String? = nil) {
        let changed = state.withLock { s -> Bool in
            guard s.places[key] == nil, !s.removed.contains(key) else { return false }
            s.places[key] = KnownPlace(key: key, name: name, addedAt: now(), manual: false)
            return true
        }
        if changed { saveAndNotify() }
    }

    /// "+": lists the place (again) and allows automatic adding again.
    public func add(_ key: PolicyKey, name: String? = nil) {
        state.withLock { s in
            s.removed.remove(key)
            if s.places[key] == nil { s.places[key] = KnownPlace(key: key, name: name, addedAt: now(), manual: true) }
        }
        saveAndNotify()
    }

    /// Lists places that have saved settings but aren't listed yet (no effect on removed ones).
    public func adopt(_ keys: some Sequence<PolicyKey>) {
        let changed = state.withLock { s -> Bool in
            var any = false
            for k in keys where s.places[k] == nil {
                s.places[k] = KnownPlace(key: k, addedAt: now(), manual: true)
                s.removed.remove(k)
                any = true
            }
            return any
        }
        if changed { saveAndNotify() }
    }

    /// "−": unlists the place and keeps it from being added automatically.
    public func remove(_ key: PolicyKey) {
        state.withLock { s in
            s.places.removeValue(forKey: key)
            s.removed.insert(key)
        }
        saveAndNotify()
    }

    private func saveAndNotify() {
        if let url {
            let file = state.withLock { s in
                FileFormat(schemaVersion: Self.schemaVersion,
                           places: s.places.values.sorted { String(describing: $0.key) < String(describing: $1.key) },
                           removed: s.removed.sorted { String(describing: $0) < String(describing: $1) })
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(file) {
                try? PrivateFile.write(data, to: url)
            }
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}
