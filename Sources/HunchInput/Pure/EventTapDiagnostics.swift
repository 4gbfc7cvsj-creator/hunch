import Foundation

/// Where a tap sits in the event stream (`CGEventTapLocation` raw values). HID taps see events
/// first, then session taps, then annotated-session taps.
public enum TapLocation: Sendable, Equatable {
    case hid, session, annotatedSession
    case other(UInt32)

    public init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .hid
        case 1: self = .session
        case 2: self = .annotatedSession
        default: self = .other(rawValue)
        }
    }
}

/// One entry of the system's event-tap list (`KeyboardMonitor.snapshotTaps()`), reduced to what
/// the analyzer reads. Describes the tap, never the events it saw.
public struct TapInfo: Sendable, Equatable {
    /// Process that installed the tap.
    public var pid: pid_t
    /// 0 for a tap on the whole stream; otherwise it only sees events bound for this process.
    public var targetPID: pid_t
    public var location: TapLocation
    /// `CGEventTapOptions` raw value: 0 = may consume or change events, 1 = listen-only.
    public var options: UInt32
    public var eventsMask: UInt64
    public var enabled: Bool
    /// Average callback latency in microseconds as reported by the system (0 = none measured).
    public var averageLatencyMicros: Double

    public init(pid: pid_t, targetPID: pid_t = 0, location: TapLocation, options: UInt32, eventsMask: UInt64,
                enabled: Bool = true, averageLatencyMicros: Double = 0) {
        self.pid = pid
        self.targetPID = targetPID
        self.location = location
        self.options = options
        self.eventsMask = eventsMask
        self.enabled = enabled
        self.averageLatencyMicros = averageLatencyMicros
    }

    public var isListenOnly: Bool { options != 0 }
}

/// Finds event taps that can keep keys from Hunch's consuming tap, which is appended at the
/// tail of the session stream: every consuming key tap at HID or session level runs before it.
public enum EventTapDiagnostics {
    /// `1 << CGEventType.keyDown.rawValue` (keyDown = 10).
    public static let keyDownMask: UInt64 = 1 << 10
    /// An own tap averaging this long per event makes typing lag and risks a system timeout.
    public static let slowAverageMicros: Double = 50_000
    /// The system disables a tap that blocks for about a second, so larger averages are not real
    /// measurements (seen on macOS 27 for taps that had not handled an event yet).
    public static let implausibleLatencyMicros: Double = 5_000_000

    /// Another process with a consuming key tap ahead of Hunch's.
    public struct Interceptor: Sendable, Equatable {
        public var pid: pid_t
        /// HID when any of its flagged taps is at HID level (it runs earliest), else session.
        public var location: TapLocation
        public init(pid: pid_t, location: TapLocation) {
            self.pid = pid
            self.location = location
        }
    }

    /// A problem with Hunch's own taps.
    public enum OwnTapIssue: Sendable, Equatable {
        /// The listen-only tap is off, so typing goes unseen.
        case disabled
        case slow(averageMicros: Double)
    }

    public struct Report: Sendable, Equatable {
        /// One entry per process, in tap-list order.
        public var interceptors: [Interceptor]
        public var ownIssues: [OwnTapIssue]
        public init(interceptors: [Interceptor] = [], ownIssues: [OwnTapIssue] = []) {
            self.interceptors = interceptors
            self.ownIssues = ownIssues
        }
        public var isEmpty: Bool { interceptors.isEmpty && ownIssues.isEmpty }
    }

    /// Flags enabled consuming taps of other processes that see keyDown at HID or session level,
    /// plus Hunch's own taps when its listen-only tap is disabled or any own tap is slow.
    /// Listen-only taps, per-process taps, annotated-session taps (they run after Hunch's)
    /// and masks without keyDown are ignored. Hunch's consuming tap is off unless a ghost is
    /// visible or a shortcut is bound, so its being disabled is not an issue.
    public static func analyze(taps: [TapInfo], ownPID: pid_t) -> Report {
        var report = Report()
        var indexByPID: [pid_t: Int] = [:]
        var ownDisabled = false
        var slowest: Double?
        for tap in taps {
            if tap.pid == ownPID {
                if tap.isListenOnly, !tap.enabled { ownDisabled = true }
                let average = tap.averageLatencyMicros
                if average >= slowAverageMicros, average < implausibleLatencyMicros {
                    slowest = max(slowest ?? 0, average)
                }
                continue
            }
            guard tap.enabled, !tap.isListenOnly, tap.targetPID == 0,
                  tap.eventsMask & keyDownMask != 0,
                  tap.location == .hid || tap.location == .session else { continue }
            if let index = indexByPID[tap.pid] {
                if tap.location == .hid { report.interceptors[index].location = .hid }
            } else {
                indexByPID[tap.pid] = report.interceptors.count
                report.interceptors.append(Interceptor(pid: tap.pid, location: tap.location))
            }
        }
        if ownDisabled { report.ownIssues.append(.disabled) }
        if let slowest { report.ownIssues.append(.slow(averageMicros: slowest)) }
        return report
    }
}

/// User-facing wording for the menu's problem line and Settings → Privacy & Data → Diagnostics.
public enum DiagnosticsWording {
    public static let terminalBundleID = "com.apple.Terminal"
    public static let noInterceptors = "No other app intercepts keys."

    /// The app's name, or "pid <n>" for a process without one.
    public static func processName(_ localizedName: String?, pid: pid_t) -> String {
        guard let name = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "pid \(pid)"
        }
        return name
    }

    /// Menu problem line. `ownerName` nil: the owner is unknown (loginwindow and other system
    /// processes often hold Secure Input without reporting a pid).
    public static func secureInputProblem(ownerName: String?, ownerBundleID: String?) -> String {
        let line = "Secure Input is on in \(ownerName ?? "a system process"); suggestions paused"
        guard ownerBundleID == terminalBundleID else { return line }
        return line + " (turn off Secure Keyboard Entry in Terminal's menu)"
    }

    /// Settings row.
    public static func secureInputStatus(ownerName: String?) -> String {
        "Secure Input is on in \(ownerName ?? "a system process")"
    }

    /// Shown next to each flagged app in Settings. Not in the menu: these taps are often
    /// harmless (Siri's passes Tab through), so a menu warning would show while everything works.
    public static let interceptorWarning = "This app's event tap may block shortcuts"

    /// Secondary caption under a flagged app in Settings.
    public static func caption(_ location: TapLocation) -> String {
        switch location {
        case .hid: "consuming tap at HID level"
        case .session: "consuming tap at session level"
        case .annotatedSession: "consuming tap at annotated session level"
        case .other(let raw): "consuming tap at level \(raw)"
        }
    }

    /// Secondary caption under Hunch's own row in Settings.
    public static func caption(_ issue: EventTapDiagnostics.OwnTapIssue) -> String {
        switch issue {
        case .disabled: "keyboard tap is disabled"
        case .slow(let micros): "keyboard tap is slow (\(Int((micros / 1000).rounded())) ms per key on average)"
        }
    }

    /// Settings caption for a flagged app; system processes are marked " (system)".
    public static func caption(_ app: InterceptingApp) -> String {
        caption(app.location) + (app.isSystem ? " (system)" : "")
    }
}

/// A flagged process with its resolved name, for `DiagnosticsWording`.
public struct InterceptingApp: Sendable, Equatable {
    public var name: String
    public var bundleID: String?
    public var location: TapLocation

    public init(name: String, bundleID: String?, location: TapLocation) {
        self.name = name
        self.bundleID = bundleID
        self.location = location
    }

    /// Apple's own processes, and daemons without a bundle id (no app the user could quit).
    public var isSystem: Bool {
        guard let bundleID else { return true }
        return bundleID.hasPrefix("com.apple.")
    }
}
