import Foundation
import HunchCore
import Testing
@testable import HunchSettingsStore

@Test func settingsFilesWithoutStylesGetTheBuiltIns() throws {
    let data = try JSONEncoder().encode(HunchSettings())
    var dict = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    dict.removeValue(forKey: "suggestionStyles")
    let decoded = try #require(JSONSettingsStore.decodeTolerant(JSONSerialization.data(withJSONObject: dict)))
    #expect(decoded.suggestionStyles == SuggestionStyle.builtIns)
}
