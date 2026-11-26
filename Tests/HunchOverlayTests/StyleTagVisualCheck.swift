import AppKit
import Foundation
import HunchCore
import Testing
@testable import HunchOverlay

/// Opt-in visual check: steps the style tag forward and back with the slide slowed down, and
/// screenshots it mid-move. Run with `HUNCH_VISUAL_CHECK=<folder> swift test --filter StyleTagVisualCheck`.
@Suite struct StyleTagVisualCheck {
    static let folder = ProcessInfo.processInfo.environment["HUNCH_VISUAL_CHECK"]

    @MainActor
    @Test(.enabled(if: folder != nil)) func slideFrames() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let dir = URL(fileURLWithPath: Self.folder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screen = try #require(NSScreen.screens.first)
        let caret = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 1, height: 20)
        let region = CGRect(x: caret.minX - 160, y: screen.frame.maxY - caret.minY - 10, width: 360, height: 40)
        func shoot(_ name: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))",
                           dir.appendingPathComponent("\(name).png").path]
            try? p.run()
            while p.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        StyleTagPresenter.slideDuration = 1.6
        let tag = StyleTagPresenter()
        let ring = ["AI", "Casual", "Formal", "Concise"]
        func names(_ i: Int, _ step: StyleTagNames.Step?) -> StyleTagNames {
            let n = ring.count
            return StyleTagNames(previous: ring[(i + n - 1) % n], current: ring[i % n], next: ring[(i + 1) % n], step: step)
        }
        tag.show(names(0, nil), caret: caret)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        shoot("0-start")
        for (label, i, step) in [("1-forward", 1, StyleTagNames.Step.forward), ("2-back", 0, .back)] {
            let start = Date()
            tag.show(names(i, step), caret: caret)
            for t in [0.15, 0.6, 1.0, 2.0] {
                RunLoop.main.run(until: start.addingTimeInterval(t))
                shoot(String(format: "%@-%04.0fms", label, t * 1000))
            }
        }
        tag.hide()
    }
}
