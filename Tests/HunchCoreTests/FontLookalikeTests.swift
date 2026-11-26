import CoreGraphics
import Testing
@testable import HunchCore

@Suite struct FontLookalikeTests {
    @Test func discordFacesMapToAvenirNext() {
        #expect(FontLookalike.family(forFamily: "gg sans", name: nil) == "Avenir Next")
        #expect(FontLookalike.family(forFamily: "gg sans Normal", name: nil) == "Avenir Next")
        #expect(FontLookalike.family(forFamily: nil, name: "ggsans-Medium") == "Avenir Next")
        #expect(FontLookalike.family(forFamily: "\"gg sans\", \"Noto Sans\", sans-serif", name: nil) == "Avenir Next")
        #expect(FontLookalike.family(forFamily: "Whitney", name: nil) == "Avenir Next")
    }

    @Test func otherFontsHaveNoStandIn() {
        #expect(FontLookalike.family(forFamily: "Helvetica", name: "Helvetica") == nil)
        #expect(FontLookalike.family(forFamily: ".AppleSystemUIFont", name: nil) == nil)
        #expect(FontLookalike.family(forFamily: nil, name: nil) == nil)
        // A later entry in a CSS list still counts only if it is a known web face.
        #expect(FontLookalike.family(forFamily: "Inter, Arial", name: nil) == nil)
    }

    @Test func trackingSpreadsTheWidthDifferenceOverCharacters() {
        // Discord: typed text 0.936 of Avenir Next's width, mean advance 5.9 pt at 16 pt.
        #expect(abs(FontLookalike.tracking(widthScale: 0.936, meanAdvance: 5.9) - (-0.3776)) < 0.001)
        #expect(FontLookalike.tracking(widthScale: nil, meanAdvance: 5.9) == 0)
        #expect(FontLookalike.tracking(widthScale: 1, meanAdvance: 5.9) == 0)
        // Clamped: a wild scale never squeezes letters together.
        #expect(abs(FontLookalike.tracking(widthScale: 0.5, meanAdvance: 6) - (-0.9)) < 0.0001)
        #expect(abs(FontLookalike.tracking(widthScale: 1.5, meanAdvance: 6) - 0.6) < 0.0001)
    }
}
