import Foundation
import Synchronization
import Testing
@testable import HunchCore

@Suite struct DiagnosticRecorderTests {
    private func record(_ key: UInt64? = nil, app: String = "Notes") -> DiagnosticRecord {
        DiagnosticRecord(requestKey: key, kind: .suggestion, appName: app)
    }

    @Test func isOffByDefaultAndRecordsNothing() {
        let recorder = DiagnosticRecorder()
        #expect(!recorder.isEnabled)
        #expect(recorder.record(record()) == nil)
        #expect(recorder.entries.isEmpty)
    }

    @Test func recordsNewestFirstWhileOn() {
        let recorder = DiagnosticRecorder()
        recorder.enable()
        #expect(recorder.record(record(app: "First")) == 1)
        #expect(recorder.record(record(app: "Second")) == 2)
        #expect(recorder.entries.map(\.appName) == ["Second", "First"])
        #expect(recorder.entries.map(\.id) == [2, 1])
    }

    @Test func keepsOnlyTheLastFifty() {
        let recorder = DiagnosticRecorder()
        #expect(recorder.capacity == 50)
        recorder.enable()
        for n in 1...60 { recorder.record(record(UInt64(n))) }
        let entries = recorder.entries
        #expect(entries.count == 50)
        #expect(entries.first?.requestKey == 60)
        #expect(entries.last?.requestKey == 11)
    }

    @Test func closingThrowsEverythingAwayAndStopsRecording() {
        let recorder = DiagnosticRecorder()
        recorder.enable()
        recorder.record(record())
        recorder.disable()
        #expect(!recorder.isEnabled)
        #expect(recorder.entries.isEmpty)
        #expect(recorder.record(record()) == nil)
        // Reopening starts from an empty list.
        recorder.enable()
        #expect(recorder.entries.isEmpty)
    }

    @Test func updateChangesTheNewestRecordForARequest() {
        let recorder = DiagnosticRecorder()
        recorder.enable()
        recorder.record(record(7, app: "Old"))
        recorder.record(record(7, app: "New"))
        recorder.record(record(8))
        recorder.update(requestKey: 7) { $0.fate = .shown("hello") }
        let byKey = recorder.entries.filter { $0.requestKey == 7 }
        #expect(byKey.first?.fate == .shown("hello"))
        #expect(byKey.last?.fate == .notApplicable)
        // Other kinds, and unknown requests, are left alone.
        recorder.update(requestKey: 7, kind: .dictation) { $0.fate = .cancelled }
        recorder.update(requestKey: 99) { $0.fate = .cancelled }
        #expect(recorder.entries.filter { $0.fate == .cancelled }.isEmpty)
    }

    @Test func updateIsANoOpWhileOff() {
        let recorder = DiagnosticRecorder()
        var called = false
        recorder.update(requestKey: 1) { _ in called = true }
        #expect(!called)
    }

    @Test func observersHearAboutChangesAndClosing() {
        let recorder = DiagnosticRecorder()
        let count = Atomic<Int>(0)
        let token = recorder.addObserver { count.add(1, ordering: .relaxed) }
        recorder.enable()
        recorder.record(record(1))
        recorder.update(requestKey: 1) { $0.note = "x" }
        recorder.disable()
        #expect(count.load(ordering: .relaxed) == 3)
        recorder.removeObserver(token)
        recorder.enable()
        recorder.record(record(2))
        #expect(count.load(ordering: .relaxed) == 3)
    }

    @Test func entriesStaySmallEnoughToHoldInMemory() {
        // The record is a plain value: a list of 50 is a few hundred kilobytes at most, and never
        // touches disk (the recorder has no file API at all).
        let recorder = DiagnosticRecorder(capacity: 3)
        recorder.enable()
        for n in 1...5 { recorder.record(record(UInt64(n))) }
        #expect(recorder.entries.count == 3)
    }
}
