import Foundation
import HunchCore

/// Paw walk's cat as it goes along a suggestion: the steps it has taken, in the current text's
/// letters, on its own clock (seconds since it set off).
///
/// A step's letters and landing time are fixed once it lands, so words that stream in later don't
/// move or re-land earlier prints: the cat steps on to them at its own pace, or, if it had reached
/// the end, as soon as they arrive.
public struct PawWalk: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public var first: Int
        public var last: Int
        public var land: TimeInterval
        /// Which step of the walk this is: sides and colors alternate by it.
        public var ordinal: Int
        /// Letters of its front already typed through.
        public var cut = 0
    }

    public private(set) var steps: [Step] = []
    /// The first letter not stepped on yet.
    public private(set) var next = 0
    /// When the next step lands.
    public private(set) var nextLand: TimeInterval = 0
    public let step: TimeInterval
    public let letters: Int
    private var ordinal = 0
    private var caughtUp = false

    /// A walk over a suggestion of `characters` letters (which sets its pace, as `pawStepSeconds`).
    public init(_ r: PopInRecipe, characters: Int) {
        step = PopIn.pawStepSeconds(r, characters: characters)
        letters = PopIn.pawLetters(r)
    }

    /// Takes every step due by `time`, over a text now `characters` letters long. A cat that has
    /// reached the end waits there, and steps on letters that arrive later at once (or one step
    /// after its last, if that is sooner).
    public mutating func advance(to time: TimeInterval, characters: Int) {
        // Caught up last time: letters that have arrived since are stepped on now, not back then.
        if caughtUp, next < characters { nextLand = max(nextLand, time) }
        while next < characters, nextLand <= time {
            let last = min(characters, next + letters) - 1
            steps.append(Step(first: next, last: last, land: nextLand, ordinal: ordinal))
            ordinal += 1
            next = last + 1
            nextLand += step
        }
        caughtUp = next >= characters
        if caughtUp { nextLand = max(nextLand, time) }
    }

    /// Letters before `index` count as stamped already (they finished before the cat was there).
    public mutating func skip(to index: Int) { next = max(next, index) }

    /// The user typed through `count` letters of the front: letters (and steps) move up, and steps
    /// wholly typed through go.
    public mutating func dropFront(_ count: Int) {
        guard count > 0 else { return }
        steps = steps.compactMap { s in
            guard s.last >= count else { return nil }
            var s = s
            s.cut += max(0, count - s.first)
            s.first = max(0, s.first - count)
            s.last -= count
            return s
        }
        next = max(0, next - count)
    }

    /// When letter `index` is stamped, or nil if the cat hasn't stepped on it yet.
    public func letterStart(_ r: PopInRecipe, index: Int) -> TimeInterval? {
        guard index < next, let s = steps.last(where: { $0.first <= index }), index <= s.last else { return nil }
        // Offsets count from the step's own front, even once typing has cut into it.
        return s.land + PopIn.pawLetterDelay(r, offset: index - s.first + s.cut, step: step)
    }

    /// The prints showing at `time`.
    public func prints(_ r: PopInRecipe, at time: TimeInterval) -> [PopIn.PawPrint] {
        steps.compactMap {
            PopIn.pawPrint(r, first: $0.first, last: $0.last, ordinal: $0.ordinal, age: time - $0.land, step: step)
        }
    }

    /// Whether every letter of a `characters`-letter text is stamped and every print has gone or
    /// faded to the trail by `time`.
    public func isQuiet(_ r: PopInRecipe, at time: TimeInterval, characters: Int) -> Bool {
        guard next >= characters else { return false }
        guard let last = steps.last else { return true }
        return time >= last.land + PopIn.pawQuiet(r, step: step)
    }
}
