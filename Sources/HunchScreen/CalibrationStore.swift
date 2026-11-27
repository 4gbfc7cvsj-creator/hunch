import Foundation
import HunchCore

/// When to try the on-screen match again for one line style: a burst of up to `burst` tries at
/// least `spacing` apart, then, if none succeeded, a fresh burst after `cooldown`. A failed streak
/// (too little text typed yet, a menu over the field) never switches calibration off for the rest
/// of the session.
public struct CalibrationRetry: Sendable, Equatable {
    public var count = 0
    public var last: ContinuousClock.Instant?

    public static let burst = 3
    public static let spacing: Duration = .seconds(2)
    public static let cooldown: Duration = .seconds(30)

    public init() {}

    /// Records a try and returns true when one is due at `now`; false leaves the state unchanged.
    public mutating func begin(at now: ContinuousClock.Instant) -> Bool {
        if let last {
            let since = now - last
            if since >= Self.cooldown {
                count = 0
            } else if count >= Self.burst || since < Self.spacing {
                return false
            }
        }
        count += 1
        last = now
        return true
    }
}

/// Saved on-screen measurements, one per app and line style, so a new session starts aligned.
/// The coordinator still re-measures once per session and saves the newer value. Holds bundle IDs
/// and numbers only, never text. Main-thread use only.
public final class CalibrationStore {
    public struct Key: Hashable, Codable, Sendable {
        public var bundleID: String
        public var caretHeight: Int
        /// Reported font size in half points (0 when unknown).
        public var fontSize: Int
        /// Short tag of the reported font (`FaceChoiceBook.fontTag`). Saves made before it existed
        /// decode as "" and are dropped on load: they were shared by every font in the app.
        public var fontTag: String
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bundleID = try c.decode(String.self, forKey: .bundleID)
            caretHeight = try c.decode(Int.self, forKey: .caretHeight)
            fontSize = try c.decode(Int.self, forKey: .fontSize)
            fontTag = try c.decodeIfPresent(String.self, forKey: .fontTag) ?? ""
        }
        public init(bundleID: String, caretHeight: Int, fontSize: Int, fontTag: String = "-") {
            self.fontTag = fontTag
            self.bundleID = bundleID
            self.caretHeight = caretHeight
            self.fontSize = fontSize
        }
    }

    private struct Entry: Codable {
        var key: Key
        var baseline: Double
        var xHeight: Double?
        var pointSize: Double?
        var score: Double?
        var hostXHeight: Double?
        var measuredAtSize: Double?
        var faceXHeights: [String: Double]?
        var sizeSuggestion: Double?
        var sizeFactor: Double?
        var pickedFamily: String?
        var savedAt: Date
    }

    /// Oldest entries are dropped beyond this.
    public static let capacity = 256

    private let fileURL: URL?
    private var entries: [Key: Entry] = [:]

    /// `fileURL` nil keeps everything in memory (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for entry in list where entry.baseline.isFinite && !entry.key.fontTag.isEmpty { entries[entry.key] = entry }
    }

    public func calibration(for key: Key) -> TextCalibration? {
        guard let e = entries[key] else { return nil }
        return TextCalibration(baselineAboveCaretBottom: CGFloat(e.baseline), xHeight: e.xHeight.map { CGFloat($0) },
                               pointSize: e.pointSize.map { CGFloat($0) }, score: e.score,
                               hostXHeight: e.hostXHeight.map { CGFloat($0) },
                               measuredAtSize: e.measuredAtSize.map { CGFloat($0) },
                               faceXHeights: (e.faceXHeights ?? [:]).mapValues { CGFloat($0) },
                               sizeSuggestion: e.sizeSuggestion.map { CGFloat($0) },
                               sizeFactor: CGFloat(e.sizeFactor ?? 1), pickedFamily: e.pickedFamily)
    }

    public func save(_ calibration: TextCalibration, for key: Key, at date: Date = Date()) {
        entries[key] = Entry(key: key, baseline: Double(calibration.baselineAboveCaretBottom),
                             xHeight: calibration.xHeight.map { Double($0) },
                             pointSize: calibration.pointSize.map { Double($0) }, score: calibration.score,
                             hostXHeight: calibration.hostXHeight.map { Double($0) },
                             measuredAtSize: calibration.measuredAtSize.map { Double($0) },
                             faceXHeights: calibration.faceXHeights.mapValues { Double($0) },
                             sizeSuggestion: calibration.sizeSuggestion.map { Double($0) },
                             sizeFactor: Double(calibration.sizeFactor), pickedFamily: calibration.pickedFamily,
                             savedAt: date)
        if entries.count > Self.capacity {
            let oldest = entries.values.sorted { $0.savedAt < $1.savedAt }.prefix(entries.count - Self.capacity)
            for e in oldest { entries[e.key] = nil }
        }
        write()
    }

    private func write() {
        guard let fileURL else { return }
        let list = entries.values.sorted { $0.savedAt < $1.savedAt }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? PrivateFile.write(data, to: fileURL)
    }
}
