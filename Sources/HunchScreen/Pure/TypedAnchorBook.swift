import CoreGraphics

/// Typed-line anchors per line style (an app's field of a given size): a new query or a refocused
/// field gets its caret placed right away instead of after the next look. Guards against a single
/// look matching something else on screen (the dropdown, a tab title): a position far from the
/// known one is adopted only when seen twice in a row, and a known anchor is forgotten only after
/// `missesToForget` misses in a row.
public struct TypedAnchorBook<Key: Hashable & Sendable>: Sendable {
    /// Start or baseline moves within this (points) refine the anchor; larger ones are jumps.
    public static var moveTolerance: CGFloat { 4 }
    public static var missesToForget: Int { 3 }
    static var capacity: Int { 64 }

    private var anchors: [Key: TypedTextAnchor] = [:]
    private var pending: [Key: TypedTextAnchor] = [:]
    private var misses: [Key: Int] = [:]

    public init() {}

    /// Starts from saved anchors (`TypedAnchorStore`), trusted like ones found this session.
    public init(anchors: [Key: TypedTextAnchor]) {
        self.anchors = anchors.count > Self.capacity ? [:] : anchors
    }

    public func anchor(for key: Key) -> TypedTextAnchor? { anchors[key] }

    /// A confident look. True when the anchor in use changed.
    @discardableResult
    public mutating func noteFound(_ found: TypedTextAnchor, for key: Key) -> Bool {
        misses[key] = nil
        guard let known = anchors[key] else {
            if anchors.count >= Self.capacity { anchors.removeAll(); pending.removeAll(); misses.removeAll() }
            anchors[key] = found
            pending[key] = nil
            return true
        }
        if Self.isNear(found, known) {
            pending[key] = nil
            guard found != known else { return false }
            anchors[key] = found
            return true
        }
        // A jump: adopt it only if the previous look saw the same.
        if let candidate = pending[key], Self.isNear(found, candidate) {
            anchors[key] = found
            pending[key] = nil
            return true
        }
        pending[key] = found
        return false
    }

    /// A look with no confident match. True when the anchor was forgotten.
    @discardableResult
    public mutating func noteMissed(for key: Key) -> Bool {
        pending[key] = nil
        guard anchors[key] != nil else { return false }
        let count = (misses[key] ?? 0) + 1
        guard count >= Self.missesToForget else { misses[key] = count; return false }
        anchors[key] = nil
        misses[key] = nil
        return true
    }

    static func isNear(_ a: TypedTextAnchor, _ b: TypedTextAnchor) -> Bool {
        abs(a.startOffset - b.startOffset) <= moveTolerance && abs(a.baselineOffset - b.baselineOffset) <= moveTolerance
    }
}
