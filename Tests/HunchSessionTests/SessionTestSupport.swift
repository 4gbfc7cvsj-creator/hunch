import CoreGraphics
import Foundation
import HunchCore
@testable import HunchSession

enum Fixture {
    static let app = AppIdentity(bundleID: "com.example.editor", pid: 42, localizedName: "Editor")
    static let fieldA = FieldID(pid: 42, elementHash: 1, generation: 1)
    static let fieldB = FieldID(pid: 42, elementHash: 2, generation: 1)
    static let geometry = CaretGeometry(caretRect: CGRect(x: 10, y: 10, width: 1, height: 14), quality: .exact)
    static let movedGeometry = CaretGeometry(caretRect: CGRect(x: 40, y: 10, width: 1, height: 14), quality: .exact)
    static let t0 = ContinuousClock.now

    static func context(_ before: String, field: FieldID = fieldA, after: String = "", marked: Bool = false,
                        selection: Int = 0, lineEnd: Bool = true, surface: SurfaceKind = .unknown) -> TextContext {
        var hasher = Hasher()
        hasher.combine(before)
        hasher.combine(after)
        hasher.combine(selection)
        return TextContext(app: app, field: field, before: before, after: after, selectionLength: selection,
                           hasMarkedText: marked, caretAtLineEnd: lineEnd, metadata: FieldMetadata(surface: surface),
                           contentSignature: UInt64(bitPattern: Int64(hasher.finalize())))
    }
}

/// Drives a session the way the coordinator does, remembering the latest request.
struct Driver {
    var session = SuggestionSession()
    var now = Fixture.t0
    var lastRequest: (id: RequestID, context: TextContext, refill: Bool)?

    @discardableResult
    mutating func send(_ event: SessionEvent) -> [SessionCommand] {
        let commands = session.handle(event, now: now)
        for command in commands {
            if case let .request(id, context, refill) = command { lastRequest = (id, context, refill) }
        }
        return commands
    }

    @discardableResult
    mutating func type(_ before: String, field: FieldID = Fixture.fieldA,
                       geometry: CaretGeometry = Fixture.geometry, midLine: Bool = false) -> [SessionCommand] {
        send(.context(Fixture.context(before, field: field), geometry, midLineEnabled: midLine))
    }

    /// Answers the latest request with `text`.
    @discardableResult
    mutating func answer(_ text: String) -> [SessionCommand] {
        guard let last = lastRequest else { return [] }
        return send(.result(id: last.id, text: text, requestContext: last.context))
    }

    /// Types `before`, then shows `suggestion` for it.
    mutating func show(_ suggestion: String, after before: String) {
        type(before)
        answer(suggestion)
    }
}

extension Array where Element == SessionCommand {
    var requests: [(RequestID, TextContext, Bool)] {
        compactMap { if case let .request(id, context, refill) = $0 { return (id, context, refill) } else { return nil } }
    }
    var inserts: [String] {
        compactMap { if case let .insert(text, _, _) = $0 { return text } else { return nil } }
    }
    var presented: [String] {
        compactMap { if case let .present(ghost) = $0 { return ghost.remaining } else { return nil } }
    }
    var hides: Bool { contains(.hide) }
}
