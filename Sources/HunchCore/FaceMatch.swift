import CoreGraphics
import Foundation

/// What the ghost draws with for one app and reported size, decided from the host's text as
/// measured on screen (x-height from the ink), so it holds whatever font name the host reports.
///
/// - `family`: an installed face picked because the host's font can't be loaded and the system
///   face's letters came out clearly taller or shorter than the host's (Discord's gg sans, which
///   it may report by name or not at all).
/// - `sizeFactor`: for a host font that loads, a confirmed size correction (the same face measured
///   a different height twice running means the reported size is wrong). 1 leaves it alone.
public struct FaceChoice: Sendable, Equatable, Codable {
    public var family: String?
    public var sizeFactor: CGFloat
    public init(family: String? = nil, sizeFactor: CGFloat = 1) {
        self.family = family
        self.sizeFactor = sizeFactor
    }
    public static let none = FaceChoice()
}

/// Pure decisions from measured x-heights. All heights are in points.
public enum FaceMatch {
    /// Installed faces tried for a host font that can't be loaded, in order of preference on a tie.
    /// The system face comes first: it's the default and is kept unless another clearly fits better.
    public static let candidates = [systemFamily, "Avenir Next", "Helvetica Neue"]
    /// Key for the system face in measurements (its real family name is private).
    public static let systemFamily = "System"

    /// A drawn and a measured x-height closer than this look aligned.
    public static let tolerance: CGFloat = 0.3
    /// Another face replaces the system face only when it's this much closer to the host.
    public static let pickMargin: CGFloat = 0.2
    /// A loaded font's size is corrected only past both of these gaps.
    public static let sizeGap: CGFloat = 0.4
    public static let sizeShare: CGFloat = 0.05
    /// Size corrections stay within this share either way.
    public static let maxSizeChange: CGFloat = 0.1
    /// Two measurements confirm each other when their corrections are this close.
    public static let confirmShare: CGFloat = 0.03

    /// The face to draw a host font that can't be loaded: nil keeps the system face. `xHeights`
    /// holds each candidate's x-height at the reported size, measured the same way as `host`.
    public static func pickFace(host: CGFloat, xHeights: [String: CGFloat]) -> String? {
        guard host > 0, let system = xHeights[systemFamily] else { return nil }
        let systemGap = abs(system - host)
        guard systemGap > tolerance else { return nil }
        var best: (family: String, gap: CGFloat)?
        for family in candidates where family != systemFamily {
            guard let x = xHeights[family], x > 0 else { continue }
            let gap = abs(x - host)
            if best == nil || gap < best!.gap { best = (family, gap) }
        }
        guard let best, best.gap < systemGap - pickMargin else { return nil }
        return best.family
    }

    /// The size correction one measurement suggests for a host font that loads: host ÷ drawn,
    /// within ±10%, or nil when the two are close enough.
    public static func suggestedSizeFactor(host: CGFloat, drawn: CGFloat) -> CGFloat? {
        guard host > 0, drawn > 0 else { return nil }
        let gap = abs(host - drawn)
        guard gap > sizeGap, gap / drawn > sizeShare else { return nil }
        return min(max(host / drawn, 1 - maxSizeChange), 1 + maxSizeChange)
    }

    /// A correction both measurements agree on (same direction, within 3%), else nil.
    public static func confirm(_ previous: CGFloat?, _ current: CGFloat?) -> CGFloat? {
        guard let previous, let current, (previous > 1) == (current > 1),
              abs(previous - current) <= confirmShare else { return nil }
        return (previous + current) / 2
    }

    /// The size factor to keep after a new measurement: a confirmed new one, else the one already
    /// in force unless this measurement found the sizes in agreement.
    public static func nextSizeFactor(current: CGFloat, previousSuggestion: CGFloat?,
                                      suggestion: CGFloat?) -> CGFloat {
        if let confirmed = confirm(previousSuggestion, suggestion) { return confirmed }
        return suggestion == nil ? 1 : current
    }

    /// True when the drawn and measured x-heights disagree noticeably.
    public static func isDrift(host: CGFloat, drawn: CGFloat) -> Bool {
        abs(host - drawn) > tolerance
    }
}

/// The current `FaceChoice` per app and reported size, shared by everything that draws or measures
/// the ghost's font (overlay, width learner, calibration), so they never disagree. Thread-safe.
public final class FaceChoiceBook: @unchecked Sendable {
    /// Stable (same across launches) short tag for the host font a hint reports, so a measurement
    /// made for one font in an app is not reused for another. "-" when the host reports none.
    public static func fontTag(_ hint: FontHint?) -> String {
        guard let name = hint?.name ?? hint?.family, !name.isEmpty else { return "-" }
        var h: UInt32 = 2166136261
        for byte in name.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
        return String(h, radix: 16)
    }

    public static let shared = FaceChoiceBook()

    public struct Key: Hashable, Sendable {
        public var bundleID: String
        /// Reported size in half points (0 when unknown).
        public var halfPoints: Int
        /// `FaceChoiceBook.fontTag` of the reported font.
        public var fontTag: String
        public init(bundleID: String, pointSize: CGFloat?, fontTag: String = "-") {
            self.bundleID = bundleID
            self.fontTag = fontTag
            self.halfPoints = Int(((pointSize ?? 0) * 2).rounded())
        }
    }

    private let lock = NSLock()
    private var choices: [Key: FaceChoice] = [:]

    public init() {}

    public func choice(for key: Key) -> FaceChoice {
        lock.withLock { choices[key] ?? .none }
    }

    public func set(_ choice: FaceChoice, for key: Key) {
        lock.withLock {
            if choices.count > 256 { choices.removeAll() }
            choices[key] = choice == .none ? nil : choice
        }
    }

    /// `hint` with the choice for this app and its size applied (a hint is made when there was none).
    public func apply(to hint: FontHint?, bundleID: String) -> FontHint? {
        let choice = choice(for: Key(bundleID: bundleID, pointSize: hint?.pointSize,
                                        fontTag: Self.fontTag(hint)))
        guard choice != .none || hint != nil else { return nil }
        var out = hint ?? FontHint()
        out.measuredFamily = choice.family
        out.sizeFactor = choice.sizeFactor
        return out
    }
}

/// Opt-in alignment check (Privacy & Data › Diagnostics): one line to
/// `~/Library/Logs/Hunch/alignment.log` when the ghost's letters are drawn noticeably taller
/// or shorter than the host's, when a correction is applied or cleared, and once per app and size
/// while it's aligned. Repeats of the same line are skipped. Sizes and app IDs only, never text.
public enum AlignmentCheckLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var lastLines: [String: String] = [:]

    public static var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// Forgets the last line for `key`, so the same drift is written again if it comes back.
    public static func clear(key: String) {
        lock.withLock { _ = lastLines.removeValue(forKey: key) }
    }

    /// Writes `text` only if nothing was written for `key` since it was last cleared.
    public static func noteOnce(_ text: String, key: String) {
        let first: Bool = lock.withLock { enabled && lastLines[key] == nil }
        if first { note(text, key: key) }
    }

    /// Writes `text` unless the last line written for `key` was the same.
    public static func note(_ text: String, key: String) {
        let fresh: Bool = lock.withLock {
            guard enabled, lastLines[key] != text else { return false }
            if lastLines.count > 512 { lastLines.removeAll() }
            lastLines[key] = text
            return true
        }
        guard fresh else { return }
        let dir = DrawDebugLog.logDirectory
        let url = dir.appendingPathComponent("alignment.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
