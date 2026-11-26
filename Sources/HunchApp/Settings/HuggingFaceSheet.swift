import Foundation
import HunchModels
import Observation
import SwiftUI

/// "Search Hugging Face…" for one category: search GGUF repos, pick one, then download one of its
/// files into the models folder. Nothing touches the network until the user presses Search.
@MainActor
@Observable
final class HuggingFaceSearchModel: Identifiable {
    let use: ModelUse
    var query = ""
    private(set) var repos: [HFRepo] = []
    /// The repo whose files are listed; nil shows the search results.
    private(set) var repo: String?
    private(set) var files: [HFFile] = []
    private(set) var loading = false
    private(set) var message: String?
    /// True once a search has come back (so "No results" can show).
    private(set) var searched = false

    @ObservationIgnored private var client: HuggingFaceClient?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(use: ModelUse) {
        self.use = use
    }

    func search() {
        let q = query
        run { client in
            let found = try await client.search(q)
            self.repos = found
            self.searched = true
            self.message = found.isEmpty ? "No GGUF repos match “\(q)”." : nil
        }
    }

    func open(_ repo: HFRepo) {
        self.repo = repo.id
        files = []
        run { client in
            let found = try await client.files(in: repo.id)
            self.files = found
            self.message = found.isEmpty ? "This repo has no single-file GGUF models Hunch can download." : nil
        }
    }

    func back() {
        task?.cancel()
        loading = false
        repo = nil
        files = []
        message = repos.isEmpty && searched ? "No GGUF repos match “\(query)”." : nil
    }

    func stop() {
        task?.cancel()
        loading = false
    }

    private func run(_ work: @escaping @MainActor (HuggingFaceClient) async throws -> Void) {
        task?.cancel()
        let client = self.client ?? HuggingFaceClient()
        self.client = client
        loading = true
        message = nil
        task = Task { [weak self] in
            do {
                try await work(client)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.message = (error as? HuggingFaceError)?.message ?? error.localizedDescription
            }
            if !Task.isCancelled { self?.loading = false }
        }
    }
}

struct HuggingFaceSheet: View {
    @Bindable var search: HuggingFaceSearchModel
    let model: ModelsPaneModel
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch search.use {
        case .autocomplete: "Search Hugging Face for Language Models"
        case .writing: "Search Hugging Face for writing models"
        case .speechToText: "Search Hugging Face for speech to text models"
        }
    }

    private var hint: String {
        switch search.use {
        case .autocomplete: "Pick an instruct (chat) model: it also runs Write for me. A base model works for "
            + "suggestions, but Write for me then needs a separate writing model."
        case .writing: "Writing needs instruct (chat) models."
        case .speechToText: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary) }
            if let repo = search.repo {
                HStack {
                    Button { search.back() } label: { Label("Results", systemImage: "chevron.left") }
                    Text(repo).font(.callout.weight(.semibold)).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if search.loading { ProgressView().controlSize(.small) }
                }
            } else {
                HStack {
                    TextField("Model name, e.g. Qwen3 1.7B Base", text: $search.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { search.search() }
                    Button("Search") { search.search() }
                        .disabled(search.query.trimmingCharacters(in: .whitespaces).isEmpty || search.loading)
                    if search.loading { ProgressView().controlSize(.small) }
                }
            }
            if let message = search.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            List {
                if search.repo == nil {
                    ForEach(search.repos) { repo in
                        Button { search.open(repo) } label: { RepoRow(repo: repo) }
                            .buttonStyle(.plain)
                    }
                } else {
                    ForEach(search.files) { file in
                        FileRow(file: file, repo: search.repo ?? "", use: search.use, model: model)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 260)
            HStack {
                Text(model.canDownload
                     ? "Files are checked against their SHA-256 and saved in the models folder."
                     : "Choose a models folder before downloading.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { search.stop(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 620, height: 520)
    }
}

private struct RepoRow: View {
    let repo: HFRepo

    var body: some View {
        HStack {
            Text(repo.id).lineLimit(1).truncationMode(.middle)
            Spacer()
            Label(repo.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
            Label(repo.likes.formatted(.number.notation(.compactName)), systemImage: "heart")
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .font(.callout)
        .contentShape(Rectangle())
    }
}

private struct FileRow: View {
    let file: HFFile
    let repo: String
    let use: ModelUse
    let model: ModelsPaneModel

    /// Running or failed, else already in the folder, else available.
    private var state: CatalogRow.State {
        if let state = model.downloadStates[file.fileName] { return state }
        let name = file.fileName.lowercased()
        let present = model.rows.contains { ($0.id.relativePath as NSString).lastPathComponent.lowercased() == name }
        return present ? .downloaded : .available
    }

    /// More than about two thirds of memory leaves too little for the context and other apps.
    private var tooLarge: Bool { Double(file.byteSize) > Double(MachineFacts.physicalMemory) * 0.66 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.fileName).lineLimit(1).truncationMode(.middle)
                    Text([file.quantization, DownloadFormat.gigabytes(file.byteSize)].compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if tooLarge {
                        Text("Likely too large for this Mac's memory.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                switch state {
                case .available:
                    Button("Download") { model.downloadPicked(repo, file, use) }.disabled(!model.canDownload)
                case .downloaded:
                    Text("Downloaded ✓").foregroundStyle(.secondary)
                case .downloading, .failed:
                    EmptyView()
                }
            }
            switch state {
            case .downloading(let fraction, let text):
                ProgressView(value: fraction)
                HStack {
                    Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelDownload(file.fileName) }
                }
            case .failed(let message):
                HStack {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Button("Retry") { model.downloadPicked(repo, file, use) }.disabled(!model.canDownload)
                }
            case .available, .downloaded:
                EmptyView()
            }
        }
    }
}
