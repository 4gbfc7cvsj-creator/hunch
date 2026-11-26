import Foundation
import HunchCore

/// Memory class a catalog entry is recommended for (see `ModelRecommender.tier(ramBytes:)`).
public enum MemoryTier: String, Sendable, Equatable, CaseIterable {
    /// 8 GB or less.
    case small
    /// More than 8 GB, less than 32 GB (16, 18, 24 GB Macs).
    case standard
    /// 32 GB or more.
    case large
}

/// What a model is for. Each use has its own catalog section and recommendation in Settings.
public enum ModelUse: String, Sendable, Equatable, CaseIterable {
    /// The Language Model: inline suggestions, and Write for me unless a separate writing model is on.
    case autocomplete
    /// Instruct models for Write for me.
    case writing
    /// Speech-to-text models (whisper.cpp files) for dictation.
    case speechToText
}

/// One downloadable GGUF file. Hash and size are pinned so a download is checked against what
/// was reviewed, not against whatever the repo serves today.
public struct CatalogModel: Sendable, Equatable, Identifiable {
    public var id: String { fileName }
    public let displayName: String
    /// Hugging Face repo, "owner/name".
    public let repo: String
    /// File name in the repo and in the models folder (one path component).
    public let fileName: String
    /// Lowercase hex SHA-256 of the whole file (the LFS object id).
    public let sha256: String
    public let byteSize: Int64
    /// Parameters in billions (effective parameters for Gemma's E-series).
    public let parameterBillions: Double
    /// Short label for the UI: "E4B", "1.7B", "8B".
    public let parameterLabel: String
    public let quantization: String
    public let family: ModelFamily
    public let isInstruct: Bool
    /// Below this much physical memory the model is expected to page or crowd out other apps.
    public let minimumRAMBytes: UInt64
    /// The tier this entry is the recommendation for within its use; nil for alternatives.
    public let recommendedTier: MemoryTier?

    /// Set for entries that aren't language models (speech to text).
    private let fixedUse: ModelUse?

    /// Instruct models write, base models autocomplete; speech models are their own use.
    public var use: ModelUse { fixedUse ?? (isInstruct ? .writing : .autocomplete) }

    public init(displayName: String, repo: String, fileName: String, sha256: String, byteSize: Int64,
                parameterBillions: Double, parameterLabel: String, quantization: String, family: ModelFamily,
                isInstruct: Bool, minimumRAMBytes: UInt64, recommendedTier: MemoryTier?, use: ModelUse? = nil) {
        self.fixedUse = use
        self.displayName = displayName
        self.repo = repo
        self.fileName = fileName
        self.sha256 = sha256
        self.byteSize = byteSize
        self.parameterBillions = parameterBillions
        self.parameterLabel = parameterLabel
        self.quantization = quantization
        self.family = family
        self.isInstruct = isInstruct
        self.minimumRAMBytes = minimumRAMBytes
        self.recommendedTier = recommendedTier
    }

    /// "1.7B · Q4_K_M", with "· instruct" for instruct models; speech models show the label alone.
    public var parameterQuantLine: String {
        if use == .speechToText { return parameterLabel }
        return ([parameterLabel, quantization] + (isInstruct ? ["instruct"] : [])).joined(separator: " · ")
    }
}

/// The static model catalog. Nothing here touches the network; downloads start only from Settings.
/// Values were checked against Hugging Face on `updated`; a re-uploaded file fails its hash check
/// rather than loading silently, so keep the table small and re-verify when editing it.
public enum ModelCatalog {
    public static let updated = "2026-10-19"
    /// The only host downloads go to (shown in Settings).
    public static let host = "huggingface.co"

    static let gib: UInt64 = 1 << 30

    public static let entries: [CatalogModel] = [
        // The model Hunch was developed with (base + document framing).
        CatalogModel(displayName: "Gemma 4 E4B", repo: "mradermacher/gemma-4-E4B-i1-GGUF",
                     fileName: "gemma-4-E4B.i1-Q5_K_M.gguf",
                     sha256: "6672b7962494139138c4c98b498ceb97c06c00dc9000e5fc1760046522ac6351",
                     byteSize: 5_762_896_640, parameterBillions: 4, parameterLabel: "E4B", quantization: "Q5_K_M",
                     family: .gemma, isInstruct: false, minimumRAMBytes: 16 * gib, recommendedTier: .standard),
        CatalogModel(displayName: "Gemma 4 E4B Instruct", repo: "mradermacher/gemma-4-E4B-it-i1-GGUF",
                     fileName: "gemma-4-E4B-it.i1-Q5_K_M.gguf",
                     sha256: "feb04d4d1d089b0388f704c1c07d5093f72315b859f50eb04d68c9ef22ea05e4",
                     byteSize: 5_762_912_960, parameterBillions: 4, parameterLabel: "E4B", quantization: "Q5_K_M",
                     family: .gemma, isInstruct: true, minimumRAMBytes: 16 * gib, recommendedTier: .standard),
        // The smaller Gemma 4 for 8 GB Macs that want Gemma over Qwen (an alternative, no tier).
        CatalogModel(displayName: "Gemma 4 E2B Instruct", repo: "mradermacher/gemma-4-E2B-it-i1-GGUF",
                     fileName: "gemma-4-E2B-it.i1-Q4_K_M.gguf",
                     sha256: "8b732c669bf021855a7e6eecf704462170b26cc0aac0f973d8482ae4f98acce4",
                     byteSize: 3_427_878_560, parameterBillions: 2, parameterLabel: "E2B", quantization: "Q4_K_M",
                     family: .gemma, isInstruct: true, minimumRAMBytes: 8 * gib, recommendedTier: nil),
        CatalogModel(displayName: "Qwen3 1.7B Base", repo: "mradermacher/Qwen3-1.7B-Base-i1-GGUF",
                     fileName: "Qwen3-1.7B-Base.i1-Q4_K_M.gguf",
                     sha256: "b3aac3227132b11e0ea8c818569f27c053ebde24d0b8530f3bd476e7ff33ee20",
                     byteSize: 1_107_409_248, parameterBillions: 1.7, parameterLabel: "1.7B", quantization: "Q4_K_M",
                     family: .qwen, isInstruct: false, minimumRAMBytes: 8 * gib, recommendedTier: .small),
        CatalogModel(displayName: "Qwen3 8B Base", repo: "mradermacher/Qwen3-8B-Base-i1-GGUF",
                     fileName: "Qwen3-8B-Base.i1-Q4_K_M.gguf",
                     sha256: "983b5fac39c91e8167c150c2878a011878a3281c5412610342b33cb07a13e834",
                     byteSize: 5_027_784_192, parameterBillions: 8, parameterLabel: "8B", quantization: "Q4_K_M",
                     family: .qwen, isInstruct: false, minimumRAMBytes: 16 * gib, recommendedTier: .large),
        // Instruct counterparts of the Qwen3 base models (Qwen3's hybrid post-trained checkpoints).
        CatalogModel(displayName: "Qwen3 1.7B Instruct", repo: "mradermacher/Qwen3-1.7B-i1-GGUF",
                     fileName: "Qwen3-1.7B.i1-Q4_K_M.gguf",
                     sha256: "f2fd0515cd4a2ee9b6ed419c1174d4838dc9067dd8a36f44d0df643fc0614506",
                     byteSize: 1_282_439_936, parameterBillions: 1.7, parameterLabel: "1.7B", quantization: "Q4_K_M",
                     family: .qwen, isInstruct: true, minimumRAMBytes: 8 * gib, recommendedTier: .small),
        CatalogModel(displayName: "Qwen3 8B Instruct", repo: "mradermacher/Qwen3-8B-i1-GGUF",
                     fileName: "Qwen3-8B.i1-Q4_K_M.gguf",
                     sha256: "98ff48cf082f40b36ceedba186b9aac32c46626e85c49f65b11a2a005665359b",
                     byteSize: 5_027_784_512, parameterBillions: 8, parameterLabel: "8B", quantization: "Q4_K_M",
                     family: .qwen, isInstruct: true, minimumRAMBytes: 16 * gib, recommendedTier: .large),
    ] + speechEntries

    /// whisper.cpp's own conversions of OpenAI's Whisper models (GGML, not GGUF: the folder scan
    /// doesn't list them; Settings finds them by file name). All multilingual. Turbo is large-v3
    /// with a smaller decoder: near-large accuracy at a fraction of the time, so it is the pick.
    static let speechEntries: [CatalogModel] = [
        speech("Whisper Tiny", "ggml-tiny.bin", "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
               77_691_713, label: "Fastest, least accurate"),
        speech("Whisper Base", "ggml-base.bin", "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
               147_951_465, label: "Fast, rough"),
        speech("Whisper Small", "ggml-small.bin", "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
               487_601_967, label: "Better, slower"),
        speech("Whisper Medium", "ggml-medium.bin", "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
               1_533_763_059, label: "Good, slow"),
        speech("Whisper Large v3 Turbo", "ggml-large-v3-turbo.bin",
               "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", 1_624_555_275,
               label: "Accurate and fast", tier: .standard),
        speech("Whisper Large v3", "ggml-large-v3.bin", "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
               3_095_033_483, label: "Most accurate, slowest"),
    ]

    private static func speech(_ name: String, _ file: String, _ sha: String, _ bytes: Int64, label: String,
                               tier: MemoryTier? = nil) -> CatalogModel {
        CatalogModel(displayName: name, repo: "ggerganov/whisper.cpp", fileName: file, sha256: sha, byteSize: bytes,
                     parameterBillions: 0, parameterLabel: label, quantization: "", family: .unknown, isInstruct: false,
                     minimumRAMBytes: 8 * gib, recommendedTier: tier, use: .speechToText)
    }

    /// The entries offered for one use, in catalog order. The Language Model and the writing model
    /// both offer the instruct entries; the base entries stay in the table so files already
    /// downloaded are still recognized, but they are no longer offered.
    public static func entries(for use: ModelUse) -> [CatalogModel] {
        switch use {
        case .autocomplete, .writing: entries.filter { $0.isInstruct && $0.use != .speechToText }
        case .speechToText: speechEntries
        }
    }

    /// The catalog entry a file in the models folder corresponds to, by file name (case-insensitive,
    /// as on the default APFS volume; subfolders don't matter).
    public static func entry(forFileName name: String, in catalog: [CatalogModel] = entries) -> CatalogModel? {
        let last = (name as NSString).lastPathComponent.lowercased()
        return catalog.first { $0.fileName.lowercased() == last }
    }

    /// File names (as spelled in the catalog) of entries already present among `relativePaths`.
    public static func downloaded(relativePaths: [String], in catalog: [CatalogModel] = entries) -> Set<String> {
        Set(relativePaths.compactMap { entry(forFileName: $0, in: catalog)?.fileName })
    }
}
