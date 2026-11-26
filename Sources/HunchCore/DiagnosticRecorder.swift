import Foundation
import Synchronization

/// The diagnostic console's memory: the last `capacity` requests, newest first, kept only while the
/// console window is open. Off by default; while off every call is a no-op and the typing path pays
/// one atomic read (`isEnabled`). Nothing here is written to disk, and `disable()` (the window
/// closing) throws everything away.
public final class DiagnosticRecorder: @unchecked Sendable {
    /// The app-wide recorder the engines and the coordinator report to.
    public static let shared = DiagnosticRecorder()
    public static let defaultCapacity = 50

    public let capacity: Int
    private let flag = Atomic<Bool>(false)
    private struct State {
        var entries: [DiagnosticRecord] = []
        var nextID = 1
        var observers: [UInt64: @Sendable () -> Void] = [:]
        var nextObserver: UInt64 = 1
    }
    private let state = Mutex(State())

    public init(capacity: Int = DiagnosticRecorder.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// True while the console window is open. Read this before building anything to record.
    public var isEnabled: Bool { flag.load(ordering: .relaxed) }

    /// Starts recording (the console window opened).
    public func enable() {
        flag.store(true, ordering: .relaxed)
    }

    /// Stops recording and forgets everything (the console window closed).
    public func disable() {
        flag.store(false, ordering: .relaxed)
        let observers = state.withLock { s -> [@Sendable () -> Void] in
            s.entries.removeAll()
            return Array(s.observers.values)
        }
        observers.forEach { $0() }
    }

    /// The recorded requests, newest first.
    public var entries: [DiagnosticRecord] { state.withLock { $0.entries } }

    /// Adds a record (its `id` is assigned here) and drops the oldest beyond `capacity`.
    /// Returns nil, recording nothing, while off.
    @discardableResult
    public func record(_ record: DiagnosticRecord) -> Int? {
        guard isEnabled else { return nil }
        let (id, observers) = state.withLock { s -> (Int, [@Sendable () -> Void]) in
            var entry = record
            entry.id = s.nextID
            s.nextID += 1
            s.entries.insert(entry, at: 0)
            if s.entries.count > capacity { s.entries.removeLast(s.entries.count - capacity) }
            return (entry.id, Array(s.observers.values))
        }
        observers.forEach { $0() }
        return id
    }

    /// Changes the newest record of `kind` made for the request `key` (the app adds what the user was
    /// shown once the engine's result is judged). No-op when there is none or while off.
    public func update(requestKey key: UInt64, kind: DiagnosticKind = .suggestion,
                       _ change: (inout DiagnosticRecord) -> Void) {
        guard isEnabled else { return }
        let observers = state.withLock { s -> [@Sendable () -> Void] in
            guard let index = s.entries.firstIndex(where: { $0.requestKey == key && $0.kind == kind }) else { return [] }
            change(&s.entries[index])
            return Array(s.observers.values)
        }
        observers.forEach { $0() }
    }

    /// Calls `handler` (on whatever thread changed the list) after every change. Returns a token for
    /// `removeObserver`.
    public func addObserver(_ handler: @escaping @Sendable () -> Void) -> UInt64 {
        state.withLock { s in
            let token = s.nextObserver
            s.nextObserver += 1
            s.observers[token] = handler
            return token
        }
    }

    public func removeObserver(_ token: UInt64) {
        state.withLock { $0.observers[token] = nil }
    }
}
