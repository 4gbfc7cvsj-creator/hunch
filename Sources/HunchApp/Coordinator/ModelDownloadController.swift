import Foundation
import HunchCore
import HunchModels

/// Catalog downloads started from Settings → Model. The downloader (and its URLSession) is made on
/// the first Download press, so nothing here touches the network until the user asks.
@MainActor
final class ModelDownloadController {
    enum State: Equatable {
        case downloading(DownloadProgress)
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var downloader: ModelDownloader?
    /// Files picked from Hugging Face search (not in the catalog), by file name, kept so Retry works.
    private var picked: [String: CatalogModel] = [:]
    /// Memory and chip don't change while the app runs.
    private let ramBytes = MachineFacts.physicalMemory
    private let chipBrand = MachineFacts.chipBrand
    /// Called on every state or progress change.
    var onChange: (() -> Void)?
    /// Called with the new file (relative to the folder) once it is verified and in place.
    var onCompleted: ((ModelEntryID) -> Void)?

    /// Downloads, or resumes, `fileName` from the catalog (or an earlier Hugging Face pick) into `folder`.
    func start(_ fileName: String, in folder: URL) {
        guard let model = ModelCatalog.entry(forFileName: fileName) ?? picked[fileName] else { return }
        start(model, in: folder)
    }

    /// Downloads a file picked from Hugging Face search; it then lists in the category it came from.
    func start(picked model: CatalogModel, in folder: URL) {
        if ModelCatalog.entry(forFileName: model.fileName) == nil { picked[model.fileName] = model }
        start(model, in: folder)
    }

    /// Every running or failed download's state by file name (catalog or picked), for the Hugging Face sheet.
    var paneStates: [String: CatalogRow.State] {
        states.mapValues {
            switch $0 {
            case .downloading(let p): .downloading(fraction: p.fraction, text: p.summary)
            case .failed(let message): .failed(message)
            }
        }
    }

    private func start(_ model: CatalogModel, in folder: URL) {
        let fileName = model.fileName
        guard tasks[fileName] == nil else { return }
        let downloader = self.downloader ?? ModelDownloader()
        self.downloader = downloader
        states[fileName] = .downloading(DownloadProgress(receivedBytes: 0, totalBytes: model.byteSize, bytesPerSecond: 0))
        onChange?()
        tasks[fileName] = Task { [weak self] in
            let job = await downloader.download(model, into: folder)
            for await progress in job.progress {
                self?.states[fileName] = .downloading(progress)
                self?.onChange?()
            }
            let outcome: Result<URL, any Error>
            do {
                outcome = .success(try await withTaskCancellationHandler { try await job.result } onCancel: { job.cancel() })
            } catch {
                outcome = .failure(error)
            }
            self?.finish(fileName, outcome)
        }
    }

    /// Stops a download; its part file stays, so Download resumes it.
    func cancel(_ fileName: String) {
        tasks[fileName]?.cancel()
    }

    private func finish(_ fileName: String, _ outcome: Result<URL, any Error>) {
        tasks[fileName] = nil
        switch outcome {
        case .success(let url):
            states[fileName] = nil
            onCompleted?(ModelEntryID(relativePath: url.lastPathComponent))
        case .failure(DownloadError.cancelled):
            states[fileName] = nil
        case .failure(let error):
            let message = (error as? DownloadError)?.message ?? error.localizedDescription
            states[fileName] = .failed("Download failed: \(message)")
        }
        onChange?()
    }

    // MARK: Pane rows

    /// The Models pane's catalog rows for each use: that use's recommendation for this Mac first
    /// (with its reason and warnings), then the rest.
    /// - Parameters:
    ///   - models: the folder's current models (a matching file name counts as downloaded).
    ///   - folder: the available models folder, if any (free space is read from its volume).
    func paneRows(models: [ModelEntry], folder: URL?) -> [ModelUse: [CatalogRow]] {
        let free = folder.flatMap { MachineFacts.freeDiskBytes(at: $0) }
        let present = ModelCatalog.downloaded(relativePaths: models.map(\.id.relativePath))
        func state(_ model: CatalogModel) -> CatalogRow.State {
            switch states[model.fileName] {
            case .downloading(let p): return .downloading(fraction: p.fraction, text: p.summary)
            case .failed(let message): return .failed(message)
            case nil: break
            }
            let onDisk = folder.map {
                FileManager.default.fileExists(atPath: DownloadPlan.finalURL(for: model.fileName, in: $0).path)
            } ?? false
            return present.contains(model.fileName) || onDisk ? .downloaded : .available
        }
        func row(_ model: CatalogModel, reason: String = "") -> CatalogRow {
            CatalogRow(id: model.fileName, name: model.displayName, detail: model.parameterQuantLine,
                       size: DownloadFormat.gigabytes(model.byteSize), reason: reason, warnings: [],
                       state: state(model), byteSize: model.byteSize)
        }
        var out: [ModelUse: [CatalogRow]] = [:]
        for use in ModelUse.allCases {
            let catalog = ModelCatalog.entries(for: use)
            guard !catalog.isEmpty else { continue }
            let recommendation = ModelRecommender.recommend(ramBytes: ramBytes, chipBrand: chipBrand,
                                                            freeDiskBytes: free, catalog: catalog)
            var rows: [CatalogRow] = []
            if let r = recommendation {
                var top = row(r.model, reason: r.reason)
                top.isRecommended = true
                // Recomputed with what is already on disk, so the disk warning doesn't appear while a
                // download fills the disk, nor once the model is there.
                let onDisk = top.state == .downloaded ? r.model.byteSize : folder.map { partBytes(r.model, in: $0) } ?? 0
                top.warnings = ModelRecommender.warnings(for: r.model, ramBytes: ramBytes, chipBrand: chipBrand,
                                                         freeDiskBytes: free, downloadedBytes: onDisk).map(\.message)
                rows.append(top)
            }
            rows += catalog.filter { $0.fileName != recommendation?.model.fileName }.map { row($0) }
            out[use] = rows
        }
        // Hugging Face picks show in their category while downloading or failed; once in the
        // folder they are ordinary models.
        for model in picked.values.sorted(by: { $0.fileName < $1.fileName }) where states[model.fileName] != nil {
            out[model.use, default: []].append(row(model))
        }
        return out
    }

    private func partBytes(_ model: CatalogModel, in folder: URL) -> Int64 {
        let part = DownloadPlan.partURL(for: model.fileName, in: folder)
        return (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
