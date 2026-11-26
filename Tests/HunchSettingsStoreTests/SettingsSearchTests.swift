import Foundation
import Testing
import HunchCore
@testable import HunchSettingsStore

@Suite struct SettingsSearchTests {
    private func titles(_ q: String) -> [String] { SettingsSearch.search(q).map(\.title) }

    @Test func titleStartRanksFirst() {
        let sugg = titles("sugg")
        #expect(sugg.prefix(5).allSatisfy { $0.hasPrefix("Sugg") })
        #expect(sugg.prefix(5).contains("Suggestions"))
        #expect(titles("length").first == "Suggestion length")
    }

    @Test func keywordsFindSettings() {
        #expect(titles("hotkey").contains("Accept next word"))
        #expect(titles("gpu").contains("Dynamic Power Mode"))
        #expect(titles("llm").contains("Language Model"))
        #expect(titles("whisper").contains("Speech to Text"))
    }

    @Test func everyWordMustMatch() {
        #expect(titles("emoji skin").first == "Skin tone")
        #expect(titles("emoji zebra").isEmpty)
    }

    @Test func caseAndAccentsIgnored() {
        #expect(titles("SMART").isEmpty) // only an Apps & Sites setting is called that
        #expect(SettingsSearch.score("ÉMOJI", title: "Emoji suggestions") != nil)
    }

    @Test func shortWordsMatchOnlyAtWordStarts() {
        // "ip" is inside "Skip"/"Tip"-like words but must not match mid-word.
        #expect(SettingsSearch.score("ip", title: "Clipboard") == nil)
        #expect(SettingsSearch.score("clip", title: "Recent clipboard") != nil)
    }

    @Test func contextOnlyMatchesRankLast() {
        let byTitle = SettingsSearch.score("strength", title: "Autocorrect strength")!
        let byContext = SettingsSearch.score("strength", title: "Rewrite pause", context: ["Strength"])!
        #expect(byTitle < byContext)
    }

    @Test func emptyQueryFindsNothing() {
        #expect(titles("   ").isEmpty)
    }

    @Test func requirementsFollowSettings() {
        var s = HunchSettings()
        s.enabled = false
        #expect(!SettingsSearch.Requirement.suggestionsOn.isMet(s))
        s.enabled = true
        #expect(SettingsSearch.Requirement.suggestionsOn.isMet(s))
        s.autocorrectEnabled = true
        s.autocorrectStrength = .balanced
        #expect(!SettingsSearch.Requirement.strongAutocorrect.isMet(s))
    }

    @Test func placeSettingsSeeOverrides() {
        var p = AppPolicyPatch()
        let insertion = SettingsSearch.placeSettings.first { $0.anchor == "apps.insertion" }!
        #expect(!insertion.isSet(p))
        p.insertion = .paste
        #expect(insertion.isSet(p))
    }

    @Test func effectsFindableByName() {
        #expect(titles("matrix").first == "Matrix")
        #expect(titles("neon").first == "Neon")
        #expect(SettingsSearch.effects.allSatisfy { PopInAnimation(rawValue: $0.raw) != nil })
        #expect(SettingsSearch.effectAnchor("decode") == "appearance.effectDecode")
    }

    @Test func anchorsAreUnique() {
        let all = SettingsSearch.entries.map(\.anchor) + SettingsSearch.placeSettings.map(\.anchor)
        #expect(Set(all).count == all.count)
    }

    /// Every `.searchAnchor("…")` in the Settings panes is in the index, and every indexed anchor
    /// is on a row, so a new setting can't be added without becoming searchable (or vice versa).
    @Test func indexMatchesThePanes() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HunchApp/Settings")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"(?:searchAnchor|\.id)\("([a-z]+\.[A-Za-z]+)"\)"#)
        var inSource: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                inSource.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        // The Models pane's sections take their ids from `ModelsPane.anchor(_:)`, and each effect row
        // in Appearance from `SettingsSearch.effectAnchor(_:)`.
        inSource.formUnion(["model.autocomplete", "model.writing", "model.speechToText"])
        inSource.formUnion(SettingsSearch.effects.map { SettingsSearch.effectAnchor($0.raw) })
        let indexed = Set(SettingsSearch.entries.map(\.anchor) + SettingsSearch.placeSettings.map(\.anchor))
        #expect(inSource.subtracting(indexed).isEmpty, "on a row but not in SettingsSearch: \(inSource.subtracting(indexed).sorted())")
        #expect(indexed.subtracting(inSource).isEmpty, "in SettingsSearch but on no row: \(indexed.subtracting(inSource).sorted())")
    }
}
