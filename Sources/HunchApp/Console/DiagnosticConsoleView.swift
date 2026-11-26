import AppKit
import HunchCore
import SwiftUI

/// The console: the last requests on the left, the open one on the right.
struct DiagnosticConsoleView: View {
    let model: DiagnosticConsoleModel

    var body: some View {
        Group {
            if model.entries.isEmpty {
                ConsoleEmptyState()
            } else {
                HSplitView {
                    EntryList(model: model)
                        .frame(minWidth: 240, idealWidth: 290, maxWidth: 420)
                    Group {
                        if let entry = model.selected {
                            EntryDetail(entry: entry)
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ConsoleEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Console open, nothing recorded yet.")
                .font(.headline)
            Text("Type in another app, dictate, or use Write for me: each model request appears here as it finishes. "
                 + "If the model was released while idle, the first request wakes it, so the first entry can take a moment. "
                 + "Entries are kept in memory only, and are thrown away when you close this window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: List

private struct EntryList: View {
    let model: DiagnosticConsoleModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selected?.id }, set: { if let id = $0 { model.select(id) } })) {
                ForEach(model.entries) { entry in
                    EntryRow(entry: entry).tag(entry.id)
                }
            }
            .listStyle(.inset)
            Divider()
            Text(model.isFollowingNewest
                 ? "Following the newest request. Last \(DiagnosticRecorder.defaultCapacity) are kept."
                 : "Showing an older request. Pick the top one to follow the newest again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}

private struct EntryRow: View {
    let entry: DiagnosticRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                Spacer()
                Text(entry.kind.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .font(.caption)
            Text(entry.placeSummary)
                .font(.callout)
                .lineLimit(1)
            Text(entry.outcomeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Detail

private struct EntryDetail: View {
    let entry: DiagnosticRecord
    private enum Tab: String, CaseIterable, Identifiable {
        case details = "Overview", prompt = "Full prompt"
        var id: String { rawValue }
    }
    @State private var tab = Tab.details
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .details: details
                    case .prompt: PromptView(entry: entry)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.kind.title) · \(entry.placeSummary)")
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.plainText(), forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .help("Puts this entry on the clipboard as plain text")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            TimeAndSize(entry: entry)
            OutputView(entry: entry)
            VStack(alignment: .leading, spacing: 14) {
                Text("What went in")
                    .font(.title3.weight(.semibold))
                ForEach(entry.sections) { SectionView(section: $0) }
            }
        }
    }
}

private struct TimeAndSize: View {
    let entry: DiagnosticRecord

    var body: some View {
        let facts = lines
        if !facts.isEmpty {
            Text(facts.joined(separator: "  ·  "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var lines: [String] {
        var facts: [String] = []
        let t = entry.timing
        if let total = t.totalMs { facts.append(String(format: "took %.0f ms", total)) }
        if let first = t.firstWordsMs { facts.append(String(format: "first words %.0f ms", first)) }
        if let framing = t.framingMs, framing > 0 { facts.append(String(format: "framing %.1f ms", framing)) }
        if let sync = t.promptSyncMs, sync > 0 { facts.append(String(format: "prompt sync %.0f ms", sync)) }
        if let prompt = entry.prompt {
            var text = "prompt \(prompt.promptTokens) tokens"
            if let budget = prompt.budget { text += " of \(budget)" }
            if let reused = prompt.reusedTokens, reused > 0 { text += ", \(reused) reused" }
            facts.append(text)
        }
        if let generated = entry.output?.generatedTokens, generated > 0 { facts.append("wrote \(generated) tokens") }
        if let path = entry.servePath { facts.append("served: \(path)") }
        return facts
    }
}

// MARK: What went in

private struct SectionView: View {
    let section: DiagnosticSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
            if section.items.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 1) {
                        if let label = item.label {
                            Text(label).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Full prompt

private struct PromptView: View {
    let entry: DiagnosticRecord

    var body: some View {
        if let prompt = entry.prompt {
            VStack(alignment: .leading, spacing: 8) {
                Text("The prompt exactly as the model received it, after redaction. Framer text is dimmed; text from you, the field or the screen is in full colour.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(prompt.framerName + " · \(prompt.promptTokens) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(attributed(prompt))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                if !prompt.requiredPrefix.isEmpty {
                    Text("The model had to start with: \(prompt.requiredPrefix.debugDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(entry.note ?? "There is no prompt for this entry.")
                .foregroundStyle(.secondary)
        }
    }

    private func attributed(_ prompt: DiagnosticPrompt) -> AttributedString {
        var result = AttributedString()
        for segment in prompt.segments {
            var piece = AttributedString(segment.text)
            piece.foregroundColor = segment.isControl || segment.label == nil ? .secondary : .primary
            result += piece
        }
        return result
    }
}

// MARK: What came out

private struct OutputView: View {
    let entry: DiagnosticRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What came out")
                .font(.title3.weight(.semibold))
            if let output = entry.output, !output.text.isEmpty {
                if output.hasScores {
                    FlowLayout(spacing: 4, lineSpacing: 8) {
                        ForEach(cells(output)) { cell in
                            switch cell.kind {
                            case .word(let word, let dimmed):
                                WordCell(word: word, dimmed: dimmed)
                            case .cut(let reason):
                                CutCell(reason: reason)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                } else {
                    Text(output.text)
                        .font(.system(.body, design: .default))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    if entry.kind != .suggestion {
                        Text("Dictation cleanup and Write for me keep no per-token scores, so there are no percentages here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let stop = output.stopText {
                    Text(stop).font(.callout)
                }
                if output.hasScores {
                    Text(DiagnosticWords.ruleDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !output.alternatives.isEmpty {
                    Text("Other options it wrote: " + output.alternatives.map { "“\($0.trimmingCharacters(in: .whitespaces))”" }
                        .joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("The model wrote nothing for this request.")
                    .foregroundStyle(.secondary)
            }
            if entry.kind == .suggestion {
                Text("\(Text("Shown to you: ").fontWeight(.semibold))\(entry.fate.text)")
                    .textSelection(.enabled)
            }
            if entry.kind == .suggestedReplies {
                Text("\(Text("What happened: ").fontWeight(.semibold))\(entry.fate.text)")
                    .textSelection(.enabled)
            }
            if let note = entry.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct Cell: Identifiable {
        enum Kind {
            case word(DiagnosticWord, dimmed: Bool)
            case cut(CutReason)
        }
        let id: Int
        let kind: Kind
    }

    /// Words with a ✂ cell at each cut; words from the first cut on are dimmed.
    private func cells(_ output: DiagnosticOutput) -> [Cell] {
        var cells: [Cell] = []
        let firstCut = output.firstCutAfterWord ?? Int.max
        func addCuts(at index: Int) {
            for cut in output.cuts where cut.afterWords == index {
                cells.append(Cell(id: cells.count, kind: .cut(cut.reason)))
            }
        }
        for (index, word) in output.words.enumerated() {
            addCuts(at: index)
            cells.append(Cell(id: cells.count, kind: .word(word, dimmed: index >= firstCut)))
        }
        addCuts(at: output.words.count)
        return cells
    }
}

private struct WordCell: View {
    let word: DiagnosticWord
    let dimmed: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(word.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.body, design: .default))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(tint, in: RoundedRectangle(cornerRadius: 4))
            Text(percent)
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .opacity(dimmed ? 0.35 : 1)
        .textSelection(.enabled)
    }

    private var percent: String {
        guard let p = word.probability else { return "?" }
        let value = Double(p) * 100
        return value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    /// Strong confidence is green, weak is red, in between amber; translucent so the text stays
    /// readable in light and dark mode.
    private var tint: Color {
        guard let p = word.probability else { return Color.gray.opacity(0.2) }
        let level = min(max((Double(p) - 0.1) / 0.8, 0), 1)
        return Color(hue: 0.33 * level, saturation: 0.75, brightness: 0.9).opacity(0.32)
    }
}

private struct CutCell: View {
    let reason: CutReason

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("✂")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(reason.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    }
}

// MARK: Flow layout

/// Lays subviews out left to right, wrapping to a new line when the row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for item in rows.items {
            subviews[item.index].place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                                       proposal: ProposedViewSize(item.size))
        }
    }

    private struct Arrangement {
        var items: [(index: Int, origin: CGPoint, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> Arrangement {
        var result = Arrangement()
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            result.items.append((index, CGPoint(x: x, y: y), size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            result.width = max(result.width, x - spacing)
        }
        result.height = y + rowHeight
        return result
    }
}
