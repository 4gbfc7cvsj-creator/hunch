import AppKit
import HunchCore
import SwiftUI

/// Privacy & Data → Diagnostics → Saved logs: every log Debug logging saves, by type. Each type
/// lists its entries (date, app, preview; select one for all of it) with single, selected and
/// whole-log delete; the plain-text debug logs are listed by size.
struct SavedLogsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SavedLogKind: [SavedLogEntry]] = [:]
    @State private var debugFiles: [DebugLogFile] = []
    @State private var loaded = false
    @State private var confirmEverything = false
    @State private var failure: String?

    /// The Diagnostics row's caption: what is saved, by type.
    static func summary() -> String {
        let parts = SavedLogKind.allCases.compactMap { kind -> String? in
            guard let n = SavedLogs.count(kind), n > 0 else { return nil }
            return kind.count(n)
        }
        let debug = SavedLogs.debugLogFiles()
        let all = parts + (debug.isEmpty ? [] : [debug.count == 1 ? "1 debug log" : "\(debug.count) debug logs"])
        return all.isEmpty ? "Nothing saved." : all.joined(separator: ", ")
    }

    private var sheetHeight: CGFloat {
        min(1300, (NSScreen.main?.visibleFrame.height ?? 900) - 80)
    }

    private var nothingSaved: Bool {
        loaded && debugFiles.isEmpty && entries.values.allSatisfy(\.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(SavedLogKind.allCases) { kind in
                        SavedLogGroup(kind: kind, entries: entries[kind] ?? [], loaded: loaded,
                                      reload: { reload(kind) }, failure: $failure)
                    }
                    DebugLogsGroup(files: debugFiles, reload: reloadDebugFiles, failure: $failure)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Delete All Saved Logs\u{2026}", role: .destructive) { confirmEverything = true }
                    .disabled(nothingSaved)
                    .confirmationDialog("Delete every saved log?", isPresented: $confirmEverything) {
                        Button("Delete All", role: .destructive) { deleteEverything() }
                    } message: {
                        Text("This removes the eval captures, typing samples, suggestion outcomes, the dictation "
                             + "log and the debug logs. It can\u{2019}t be undone.")
                    }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 780, height: sheetHeight)
        .task { await reloadAll() }
    }

    private func reloadAll() async {
        let read = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: SavedLogKind.allCases.map { ($0, SavedLogs.entries($0)) })
        }.value
        entries = read
        reloadDebugFiles()
        loaded = true
    }

    private func reload(_ kind: SavedLogKind) {
        entries[kind] = SavedLogs.entries(kind)
    }

    private func reloadDebugFiles() {
        debugFiles = SavedLogs.debugLogFiles()
    }

    private func deleteEverything() {
        do {
            for kind in SavedLogKind.allCases { try SavedLogs.removeAll(kind) }
            for file in SavedLogs.debugLogFiles() { try SavedLogs.removeFile(file.url) }
            failure = nil
        } catch {
            failure = "Couldn\u{2019}t delete: \(error.localizedDescription)"
        }
        for kind in SavedLogKind.allCases { reload(kind) }
        reloadDebugFiles()
    }
}

/// One log type: its table, the selected entry in full, and its delete buttons.
private struct SavedLogGroup: View {
    let kind: SavedLogKind
    let entries: [SavedLogEntry]
    let loaded: Bool
    let reload: () -> Void
    @Binding var failure: String?
    @State private var selection = Set<SavedLogEntry.ID>()
    @State private var confirmAll = false

    private var selected: [SavedLogEntry] { entries.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title).font(.headline)
                Text(loaded ? (entries.isEmpty ? "none saved" : "\(kind.count(entries.count)) saved") : "Loading\u{2026}")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { reveal(kind.fileURL) }
            }
            Table(entries, selection: $selection) {
                TableColumn("Date") { entry in
                    if let date = entry.date {
                        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    } else {
                        Text("\u{2013}").foregroundStyle(.secondary)
                    }
                }.width(110)
                TableColumn("App") { entry in
                    Text(entry.app ?? "\u{2013}").foregroundStyle(entry.app == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                }.width(150)
                TableColumn("Entry") { entry in Text(entry.preview).lineLimit(1) }
                TableColumn("") { entry in
                    Button(role: .destructive) { delete([entry]) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete this entry")
                }.width(30)
            }
            .frame(height: 170)
            if selected.count == 1, let entry = selected.first {
                EntryDetail(entry: entry)
            }
            HStack {
                Button(selection.count > 1 ? "Delete \(selection.count) Selected" : "Delete Selected",
                       role: .destructive) { delete(selected) }
                    .disabled(selected.isEmpty)
                Button("Delete All\u{2026}", role: .destructive) { confirmAll = true }
                    .disabled(entries.isEmpty)
                    .confirmationDialog("Delete all \(kind.title.lowercased())?", isPresented: $confirmAll) {
                        Button("Delete All", role: .destructive) {
                            run { try SavedLogs.removeAll(kind) }
                        }
                    } message: {
                        Text("This removes \(kind.fileURL.lastPathComponent). It can\u{2019}t be undone.")
                    }
            }
        }
    }

    private func delete(_ chosen: [SavedLogEntry]) {
        let lines = Set(chosen.map(\.line))
        run { try SavedLogs.remove(lines: lines, from: kind) }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            failure = nil
        } catch {
            failure = "Couldn\u{2019}t delete: \(error.localizedDescription)"
        }
        selection = []
        reload()
    }
}

/// Every field of one entry, selectable so it can be copied.
private struct EntryDetail: View {
    let entry: SavedLogEntry

    var body: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                if let date = entry.date {
                    row("Date", date.formatted(date: .abbreviated, time: .standard))
                }
                ForEach(entry.fields, id: \.self) { field in row(field.name, field.value) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(height: 160)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The plain-text debug logs: name, size, Show in Finder, delete.
private struct DebugLogsGroup: View {
    let files: [DebugLogFile]
    let reload: () -> Void
    @Binding var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Debug logs").font(.headline)
                Text("timings, sizes and field details").foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { reveal(DrawDebugLog.logDirectory) }
            }
            if files.isEmpty {
                Text("None saved.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        HStack {
                            Text(file.name)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                            Button { reveal(file.url) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless).help("Show in Finder")
                            Button(role: .destructive) {
                                do {
                                    try SavedLogs.removeFile(file.url)
                                    failure = nil
                                } catch {
                                    failure = "Couldn\u{2019}t delete: \(error.localizedDescription)"
                                }
                                reload()
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete \(file.name)")
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        if file != files.last { Divider() }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
        }
    }
}

/// Selects the file in Finder, or opens its folder when it isn't there yet.
private func reveal(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
}
