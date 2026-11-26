import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import HunchCore
import HunchPolicy
import ScreenCaptureKit
import Vision

/// Opt-in screen-aware context: captures the field's window, runs on-device OCR, discards the
/// image, and returns a sanitized excerpt. Never requests permission itself (see `requestPermission`).
/// Neither images nor recognized text are stored beyond the single cached excerpt or logged.
public actor ScreenContextProvider: ScreenContextProviding {
    private var store: ExcerptCacheStore<ScreenExcerpt>
    private var inFlight = false
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    public init(minInterval: Duration = .seconds(3)) {
        store = ExcerptCacheStore(interval: minInterval)
    }

    /// Forgets the cached excerpt and throttle state for every field.
    public func purge() { store.purge() }

    public nonisolated func isPermitted() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Call from the app only when the user enables the feature. May show the system prompt.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// `fieldBefore`/`fieldAfter` (optional) let already-typed text be deduplicated out of the excerpt.
    public func excerpt(app: AppIdentity, fieldFrame: CGRect?, caretRect: CGRect, pass: SecureGatePass,
                        maxCharacters: Int) async -> ScreenExcerpt? {
        await excerpt(app: app, fieldFrame: fieldFrame, caretRect: caretRect, pass: pass,
                      maxCharacters: maxCharacters, fieldBefore: "", fieldAfter: "")
    }

    public func excerpt(app: AppIdentity, fieldFrame: CGRect?, caretRect: CGRect, pass: SecureGatePass,
                        maxCharacters: Int, fieldBefore: String, fieldAfter: String,
                        chatSides: Bool = false, bubbleApp: Bool = false,
                        sentMessages: [String] = [], senderNames: Bool = true,
                        listChat: Bool = false, myAvatars: [MyAvatar] = []) async -> ScreenExcerpt? {
        let field = pass.field
        guard pass.isValid(for: field), field.pid == app.pid, maxCharacters > 0 else { return nil }
        guard CGPreflightScreenCaptureAccess(), !IsSecureEventInputEnabled() else { return nil }

        let now = ContinuousClock.now
        if let cache = store.cached, cache.field == field, !store.throttle.mayCapture(field: field, now: now) {
            return cache.excerpt
        }
        if inFlight { return store.cached?.field == field ? store.cached?.excerpt : nil }
        inFlight = true
        defer { inFlight = false }
        store.throttle.recordCapture(field: field, at: now)

        let captured = await Self.captureAndRecognize(
            pid: app.pid, fieldFrame: fieldFrame, caretRect: caretRect, ownPid: ownPid,
            stillAllowed: { pass.isValid(for: field) && !IsSecureEventInputEnabled() })
        let lines = captured?.lines
        // Debug logging only (prompt.log already holds screen text): every OCR line with its rect, to
        // see what the column filter and row joining had to work with.
        if PromptDebugLog.isEnabled, let captured {
            let dump = captured.lines.map { "\(Self.rectText($0.rect)) \(String(format: "%.2f", $0.confidence)) \($0.text)" }
            PromptDebugLog.note("ocr lines window=\(Self.rectText(captured.window)) field=\(Self.rectText(fieldFrame)) "
                                + "caret=\(Self.rectText(caretRect))\n" + dump.joined(separator: "\n"), file: "screen.log")
        }
        // The field's column: its frame, else a column from the caret (`CaptureGeometry.caretColumn`).
        let givenField = fieldFrame.flatMap { $0.isEmpty ? nil : $0 }
        let column = givenField ?? captured.flatMap {
            CaptureGeometry.caretColumn(caret: caretRect, window: $0.window, lineBefore: fieldBefore)
        }
        let columnSource = givenField != nil ? "field" : column != nil ? "caret" : "none"
        // Re-check after the awaits: the gate may have changed while we were capturing.
        guard !IsSecureEventInputEnabled() else { return nil }

        // List chats: avatars are read from the capture beside each header, while it is in hand.
        let avatarNotes = PromptDebugLog.isEnabled ? ImageAvatarSource.Notes() : nil
        let avatars = listChat ? captured.map { ImageAvatarSource(image: $0.image, band: $0.band, notes: avatarNotes) } : nil
        var result: ScreenExcerpt?
        if let lines,
           let out = ScreenTextPipeline.process(
               lines: lines, caret: CGPoint(x: caretRect.midX, y: caretRect.midY),
               field: column,
               fieldBefore: fieldBefore, fieldAfter: fieldAfter, maxCharacters: maxCharacters,
               chatSides: chatSides, bubbleApp: bubbleApp, sentMessages: sentMessages, senderNames: senderNames,
               listChat: listChat, myAvatars: myAvatars,
               avatarAt: avatars.map { source in { source.print(in: $0, minSide: $1, maxSide: $2) } }) {
            result = ScreenExcerpt(text: out.text, capturedAt: .now, signature: out.signature)
            result?.interfaceDropped = out.interfaceDropped
            result?.sentConfirmed = out.sentConfirmed
            result?.sentVetoed = out.sentVetoed
            result?.learnedAvatars = out.learnedAvatars
            if listChat, let avatarNotes, PromptDebugLog.isEnabled {
                PromptDebugLog.note("list chat avatars known=\(myAvatars.count) learned=\(out.learnedAvatars.count)\n"
                                    + (avatarNotes.lines + out.avatarNotes).joined(separator: "\n"), file: "screen.log")
            }
            // Counts only, once per fresh capture.
            PromptDebugLog.note("screen capture ocrLines=\(lines.count) kept=\(out.lineCount) "
                                + "column=\(columnSource) outsideColumn=\(out.outsideColumn) "
                                + "window=\(Self.rectText(captured?.window)) field=\(Self.rectText(givenField)) "
                                + "caret=\(Self.rectText(caretRect)) "
                                + "previewsDropped=\(out.previewsDropped) previewsKept=\(out.previewsKept) "
                                + "interfaceDropped=\(out.interfaceDropped) sideLabeled=\(out.sideLabeled) "
                                + "sentConfirmed=\(out.sentConfirmed) sentVetoed=\(out.sentVetoed) belowField=\(out.belowField)"
                                + (listChat ? " avatarMe=\(out.avatarMe) avatarThem=\(out.avatarThem) "
                                   + "avatarsKnown=\(myAvatars.count) avatarsLearned=\(out.learnedAvatars.count)" : ""),
                                file: "perf.log")
        }
        store.cached = (field, result)
        return result
    }

    /// "x,y,wxh" in screen points (top-left origin), or "-": geometry only, never text.
    static func rectText(_ r: CGRect?) -> String {
        guard let r else { return "-" }
        return "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height))"
    }

    // MARK: - Capture + OCR (no unit tests: needs Screen Recording permission)

    private static func captureAndRecognize(
        pid: pid_t, fieldFrame: CGRect?, caretRect: CGRect, ownPid: pid_t,
        stillAllowed: @Sendable () -> Bool
    ) async -> (lines: [OCRLine], window: CGRect, image: CGImage, band: CGRect)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return nil }
        let anchorRect = fieldFrame.flatMap { $0.isEmpty ? nil : $0 } ?? caretRect
        let center = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first
        else { return nil }

        // Only the owning app's window is captured, so other apps' windows, notification banners and
        // system UI that overlap it never reach the image.
        let wide = CaptureGeometry.band(fieldFrame: fieldFrame, caretRect: caretRect, container: display.frame)
        guard let wide else { return nil }
        let infos = content.windows.map {
            WindowInfo(id: $0.windowID, pid: $0.owningApplication?.processID ?? -1, frame: $0.frame,
                       layer: $0.windowLayer, isOnScreen: $0.isOnScreen)
        }
        guard let chosen = WindowSelection.select(windows: WindowSelection.frontToBack(infos, order: WindowSelection.stackingOrder()), targetPid: pid, ownPid: ownPid,
                                                  anchor: center, band: wide),
              let window = content.windows.first(where: { $0.windowID == chosen.id })
        else { return nil }
        // The whole window (on this display): in chat apps the field sits at the bottom and the
        // conversation fills the window above it. The pipeline keeps the field's column.
        let band = window.frame.intersection(display.frame)
        guard !band.isNull, !band.isEmpty else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // The whole window, then cropped here to the part on this display. `sourceRect` is not used:
        // inside the app it was read in the display's space for a window away from the display's
        // left edge (Messages at x 404 came back shifted by 404 points: sidebar mixed into the chat,
        // the right side cut off), while the same call in a plain process read it in the window's.
        let scale = min(2, CGFloat(filter.pointPixelScale))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.capturesAudio = false

        guard stillAllowed() else { return nil }
        // The image lives only for this read: OCR, then avatar fingerprints in list chats (`excerpt`).
        guard let whole = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }
        let image: CGImage
        if band == window.frame {
            image = whole
        } else {
            let px = CGFloat(whole.width) / max(1, window.frame.width)
            let crop = CGRect(x: (band.minX - window.frame.minX) * px, y: (band.minY - window.frame.minY) * px,
                              width: band.width * px, height: band.height * px).integral
            guard let part = whole.cropping(to: crop) else { return nil }
            image = part
        }
        guard stillAllowed() else { return nil }
        if PromptDebugLog.isEnabled {
            PromptDebugLog.note("capture image=\(image.width)x\(image.height) contentRect=\(rectText(filter.contentRect)) "
                                + "pointPixelScale=\(filter.pointPixelScale) "
                                + "window=\(rectText(window.frame)) display=\(rectText(display.frame)) "
                                + "windows=\(content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }.map { "\($0.windowID):\(rectText($0.frame))\($0.isOnScreen ? "" : " off")" })", file: "screen.log")
        }
        guard let lines = await recognize(image, band: band) else { return nil }
        return (lines, band, image, band)
    }

    /// Vision's Swift API. The older `VNRecognizeTextRequest` in accurate mode left ~150 KB of
    /// system-owned memory behind per call inside the app (2,600 pieces, ~400 MB over 4 days of use);
    /// this one, at the same level, correction and languages, left none.
    /// A big capture is read in overlapping strips (`OCRStrips`): read whole, it is shrunk first and
    /// its text comes back garbled.
    private static func recognize(_ image: CGImage, band: CGRect) async -> [OCRLine]? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages
        let strips = OCRStrips.plan(width: image.width, height: image.height)
        var lines: [OCRLine] = []
        for strip in strips {
            let part: CGImage
            if strips.count == 1 {
                part = image
            } else {
                guard let cropped = image.cropping(to: CGRect(x: 0, y: strip.top, width: image.width, height: strip.height))
                else { return nil }
                part = cropped
            }
            guard let observations = try? await request.perform(on: part) else { return nil }
            for obs in observations {
                guard let top = obs.topCandidates(1).first else { continue }
                let box = OCRStrips.wholeImageBox(obs.boundingBox.cgRect, strip: strip, imageHeight: image.height)
                guard strips.count == 1 || OCRStrips.keeps(box, strip: strip, imageHeight: image.height) else { continue }
                lines.append(OCRLine(text: top.string, confidence: top.confidence,
                                     rect: CaptureGeometry.screenRect(normalized: box, in: band)))
            }
        }
        return lines
    }

    /// English and both Chinese scripts plus the user's languages, those Vision can read, in that
    /// order. Worked out once.
    private static let recognitionLanguages: [Locale.Language] = {
        let supported = Set(RecognizeTextRequest().supportedRecognitionLanguages.map(\.maximalIdentifier))
        var seen = Set<String>()
        let wanted = (["en-US", "zh-Hans", "zh-Hant"] + Locale.preferredLanguages)
            .map { Locale.Language(identifier: $0) }
            .filter { supported.contains($0.maximalIdentifier) && seen.insert($0.maximalIdentifier).inserted }
        return wanted.isEmpty ? [Locale.Language(identifier: "en-US")] : wanted
    }()
}
