import Foundation
import HunchCore

/// A GGUF repo from a Hugging Face search.
public struct HFRepo: Sendable, Equatable, Identifiable, Decodable {
    /// "owner/name".
    public let id: String
    public let downloads: Int
    public let likes: Int
    public let pipelineTag: String?

    public init(id: String, downloads: Int = 0, likes: Int = 0, pipelineTag: String? = nil) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
        self.pipelineTag = pipelineTag
    }

    enum CodingKeys: String, CodingKey { case id, downloads, likes, pipelineTag = "pipeline_tag" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        pipelineTag = try c.decodeIfPresent(String.self, forKey: .pipelineTag)
    }
}

/// A downloadable GGUF file in a repo: a single file at the repo's top level, stored in LFS so its
/// SHA-256 is known.
public struct HFFile: Sendable, Equatable, Identifiable {
    public var id: String { fileName }
    public let fileName: String
    public let byteSize: Int64
    /// Lowercase hex SHA-256 (the LFS object id).
    public let sha256: String

    public init(fileName: String, byteSize: Int64, sha256: String) {
        self.fileName = fileName
        self.byteSize = byteSize
        self.sha256 = sha256
    }

    /// The quantization in the file name ("Q4_K_M", "IQ2_XS", "F16"), if there is one.
    public var quantization: String? {
        let stem = (fileName as NSString).deletingPathExtension
        let pattern = #"(?i)(?:^|[.\-_])((?:I?Q\d+(?:_[A-Z0-9]+)*)|F16|BF16|F32)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let range = Range(match.range(at: 1), in: stem) else { return nil }
        return stem[range].uppercased()
    }
}

/// The pure half of Hugging Face search: URLs, decoding and filtering. `HuggingFaceClient` sends
/// the requests.
public enum HuggingFaceSearch {
    /// Repos whose task tag is one of these (or untagged) can be text models; ASR, embedding and
    /// image-generation repos are left out.
    static let textPipelines: Set<String> = ["text-generation", "text2text-generation", "image-text-to-text"]

    /// `https://huggingface.co/api/models?search=<q>&filter=gguf&sort=downloads&direction=-1&limit=<n>`,
    /// or nil for an empty query.
    public static func searchURL(query: String, limit: Int = 30, host: String = ModelCatalog.host) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/api/models"
        c.queryItems = [
            URLQueryItem(name: "search", value: q), URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"), URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return c.url
    }

    /// `https://huggingface.co/api/models/<owner>/<name>/tree/main`, or nil for an unsafe repo id.
    public static func treeURL(repo: String, host: String = ModelCatalog.host) -> URL? {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(DownloadPlan.isSafeComponent) else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/api/models/\(repo)/tree/main"
        return c.url
    }

    /// Text-model repos from a search response, in the server's order.
    public static func repos(from data: Data) throws -> [HFRepo] {
        try JSONDecoder().decode([HFRepo].self, from: data)
            .filter { $0.pipelineTag.map(textPipelines.contains) ?? true }
    }

    private struct TreeItem: Decodable {
        struct LFS: Decodable { let oid: String; let size: Int64 }
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
    }

    /// The loadable GGUF files in a tree response, smallest first. Left out: folders and files in
    /// them, split parts (`-00001-of-00003`), vision projectors (`mmproj`), files not in LFS, and
    /// anything whose hash doesn't look like a SHA-256.
    public static func files(from data: Data) throws -> [HFFile] {
        try JSONDecoder().decode([TreeItem].self, from: data).compactMap { item -> HFFile? in
            guard item.type == "file", let lfs = item.lfs,
                  DownloadPlan.isSafeComponent(Substring(item.path)),
                  item.path.lowercased().hasSuffix(".gguf"),
                  !item.path.lowercased().contains("mmproj"),
                  SplitName(fileName: item.path) == nil,
                  lfs.oid.count == 64, lfs.oid.allSatisfy(\.isHexDigit), lfs.size > 0
            else { return nil }
            return HFFile(fileName: item.path, byteSize: lfs.size, sha256: lfs.oid.lowercased())
        }
        .sorted { $0.byteSize < $1.byteSize }
    }
}

public enum HuggingFaceError: Error, Sendable, Equatable {
    case invalidRequest
    case http(status: Int)
    case network(String)
    case badResponse

    public var message: String {
        switch self {
        case .invalidRequest: "That search can't be sent."
        case .http(let status): "\(ModelCatalog.host) answered HTTP \(status)."
        case .network(let message): message
        case .badResponse: "\(ModelCatalog.host) sent a reply Hunch couldn't read."
        }
    }
}

/// Sends Hugging Face search and file-list requests; only ever started from Settings.
public struct HuggingFaceClient: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? ModelDownloader.makeSession()
    }

    public func search(_ query: String) async throws -> [HFRepo] {
        guard let url = HuggingFaceSearch.searchURL(query: query) else { throw HuggingFaceError.invalidRequest }
        return try decode(try await get(url), HuggingFaceSearch.repos)
    }

    public func files(in repo: String) async throws -> [HFFile] {
        guard let url = HuggingFaceSearch.treeURL(repo: repo) else { throw HuggingFaceError.invalidRequest }
        return try decode(try await get(url), HuggingFaceSearch.files)
    }

    private func decode<T>(_ data: Data, _ parse: (Data) throws -> T) throws -> T {
        do { return try parse(data) } catch { throw HuggingFaceError.badResponse }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw HuggingFaceError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HuggingFaceError.http(status: status) }
        return data
    }
}

extension CatalogModel {
    /// A file picked from Hugging Face search, downloaded and verified like a catalog entry. It goes
    /// in the category it was found from (`isInstruct` follows `use`).
    public static func huggingFace(repo: String, file: HFFile, use: ModelUse) -> CatalogModel {
        let stem = (file.fileName as NSString).deletingPathExtension
        return CatalogModel(displayName: stem, repo: repo, fileName: file.fileName, sha256: file.sha256,
                            byteSize: file.byteSize, parameterBillions: 0, parameterLabel: "",
                            quantization: file.quantization ?? "", family: .unknown,
                            isInstruct: use == .writing, minimumRAMBytes: 0, recommendedTier: nil)
    }
}
