import Foundation
import HunchCore

/// Opt-in caret-geometry trace for diagnosing hosts whose ghost lands in the wrong place.
/// Enabled only while `~/Library/Application Support/Hunch/debug-geometry` exists; writes to
/// `~/Library/Logs/Hunch/geometry.log`. Records bundle IDs, caret offsets, rects, and font
/// metadata only, never field text.
final class GeometryDebugLog: @unchecked Sendable {
    static let shared = GeometryDebugLog()

    private let lock = NSLock()
    private var line = ""
    private var enabledCheckedAt = Date.distantPast
    private var enabled = false
    private var lastLine = ""

    private let flagURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Hunch/debug-geometry")
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Hunch/geometry.log")

    /// Re-checks the flag file at most every 2 s so enabling it needs no relaunch.
    private var isEnabled: Bool {
        let now = Date()
        if now.timeIntervalSince(enabledCheckedAt) > 2 {
            enabledCheckedAt = now
            enabled = FileManager.default.fileExists(atPath: flagURL.path)
        }
        return enabled
    }

    func begin(bundleID: String, caret: Int, frame: CGRect?, font: FontHint?, previousIsBreak: Bool,
               nextIsBreakOrEnd: Bool, nextScalar: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        guard isEnabled else { line = ""; return }
        var fontText = "nil"
        if let font {
            let color = font.textColor.map { String(format: "rgb(%.2f,%.2f,%.2f)", $0.red, $0.green, $0.blue) } ?? "nil"
            fontText = "\(font.family ?? "?")/\(font.name ?? "?")@\(font.pointSize.map { "\($0)" } ?? "?") color=\(color)"
        }
        line = "\(bundleID) caret=\(caret) prevBreak=\(previousIsBreak) nextBreakOrEnd=\(nextIsBreakOrEnd) "
            + "next=\(nextScalar.map { String(format: "U+%04X", $0) } ?? "none") "
            + "frame=\(Self.fmt(frame)) font=\(fontText)"
    }

    func step(_ name: String, _ rect: CGRect?, _ accepted: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !line.isEmpty else { return }
        line += " | \(name)=\(Self.fmt(rect))\(accepted ? " ok" : rect == nil ? "" : " rejected")"
    }

    func done(_ geometry: CaretGeometry) -> CaretGeometry {
        lock.lock(); defer { lock.unlock() }
        if !line.isEmpty { line += " => \(geometry.quality) appkit=\(Self.fmt(geometry.caretRect))" }
        return geometry
    }

    /// A one-line event outside the caret ladder (blocked fields, failed reads).
    func note(_ text: String) {
        lock.lock()
        let on = isEnabled
        lock.unlock()
        guard on else { return }
        begin(raw: text)
        flush()
    }

    private func begin(raw: String) {
        lock.lock(); defer { lock.unlock() }
        line = raw
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        guard !line.isEmpty else { return }
        defer { line = "" }
        // The tracker polls; skip identical consecutive traces.
        guard line != lastLine else { return }
        lastLine = line
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: logURL)
        }
    }

    private static func fmt(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return String(format: "(%.1f,%.1f %.1fx%.1f)", r.minX, r.minY, r.width, r.height)
    }
}
