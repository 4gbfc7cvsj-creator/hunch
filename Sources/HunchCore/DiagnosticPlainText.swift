import Foundation

extension DiagnosticRecord {
    /// The entry as plain text for the Copy button: what went in, the prompt, what came out.
    public func plainText(prompt includePrompt: Bool = true) -> String {
        var out: [String] = []
        let time = date.formatted(date: .abbreviated, time: .standard)
        out.append("Hunch diagnostic entry: \(kind.title), \(placeSummary), \(time)")
        if let model { out.append("Model: \(model)") }
        out.append("")
        out.append("== What went in ==")
        for section in sections {
            out.append("")
            out.append("[\(section.title)]")
            if section.items.isEmpty { out.append("(none)") }
            for item in section.items {
                out.append(item.label.map { "\($0): \(item.text)" } ?? item.text)
            }
        }
        if includePrompt, let prompt {
            out.append("")
            out.append("== Full prompt, exactly as the model received it ==")
            out.append(prompt.fullText)
            if !prompt.requiredPrefix.isEmpty { out.append("[the model had to start with: \(prompt.requiredPrefix.debugDescription)]") }
        }
        out.append("")
        out.append("== What came out ==")
        if let output {
            if output.hasScores {
                out.append(output.laidOutText)
                out.append(DiagnosticWords.ruleDescription)
            } else {
                out.append(output.text.isEmpty ? "(no text)" : output.text)
                if kind != .suggestion || servePath == ServePath.cache.rawValue {
                    out.append("No per-word confidence is available for this entry.")
                }
            }
            for cut in output.cuts { out.append("✂ after word \(cut.afterWords): \(cut.reason.text)") }
            if let stop = output.stopText { out.append(stop) }
            if !output.alternatives.isEmpty { out.append("Alternatives: " + output.alternatives.joined(separator: " | ")) }
        } else {
            out.append("(nothing generated)")
        }
        if kind == .suggestion { out.append("Shown to you: \(fate.text)") }
        if kind == .suggestedReplies { out.append("What happened: \(fate.text)") }
        if let note { out.append(note) }
        out.append("")
        out.append("== Time and size ==")
        var facts: [String] = []
        if let total = timing.totalMs { facts.append(String(format: "total %.0f ms", total)) }
        if let framing = timing.framingMs { facts.append(String(format: "framing %.1f ms", framing)) }
        if let sync = timing.promptSyncMs { facts.append(String(format: "prompt sync %.0f ms", sync)) }
        if let first = timing.firstWordsMs { facts.append(String(format: "first words %.0f ms", first)) }
        if let prompt {
            facts.append("prompt \(prompt.promptTokens) tokens"
                + (prompt.reusedTokens.map { " (\($0) reused)" } ?? ""))
        }
        if let tokens = output?.generatedTokens, tokens > 0 { facts.append("generated \(tokens) tokens") }
        if let servePath { facts.append("served: \(servePath)") }
        out.append(facts.isEmpty ? "(none)" : facts.joined(separator: ", "))
        return out.joined(separator: "\n")
    }
}

extension DiagnosticOutput {
    /// The words with their percentages, a ✂ at each cut, in one line of text.
    public var laidOutText: String {
        var parts: [String] = []
        for (index, word) in words.enumerated() {
            for cut in cuts where cut.afterWords == index { parts.append("✂") }
            let percent = word.probability.map { String(format: "%.0f%%", Double($0) * 100) } ?? "?"
            parts.append("\(word.text.trimmingCharacters(in: .whitespacesAndNewlines))[\(percent)]")
        }
        for cut in cuts where cut.afterWords >= words.count { parts.append("✂") }
        return parts.joined(separator: " ")
    }
}
