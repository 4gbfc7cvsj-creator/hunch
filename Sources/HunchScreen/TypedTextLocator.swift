import AppKit
import Carbon.HIToolbox
import CoreGraphics
import HunchCore
import ScreenCaptureKit

/// Finds a field's typed line on screen when the host reports no text positions (Chrome's address
/// bar answers every range with an empty rect and reports no font), so the caret can be placed
/// after it. Captures a band around the field's frame (hosts misreport it: Chrome's address bar
/// frame sat ~330 pt left of the real one), analyzes it in memory, and keeps a few numbers
/// (`TypedTextAnchor`). Match and verify as in `TextCalibrationProbe`: only a confident fit of the
/// whole typed line, with nothing painted right after it, is used.
/// Requires Screen Recording permission; does nothing without it or during Secure Input.
public final class TypedTextLocator: Sendable {
    public init() {}

    /// - Parameters:
    ///   - fieldFrame: the field, AppKit global coordinates.
    ///   - text: the field's whole text before the caret (one line, caret at its end).
    ///   - font: the host's reported font, if any.
    public func locate(pid: pid_t, fieldFrame field: CGRect, text: String, font hint: FontHint?,
                       ownPid: pid_t) async -> TypedTextAnchor? {
        guard CGPreflightScreenCaptureAccess(), !IsSecureEventInputEnabled(),
              TypedTextAnchor.isEligible(before: text),
              field.width >= TextCalibrationProbe.minStripWidth, field.height > 6, field.height <= 80 else {
            DrawDebugLog.note("locate skipped: access=\(CGPreflightScreenCaptureAccess()) field=\(DrawDebugLog.fmt(field))")
            return nil
        }
        // The band: a quarter of the field's width to its left, a whole width to its right, half its
        // height above and below, clipped to the host's window.
        let band = CGRect(x: field.minX - field.width * 0.25, y: field.minY - field.height * 0.5,
                          width: field.width * 2.25, height: field.height * 2)
        guard let captured = await Self.captureDisplay(strip: band, anchor: CGPoint(x: field.midX, y: field.midY),
                                                       pid: pid, ownPid: ownPid)
        else { return nil }
        let px = captured.pixelsPerPoint
        // No caret to size from: without a reported size, every size that fits the field is tried.
        let sizes = hint?.pointSize.map { TemplateMatch.candidateSizes(reported: $0, caretHeight: $0) }
            ?? TemplateMatch.locateSizes(fieldHeight: field.height)
        let started = ContinuousClock.now
        let found = TemplateMatch.locate(gray: captured.gray.bytes, width: captured.gray.width,
                                         height: captured.gray.height, scale: px, text: text,
                                         sizes: sizes,
                                         font: { TextCalibrationProbe.font(for: hint, size: $0) })
        if DrawDebugLog.isEnabled {
            let url = DrawDebugLog.logDirectory.appendingPathComponent("locate-strip.png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, captured.image, nil)
                CGImageDestinationFinalize(dest)
            }
            DrawDebugLog.note("locate field=\(DrawDebugLog.fmt(field)) px=\(captured.gray.width)x\(captured.gray.height) "
                + "fit=\(found.map { String(format: "size=%.2f start=%.1f end=%.1f baselineRow=%.2f score=%.3f trailing=%.2f", $0.pointSize, $0.startColumn, $0.endColumn, $0.baselineRow, $0.score, $0.trailingInk) } ?? "nil") "
                + "time=\(ContinuousClock.now - started)")
        }
        guard let found, found.isConfident else {
            DrawDebugLog.note("locate rejected: no confident match")
            return nil
        }
        // Capture pixels -> AppKit global points.
        let startX = captured.inside.minX + CGFloat(found.startColumn) / px
        let baselineCG = captured.inside.minY + CGFloat(found.baselineRow) / px
        let baseline = captured.primaryHeight - baselineCG
        // Text running past what was captured is scrolled or cut off by the host: the caret is
        // placed only while it stays two ems inside the captured band.
        let visibleRight = captured.inside.maxX - found.pointSize * 2
        let anchor = TypedTextAnchor(startOffset: startX - field.minX, baselineOffset: baseline - field.minY,
                                     pointSize: found.pointSize, rightLimitMargin: visibleRight - field.maxX)
        DrawDebugLog.note(String(format: "locate anchor start=%.1f baseline=%.1f limit=%.1f (field-relative)",
                                 anchor.startOffset, anchor.baselineOffset, visibleRight - field.minX))
        return anchor
    }

    /// Captures `strip` (AppKit global) as it shows on the display holding `anchor`, without
    /// Hunch's own windows. Not one window: Chrome redraws the address bar in its dropdown,
    /// a separate window, and a capture of that window came back offset by the window's origin.
    /// Nil unless the host is the frontmost app on that spot.
    static func captureDisplay(strip: CGRect, anchor: CGPoint, pid: pid_t,
                               ownPid: pid_t) async -> TextCalibrationProbe.CapturedStrip? {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let stripCG = CGRect(x: strip.minX, y: primaryHeight - strip.maxY, width: strip.width, height: strip.height)
        let anchorCG = CGPoint(x: anchor.x, y: primaryHeight - anchor.y)
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { DrawDebugLog.note("locate skipped: no shareable content"); return nil }
        // The window on top at the field must be the host's (or ours): anything else covers the field.
        let infos = content.windows.map {
            WindowInfo(id: $0.windowID, pid: $0.owningApplication?.processID ?? -1, frame: $0.frame,
                       layer: $0.windowLayer, isOnScreen: $0.isOnScreen)
        }
        let top = WindowSelection.frontToBack(infos, order: WindowSelection.stackingOrder()).first {
            $0.pid != ownPid && $0.layer == 0 && $0.isOnScreen && $0.frame.contains(anchorCG)
        }
        guard top?.pid == pid,
              let display = content.displays.first(where: { $0.frame.contains(anchorCG) })
        else { DrawDebugLog.note("locate skipped: no host window or display at the field"); return nil }
        let inside = stripCG.intersection(display.frame)
        guard !inside.isNull, inside.height >= 8, inside.width >= TextCalibrationProbe.minStripWidth else { return nil }

        let own = content.applications.filter { $0.processID == ownPid }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: inside.minX - display.frame.minX, y: inside.minY - display.frame.minY,
                                   width: inside.width, height: inside.height)
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(inside.width * scale))
        config.height = max(1, Int(inside.height * scale))
        config.showsCursor = false
        config.capturesAudio = false
        guard !IsSecureEventInputEnabled(),
              let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let gray = TextCalibrationProbe.grayscale(image)
        else { DrawDebugLog.note("locate skipped: capture failed"); return nil }
        return TextCalibrationProbe.CapturedStrip(image: image, gray: gray, inside: inside,
                                                  pixelsPerPoint: CGFloat(gray.height) / inside.height,
                                                  primaryHeight: primaryHeight)
    }
}
