import Foundation
import HunchCore

/// What the filesystem looks like for the configured path.
public enum PathExistence: Sendable, Equatable { case absent, file, directory }
public enum ReadProbe: Sendable, Equatable { case ok, denied, failed }

/// Facts gathered by the manager; the classifier is pure so it can be tested without volumes.
public struct FolderFacts: Sendable, Equatable {
    public var configured: Bool
    public var url: URL
    public var lastPath: String
    public var volumeName: String?
    /// UUID recorded when the folder was chosen; nil means unknown (treated as mounted).
    public var volumeUUID: String?
    public var mountedVolumeUUIDs: Set<String>
    public var existence: PathExistence
    public var readProbe: ReadProbe
    public init(configured: Bool = true, url: URL, lastPath: String, volumeName: String? = nil,
                volumeUUID: String? = nil, mountedVolumeUUIDs: Set<String> = [],
                existence: PathExistence, readProbe: ReadProbe) {
        self.configured = configured
        self.url = url
        self.lastPath = lastPath
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.mountedVolumeUUIDs = mountedVolumeUUIDs
        self.existence = existence
        self.readProbe = readProbe
    }
}

public enum FolderStateClassifier {
    public static func classify(_ f: FolderFacts) -> FolderState {
        guard f.configured else { return .notConfigured }
        if let uuid = f.volumeUUID, !f.mountedVolumeUUIDs.contains(uuid) {
            return .volumeOffline(volumeName: f.volumeName, lastPath: f.lastPath)
        }
        switch f.existence {
        case .absent: return .missing(lastPath: f.lastPath)
        case .file: return .notADirectory(f.url)
        case .directory:
            switch f.readProbe {
            case .ok: return .available(f.url)
            case .denied: return .permissionDenied(f.url)
            case .failed: return .missing(lastPath: f.lastPath)
            }
        }
    }
}

/// Pure debounce bookkeeping: fire once `interval` has passed since the last recorded event.
public struct DebounceTimeline: Sendable, Equatable {
    public let interval: TimeInterval
    public private(set) var lastEvent: Date?
    public init(interval: TimeInterval = 0.5) { self.interval = interval }

    public mutating func record(at now: Date) { lastEvent = now }

    /// Seconds still to wait, or nil if nothing is pending.
    public func remaining(at now: Date) -> TimeInterval? {
        guard let last = lastEvent else { return nil }
        return max(0, last.addingTimeInterval(interval).timeIntervalSince(now))
    }

    public func isDue(at now: Date) -> Bool { remaining(at: now) == 0 }
    public mutating func reset() { lastEvent = nil }
}
