import Foundation
import Testing
import HunchCore
@testable import HunchSettingsStore

/// Where a `hunch://settings?setting=` link lands.
@Suite struct SettingsJumpTargetTests {
    @Test func knownRowsAndPlaceSettings() {
        let s = HunchSettings()
        #expect(SettingsSearch.jumpTarget("general.openAtLogin", settings: s) == "general.openAtLogin")
        #expect(SettingsSearch.jumpTarget("apps.insertion", settings: s) == "apps.insertion")
        #expect(SettingsSearch.jumpTarget("general.nope", settings: s) == nil)
        #expect(SettingsSearch.jumpTarget("apps.nope", settings: s) == nil)
    }

    @Test func hiddenRowGoesToItsSwitch() {
        var s = HunchSettings()
        s.dictation.enabled = false
        #expect(SettingsSearch.jumpTarget("general.cleanupOn", settings: s) == "general.dictation")
        s.dictation.enabled = true
        #expect(SettingsSearch.jumpTarget("general.cleanupOn", settings: s) == "general.cleanupOn")
    }

    @Test func everyAnchorFitsTheLinkShape() {
        // Every row must be reachable by a link, so anchors keep the `pane.name` shape the parser accepts.
        let anchors = SettingsSearch.entries.map(\.anchor) + SettingsSearch.placeSettings.map(\.anchor)
        for anchor in anchors {
            #expect(HunchURLCommand.validate(
                URL(string: "hunch://settings?select=a.b&setting=\(anchor)")!, siteKey: { _ in nil }) != nil)
            if case .failure(let r)? = HunchURLCommand.validate(
                URL(string: "hunch://settings?setting=\(anchor)")!, siteKey: { _ in nil }),
               !anchor.hasPrefix("apps.") {
                Issue.record("\(anchor): \(r)")
            }
        }
    }
}
