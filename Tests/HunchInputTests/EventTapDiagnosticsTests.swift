import Foundation
import Testing
@testable import HunchInput

// MARK: Event-tap analyzer

private let own: pid_t = 100
private let keyMask: UInt64 = (1 << 10) | (1 << 11) | (1 << 12)   // keyDown, keyUp, flagsChanged
private let mouseMask: UInt64 = (1 << 1) | (1 << 3) | (1 << 25)  // left/right mouse down, other mouse down

@Test func emptyTapListReportsNothing() {
    #expect(EventTapDiagnostics.analyze(taps: [], ownPID: own).isEmpty)
}

@Test func ownTapsAreIgnoredWhenHealthy() {
    let taps = [
        TapInfo(pid: own, location: .session, options: 1, eventsMask: keyMask),
        // The consuming tap is off unless a ghost is visible: not an issue.
        TapInfo(pid: own, location: .session, options: 0, eventsMask: 1 << 10, enabled: false),
    ]
    #expect(EventTapDiagnostics.analyze(taps: taps, ownPID: own).isEmpty)
}

@Test func listenOnlyTapsOfOtherAppsAreIgnored() {
    let taps = [TapInfo(pid: 200, location: .session, options: 1, eventsMask: keyMask),
                TapInfo(pid: 201, location: .hid, options: 1, eventsMask: ~0)]
    #expect(EventTapDiagnostics.analyze(taps: taps, ownPID: own).isEmpty)
}

@Test func consumingKeyDownTapIsFlagged() {
    let taps = [TapInfo(pid: 200, location: .session, options: 0, eventsMask: keyMask)]
    let report = EventTapDiagnostics.analyze(taps: taps, ownPID: own)
    #expect(report.interceptors == [.init(pid: 200, location: .session)])
    #expect(report.ownIssues.isEmpty)
}

@Test func allEventsMaskCountsAsKeyDown() {
    let taps = [TapInfo(pid: 200, location: .hid, options: 0, eventsMask: ~0)]
    #expect(EventTapDiagnostics.analyze(taps: taps, ownPID: own).interceptors == [.init(pid: 200, location: .hid)])
}

@Test func mouseOnlyMasksAreIgnored() {
    let taps = [TapInfo(pid: 200, location: .session, options: 0, eventsMask: mouseMask),
                TapInfo(pid: 201, location: .hid, options: 0, eventsMask: 1 << 12)]   // flagsChanged only
    #expect(EventTapDiagnostics.analyze(taps: taps, ownPID: own).isEmpty)
}

@Test func tapsThatRunAfterOursOrAreOffAreIgnored() {
    let taps = [
        TapInfo(pid: 200, location: .annotatedSession, options: 0, eventsMask: keyMask),
        TapInfo(pid: 201, targetPID: 300, location: .session, options: 0, eventsMask: keyMask),
        TapInfo(pid: 202, location: .session, options: 0, eventsMask: keyMask, enabled: false),
    ]
    #expect(EventTapDiagnostics.analyze(taps: taps, ownPID: own).isEmpty)
}

@Test func oneEntryPerProcessPreferringHID() {
    let taps = [
        TapInfo(pid: 200, location: .session, options: 0, eventsMask: keyMask),
        TapInfo(pid: 300, location: .session, options: 0, eventsMask: keyMask),
        TapInfo(pid: 200, location: .hid, options: 0, eventsMask: keyMask),
    ]
    #expect(EventTapDiagnostics.analyze(taps: taps, ownPID: own).interceptors
            == [.init(pid: 200, location: .hid), .init(pid: 300, location: .session)])
}

@Test func disabledOwnListenTapIsFlagged() {
    let taps = [TapInfo(pid: own, location: .session, options: 1, eventsMask: keyMask, enabled: false)]
    #expect(EventTapDiagnostics.analyze(taps: taps, ownPID: own).ownIssues == [.disabled])
}

@Test func slowOwnTapIsFlaggedWithTheSlowestAverage() {
    let taps = [TapInfo(pid: own, location: .session, options: 1, eventsMask: keyMask, averageLatencyMicros: 60_000),
                TapInfo(pid: own, location: .session, options: 0, eventsMask: 1 << 10, averageLatencyMicros: 90_000)]
    #expect(EventTapDiagnostics.analyze(taps: taps, ownPID: own).ownIssues == [.slow(averageMicros: 90_000)])
}

@Test func fastOrImplausibleOwnLatencyIsNotFlagged() {
    let taps = [TapInfo(pid: own, location: .session, options: 1, eventsMask: keyMask, averageLatencyMicros: 300),
                TapInfo(pid: own, location: .session, options: 0, eventsMask: 1 << 10, averageLatencyMicros: 4.27e8)]
    #expect(EventTapDiagnostics.analyze(taps: taps, ownPID: own).isEmpty)
}

@Test func tapLocationMapsRawValues() {
    #expect(TapLocation(rawValue: 0) == .hid)
    #expect(TapLocation(rawValue: 1) == .session)
    #expect(TapLocation(rawValue: 2) == .annotatedSession)
    #expect(TapLocation(rawValue: 9) == .other(9))
}

// MARK: Diagnostics wording

@Test func processNameFallsBackToPID() {
    #expect(DiagnosticsWording.processName("Siri", pid: 42) == "Siri")
    #expect(DiagnosticsWording.processName(nil, pid: 42) == "pid 42")
    #expect(DiagnosticsWording.processName("  ", pid: 42) == "pid 42")
}

@Test func secureInputLineNamesTheOwner() {
    #expect(DiagnosticsWording.secureInputProblem(ownerName: "1Password", ownerBundleID: "com.1password.1password")
            == "Secure Input is on in 1Password; suggestions paused")
    #expect(DiagnosticsWording.secureInputProblem(ownerName: nil, ownerBundleID: nil)
            == "Secure Input is on in a system process; suggestions paused")
    #expect(DiagnosticsWording.secureInputStatus(ownerName: "Terminal") == "Secure Input is on in Terminal")
    #expect(DiagnosticsWording.secureInputStatus(ownerName: nil) == "Secure Input is on in a system process")
}

@Test func secureInputLineHintsTerminalSecureKeyboardEntry() {
    #expect(DiagnosticsWording.secureInputProblem(ownerName: "Terminal", ownerBundleID: "com.apple.Terminal")
            == "Secure Input is on in Terminal; suggestions paused (turn off Secure Keyboard Entry in Terminal's menu)")
}

@Test func interceptorWarningWording() {
    #expect(DiagnosticsWording.interceptorWarning == "This app's event tap may block shortcuts")
}

@Test func captionsDescribeTheTap() {
    #expect(DiagnosticsWording.caption(TapLocation.session) == "consuming tap at session level")
    #expect(DiagnosticsWording.caption(TapLocation.hid) == "consuming tap at HID level")
    #expect(DiagnosticsWording.caption(EventTapDiagnostics.OwnTapIssue.slow(averageMicros: 62_400))
            == "keyboard tap is slow (62 ms per key on average)")
}

@Test func systemProcessesAreMarkedInSettings() {
    let siri = InterceptingApp(name: "Siri", bundleID: "com.apple.Siri", location: .session)
    let daemon = InterceptingApp(name: "pid 7", bundleID: nil, location: .session)
    let karabiner = InterceptingApp(name: "Karabiner-Elements", bundleID: "org.pqrs.Karabiner-Elements", location: .hid)
    #expect(DiagnosticsWording.caption(siri) == "consuming tap at session level (system)")
    #expect(DiagnosticsWording.caption(daemon) == "consuming tap at session level (system)")
    #expect(DiagnosticsWording.caption(karabiner) == "consuming tap at HID level")
}
