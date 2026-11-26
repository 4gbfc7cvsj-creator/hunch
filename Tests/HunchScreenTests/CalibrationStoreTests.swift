import Foundation
import Testing
@testable import HunchScreen

@Test func calibrationRetryBurstThenCooldown() {
    var r = CalibrationRetry()
    let t0 = ContinuousClock.now
    // Seconds after t0 → whether a try is due: a burst of 3 at least 2 s apart, then 30 s after the last.
    let steps: [(Int, Bool)] = [(0, true), (1, false), (2, true), (4, true), (6, false), (33, false), (34, true), (36, true)]
    for (second, due) in steps {
        let began = r.begin(at: t0 + .seconds(second))
        #expect(began == due, "at \(second) s")
    }
    #expect(r.count == 2)
}

@Test func calibrationStoreRoundTripsThroughFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-cal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("calibrations.json")
    let key = CalibrationStore.Key(bundleID: "com.anthropic.claudefordesktop", caretHeight: 17, fontSize: 28)
    let cal = TextCalibration(baselineAboveCaretBottom: 4.96, xHeight: 6.18, pointSize: 11.75, score: 0.751)
    CalibrationStore(fileURL: url).save(cal, for: key)

    let reloaded = CalibrationStore(fileURL: url)
    let got = try #require(reloaded.calibration(for: key))
    #expect(abs(got.baselineAboveCaretBottom - 4.96) < 0.001)
    #expect(got.xHeight.map { abs($0 - 6.18) < 0.001 } == true)
    #expect(reloaded.calibration(for: .init(bundleID: "com.apple.mail", caretHeight: 17, fontSize: 28)) == nil)
}

@Test func calibrationStoreKeepsNewestWithinCapacity() {
    let store = CalibrationStore(fileURL: nil)
    let base = Date(timeIntervalSince1970: 0)
    for i in 0...CalibrationStore.capacity {
        store.save(TextCalibration(baselineAboveCaretBottom: CGFloat(i), xHeight: nil),
                   for: .init(bundleID: "app\(i)", caretHeight: 17, fontSize: 28), at: base + Double(i))
    }
    #expect(store.calibration(for: .init(bundleID: "app0", caretHeight: 17, fontSize: 28)) == nil)
    #expect(store.calibration(for: .init(bundleID: "app\(CalibrationStore.capacity)", caretHeight: 17, fontSize: 28)) != nil)
}

@Test func calibrationStoreIgnoresUnreadableFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-cal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("calibrations.json")
    try Data("not json".utf8).write(to: url)
    #expect(CalibrationStore(fileURL: url).calibration(for: .init(bundleID: "a", caretHeight: 1, fontSize: 0)) == nil)
}

@Test func calibrationStoreKeepsTheFaceDecision() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-cal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("calibrations.json")
    let key = CalibrationStore.Key(bundleID: "com.hnc.Discord", caretHeight: 22, fontSize: 32)
    let cal = TextCalibration(baselineAboveCaretBottom: 5.5, xHeight: 7.76, hostXHeight: 7.55, measuredAtSize: 16,
                              faceXHeights: ["System": 8.4, "Avenir Next": 7.5], sizeSuggestion: 1.07,
                              sizeFactor: 1.05, pickedFamily: "Avenir Next")
    CalibrationStore(fileURL: url).save(cal, for: key)
    let got = try #require(CalibrationStore(fileURL: url).calibration(for: key))
    #expect(got.pickedFamily == "Avenir Next")
    #expect(got.faceXHeights["Avenir Next"].map { abs($0 - 7.5) < 0.001 } == true)
    #expect(abs(got.sizeFactor - 1.05) < 0.001)
    #expect(got.sizeSuggestion.map { abs($0 - 1.07) < 0.001 } == true)
    #expect(got.hostXHeight.map { abs($0 - 7.55) < 0.001 } == true)
}

@Test func calibrationStoreSeparatesFontsAndDropsLegacySaves() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-cal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("calibrations.json")
    let a = CalibrationStore.Key(bundleID: "com.google.Chrome", caretHeight: 19, fontSize: 32, fontTag: "aaaa")
    let b = CalibrationStore.Key(bundleID: "com.google.Chrome", caretHeight: 19, fontSize: 32, fontTag: "bbbb")
    var cal = TextCalibration(baselineAboveCaretBottom: 4, xHeight: 6, pointSize: 12, score: 0.7)
    cal.sizeFactor = 0.93
    CalibrationStore(fileURL: url).save(cal, for: a)
    let store = CalibrationStore(fileURL: url)
    #expect(store.calibration(for: a)?.sizeFactor == 0.93)
    #expect(store.calibration(for: b) == nil)

    // A file written before keys had a font tag: no crash, and the entry is dropped.
    let legacy = #"[{"key":{"bundleID":"com.google.Chrome","caretHeight":19,"fontSize":32},"baseline":4,"savedAt":0}]"#
    try legacy.write(to: url, atomically: true, encoding: .utf8)
    let loaded = CalibrationStore(fileURL: url)
    #expect(loaded.calibration(for: a) == nil)
    #expect(loaded.calibration(for: .init(bundleID: "com.google.Chrome", caretHeight: 19, fontSize: 32, fontTag: "")) == nil)
}
