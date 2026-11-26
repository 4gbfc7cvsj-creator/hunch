import Foundation

/// Something the user should know before downloading a model. Never blocks the download.
public enum RecommendationWarning: Sendable, Equatable {
    /// The model wants more memory than this Mac has.
    case memory(requiredBytes: UInt64, physicalBytes: UInt64)
    /// Free space on the models volume is below the file size plus 10 %.
    case disk(requiredBytes: Int64, freeBytes: Int64)
    /// The chip isn't Apple silicon; llama.cpp then runs without Metal and is slow.
    case notAppleSilicon

    public var message: String {
        switch self {
        case .memory(let required, let physical):
            "Needs \(Self.gigabytes(required)) of memory; this Mac has \(Self.gigabytes(physical))."
        case .disk(let required, let free):
            "Needs \(DownloadFormat.gigabytes(required)) of free disk space; \(DownloadFormat.gigabytes(free)) available."
        case .notAppleSilicon:
            "This Mac doesn't have Apple silicon; completions will be slow."
        }
    }

    /// Physical memory in binary GB, as Apple advertises it ("16 GB").
    static func gigabytes(_ bytes: UInt64) -> String {
        "\(Int((Double(bytes) / Double(1 << 30)).rounded())) GB"
    }
}

/// The recommended catalog entry for this Mac, with why and what to watch out for.
public struct ModelRecommendation: Sendable, Equatable {
    public var model: CatalogModel
    public var tier: MemoryTier
    /// One line, e.g. "Fits comfortably in 16 GB".
    public var reason: String
    public var warnings: [RecommendationWarning]
}

/// Picks a catalog entry from the machine's memory, chip and free disk. Pure: callers pass the
/// facts (`MachineFacts.current` in the app, literals in tests).
public enum ModelRecommender {
    /// ≤ 8 GB → small; < 32 GB → standard; otherwise large. Memory is counted in binary GB, which is
    /// what `ProcessInfo.physicalMemory` reports for an advertised "16 GB" Mac.
    public static func tier(ramBytes: UInt64) -> MemoryTier {
        let gib = Double(ramBytes) / Double(1 << 30)
        if gib <= 8.5 { return .small }
        if gib < 31.5 { return .standard }
        return .large
    }

    /// The recommendation among `catalog` (one use's entries; the Language Model's by default), or nil if it
    /// has no entry at all.
    /// - Parameter freeDiskBytes: free space on the models volume; nil (unknown) skips the disk check.
    public static func recommend(ramBytes: UInt64, chipBrand: String, freeDiskBytes: Int64?,
                                 catalog: [CatalogModel] = ModelCatalog.entries(for: .autocomplete))
        -> ModelRecommendation? {
        let tier = tier(ramBytes: ramBytes)
        let order: [MemoryTier] = switch tier {
        case .small: [.small, .standard, .large]
        case .standard: [.standard, .small, .large]
        case .large: [.large, .standard, .small]
        }
        // The tier's own pick; failing that, the nearest tier's (smaller first), then anything.
        let model = order.lazy.compactMap { t in catalog.first { $0.recommendedTier == t } }.first ?? catalog.first
        guard let model else { return nil }
        let warnings = warnings(for: model, ramBytes: ramBytes, chipBrand: chipBrand, freeDiskBytes: freeDiskBytes)
        let fits = !warnings.contains { if case .memory = $0 { true } else { false } }
        let reason = fits ? "Fits comfortably in \(RecommendationWarning.gigabytes(ramBytes))"
            : "The smallest model in the catalog"
        return ModelRecommendation(model: model, tier: tier, reason: reason, warnings: warnings)
    }

    /// Memory, disk and chip warnings for any entry (the recommendation and the other models).
    /// - Parameter downloadedBytes: bytes of this model already on disk (a part file, or the whole
    ///   file once downloaded). They count toward the requirement, so the disk warning doesn't
    ///   appear while a download fills the disk, and never for a downloaded model.
    public static func warnings(for model: CatalogModel, ramBytes: UInt64, chipBrand: String,
                                freeDiskBytes: Int64?, downloadedBytes: Int64 = 0) -> [RecommendationWarning] {
        var out: [RecommendationWarning] = []
        if model.minimumRAMBytes > ramBytes {
            out.append(.memory(requiredBytes: model.minimumRAMBytes, physicalBytes: ramBytes))
        }
        if let free = freeDiskBytes, downloadedBytes < model.byteSize {
            let required = requiredDiskBytes(for: model) - max(0, downloadedBytes)
            if free < required { out.append(.disk(requiredBytes: required, freeBytes: free)) }
        }
        if !isAppleSilicon(chipBrand) { out.append(.notAppleSilicon) }
        return out
    }

    /// File size plus 10 % headroom.
    public static func requiredDiskBytes(for model: CatalogModel) -> Int64 {
        model.byteSize + (model.byteSize + 9) / 10
    }

    /// `machdep.cpu.brand_string` is "Apple M1 Pro" etc. on Apple silicon. An empty string (the
    /// sysctl failed) is not held against the Mac.
    public static func isAppleSilicon(_ chipBrand: String) -> Bool {
        let brand = chipBrand.trimmingCharacters(in: .whitespaces)
        return brand.isEmpty || brand.hasPrefix("Apple")
    }
}

/// Reads the facts the recommender needs. Local queries only.
public enum MachineFacts {
    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    public static var chipBrand: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Free space for "important" data on the volume holding `folder` (what macOS would free up
    /// for a user-requested download), or nil if it can't be read.
    public static func freeDiskBytes(at folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
