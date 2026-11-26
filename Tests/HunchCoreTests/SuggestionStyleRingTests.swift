import Foundation
import Testing
@testable import HunchCore

@Suite struct SuggestionStyleRingTests {
    let styles = SuggestionStyle.builtIns

    @Test func nextWalksForwardAndWrapsThroughTheAppsOwn() {
        var current: String? = nil
        var seen: [String?] = []
        for _ in 0..<5 {
            current = SuggestionStyleRing.step(from: current, forward: true, styles: styles)
            seen.append(current)
        }
        #expect(seen == ["casual", "formal", "concise", "detailed", nil])
    }

    @Test func upWalksBack() {
        #expect(SuggestionStyleRing.step(from: nil, forward: false, styles: styles) == "detailed")
        #expect(SuggestionStyleRing.step(from: "casual", forward: false, styles: styles) == nil)
    }

    @Test func offAndEmptyStylesAreSkipped() {
        var list = styles
        list[1].enabled = false
        list[2].instructions = "  "
        #expect(SuggestionStyleRing.step(from: "casual", forward: true, styles: list) == "detailed")
        // A style turned off while in use counts as the app's own.
        #expect(SuggestionStyleRing.step(from: "formal", forward: true, styles: list) == "casual")
        #expect(SuggestionStyleRing.style("formal", in: list) == nil)
    }

    @Test func noStylesStaysOnTheAppsOwn() {
        #expect(SuggestionStyleRing.step(from: nil, forward: true, styles: []) == nil)
    }

    @Test func builtInLengths() {
        #expect(SuggestionStyle.builtIn(id: "concise")?.length == .medium)
        #expect(SuggestionStyle.builtIn(id: "detailed")?.length == .ultra)
        #expect(SuggestionStyle.builtIn(id: "formal")?.length == nil)
    }

    @Test func editedBuiltInIsNoticed() {
        var s = SuggestionStyle.builtIn(id: "casual")!
        #expect(!s.isEditedBuiltIn)
        s.enabled = false
        #expect(!s.isEditedBuiltIn)
        s.instructions = "lol"
        #expect(s.isEditedBuiltIn)
    }
}

@Test func tagNamesTheStylesEitherSide() {
    let styles = SuggestionStyle.builtIns
    let usable = SuggestionStyleRing.usable(styles)
    let own = SuggestionStyleRing.tag(for: nil, styles: styles, ownName: "AI")
    #expect(own == StyleTagNames(previous: usable[usable.count - 1].name, current: "AI", next: usable[0].name))
    let first = SuggestionStyleRing.tag(for: usable[0].id, styles: styles, ownName: "AI")
    #expect(first == StyleTagNames(previous: "AI", current: usable[0].name, next: usable[1].name))
    let last = SuggestionStyleRing.tag(for: usable[usable.count - 1].id, styles: styles, ownName: "Mail")
    #expect(last?.previous == usable[usable.count - 2].name)
    #expect(last?.next == "Mail")
    #expect(SuggestionStyleRing.tag(for: nil, styles: [], ownName: "AI") == nil)
}

@Test func ownChipNamesWhereTheInstructionsComeFrom() {
    #expect(StyleTagNames.ownName(source: .category(name: "AI"), appName: "ChatGPT") == "AI")
    #expect(StyleTagNames.ownName(source: .app(bundleID: "com.apple.mail"), appName: "Mail") == "Mail")
    #expect(StyleTagNames.ownName(source: .app(bundleID: "com.apple.mail"), appName: nil) == "com.apple.mail")
    #expect(StyleTagNames.ownName(source: .domain(pattern: "*.slack.com"), appName: "Safari") == "slack.com")
    #expect(StyleTagNames.ownName(source: nil, appName: "Notes") == StyleTagNames.plain)
}
