import Foundation
import HunchCore
import Testing
@testable import HunchPolicy

/// `hunch://` domain targets go through the same validation as Websites → "+" in the Apps pane.
@Suite struct URLCommandSiteTests {
    private func parse(_ s: String) -> HunchURLCommand.Command? {
        HunchURLCommand.parse(URL(string: s)!, siteKey: KnownPlacesStore.siteKey(fromInput:))
    }

    @Test func domainPatternsMatchAppsPane() {
        #expect(parse("hunch://clearOverride?domain=www.Example.com") == .clearOverride(.domain(pattern: "example.com")))
        #expect(parse("hunch://clearOverride?domain=*.sharepoint.com")
                == .clearOverride(.domain(pattern: "*.sharepoint.com")))
        #expect(parse("hunch://clearOverride?domain=localhost") == nil)
        #expect(parse("hunch://clearOverride?domain=a.com:8080") == nil)
        #expect(parse("hunch://clearOverride?domain=*.*.com") == nil)
        #expect(parse("hunch://settings?select=*.atlassian.net") == .settings(.init(place: .domain(pattern: "*.atlassian.net"))))
    }
}
