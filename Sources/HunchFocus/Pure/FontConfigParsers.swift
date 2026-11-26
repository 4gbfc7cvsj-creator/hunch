import Foundation

/// A font as a host's own configuration names it, before it is matched against installed fonts.
public struct ConfiguredFont: Sendable, Equatable {
    /// Family names in the host's preference order; empty means the host's built-in default.
    public var families: [String]
    /// PostScript name, when the host stores one instead of a family (iTerm2).
    public var postScriptName: String?
    /// Point size as the host renders it (VS Code's window zoom already applied).
    public var size: Double
    /// Cell width ÷ glyph advance (iTerm2's horizontal spacing); 1 elsewhere.
    public var widthSpacing: Double
    public init(families: [String] = [], postScriptName: String? = nil, size: Double, widthSpacing: Double = 1) {
        self.families = families
        self.postScriptName = postScriptName
        self.size = size
        self.widthSpacing = widthSpacing
    }
}

/// What a family list resolves to on this system.
public enum FamilyChoice: Sendable, Equatable {
    /// An installed family, spelled as the system spells it.
    case installed(String)
    /// The CSS `monospace` / `ui-monospace` generics.
    case systemMonospaced
    /// Any other CSS generic (`sans-serif`, `system-ui`, ...).
    case system
}

/// Parsers for the font settings of hosts that report no font through accessibility (terminals) or
/// may not (Electron editors). They take file contents and preference values, never paths, so the
/// reading side stays in `HostFontConfigs` and these stay testable on strings. Missing or
/// unparseable input gives nil; keys a readable config leaves out take the host's documented default.
public enum FontConfigParsers {

    // MARK: Family resolution

    static let monospaceGenerics: Set<String> = ["monospace", "ui-monospace"]
    static let otherGenerics: Set<String> = ["serif", "sans-serif", "system-ui", "ui-sans-serif", "ui-serif",
                                             "ui-rounded", "cursive", "fantasy", "-apple-system",
                                             "blinkmacsystemfont"]

    /// First family that is installed (`installed` maps a name to the system's spelling, or nil),
    /// stopping at a CSS generic the way a browser does; nil when nothing in the list is usable.
    public static func resolveFamily(_ families: [String], installed: (String) -> String?) -> FamilyChoice? {
        for family in families {
            let key = family.lowercased()
            if monospaceGenerics.contains(key) { return .systemMonospaced }
            if otherGenerics.contains(key) { return .system }
            if let name = installed(family) { return .installed(name) }
        }
        return nil
    }

    // MARK: Ghostty

    /// Ghostty's font size when the config sets none (macOS).
    static let ghosttyDefaultSize = 13.0
    /// Ghostty's built-in face; it is embedded in the app, so it only matches when also installed.
    static let ghosttyDefaultFamily = "JetBrains Mono"
    /// Include nesting below the root files; deeper `config-file` entries are ignored.
    static let ghosttyMaxIncludeDepth = 4

    /// Ghostty's font from its config files. `roots` are absolute paths in load order (later files
    /// override earlier ones); `read` returns a file's contents or nil when it does not exist.
    /// `font-family` repeats as a fallback list, so the first one wins and an empty value resets the
    /// list; `font-size` takes the last value. `config-file` entries load after every file already
    /// queued (Ghostty processes them at the end of the file, appending to one list), relative to the
    /// including file, `?`-prefixed ones optional; cycles and nesting deeper than
    /// `ghosttyMaxIncludeDepth` are skipped. Nil when no root file is readable.
    public static func ghostty(roots: [String], home: String, read: (String) -> String?) -> ConfiguredFont? {
        var families: [String] = []
        var size: Double?
        var queue: [(path: String, depth: Int)] = roots.map { (standardized($0), 0) }
        var seen = Set<String>()
        var readAny = false
        var index = 0
        while index < queue.count {
            let (path, depth) = queue[index]
            index += 1
            guard seen.insert(path).inserted, let text = read(path) else { continue }
            if depth == 0 { readAny = true }
            for (key, value) in ghosttyEntries(text) {
                switch key {
                case "font-family":
                    let value = unquoted(value)
                    if value.isEmpty { families.removeAll() } else { families.append(value) }
                case "font-size":
                    let value = unquoted(value)
                    if value.isEmpty { size = nil } else if let v = Double(value), v > 0, v.isFinite { size = v }
                case "config-file":
                    guard depth < ghosttyMaxIncludeDepth else { continue }
                    var target = value
                    if target.hasPrefix("?") { target.removeFirst() }
                    target = unquoted(target)
                    guard !target.isEmpty else { continue }
                    queue.append((resolve(target, relativeTo: path, home: home), depth + 1))
                default:
                    continue
                }
            }
        }
        guard readAny else { return nil }
        return ConfiguredFont(families: families.isEmpty ? [ghosttyDefaultFamily] : families,
                              size: size ?? ghosttyDefaultSize)
    }

    /// `key = value` lines, values still quoted (a quoted `config-file` value keeps a literal leading
    /// `?`); `#` comments are valid only on their own line.
    static func ghosttyEntries(_ text: String) -> [(String, String)] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, value)
        }
    }

    static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    static func resolve(_ path: String, relativeTo file: String, home: String) -> String {
        if path.hasPrefix("/") { return standardized(path) }
        if path == "~" || path.hasPrefix("~/") { return standardized(home + path.dropFirst()) }
        let dir = (file as NSString).deletingLastPathComponent
        return standardized(dir + "/" + path)
    }

    /// Removes `.`, `..` and repeated slashes without touching the file system.
    static func standardized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: kitty

    /// kitty's size when `font_size` is unset.
    static let kittyDefaultSize = 11.0
    /// What kitty's default `monospace` resolves to on macOS.
    static let kittyDefaultFamily = "Menlo"

    /// kitty's font from `kitty.conf`: `font_family` and `font_size`, last value winning. The family
    /// is either a plain name or kitty's `family="Name" style=...` form; `monospace` and `auto` mean
    /// the default. `include` directives are not followed.
    public static func kitty(_ text: String) -> ConfiguredFont {
        var family: String?
        var size: Double?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let key = line.prefix { !$0.isWhitespace }
            let value = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            switch key {
            case "font_family":
                let name = kittyFamily(value)
                family = name.flatMap { ["monospace", "auto"].contains($0.lowercased()) ? nil : $0 }
            case "font_size":
                if let v = Double(value), v > 0, v.isFinite { size = v }
            default:
                continue
            }
        }
        return ConfiguredFont(families: [family ?? kittyDefaultFamily], size: size ?? kittyDefaultSize)
    }

    static func kittyFamily(_ value: String) -> String? {
        guard value.hasPrefix("family=") else { return value.isEmpty ? nil : value }
        let rest = value.dropFirst("family=".count)
        if let quote = rest.first, quote == "\"" || quote == "'" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: quote) else { return nil }
            let name = String(body[..<end])
            return name.isEmpty ? nil : name
        }
        let name = String(rest.prefix { !$0.isWhitespace })
        return name.isEmpty ? nil : name
    }

    // MARK: iTerm2

    /// iTerm2's profiles (`New Bookmarks`), the default profile (`Default Bookmark Guid`) first and
    /// the rest in their stored order. Each profile's `Normal Font` is "PostScriptName size" and its
    /// `Horizontal Spacing` scales the cell width. Profiles without a parseable font are dropped.
    public static func iTerm2(bookmarks: [[String: Any]], defaultGuid: String?) -> [ConfiguredFont] {
        let defaults = bookmarks.filter { defaultGuid != nil && $0["Guid"] as? String == defaultGuid }
        let others = bookmarks.filter { !(defaultGuid != nil && $0["Guid"] as? String == defaultGuid) }
        return (defaults + others).compactMap { profile in
            guard let spec = (profile["Normal Font"] as? String).flatMap(iTerm2FontSpec) else { return nil }
            let spacing = (profile["Horizontal Spacing"] as? NSNumber)?.doubleValue ?? 1
            return ConfiguredFont(postScriptName: spec.name, size: spec.size,
                                  widthSpacing: spacing > 0 && spacing.isFinite ? spacing : 1)
        }
    }

    /// "MesloLGS-NF-Regular 13" → ("MesloLGS-NF-Regular", 13): the name, a space, then the size.
    static func iTerm2FontSpec(_ spec: String) -> (name: String, size: Double)? {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.lastIndex(of: " ") else { return nil }
        let name = trimmed[..<space].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let size = Double(trimmed[trimmed.index(after: space)...]), size > 0, size.isFinite
        else { return nil }
        return (name, size)
    }

    // MARK: VS Code family

    /// VS Code's macOS default for `editor.fontSize`, and its accepted range.
    static let vsCodeDefaultSize = 12.0
    static let vsCodeSizeRange = 6.0...100.0
    static let vsCodeDefaultFamily = "Menlo, Monaco, 'Courier New', monospace"

    /// The editor font from a VS Code-style `settings.json` (JSON with comments and trailing commas):
    /// `editor.fontFamily` as a CSS family list, `editor.fontSize` scaled by 1.2^`window.zoomLevel`,
    /// as Electron zooms. Nil when the text is not a JSON object.
    public static func vsCode(settings text: String) -> ConfiguredFont? {
        guard let data = stripJSONC(text).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any] else { return nil }
        let familyList = (settings["editor.fontFamily"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? vsCodeDefaultFamily
        var size = number(settings["editor.fontSize"]) ?? vsCodeDefaultSize
        size = size > 0 ? min(max(size, vsCodeSizeRange.lowerBound), vsCodeSizeRange.upperBound) : vsCodeDefaultSize
        let zoom = number(settings["window.zoomLevel"]) ?? 0
        return ConfiguredFont(families: cssFamilies(familyList), size: size * pow(1.2, zoom))
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = value as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
        return nil
    }

    /// Splits a CSS `font-family` list on commas outside quotes and unwraps quoted names.
    static func cssFamilies(_ list: String) -> [String] {
        var families: [String] = []
        var current = ""
        var quote: Character?
        for ch in list {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "," {
                families.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        families.append(current)
        return families.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Drops `//` and `/* */` comments and commas before a closing `}` or `]`, leaving strings
    /// untouched, so `JSONSerialization` accepts VS Code's JSONC. An unclosed block comment or string
    /// runs to the end (the result then fails to parse).
    static func stripJSONC(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), dq = UInt8(ascii: "\""), bs = UInt8(ascii: "\\")
        var i = 0
        var inString = false
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                out.append(b)
                if b == bs, i + 1 < bytes.count { out.append(bytes[i + 1]); i += 2; continue }
                if b == dq { inString = false }
                i += 1
            } else if b == dq {
                inString = true
                out.append(b)
                i += 1
            } else if b == slash, i + 1 < bytes.count, bytes[i + 1] == slash {
                while i < bytes.count, bytes[i] != UInt8(ascii: "\n") { i += 1 }
            } else if b == slash, i + 1 < bytes.count, bytes[i + 1] == star {
                i += 2
                while i < bytes.count, !(bytes[i] == star && i + 1 < bytes.count && bytes[i + 1] == slash) { i += 1 }
                i += 2
                out.append(UInt8(ascii: " "))
            } else {
                out.append(b)
                i += 1
            }
        }
        // Trailing commas: comments are gone, so only whitespace can sit between ',' and the closer.
        var result: [UInt8] = []
        result.reserveCapacity(out.count)
        inString = false
        var j = 0
        while j < out.count {
            let b = out[j]
            if inString {
                result.append(b)
                if b == bs, j + 1 < out.count { result.append(out[j + 1]); j += 2; continue }
                if b == dq { inString = false }
            } else if b == dq {
                inString = true
                result.append(b)
            } else if b == UInt8(ascii: ",") {
                var k = j + 1
                while k < out.count, [0x20, 0x09, 0x0A, 0x0D].contains(out[k]) { k += 1 }
                if k < out.count, out[k] == UInt8(ascii: "}") || out[k] == UInt8(ascii: "]") {
                    j += 1
                    continue
                }
                result.append(b)
            } else {
                result.append(b)
            }
            j += 1
        }
        return String(decoding: result, as: UTF8.self)
    }
}
