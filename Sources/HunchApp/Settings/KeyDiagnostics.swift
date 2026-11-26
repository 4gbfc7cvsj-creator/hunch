import AppKit
import HunchInput
import HunchPolicy

/// Thin glue for the key-interception diagnostics: the system calls and app-name lookups.
/// What counts as a problem and how it is worded live in HunchInput (`EventTapDiagnostics`,
/// `DiagnosticsWording`). Everything here is best-effort and returns quickly.
enum KeyDiagnostics {
    /// One flagged app (or Hunch itself) for Settings → Privacy & Data → Diagnostics.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let caption: String
        /// Set on other apps' rows, nil on Hunch's own.
        var warning: String?
    }

    struct Snapshot: Equatable {
        var rows: [Row] = []
        /// "Secure Input is on in <App>", nil while Secure Input is off.
        var secureInput: String?
    }

    static func appName(pid: pid_t) -> String {
        DiagnosticsWording.processName(NSRunningApplication(processIdentifier: pid)?.localizedName, pid: pid)
    }

    static func bundleID(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    static func report() -> EventTapDiagnostics.Report {
        EventTapDiagnostics.analyze(taps: KeyboardMonitor.snapshotTaps(),
                                    ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    static func interceptingApps(_ report: EventTapDiagnostics.Report) -> [InterceptingApp] {
        report.interceptors.map { found in
            InterceptingApp(name: appName(pid: found.pid), bundleID: bundleID(pid: found.pid), location: found.location)
        }
    }

    static func snapshot() -> Snapshot {
        let report = report()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var rows = zip(report.interceptors, interceptingApps(report)).map { found, app in
            Row(id: "\(found.pid)", name: app.name, caption: DiagnosticsWording.caption(app),
                warning: DiagnosticsWording.interceptorWarning)
        }
        rows += report.ownIssues.map { issue in
            let caption = DiagnosticsWording.caption(issue)
            return Row(id: "own \(caption)", name: appName(pid: ownPID), caption: caption)
        }
        var secureInput: String?
        if SecureInputProbe.isSecureEventInputEnabled() {
            secureInput = DiagnosticsWording.secureInputStatus(ownerName: SecureInputProbe.ownerPID().map(appName(pid:)))
        }
        return Snapshot(rows: rows, secureInput: secureInput)
    }
}
