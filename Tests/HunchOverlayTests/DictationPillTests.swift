import AppKit
import Testing
@testable import HunchOverlay

@MainActor
@Suite struct DictationPillTests {
    @Test func recordingIsACircleWithTheCatCentered() {
        let pill = DictationPill()
        pill.show(.recording, near: CGRect(x: 400, y: 400, width: 2, height: 18))
        defer { pill.hide() }
        pill.panel.contentView?.layoutSubtreeIfNeeded()
        let frame = pill.panel.frame
        #expect(frame.width == DictationPill.height && frame.height == DictationPill.height)
        let glyph = pill.glyph.convert(pill.glyph.bounds, to: nil)
        #expect(abs(glyph.midX - frame.width / 2) < 0.5)
        #expect(abs(glyph.midY - frame.height / 2) < 0.5)
    }

    @Test func workingKeepsTheCatOnTheLeftOfTheWord() {
        let pill = DictationPill()
        pill.show(.working("Transcribing…"), near: CGRect(x: 400, y: 400, width: 2, height: 18))
        defer { pill.hide() }
        pill.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(!pill.glyph.isHidden)
        let glyph = pill.glyph.convert(pill.glyph.bounds, to: nil)
        #expect(glyph.minX < 12 && pill.panel.frame.width > 60)
        #expect(pill.glyph.layer?.animation(forKey: "pulse") != nil)
    }

    @Test func messagesStillWiden() {
        let pill = DictationPill()
        pill.show(.message("The text box changed: the text is on the clipboard", isProblem: true))
        defer { pill.hide() }
        #expect(pill.panel.frame.width > 120)
        #expect(pill.glyph.isHidden)
    }
}
