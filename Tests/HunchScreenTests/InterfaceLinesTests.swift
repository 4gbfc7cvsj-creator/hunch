import CoreGraphics
import Foundation
import HunchCore
import Testing
@testable import HunchScreen

@Test func statusBoxLinesAreInterface() {
    for l in ["53%", "©2d13h", "7d", "+0 −0", "Opus 5.5 · Medium · Auto", "Opus 5.5 - Medium • Auto",
              "last turn 1m • session 8h00", "+ master • 2 files • +0 -0", "Opus 5.5 Medium Auto O",
              "↑6.9M ↓15.4k tokens", "1h17", "CSd13H", "G4dCH"] {
        #expect(InterfaceLines.kind(l) == .interface, "\(l)")
    }
}

@Test func shortWordsAreKeptButDoNotEndTheRun() {
    for l in ["Idle", "cache", "cont cold", "ok", "lol", "Hi Alex", "sounds good"] {
        #expect(InterfaceLines.kind(l) == .other, "\(l)")
    }
}

@Test func writingEndsTheRun() {
    for l in ["Good to go, or anything to change?", "• Tests, and updates to the two eval-harness docs.",
              "I think we should ship it today", "Nora 10:14 AM", "Yesterday at 4:06 PM", "我們明天再討論這件事",
              "See you at 5"] {
        #expect(InterfaceLines.kind(l) != .interface, "\(l)")
    }
    #expect(InterfaceLines.kind("Good to go, or anything to change?") == .writing)
    #expect(InterfaceLines.kind("Nora 10:14 AM") == .writing)
}

@Test func runStopsAtFirstWriting() {
    // Nearest the field first.
    let lines = ["+ master • 2 files • +0 -0", "53%", "Idle", "7d", "Good to go, or anything to change?", "42%"]
    #expect(InterfaceLines.run(lines) == [0, 1, 3])
}

@Test func trailingRunOfCaptureText() {
    let text = "Plan looks good.\nGood to go, or anything to change?\ncache\nIdle\nOpus 5.5 - Medium • Auto\n53%\nOpus 5.5 Medium Auto O"
    let (kept, dropped) = InterfaceLines.droppingTrailingRun(text)
    #expect(kept == "Plan looks good.\nGood to go, or anything to change?\ncache\nIdle")
    #expect(dropped == ["Opus 5.5 - Medium • Auto", "53%", "Opus 5.5 Medium Auto O"])
}

private func row(_ t: String, y: CGFloat) -> OCRLine {
    OCRLine(text: t, confidence: 0.9, rect: CGRect(x: 0, y: y, width: 300, height: 14))
}

@Test func pipelineDropsStatusBoxAndBarNextToField() {
    let field = CGRect(x: 0, y: 600, width: 400, height: 40)
    let lines = [
        row("Here is the plan for the eval log.", y: 300),
        row("Good to go, or anything to change?", y: 330),
        row("Idle", y: 450),
        row("Opus 5.5 · Medium · Auto", y: 480),
        row("last turn 1m • session 8h00", y: 510),
        row("+ master • 2 files • +0 −0", y: 560),
        row("Opus 5.5 Medium Auto", y: 660),
    ]
    let out = ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: 10, y: 620), field: field, maxCharacters: 500)
    #expect(out?.text == "Here is the plan for the eval log.\nGood to go, or anything to change?\nIdle")
    #expect(out?.interfaceDropped == 4)
}

@Test func pipelineKeepsInterfaceLookingLinesBetweenMessages() {
    let field = CGRect(x: 0, y: 600, width: 400, height: 40)
    let lines = [row("First message here, a long one.", y: 300), row("53%", y: 330),
                 row("Second message right above.", y: 560)]
    let out = ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: 10, y: 620), field: field, maxCharacters: 500)
    #expect(out?.text == "First message here, a long one.\n53%\nSecond message right above.")
    #expect(out?.interfaceDropped == 0)
}
