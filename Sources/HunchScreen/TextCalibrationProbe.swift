import AppKit
import Carbon.HIToolbox
import CoreGraphics
import HunchCore
import ScreenCaptureKit

/// Measures where the host really painted the text before the caret (baseline and x-height), so
/// the ghost matches hosts whose font Hunch can't load (web fonts in Electron apps) or whose
/// caret rect doesn't say where the baseline is. Captures only a thin strip of the host's own
/// window just left of the caret, analyzes it in memory, and keeps nothing but a few numbers.
///
/// Match and verify: the text known to be before the caret is drawn at candidate sizes and slid
/// over the capture (`TemplateMatch`); only a confident fit is used. A capture that doesn't show
/// that text (the wrong window, a separator, another line) gives no calibration, and the ghost
/// falls back to the caret rect and reported font.
/// Requires Screen Recording permission; does nothing without it or during Secure Input.
public final class TextCalibrationProbe: Sendable {
    public init() {}

    /// `caretRect` is in AppKit global coordinates.
    /// Smallest strip of typed text worth measuring (points).
    public static let minStripWidth: CGFloat = 24

    /// True when there is enough typed text left of the caret, inside the field, to measure.
    public static func hasRoom(caretRect caret: CGRect, fieldFrame: CGRect?) -> Bool {
        guard let field = fieldFrame, field.width > 0 else { return true }
        return caret.minX - 1 - (field.minX + 2) >= minStripWidth
    }

    /// - Parameters:
    ///   - lineText: the text before the caret on its line (what should appear in the strip).
    ///   - font: the host's reported font, if any.
    public func measure(pid: pid_t, caretRect caret: CGRect, fieldFrame: CGRect? = nil,
                        lineText: String, font hint: FontHint?, ownPid: pid_t) async -> TextCalibration? {
        guard CGPreflightScreenCaptureAccess(), !IsSecureEventInputEnabled(), caret.height > 4,
              lineText.contains(where: { !$0.isWhitespace }) else {
            DrawDebugLog.note("calibrate skipped: access=\(CGPreflightScreenCaptureAccess()) secure=\(IsSecureEventInputEnabled()) caretH=\(caret.height)")
            return nil
        }
        // Strip of already-typed text ending just before the caret, with room above and below the line.
        // It never reaches left of the field: buttons and icons beside the text box (a "+" attach
        // button, a settings gear) would otherwise be measured as text.
        var left = caret.minX - 1 - min(240, max(caret.height * 8, 80))
        if let field = fieldFrame, field.width > 0 { left = max(left, field.minX + 2) }
        let width = caret.minX - 1 - left
        guard width >= Self.minStripWidth else { DrawDebugLog.note("calibrate skipped: strip width \(width)"); return nil }
        let strip = CGRect(x: left, y: caret.minY - caret.height * 0.6,
                           width: width, height: caret.height * 2.2)
        guard let captured = await Self.capture(pid: pid, strip: strip, anchor: CGPoint(x: caret.midX, y: caret.midY),
                                                ownPid: ownPid, minWidth: Self.minStripWidth, label: "calibrate")
        else { return nil }
        let (image, gray, inside, pixelsPerPoint, primaryHeight) =
            (captured.image, captured.gray, captured.inside, captured.pixelsPerPoint, captured.primaryHeight)
        let caretCG = CGRect(x: caret.minX, y: primaryHeight - caret.maxY, width: caret.width, height: caret.height)
        // The strip ends 1 pt left of the caret; the drawn text should end at the caret itself.
        let caretColumn = Double((caretCG.minX - inside.minX) * pixelsPerPoint)
        let started = ContinuousClock.now
        let fit = TemplateMatch.fit(gray: gray.bytes, width: gray.width, height: gray.height, scale: pixelsPerPoint,
                                    text: lineText, caretColumn: caretColumn,
                                    sizes: TemplateMatch.candidateSizes(reported: hint?.pointSize, caretHeight: caret.height),
                                    font: { Self.font(for: hint, size: $0) })
        let elapsed = ContinuousClock.now - started
        if DrawDebugLog.isEnabled {
            // Debug only: keep the latest strip so the measurement can be checked by eye.
            let url = DrawDebugLog.logDirectory.appendingPathComponent("calibration-strip.png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
            DrawDebugLog.note("calibrate strip=\(DrawDebugLog.fmt(strip)) caret=\(DrawDebugLog.fmt(caret)) px=\(gray.width)x\(gray.height) "
                + "fit=\(fit.map { String(format: "size=%.2f baselineRow=%.2f dx=%d score=%.3f", $0.pointSize, $0.baselineRow, $0.shiftColumns, $0.score) } ?? "nil") "
                + "reported=\(hint?.pointSize.map { String(format: "%.1f", $0) } ?? "nil") time=\(elapsed)")
        }
        guard let fit, fit.score >= TemplateMatch.minimumScore else {
            DrawDebugLog.note("calibrate rejected: no confident match")
            return nil
        }
        let baselineCG = inside.minY + CGFloat(fit.baselineRow) / pixelsPerPoint
        let baselineAppKit = primaryHeight - baselineCG
        let offset = baselineAppKit - caret.minY
        // Even a good match must sit on the caret's own line.
        guard offset > -caret.height * 0.3, offset < caret.height * 0.8 else {
            DrawDebugLog.note("calibrate rejected offset=\(offset)")
            return nil
        }
        let xHeight = CGFloat(fit.xHeightPixels) / pixelsPerPoint
        let plausibleX = xHeight > caret.height * 0.2 && xHeight < caret.height * 0.8
        // The field's background behind the line (mirror mode paints it), from the same capture: the
        // strip's first and last columns across the caret's rows. Trusted only now that the strip
        // is known to show the typed text.
        let background = Self.rgba(image).flatMap { px -> RGBAColor? in
            let top = Int(((caretCG.minY - inside.minY) * pixelsPerPoint).rounded(.down))
            let bottom = Int(((caretCG.maxY - inside.minY) * pixelsPerPoint).rounded(.up))
            return StripBackground.modalColor(rgba: px.bytes, width: px.width, height: px.height,
                                              columns: [0, px.width - 1], rows: top..<max(top, bottom))
        }
        // Letter height straight from the host's ink, and from the same text drawn in the faces the
        // ghost could use, measured the same way (so any bias of the measurement cancels out).
        let hostX = InkBaseline.lineXHeight(gray: gray.bytes, width: gray.width, height: gray.height,
                                            baselineRow: fit.baselineRow,
                                            caretPixels: Double(caret.height * pixelsPerPoint))
            .map { CGFloat($0) / pixelsPerPoint }
        let size = hint?.pointSize ?? fit.pointSize
        var faces: [String: CGFloat] = [:]
        if hostX != nil {
            let visible = String(lineText.suffix(200)).replacingOccurrences(of: "\t", with: " ")
            func inkX(_ f: CTFont) -> CGFloat? {
                InkBaseline.drawnXHeight(text: visible, font: f, width: gray.width, height: gray.height,
                                         scale: pixelsPerPoint, rightEdge: caretColumn)
                    .map { CGFloat($0) / pixelsPerPoint }
            }
            if let own = Self.loadedHostFont(for: hint, size: size) {
                faces[TextCalibration.hostFontKey] = inkX(own)
            } else if hint?.isMonospaced != true {
                for family in FaceMatch.candidates {
                    if let f = Self.installedFace(family, size: size), let x = inkX(f) { faces[family] = x }
                }
            }
        }
        DrawDebugLog.note("calibrate inkX host=\(hostX.map { String(format: "%.2f", $0) } ?? "nil") at=\(String(format: "%.1f", size)) "
            + faces.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " "))
        return TextCalibration(baselineAboveCaretBottom: offset, xHeight: plausibleX ? xHeight : nil,
                               pointSize: fit.pointSize, score: fit.score, backgroundColor: background,
                               hostXHeight: hostX, measuredAtSize: size, faceXHeights: faces)
    }

    /// A capture of part of the host's own window, in memory only.
    struct CapturedStrip {
        let image: CGImage
        let gray: (bytes: [UInt8], width: Int, height: Int)
        /// The captured rect, in the global top-left space ScreenCaptureKit uses.
        let inside: CGRect
        let pixelsPerPoint: CGFloat
        let primaryHeight: CGFloat
    }

    /// Captures `strip` (AppKit global) from the window of `pid` that holds `anchor` (AppKit
    /// global). Nil without a fitting window, when the strip leaves the window, or during Secure Input.
    /// `clipToWindow`: capture the part of `strip` inside the window instead of requiring all of it.
    static func capture(pid: pid_t, strip: CGRect, anchor: CGPoint, ownPid: pid_t, minWidth: CGFloat,
                        label: String, clipToWindow: Bool = false) async -> CapturedStrip? {
        // ScreenCaptureKit frames use the global top-left space of the primary display.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let stripCG = CGRect(x: strip.minX, y: primaryHeight - strip.maxY, width: strip.width, height: strip.height)
        let anchorCG = CGPoint(x: anchor.x, y: primaryHeight - anchor.y)

        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { DrawDebugLog.note("\(label) skipped: no shareable content"); return nil }
        let infos = content.windows.map {
            WindowInfo(id: $0.windowID, pid: $0.owningApplication?.processID ?? -1, frame: $0.frame,
                       layer: $0.windowLayer, isOnScreen: $0.isOnScreen)
        }
        guard let chosen = WindowSelection.select(windows: WindowSelection.frontToBack(infos, order: WindowSelection.stackingOrder()), targetPid: pid, ownPid: ownPid,
                                                  anchor: anchorCG, band: stripCG),
              let window = content.windows.first(where: { $0.windowID == chosen.id })
        else { DrawDebugLog.note("\(label) skipped: no window for pid \(pid) strip=\(DrawDebugLog.fmt(stripCG))"); return nil }
        let inside = stripCG.intersection(window.frame)
        // The strip must lie fully inside the window, or rows would be missing.
        guard !inside.isNull, clipToWindow ? inside.height >= 8 : abs(inside.height - stripCG.height) < 0.5,
              inside.width >= minWidth else {
            DrawDebugLog.note("\(label) skipped: strip outside window strip=\(DrawDebugLog.fmt(stripCG)) window=\(DrawDebugLog.fmt(window.frame))")
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: inside.minX - window.frame.minX, y: inside.minY - window.frame.minY,
                                   width: inside.width, height: inside.height)
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(inside.width * scale))
        config.height = max(1, Int(inside.height * scale))
        config.showsCursor = false
        config.capturesAudio = false
        guard !IsSecureEventInputEnabled(),
              let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let gray = grayscale(image)
        else { DrawDebugLog.note("\(label) skipped: capture failed"); return nil }
        return CapturedStrip(image: image, gray: gray, inside: inside,
                             pixelsPerPoint: CGFloat(gray.height) / inside.height, primaryHeight: primaryHeight)
    }

    /// The font to draw candidates with: the host's by name or family when it can be loaded (the
    /// name must actually resolve; CoreText silently substitutes otherwise), else the system face.
    public static func font(for hint: FontHint?, size: CGFloat) -> CTFont {
        if let own = loadedHostFont(for: hint, size: size) { return own }
        // A web font macOS can't load (Discord's gg sans): its stand-in, as the ghost draws.
        if let stand = FontLookalike.standIn(for: hint), let f = installedFace(stand, size: size) { return f }
        if hint?.isMonospaced == true { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont }
        return systemFace(size: size)
    }

    /// The host's own font by name, then family, when it really loads (CoreText silently
    /// substitutes otherwise); nil for private system names.
    static func loadedHostFont(for hint: FontHint?, size: CGFloat) -> CTFont? {
        if let name = hint?.name, !name.hasPrefix(".") {
            let f = CTFontCreateWithName(name as CFString, size, nil)
            if (CTFontCopyPostScriptName(f) as String) == name || (CTFontCopyFamilyName(f) as String) == hint?.family {
                return f
            }
        }
        if let family = hint?.family, !family.hasPrefix(".") {
            let f = CTFontCreateWithName(family as CFString, size, nil)
            if (CTFontCopyFamilyName(f) as String) == family { return f }
        }
        return nil
    }

    /// An installed family (`FaceMatch.systemFamily` for the system face), nil when it isn't there.
    static func installedFace(_ family: String, size: CGFloat) -> CTFont? {
        if family == FaceMatch.systemFamily { return systemFace(size: size) }
        let f = CTFontCreateWithName(family as CFString, size, nil)
        return (CTFontCopyFamilyName(f) as String) == family ? f : nil
    }

    static func systemFace(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func grayscale(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (bytes, w, h) : nil
    }

    /// 8-bit RGBX pixels in sRGB, rows from the top.
    private static func rgba(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (bytes, w, h) : nil
    }
}
