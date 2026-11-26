import AppKit

/// One item's representations, in the order the pasteboard reported them.
public struct PasteboardSnapshot: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var type: String
        public var data: Data
        public init(type: String, data: Data) { self.type = type; self.data = data }
    }
    public var items: [[Entry]]
    public init(items: [[Entry]]) { self.items = items }
}

@MainActor
public protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    /// Replaces the contents with `text` marked transient + concealed; returns the new change count.
    func writeTransient(_ text: String) -> Int?
    func restore(_ snapshot: PasteboardSnapshot)
}

/// `NSPasteboard.general`, with nspasteboard.org markers so clipboard managers skip our write.
@MainActor
public final class SystemPasteboard: PasteboardAccess {
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let board: NSPasteboard
    public init(board: NSPasteboard = .general) { self.board = board }

    public var changeCount: Int { board.changeCount }

    public func snapshot() -> PasteboardSnapshot {
        let items = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { PasteboardSnapshot.Entry(type: type.rawValue, data: $0) } }
        }
        return PasteboardSnapshot(items: items)
    }

    public func writeTransient(_ text: String) -> Int? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: Self.transientType),
              item.setData(Data(), forType: Self.concealedType) else { return nil }
        board.clearContents()
        guard board.writeObjects([item]) else { return nil }
        return board.changeCount
    }

    public func restore(_ snapshot: PasteboardSnapshot) {
        board.clearContents()
        let items = snapshot.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type)) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}

/// Swaps the clipboard for one paste and restores it afterwards, only if nobody else wrote to it
/// in between. Back-to-back pastes keep the user's original contents (not our own text) for restore.
@MainActor
public final class ClipboardSwap {
    private struct Pending {
        var original: PasteboardSnapshot
        var ourChangeCount: Int
    }

    private let board: any PasteboardAccess
    private var pending: Pending?
    private var restoreTask: Task<Void, Never>?

    public init(board: any PasteboardAccess) { self.board = board }

    public var hasPendingRestore: Bool { pending != nil }

    /// Puts `text` on the clipboard. Returns false (with the original contents put back) on failure.
    public func stage(_ text: String) -> Bool {
        restoreTask?.cancel()
        restoreTask = nil
        let original: PasteboardSnapshot
        if let pending, board.changeCount == pending.ourChangeCount {
            original = pending.original
        } else {
            original = board.snapshot()
        }
        pending = nil
        guard let ours = board.writeTransient(text) else {
            board.restore(original)
            return false
        }
        pending = Pending(original: original, ourChangeCount: ours)
        return true
    }

    public func scheduleRestore(after delay: Duration) {
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.restoreNow()
        }
    }

    /// Forgets the user's contents: what we wrote stays on the clipboard.
    public func keepStaged() {
        restoreTask?.cancel()
        restoreTask = nil
        pending = nil
    }

    /// Restores the user's contents if the clipboard still holds exactly what we wrote.
    public func restoreNow() {
        guard let pending else { return }
        self.pending = nil
        if board.changeCount == pending.ourChangeCount { board.restore(pending.original) }
    }
}
