import Foundation
import HunchCore
import Testing
@testable import HunchSettingsStore

private func decode(_ edit: (inout [String: Any]) -> Void) throws -> HunchSettings {
    let data = try JSONEncoder().encode(HunchSettings())
    var dict = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    edit(&dict)
    return try #require(JSONSettingsStore.decodeTolerant(JSONSerialization.data(withJSONObject: dict)))
}

@Test func filesFromBeforeIconsGetTheDefaults() throws {
    let s = try decode { $0.removeValue(forKey: "menuBarIcon"); $0.removeValue(forKey: "appIcon") }
    #expect(s.menuBarIcon == .cat)
    #expect(s.appIcon == .whiteSage)
}

@Test func unknownIconsFallBackToTheDefaults() throws {
    let s = try decode { $0["menuBarIcon"] = "ghost"; $0["appIcon"] = "purple-000000" }
    #expect(s.menuBarIcon == .cat)
    #expect(s.appIcon == .standard)
}

@Test func pickedIconsRoundTrip() throws {
    let s = try decode { $0["menuBarIcon"] = "paw"; $0["appIcon"] = "tuxedo-a6b7d1" }
    #expect(s.menuBarIcon == .paw)
    #expect(s.appIcon == .tuxedoBlue)
}

@Test func everyAppIconHasArtwork() {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Resources/AppIcons").standardized
    for choice in AppIconChoice.allCases {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(choice.rawValue + ".png").path),
                "\(choice.rawValue)")
    }
}
