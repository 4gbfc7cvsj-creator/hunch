import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import HunchScreen

/// Fake captures: text drawn with a known face, size and baseline on a themed background.
private func capture(_ lines: [(text: String, baseline: Double)], face: String = "Helvetica", size: CGFloat = 13,
                     width: Int = 240, height: Int = 70, scale: CGFloat = 2, rightEdge: Double = 236,
                     dark: Bool = true, noise: Int = 0, font explicit: CTFont? = nil) -> [UInt8] {
    // System faces ("." names) must come from the UI font API; by name CoreText returns Times.
    let font = explicit ?? CTFontCreateWithName(face as CFString, size, nil)
    var coverage = [Float](repeating: 0, count: width * height)
    for line in lines {
        let c = TemplateMatch.render(line.text, font: font, width: width, height: height, scale: scale,
                                     rightEdge: rightEdge, baselineRow: line.baseline)!
        for i in 0..<c.count { coverage[i] = max(coverage[i], c[i]) }
    }
    let (bg, fg): (Double, Double) = dark ? (38, 235) : (250, 20)
    var rng = SystemRandomNumberGenerator()
    return coverage.map { cov in
        let v = bg + (fg - bg) * Double(cov) / 255 + Double(noise > 0 ? Int.random(in: -noise...noise, using: &rng) : 0)
        return UInt8(max(0, min(255, v.rounded())))
    }
}

private func system(_ size: CGFloat) -> CTFont { CTFontCreateUIFontForLanguage(.system, size, nil)! }

private func fit(_ gray: [UInt8], _ text: String, width: Int = 240, height: Int = 70, reported: CGFloat? = 13,
                 caret: Double = 236) -> TextFit? {
    TemplateMatch.fit(gray: gray, width: width, height: height, scale: 2, text: text, caretColumn: caret,
                      sizes: TemplateMatch.candidateSizes(reported: reported, caretHeight: 16), font: system)
}

@Suite struct TemplateMatchTests {
    @Test func findsBaselineInDarkAndLightThemes() {
        for dark in [true, false] {
            let gray = capture([("What about", 44)], dark: dark, noise: 6)
            let f = fit(gray, "What about")
            #expect(f != nil)
            #expect(abs((f?.baselineRow ?? 0) - 44) <= 1.0, "dark=\(dark) baseline=\(f?.baselineRow ?? -1)")
            #expect((f?.score ?? 0) >= TemplateMatch.minimumScore, "dark=\(dark) score=\(f?.score ?? -1)")
        }
    }

    @Test func findsSizeWhenReportedSizeIsOff() {
        let gray = capture([("the quarterly report", 46)], face: "Helvetica", size: 15, width: 360, rightEdge: 356)
        let f = fit(gray, "the quarterly report", width: 360, reported: 13, caret: 356)
        #expect(f.map { abs($0.pointSize - 15) <= 1 } == true, "size=\(f?.pointSize ?? -1)")
        #expect(abs((f?.baselineRow ?? 0) - 46) <= 1.0)
    }

    /// Same face as ours: the fitted size must be the real one, not a smaller size that matches
    /// only the last few letters.
    @Test func exactSizeWithSameFace() {
        for size in [11.0, 13.0, 16.0] as [CGFloat] {
            let gray = capture([("What about the rest of", 44)], width: 360, rightEdge: 356,
                               font: CTFontCreateUIFontForLanguage(.system, size, nil)!)
            let f = fit(gray, "What about the rest of", width: 360, reported: size, caret: 356)
            #expect(f.map { abs($0.pointSize - size) <= 0.3 } == true, "size \(size) fitted \(String(describing: f?.pointSize))")
        }
    }

    @Test func caretAFewPixelsOff() {
        let gray = capture([("hello there", 40)], rightEdge: 232)
        let f = fit(gray, "hello there", caret: 236)
        #expect((f?.score ?? 0) >= TemplateMatch.minimumScore)
        #expect(abs((f?.baselineRow ?? 0) - 40) <= 1.0)
    }

    /// Mail: the strip came from the viewer window behind the compose window.
    @Test func wrongWindowIsRejected() {
        let gray = capture([("Edge", 26), ("now W", 58)], face: "Helvetica-Bold", size: 14)
        let f = fit(gray, "What about")
        #expect((f?.score ?? 0) < TemplateMatch.minimumScore, "score=\(f?.score ?? -1)")
    }

    @Test func separatorLineIsRejected() {
        var gray = [UInt8](repeating: 38, count: 240 * 70)
        for x in 0..<240 { gray[20 * 240 + x] = 90; gray[21 * 240 + x] = 90 }
        let f = fit(gray, "What about")
        #expect((f?.score ?? 0) < TemplateMatch.minimumScore, "score=\(f?.score ?? -1)")
    }

    @Test func pickedTheRightLineWhenTwoAreVisible() {
        // The line above holds other text; the caret's line holds what was typed.
        let gray = capture([("Previous line of text", 18), ("What about", 50)])
        let f = fit(gray, "What about")
        #expect(abs((f?.baselineRow ?? 0) - 50) <= 1.0, "baseline=\(f?.baselineRow ?? -1)")
        #expect((f?.score ?? 0) >= TemplateMatch.minimumScore)
    }

    @Test func emptyOrBlankInputs() {
        let blank = [UInt8](repeating: 38, count: 240 * 70)
        #expect((fit(blank, "What about")?.score ?? 0) < TemplateMatch.minimumScore)
        #expect(fit(capture([("x", 40)]), "   ") == nil)
    }

    @Test func speed() {
        let gray = capture([("I will send the quarterly budget report", 44)], width: 480, rightEdge: 476)
        // A fixed time limit is flaky: the other screen tests run in parallel, and on a Mac with few
        // fast cores this one lands on a slow core, so even its CPU time grows ~6x. Instead, compare
        // the fit with a reference job (rendering the same line) timed on the same thread around it.
        // The fit is single-threaded. Debug build: ratio ~5 when quiet, ~7 under a full `swift test`.
        let cpu = { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }
        let reference = {
            let t = cpu()
            for _ in 0..<20 { _ = capture([("I will send the quarterly budget report", 44)], width: 480, rightEdge: 476) }
            return cpu() - t
        }
        let r0 = reference()
        let t0 = cpu()
        _ = fit(gray, "I will send the quarterly budget report", width: 480, caret: 476)
        let ms = cpu() - t0
        let r1 = reference()
        let ratio = ms / ((r0 + r1) / 2)
        print("template fit 480x70: \(Int(ms)) ms CPU, ref \(Int(r0))/\(Int(r1)) ms, ratio \(String(format: "%.2f", ratio))")
        #expect(ratio < 20, "ratio=\(ratio)")
    }
}
