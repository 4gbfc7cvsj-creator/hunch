// Eval config and phrase file formats (Hunch's own).
import Foundation
import HunchCore

struct EvalConfig: Sendable {
    var name: String
    /// "auto" or a framer id such as "document-v1" / "chat-prefill-v1".
    var framer: String
    var length: LengthPreset
    var decode: DecodeConfig
    var promptTokenBudget: Int
    var customInstructionsFile: String?
    /// nil = trust the loaded vocabulary.
    var addBOS: Bool?
    var postConfidenceFloor: Float?
    /// Screen lines kept per case, newest (last) first, as the app's former 1500-character cap did.
    /// nil = the whole screen text (the framer's token budget trims it).
    var screenCharLimit: Int? = nil

    var framerOverride: String? { framer == "auto" ? nil : framer }

    /// Reads the user's instructions at runtime. The text is never printed or stored.
    func loadInstructions() throws -> String? {
        guard let path = customInstructionsFile, !path.isEmpty else { return nil }
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
            throw EvalError("config \(name): cannot read customInstructionsFile at \(path)")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func load(path: String) throws -> EvalConfig {
        guard let data = FileManager.default.contents(atPath: path) else { throw EvalError("cannot read config \(path)") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EvalError("config \(path): top level must be an object")
        }
        return try parse(root, fallbackName: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }

    static func parse(_ root: [String: Any], fallbackName: String) throws -> EvalConfig {
        let known: Set<String> = ["name", "framer", "length", "decode", "promptTokenBudget", "customInstructionsFile",
                                  "addBOS", "postConfidenceFloor", "screenCharLimit"]
        if let unknown = root.keys.first(where: { !known.contains($0) }) {
            throw EvalError("config \(fallbackName): unknown key '\(unknown)'")
        }
        let lengthRaw = (root["length"] as? String) ?? "medium"
        guard let length = LengthPreset(rawValue: lengthRaw) else {
            throw EvalError("config \(fallbackName): unknown length '\(lengthRaw)'")
        }
        var decode = DecodeConfig()
        decode.minWords = length.minWords
        decode.maxWords = length.maxWords
        decode.maxTokens = max(decode.maxTokens, length.maxTokens)
        decode.holdEndBelowMinWords = length.holdsEnd
        if let overrides = root["decode"] as? [String: Any], !overrides.isEmpty {
            decode = try applyOverrides(overrides, to: decode, configName: fallbackName)
        }
        return EvalConfig(
            name: (root["name"] as? String) ?? fallbackName,
            framer: (root["framer"] as? String) ?? "auto",
            length: length,
            decode: decode,
            promptTokenBudget: (root["promptTokenBudget"] as? Int) ?? 1024,
            customInstructionsFile: root["customInstructionsFile"] as? String,
            addBOS: root["addBOS"] as? Bool,
            postConfidenceFloor: (root["postConfidenceFloor"] as? NSNumber).map { $0.floatValue },
            screenCharLimit: root["screenCharLimit"] as? Int)
    }

    static func applyOverrides(_ overrides: [String: Any], to base: DecodeConfig, configName: String) throws -> DecodeConfig {
        let encoded = try JSONEncoder().encode(base)
        guard var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw EvalError("internal: DecodeConfig did not encode to an object")
        }
        for (key, value) in overrides {
            guard dict[key] != nil else { throw EvalError("config \(configName): unknown decode key '\(key)'") }
            dict[key] = value
        }
        do {
            return try JSONDecoder().decode(DecodeConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        } catch {
            throw EvalError("config \(configName): invalid decode override (\(error))")
        }
    }
}

struct Phrase: Codable, Sendable {
    var id: String
    var tags: [String]
    var before: String
    var after: String?
    var surface: SurfaceKind
    /// Optional where-it-is-written context passed to the framer (appName / domain).
    var app: String?
    var domain: String?
    /// Optional "about the writer" facts (e.g. "Name: Ann Lee."), as the app sends with personal info on.
    var about: String?
    /// Optional screen-context lines (web addresses are removed as the app does).
    var screen: String?
    /// Optional clipboard excerpt and per-app instructions, for worst-case (every setting on) cases.
    var clipboard: String?
    var appInstructions: String?
    var expect: [String]?
    var aiTrap: Bool
}

func loadPhrases(path: String) throws -> [Phrase] {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
        throw EvalError("cannot read phrases file \(path)")
    }
    var out: [Phrase] = []
    var seen = Set<String>()
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        do {
            let phrase = try JSONDecoder().decode(Phrase.self, from: Data(trimmed.utf8))
            guard seen.insert(phrase.id).inserted else { throw EvalError("duplicate id \(phrase.id)") }
            out.append(phrase)
        } catch {
            throw EvalError("\(path) line \(index + 1): \(error)")
        }
    }
    return out
}
