import Foundation
import HunchCore

/// Budget priorities shared by both framers (design §5.1, lower = kept first).
enum BlockPriority: Int, Comparable {
    case instruction = 2, appInstructions = 3, afterCaret = 4, writer = 5, place = 6, style = 7, screen = 8, clipboard = 9
    static func < (lhs: BlockPriority, rhs: BlockPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One piece of a prompt layout, in layout order.
enum LayoutItem {
    /// Always present (chat markers, separators). Never truncated, never split.
    case fixed(PromptSegment)
    /// Optional block: `prefix` and `suffix` are framer-authored, `content` is user-derived.
    case block(Block)
    /// The healed before-caret text. Must be the last item.
    case caret
}

struct Block {
    enum Keep { case start, end, whole }
    var prefix: String
    var content: String
    var suffix: String
    var priority: BlockPriority
    var stability: SegmentStability
    var keep: Keep = .start
    var maxContentTokens: Int?

    /// Debug-log name: the priority, plus the block's own heading ("writer: About the writer").
    var label: String {
        let heading = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map { String($0.prefix(32)) } ?? ""
        return heading.isEmpty ? "\(priority)" : "\(priority): \(heading)"
    }

    /// Rendered text and its cost if it fits in `available` tokens, truncating content at a word
    /// boundary when allowed. Nil when the block does not fit meaningfully.
    func fitted(available: Int, counter: any TokenCounting) -> (text: String, cost: Int)? {
        fittedDetail(available: available, counter: counter).map { ($0.text, $0.cost) }
    }

    /// Friendly name for the diagnostic console's "left out" notes.
    var displayName: String {
        let heading = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map { String($0.prefix(48)) } ?? ""
        let tidy = heading.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        switch priority {
        case .screen: return "Screen context"
        case .clipboard: return "Clipboard"
        case .style: return "Earlier sentences"
        case .afterCaret: return tidy.isEmpty ? "Text after the caret" : "Text after the caret (\(tidy))"
        case .appInstructions: return "Notes for this app"
        case .place: return "Place of writing"
        case .writer, .instruction: return tidy.isEmpty ? "\(priority)" : tidy
        }
    }

    /// `fitted` plus whether the content was shortened to fit.
    func fittedDetail(available: Int, counter: any TokenCounting) -> (text: String, cost: Int, truncated: Bool)? {
        if keep == .whole {
            let text = prefix + content + suffix
            let cost = counter.tokenCount(text)
            return cost <= available ? (text, cost, false) : nil
        }
        let overhead = counter.tokenCount(prefix + suffix)
        var room = available - overhead
        if let cap = maxContentTokens { room = min(room, cap) }
        guard room >= 4 else { return nil }
        let body = keep == .start
            ? Budget.head(content, maxTokens: room, counter: counter)
            : Budget.tail(content, maxTokens: room, counter: counter)
        guard !body.isEmpty else { return nil }
        let text = prefix + body + suffix
        let cost = counter.tokenCount(text)
        let trailing = content.utf8.reversed().prefix { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }.count
        return cost <= available ? (text, cost, body.utf8.count < content.utf8.count - trailing) : nil
    }
}

/// Allocates the token budget across a layout and renders segments in layout order.
enum FrameAssembler {
    /// Guaranteed share of the before-caret tail (counted from its end), §5.1 priority 1.
    static let minimumCaretTokens = 256

    static func assemble(layout: [LayoutItem], caretText: String, budget: Int,
                         counter: any TokenCounting) -> [PromptSegment] {
        assembleNoted(layout: layout, caretText: caretText, budget: budget, counter: counter).segments
    }

    /// `assemble`, plus a note for each block the budget dropped or shortened (the diagnostic
    /// console shows them; they change nothing about the prompt).
    static func assembleNoted(layout: [LayoutItem], caretText: String, budget: Int,
                              counter: any TokenCounting) -> (segments: [PromptSegment], notes: [BudgetNote]) {
        var notes: [BudgetNote] = []
        var remaining = budget
        for case .fixed(let segment) in layout { remaining -= counter.tokenCount(segment.text) }

        // 1. Healed before-caret tail, minimum share.
        var caret = Budget.tail(caretText, maxTokens: max(0, min(minimumCaretTokens, remaining)), counter: counter)
        var caretCost = counter.tokenCount(caret)
        remaining -= caretCost

        // 2-6. Optional blocks by priority (stable sort keeps layout order within a priority).
        var rendered: [Int: String] = [:]
        let blocks = layout.enumerated().compactMap { index, item -> (Int, Block)? in
            if case .block(let block) = item { return (index, block) }
            return nil
        }
        let ordered = blocks.enumerated().sorted { lhs, rhs in
            lhs.element.1.priority != rhs.element.1.priority
                ? lhs.element.1.priority < rhs.element.1.priority : lhs.offset < rhs.offset
        }.map(\.element)
        for (index, block) in ordered {
            guard let fit = block.fittedDetail(available: remaining, counter: counter) else {
                notes.append(BudgetNote(name: block.displayName, kind: .dropped, detail: "no room left in the token budget"))
                continue
            }
            if fit.truncated {
                notes.append(BudgetNote(name: block.displayName, kind: .cut, detail: "only part of it fit the token budget"))
            }
            rendered[index] = fit.text
            remaining -= fit.cost
        }

        // 7. Older before-caret text with whatever is left.
        if remaining > 0, caret.count < caretText.count {
            caret = Budget.tail(caretText, maxTokens: caretCost + remaining, counter: counter)
            caretCost = counter.tokenCount(caret)
        }

        if caret.utf8.count < caretText.utf8.count {
            notes.append(BudgetNote(name: "Text before the caret", kind: .cut,
                                    detail: "kept the last \(caretCost) tokens; the earlier text did not fit"))
        }
        var segments: [PromptSegment] = []
        for (index, item) in layout.enumerated() {
            switch item {
            case .fixed(let segment):
                segments.append(segment)
            case .block(let block):
                if let text = rendered[index] {
                    segments.append(PromptSegment(text: text, kind: .content, stability: block.stability,
                                                  label: block.label))
                }
            case .caret:
                segments.append(PromptSegment(text: caret, kind: .content, stability: .perKeystroke, label: "text"))
            }
        }
        return (segments, notes)
    }
}

/// Short noun phrase for the kind of text being written, or nil when unknown. For source code
/// the (opted-in) window title adds the language and file name when it names a file.
func surfacePhrase(_ surface: SurfaceKind, windowTitle: String? = nil) -> String? {
    if surface == .code, let hint = CodeFileHint.describe(windowTitle: windowTitle) {
        return "source code (\(hint))"
    }
    switch surface {
    case .email: return "an email"
    case .chat: return "a chat message"
    case .document: return "a document"
    case .note: return "a note"
    case .search: return "a search query"
    case .form: return "a form entry"
    case .code: return "source code"
    case .terminal: return "a shell command"
    case .agentPrompt: return "a request to a coding agent"
    case .shell: return "a command at a terminal's shell prompt"
    case .unknown: return nil
    }
}

/// "en", "zh-Hans" → "English", "Chinese (Simplified)"; already-readable names pass through.
func languageList(_ languages: [String]) -> String? {
    let english = Locale(identifier: "en_US")
    let names = languages.compactMap { cleaned($0) }.map { item -> String in
        let looksLikeCode = item.count <= 10 && item.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-" || $0 == "_") }
            && item.first?.isLowercase == true
        guard looksLikeCode, let name = english.localizedString(forIdentifier: item) else { return item }
        return name
    }
    return names.isEmpty ? nil : names.joined(separator: ", ")
}

/// Clipboard background text for a prompt block: trimmed, capped at `clipboardCharLimit` characters
/// (cut at a word boundary, keeping the beginning), and nil when empty or already present in the
/// text before or after the caret.
func clipboardBackground(_ input: PromptInput) -> String? {
    guard let clip = cleaned(input.clipboard) else { return nil }
    if input.before.contains(clip) || input.after.contains(clip) { return nil }
    guard clip.count > clipboardCharLimit else { return clip }
    let chars = Array(clip)
    let cut = Budget.cutPoints(chars).last(where: { $0 > 0 && $0 <= clipboardCharLimit }) ?? clipboardCharLimit
    let head = String(chars[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    return head.isEmpty ? nil : head
}

/// Longest clipboard excerpt (characters) a framer will include.
let clipboardCharLimit = 600
/// Token cap for the clipboard block, on top of the character limit.
let clipboardTokenLimit = 160

/// Longest single style example (characters) a framer will include.
let styleExampleCharLimit = 200
/// At most this many style examples are framed.
let styleExampleMaxCount = 4
/// Token cap for the whole style block.
let styleTokenLimit = 120

/// The style-example block body: each example trimmed, whitespace-collapsed, capped at
/// `styleExampleCharLimit` characters (at a word boundary), wrapped in curly quotes. Whole examples are
/// added in order while the block stays within `styleTokenLimit` tokens. Nil when nothing usable remains.
func styleBackground(_ input: PromptInput, counter: any TokenCounting) -> String? {
    var quoted: [String] = []
    for raw in input.styleExamples.prefix(styleExampleMaxCount) {
        var text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty { continue }
        if text.count > styleExampleCharLimit {
            let chars = Array(text)
            let cut = Budget.cutPoints(chars).last(where: { $0 > 0 && $0 <= styleExampleCharLimit }) ?? styleExampleCharLimit
            text = String(chars[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        text = text.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        let candidate = quoted + ["\u{201C}\(text)\u{201D}"]
        if counter.tokenCount(candidate.joined(separator: " ")) > styleTokenLimit {
            if quoted.isEmpty { continue }
            break
        }
        quoted = candidate
    }
    return quoted.isEmpty ? nil : quoted.joined(separator: " ")
}

/// Longest window title (characters) kept in the "where it was written" block.
let placeTitleLimit = 80

/// Compact form for comparing names: lowercase letters and digits only.
private func compactName(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
}

/// Where the text is being written, from the app name, website, (opted-in) window title and the
/// field's label or placeholder, e.g. `Discord (discord.com), window “#general”, field “Message #general”`.
/// A field label that repeats the app name or window title is dropped; it is capped like a title. Nil when nothing usable is given. Values are trimmed and
/// whitespace-collapsed; a title is capped at `placeTitleLimit` characters at a word boundary and skipped
/// when it only repeats the app name; a domain that repeats the app name is dropped.
func placeDescription(appName: String?, domain: String?, windowTitle: String?, field: String? = nil) -> String? {
    func tidy(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
    let app = tidy(appName)
    var site = tidy(domain)
    var title = tidy(windowTitle)
    if let s = site, let a = app {
        let cs = compactName(s), ca = compactName(a)
        if !ca.isEmpty, cs.contains(ca) || (!cs.isEmpty && ca.contains(cs)) { site = nil }
    }
    if let t = title {
        let ct = compactName(t)
        if ct.isEmpty || ct == compactName(app ?? "") { title = nil }
    }
    var label = tidy(field)
    if let l = label {
        let cl = compactName(l)
        if cl.isEmpty || cl == compactName(app ?? "") || cl == compactName(title ?? "") { label = nil }
    }
    func capped(_ t: String) -> String {
        guard t.count > placeTitleLimit else { return t }
        let cut = String(t.prefix(placeTitleLimit))
        // Keep whole words: back up to the last space unless the cut already fell on a boundary.
        let atBoundary = t[t.index(t.startIndex, offsetBy: placeTitleLimit)] == " "
        var kept = cut
        if !atBoundary, let space = cut.lastIndex(of: " ") { kept = String(cut[..<space]) }
        return kept.trimmingCharacters(in: .whitespaces) + "…"
    }
    title = title.map(capped)
    label = label.map(capped)
    var text = app ?? ""
    if let site {
        text += text.isEmpty ? site : " (\(site))"
    }
    if let title {
        text += (text.isEmpty ? "window “\(title)”" : ", window “\(title)”")
    }
    if let label {
        text += (text.isEmpty ? "field “\(label)”" : ", field “\(label)”")
    }
    return text.isEmpty ? nil : text
}

/// The file an editor window shows, from its title ("● main.swift — project — Cursor",
/// "Hunch — Seeds.swift"): the first word with a file extension, and the language that
/// extension stands for when it is a known one.
enum CodeFileHint {
    static let languages: [String: String] = [
        "swift": "Swift", "ts": "TypeScript", "tsx": "TypeScript", "mts": "TypeScript", "js": "JavaScript",
        "jsx": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript", "py": "Python", "sh": "shell script",
        "bash": "shell script", "zsh": "shell script", "fish": "shell script", "rb": "Ruby", "go": "Go",
        "rs": "Rust", "java": "Java", "kt": "Kotlin", "kts": "Kotlin", "c": "C", "h": "C", "cpp": "C++",
        "cc": "C++", "hpp": "C++", "m": "Objective-C", "mm": "Objective-C", "cs": "C#", "php": "PHP",
        "html": "HTML", "css": "CSS", "scss": "SCSS", "json": "JSON", "yaml": "YAML", "yml": "YAML",
        "toml": "TOML", "md": "Markdown", "sql": "SQL", "xml": "XML", "lua": "Lua", "dart": "Dart",
        "scala": "Scala", "ex": "Elixir", "exs": "Elixir", "hs": "Haskell", "zig": "Zig", "vue": "Vue",
        "svelte": "Svelte", "proto": "Protocol Buffers", "graphql": "GraphQL", "tf": "Terraform",
    ]
    /// Leading marks editors put in front of a modified file's name.
    static let marks: Set<Character> = ["●", "•", "*", "◆", "(", "["]
    static let trailing: Set<Character> = [")", "]", ",", ":", ";"]

    /// The first token of `title` shaped like a file name ("name.ext"), with its extension.
    static func fileName(in title: String) -> (name: String, ext: String)? {
        for raw in title.split(whereSeparator: \.isWhitespace) {
            var token = Substring(raw)
            while let f = token.first, marks.contains(f) { token = token.dropFirst() }
            while let l = token.last, trailing.contains(l) { token = token.dropLast() }
            guard let dot = token.lastIndex(of: "."), dot > token.startIndex, token.index(after: dot) < token.endIndex
            else { continue }
            let ext = token[token.index(after: dot)...]
            guard ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }), ext.contains(where: \.isLetter)
            else { continue }
            let stem = token[..<dot]
            guard stem.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { continue }
            return (String(token), ext.lowercased())
        }
        return nil
    }

    /// "Swift, in main.swift", "in notes.txt", or nil when the title names no file.
    static func describe(windowTitle: String?) -> String? {
        guard let title = windowTitle, let file = fileName(in: title) else { return nil }
        if let language = languages[file.ext] { return "\(language), in \(file.name)" }
        return "in \(file.name)"
    }
}
