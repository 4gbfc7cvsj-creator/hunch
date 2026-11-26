import Foundation

/// A small color fingerprint of a chat avatar (the picture beside a sender's header in Discord):
/// the avatar's square cut into `side` × `side` cells, each its average color. Holds no text and
/// can't be turned back into the picture. Made by `AvatarFinder` (HunchScreen).
public struct AvatarPrint: Codable, Sendable, Equatable {
    public static let side = 8
    /// RGB per cell, row by row: `side * side * 3` bytes.
    public var cells: [UInt8]

    public init(cells: [UInt8]) {
        self.cells = cells
    }

    /// Cells inside the avatar's circle (Discord draws avatars round; the corners are background,
    /// which differs on a highlighted message).
    static let circleCells: [Int] = {
        let c = Double(side) / 2
        return (0..<(side * side)).filter { i in
            let x = Double(i % side) + 0.5, y = Double(i / side) + 0.5
            return ((x - c) * (x - c) + (y - c) * (y - c)).squareRoot() <= c * 0.9
        }
    }()

    /// Mean absolute color difference per channel over the circle's cells, 0...255.
    public func distance(to other: AvatarPrint) -> Double {
        guard cells.count == other.cells.count, cells.count == Self.side * Self.side * 3 else { return 255 }
        var total = 0
        for i in Self.circleCells {
            for c in 0..<3 { total += abs(Int(cells[i * 3 + c]) - Int(other.cells[i * 3 + c])) }
        }
        return Double(total) / Double(Self.circleCells.count * 3)
    }
}

/// The writer's own avatar in a chat app, learned from a message group that held a message they
/// sent, with the header names read beside it ("" when the name couldn't be read).
public struct MyAvatar: Codable, Sendable, Equatable {
    public var print: AvatarPrint
    public var names: [String]
    public var learnedAt: Date

    public init(print: AvatarPrint, names: [String], learnedAt: Date = Date()) {
        self.print = print
        self.names = names
        self.learnedAt = learnedAt
    }
}
