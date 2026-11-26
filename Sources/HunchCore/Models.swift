import Foundation

public struct FolderBookmark: Codable, Sendable, Equatable {
    public var bookmarkData: Data
    public var lastKnownPath: String
    public var volumeUUID: String?
    public var volumeName: String?
    public var isOnRemovableVolume: Bool
    public init(bookmarkData: Data, lastKnownPath: String, volumeUUID: String?, volumeName: String?,
                isOnRemovableVolume: Bool) {
        self.bookmarkData = bookmarkData
        self.lastKnownPath = lastKnownPath
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.isOnRemovableVolume = isOnRemovableVolume
    }
}

public enum FolderState: Sendable, Equatable {
    case notConfigured
    case available(URL)
    case volumeOffline(volumeName: String?, lastPath: String)
    /// The volume is present but the folder is gone.
    case missing(lastPath: String)
    case permissionDenied(URL)
    case notADirectory(URL)
}

public enum GGUFValidity: Sendable, Equatable {
    case valid
    case notGGUF
    case unsupportedVersion(UInt32)
    case truncated
    case malformedMetadata(String)
    case splitPart(index: Int, of: Int)
    /// Not a standalone language model, e.g. a vision projector (`mmproj`).
    case auxiliary(String)
    case unreadable(String)
}

/// Header metadata read by Hunch's own GGUF inspector (never by loading the model).
public struct GGUFSummary: Sendable, Equatable, Codable {
    public var version: UInt32
    public var architecture: String?
    public var name: String?
    public var type: String?
    public var baseName: String?
    public var finetune: String?
    public var sizeLabel: String?
    public var fileType: UInt32?
    public var contextLength: Int?
    public var slidingWindow: Int?
    public var chatTemplate: String?
    public var addBOS: Bool?
    public var tensorCount: UInt64?
    public init(version: UInt32, architecture: String? = nil, name: String? = nil, type: String? = nil,
                baseName: String? = nil, finetune: String? = nil, sizeLabel: String? = nil, fileType: UInt32? = nil,
                contextLength: Int? = nil, slidingWindow: Int? = nil, chatTemplate: String? = nil, addBOS: Bool? = nil,
                tensorCount: UInt64? = nil) {
        self.version = version
        self.architecture = architecture
        self.name = name
        self.type = type
        self.baseName = baseName
        self.finetune = finetune
        self.sizeLabel = sizeLabel
        self.fileType = fileType
        self.contextLength = contextLength
        self.slidingWindow = slidingWindow
        self.chatTemplate = chatTemplate
        self.addBOS = addBOS
        self.tensorCount = tensorCount
    }
}

public struct ModelEntryID: Hashable, Codable, Sendable {
    /// Path relative to the models folder.
    public let relativePath: String
    public init(relativePath: String) { self.relativePath = relativePath }
    /// A file added from outside the models folder: `relativePath` is then its absolute path.
    public var isOutsideFolder: Bool { relativePath.hasPrefix("/") }
}

public struct ModelEntry: Identifiable, Sendable, Equatable {
    public var id: ModelEntryID
    public var url: URL
    public var byteSize: Int64
    public var modified: Date
    public var validity: GGUFValidity
    public var summary: GGUFSummary?
    public init(id: ModelEntryID, url: URL, byteSize: Int64, modified: Date, validity: GGUFValidity,
                summary: GGUFSummary?) {
        self.id = id
        self.url = url
        self.byteSize = byteSize
        self.modified = modified
        self.validity = validity
        self.summary = summary
    }
}

public protocol GGUFInspecting: Sendable {
    func inspect(_ url: URL) -> (GGUFValidity, GGUFSummary?)
}

public struct FolderSnapshot: Sendable, Equatable {
    public var state: FolderState
    public var models: [ModelEntry]
    public var scannedAt: Date?
    public init(state: FolderState, models: [ModelEntry], scannedAt: Date?) {
        self.state = state
        self.models = models
        self.scannedAt = scannedAt
    }
}

public protocol ModelsFolderManaging: Sendable {
    func snapshot() async -> FolderSnapshot
    func updates() -> AsyncStream<FolderSnapshot>
    /// Creates the bookmark and scans.
    func choose(folder: URL) async throws
    func clear() async
    func rescan() async
    func resolveForLoading(_ id: ModelEntryID) async -> Result<URL, ModelFolderUnavailable>
}

/// Error wrapper so `FolderState` can travel in a `Result`.
public struct ModelFolderUnavailable: Error, Sendable, Equatable {
    public let state: FolderState
    public init(_ state: FolderState) { self.state = state }
}

public protocol BookmarkStoring: Sendable {
    func load() -> FolderBookmark?
    func save(_ bookmark: FolderBookmark?) throws
}
