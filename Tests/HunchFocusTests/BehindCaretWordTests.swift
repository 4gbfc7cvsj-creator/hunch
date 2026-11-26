import CoreGraphics
import Testing
@testable import HunchFocus

// The faint line under a fixed word: a host answering a word's range with the whole line or field
// box (Chromium, Electron) must not get a line under that box.

@Test func wordSizedBoxFits() {
    #expect(BehindCaret.fitsWord(CGRect(x: 100, y: 200, width: 24, height: 17), characters: 3))
    #expect(BehindCaret.fitsWord(CGRect(x: 100, y: 200, width: 80, height: 17), characters: 10))
}

@Test func lineOrFieldBoxDoesNotFit() {
    #expect(!BehindCaret.fitsWord(CGRect(x: 100, y: 200, width: 640, height: 17), characters: 3))
    #expect(!BehindCaret.fitsWord(CGRect(x: 100, y: 200, width: 600, height: 120), characters: 5))
}
