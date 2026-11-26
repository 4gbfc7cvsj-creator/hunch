import AppKit
import Foundation
import HunchCore
import Testing
@testable import HunchOverlay

/// Opt-in visual check: shows a real ghost with a pop-in on screen and screenshots it over time.
/// Run with `HUNCH_VISUAL_CHECK=<folder> swift test --filter PopInVisualCheck`; skipped otherwise.
@Suite struct PopInVisualCheck {
    static let folder = ProcessInfo.processInfo.environment["HUNCH_VISUAL_CHECK"]

    @MainActor
    @Test(.enabled(if: folder != nil)) func wisteriaFrames() throws {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: Self.folder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screen = try #require(NSScreen.screens.first)
        let caret = CGPoint(x: screen.frame.midX - 200, y: screen.frame.midY)
        let presenter = GhostOverlayPresenter()
        var appearance = AppearanceSettings(animation: .wisteria)
        appearance.opacity = 0.6
        presenter.appearance = appearance

        func show(_ text: String, x: CGFloat) {
            let g = CaretGeometry(caretRect: CGRect(x: x, y: caret.y, width: 1, height: 22), quality: .exact)
            presenter.present(GhostPresentation(text: text, geometry: g, mode: .inline))
        }
        // A rect around the ghost, in screencapture's top-left coordinates.
        let region = CGRect(x: caret.x - 40, y: screen.frame.maxY - caret.y - 90, width: 520, height: 160)
        func shoot(_ name: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))",
                           dir.appendingPathComponent("\(name).png").path]
            try? p.run()
            // Keep the main run loop turning (Hang draws from a main-thread timer) while it captures.
            while p.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        func wait(until t: TimeInterval, from start: Date) {
            RunLoop.main.run(until: start.addingTimeInterval(t))
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let start = Date()
        show("before our meeting tomorrow", x: caret.x)
        for t in [0.05, 0.25, 0.5, 0.8, 1.2, 1.8, 2.6] {
            wait(until: t, from: start)
            shoot(String(format: "a-%04.0fms", t * 1000))
        }
        presenter.hide()

        // Typing through mid-pop-in: the panel moves right; particles in flight must stay put. (Wait
        // first, or showing the same text again counts as a redraw.)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let again = Date()
        show("before our meeting tomorrow", x: caret.x)
        wait(until: 0.5, from: again)
        shoot("b-0500ms-before-typing")
        let font = GhostOverlayPresenter.font(for: nil, caretHeight: 22)
        let typed = ceil(("befo" as NSString).size(withAttributes: [.font: font]).width)
        presenter.hide()
        show("re our meeting tomorrow", x: caret.x + typed)
        wait(until: 0.6, from: again)
        shoot("b-0600ms-after-typing")
        wait(until: 1.2, from: again)
        shoot("b-1200ms")
        presenter.hide()

        // Particles that keep trickling while the suggestion shows.
        var trickle = appearance
        var r = PopInRecipe.preset(.wisteria)
        r.particleEmitMs = PopInRecipe.particleEmitWhileShown
        r.particleTrickle = 6
        trickle.presetTuning["wisteria"] = r
        presenter.appearance = trickle
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let third = Date()
        show("see you then", x: caret.x)
        wait(until: 4, from: third)
        shoot("c-4000ms-trickle")
        presenter.hide()

        // Every shape, big and slow, so each one can be told apart.
        var shapes = appearance
        shapes.animation = .custom
        var big = PopInRecipe()
        big.particlesOn = true
        big.particleShapes = ParticleShape.allCases
        big.particleSize = 14
        big.particleSizeVariation = 0
        big.particleDensity = 1
        big.particleSpeed = 20
        big.particleGravity = 0
        big.particleSpin = 0
        big.particleFlutter = 0
        big.particleRoom = 60
        shapes.customRecipe = big
        presenter.appearance = shapes
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let fourth = Date()
        show("abcdefghijklmnop", x: caret.x)
        wait(until: 0.9, from: fourth)
        shoot("d-shapes")
        presenter.hide()

        presenter.appearance = AppearanceSettings(animation: .autumn, opacity: 0.6)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let fifth = Date()
        show("before our meeting tomorrow", x: caret.x)
        wait(until: 0.6, from: fifth)
        shoot("e-autumn-0600ms")
        wait(until: 1.4, from: fifth)
        shoot("e-autumn-1400ms")
        presenter.hide()

        presenter.appearance = AppearanceSettings(animation: .winter, opacity: 0.6)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let sixth = Date()
        show("before our meeting tomorrow", x: caret.x)
        wait(until: 0.6, from: sixth)
        shoot("f-winter-0600ms")
        wait(until: 1.6, from: sixth)
        shoot("f-winter-1600ms")
        presenter.hide()
    }

    /// Neon, Ocean, Stardust and Ember over time, plus particles pulled sideways.
    @MainActor
    @Test(.enabled(if: folder != nil)) func newEffectFrames() throws {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: Self.folder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screen = try #require(NSScreen.screens.first)
        let caret = CGPoint(x: screen.frame.midX - 200, y: screen.frame.midY)
        let presenter = GhostOverlayPresenter()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let region = CGRect(x: caret.x - 40, y: screen.frame.maxY - caret.y - 90, width: 520, height: 160)
        func shoot(_ name: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))",
                           dir.appendingPathComponent("\(name).png").path]
            try? p.run()
            while p.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        func play(_ appearance: AppearanceSettings, _ name: String, at times: [TimeInterval]) {
            presenter.appearance = appearance
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let start = Date()
            let g = CaretGeometry(caretRect: CGRect(x: caret.x, y: caret.y, width: 1, height: 22), quality: .exact)
            presenter.present(GhostPresentation(text: "before our meeting tomorrow", geometry: g, mode: .inline))
            for t in times {
                RunLoop.main.run(until: start.addingTimeInterval(t))
                shoot(String(format: "\(name)-%04.0fms", t * 1000))
            }
            presenter.hide()
        }
        for style in [PopInAnimation.neon, .ocean, .stardust, .ember] {
            play(AppearanceSettings(animation: style, opacity: 0.6), style.rawValue, at: [0.1, 0.3, 0.6, 1.0, 1.8])
        }
        var wind = AppearanceSettings(animation: .custom, opacity: 0.6)
        var r = PopInRecipe()
        r.particlesOn = true
        r.particleShapes = [.dot]
        r.particleDensity = 1
        r.particleSize = 5
        r.particleSpeed = 0
        r.particleGravity = 60
        r.particleGravityDirection = 90
        r.particleRoom = 60
        r.particleLifeMs = 1500
        wind.customRecipe = r
        play(wind, "wind-right", at: [0.8])
    }

    /// Works with the display asleep: the ghost's own drawing for the new effects, rendered offscreen
    /// at set times and stacked into one image per style, plus particle flight paths under each pull.
    @MainActor
    @Test(.enabled(if: folder != nil)) func offscreenFrames() throws {
        let dir = URL(fileURLWithPath: Self.folder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ rep: NSBitmapImageRep, _ name: String) throws {
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
        }
        for style in [PopInAnimation.neon, .ocean, .stardust, .ember, .wisteria] {
            let r = PopInRecipe.preset(style)
            let times = [0.05, 0.15, 0.3, 0.45, 0.6, 0.8, 1.1, 1.6]
            // Drawn as Follow effect at 60 %: the style's final color, else dark text.
            let c = AppearanceSettings(animation: style).effectColor
            let ink = c.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 0.6) }
                ?? NSColor(white: 0.1, alpha: 0.6)
            let frames = times.compactMap {
                GhostOverlayPresenter.snapshot("before our meeting", recipe: r, elapsed: $0, color: ink)
            }
            let w = frames.map(\.pixelsWide).max() ?? 1, h = frames.map(\.pixelsHigh).reduce(0, +)
            let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
            var y = h
            for f in frames {
                y -= f.pixelsHigh
                f.draw(in: CGRect(x: 0, y: y, width: f.pixelsWide, height: f.pixelsHigh))
                NSColor.lightGray.setFill()
                CGRect(x: 0, y: y, width: w, height: 1).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            try save(sheet, "sheet-\(style.rawValue)")
        }
        // Particle paths: start in the middle, pulled down, right, up and left (one color each).
        let size = 400
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: size, height: size).fill()
        let colors: [NSColor] = [.systemBlue, .systemRed, .systemGreen, .systemOrange]
        for (k, pull) in [0.0, 90, 180, -90].enumerated() {
            for spreadDeg in stride(from: -40.0, through: 40, by: 20) {
                let path = PopIn.particlePath(start: CGPoint(x: 200, y: 200), speed: 40, direction: spreadDeg,
                                              gravity: 200, gravityDirection: pull, flutter: 4, phase: 0, life: 1.2)
                let bp = NSBezierPath()
                bp.move(to: path[0])
                path.dropFirst().forEach { bp.line(to: $0) }
                colors[k].setStroke()
                bp.lineWidth = 2
                bp.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try save(rep, "gravity-paths")
    }

    /// Ghost, Phase alone and Ripple alone, on a dark and a light background, plus the Wisp and Mist
    /// shapes drawn large.
    @MainActor
    @Test(.enabled(if: folder != nil)) func ghostFrames() throws {
        let dir = URL(fileURLWithPath: Self.folder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ rep: NSBitmapImageRep, _ name: String) throws {
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
        }
        var phase = PopInRecipe()
        phase.phaseOn = true
        var ripple = PopInRecipe()
        ripple.rippleOn = true; ripple.fadeOn = true
        let ghost = PopInRecipe.preset(.spooky)
        var noGlow = ghost
        noGlow.glowOn = false
        let lavender = ghost.finalColor
        let ink = NSColor(srgbRed: lavender.red, green: lavender.green, blue: lavender.blue, alpha: 0.75)
        let backgrounds: [(String, NSColor)] = [("dark", NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)),
                                                ("light", .white)]
        for (name, r) in [("ghost", ghost), ("ghost-noglow", noGlow), ("phase", phase), ("ripple", ripple)] {
            for (bgName, bg) in backgrounds {
                let times = [0.05, 0.12, 0.2, 0.3, 0.42, 0.55, 0.75, 1.0, 1.4]
                let frames = times.compactMap {
                    GhostOverlayPresenter.snapshot("before our meeting", recipe: r, elapsed: $0,
                                                   color: bgName == "light" ? NSColor(white: 0.1, alpha: 0.6) : ink,
                                                   background: bg)
                }
                let w = frames.map(\.pixelsWide).max() ?? 1, h = frames.map(\.pixelsHigh).reduce(0, +)
                let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
                // The ghost clears its own box, so fill behind it with the page.
                bg.setFill()
                CGRect(x: 0, y: 0, width: w, height: h).fill()
                var y = h
                for f in frames {
                    y -= f.pixelsHigh
                    f.draw(in: CGRect(x: 0, y: y, width: f.pixelsWide, height: f.pixelsHigh),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                    NSColor.gray.setFill()
                    CGRect(x: 0, y: y, width: w, height: 1).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                try save(sheet, "sheet-\(name)-\(bgName)")
            }
        }
        // The new shapes, 80 pt across, filled even-odd as the emitter does.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 120, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let cg = NSGraphicsContext.current!.cgContext
        cg.setFillColor(NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        for (i, shape) in [ParticleShape.wisp, .mist].enumerated() {
            cg.saveGState()
            cg.translateBy(x: 60 + CGFloat(i) * 120, y: 60)
            cg.addPath(ParticleEmitter.path(shape, size: 80))
            cg.setFillColor(NSColor(srgbRed: 0.93, green: 0.91, blue: 1, alpha: 1).cgColor)
            cg.fillPath(using: .evenOdd)
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try save(rep, "shapes-ghost")
    }

    /// Paws as contact sheets (one row per moment), light and dark, plus a lone print drawn large.
    @MainActor
    @Test(.enabled(if: folder != nil)) func pawsFrames() throws {
        let dir = URL(fileURLWithPath: Self.folder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let paws = PopInRecipe.preset(.paws)
        var slow = paws
        slow.pawLettersPerStep = 8; slow.pawMaxMs = 1200; slow.pawStepMs = 200; slow.pawSize = 16
        slow.pawLingerMs = 1000; slow.imprintFromPercent = 130
        var trail = slow
        trail.pawTrail = .faded
        let backgrounds: [(String, NSColor, NSColor)] = [
            ("dark", NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1), NSColor(white: 0.9, alpha: 0.6)),
            ("light", .white, NSColor(white: 0.1, alpha: 0.6))]
        for (name, r) in [("paws", paws), ("paws-slow", slow), ("paws-trail", trail)] {
            for (bgName, bg, ink) in backgrounds {
                let times = [0.03, 0.08, 0.15, 0.25, 0.35, 0.5, 0.7, 0.9, 1.2, 2.0]
                let frames = times.compactMap {
                    GhostOverlayPresenter.snapshot("before our meeting tomorrow", recipe: r, elapsed: $0, color: ink,
                                                   background: bg)
                }
                let w = frames.map(\.pixelsWide).max() ?? 1, h = frames.map(\.pixelsHigh).reduce(0, +)
                let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
                bg.setFill()
                CGRect(x: 0, y: 0, width: w, height: h).fill()
                var y = h
                for f in frames {
                    y -= f.pixelsHigh
                    f.draw(in: CGRect(x: 0, y: y, width: f.pixelsWide, height: f.pixelsHigh),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                    NSColor.gray.setFill()
                    CGRect(x: 0, y: y, width: w, height: 1).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                try sheet.representation(using: .png, properties: [:])!
                    .write(to: dir.appendingPathComponent("sheet-\(name)-\(bgName).png"))
            }
        }
    }
}
