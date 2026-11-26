import CoreGraphics
import Foundation
import HunchCore
import Testing
@testable import HunchScreen

private func line(_ t: String, y: CGFloat, x: CGFloat = 0, conf: Float = 0.9, h: CGFloat = 14) -> OCRLine {
    OCRLine(text: t, confidence: conf, rect: CGRect(x: x, y: y, width: 300, height: h))
}
private let caret = CGPoint(x: 10, y: 500)

@Test func dropsLowConfidenceAndTinyLines() {
    let out = ScreenTextPipeline.process(lines: [
        line("Meeting notes for Monday", y: 480),
        line("garbage zzz", y: 490, conf: 0.2),
        line("tiny text here", y: 495, h: 3),
        line("x", y: 470),
    ], caret: caret, maxCharacters: 500)
    #expect(out?.text == "Meeting notes for Monday")
}

@Test func ordersByProximitySelectionThenReadingOrder() {
    let lines = [line("Far above line", y: 0), line("Near below line", y: 520), line("Near above line", y: 470)]
    let out = ScreenTextPipeline.process(lines: lines, caret: caret, maxCharacters: 33)
    // Budget fits the two nearest lines only; emitted top to bottom.
    #expect(out?.text == "Near above line\nNear below line")
}

@Test func capsAtLineBoundaries() {
    let lines = [line("aaaa aaaa", y: 490), line("bbbb bbbb", y: 510), line("cccc cccc", y: 530)]
    let out = ScreenTextPipeline.process(lines: lines, caret: caret, maxCharacters: 20)
    #expect(out?.text == "aaaa aaaa\nbbbb bbbb")
    #expect((out?.text.count ?? 99) <= 20)
}

@Test func dedupesLinesAlreadyInField() {
    let out = ScreenTextPipeline.process(
        lines: [line("Dear   Alice, thanks", y: 490), line("Quarterly report draft", y: 510)],
        caret: caret, fieldBefore: "dear alice, thanks for", fieldAfter: "", maxCharacters: 200)
    #expect(out?.text == "Quarterly report draft")
}

@Test func collapsesWhitespaceAndDedupesRepeats() {
    let out = ScreenTextPipeline.process(
        lines: [line("Inbox   (3)\t unread", y: 490), line("inbox (3) unread", y: 600)],
        caret: caret, maxCharacters: 200)
    #expect(out?.text == "Inbox (3) unread")
}

@Test func chineseLines() {
    let out = ScreenTextPipeline.process(
        lines: [line("明天下午三点开会，请准时参加", y: 490), line("我已经输入的内容", y: 510), line("好", y: 520)],
        caret: caret, fieldBefore: "我已经输入的内容", maxCharacters: 200)
    #expect(out?.text == "明天下午三点开会，请准时参加")
}

@Test func secretsAreRemoved() {
    let hex = String(repeating: "a1b2c3d4", count: 6)
    let b64 = "dGhpcyBpcyBhIHNlY3JldCBrZXkgMTIzNDU2Nzg5MA=="
    #expect(SecretFilter.sanitize("token \(hex) end") == "token end")
    #expect(SecretFilter.sanitize("key: \(b64)") == "key:")
    #expect(SecretFilter.sanitize("Card 4111 1111 1111 1111 exp") == nil)
    #expect(SecretFilter.sanitize("4111-1111-1111-1111") == nil)
    #expect(SecretFilter.sanitize("Your verification code is 482913") == nil)
    #expect(SecretFilter.sanitize("您的验证码是 482913，请勿泄露") == nil)
    #expect(SecretFilter.sanitize("Order 12345 shipped today") == "Order 12345 shipped today")
    #expect(SecretFilter.sanitize("Call us on 555 0100") == "Call us on 555 0100")
    #expect(SecretFilter.sanitize("internationalization-and-localization-guidelines") != nil)
}

@Test func pipelineRemovesSecretLines() {
    let out = ScreenTextPipeline.process(
        lines: [line("Your code is 123456", y: 490), line("Lunch at noon", y: 510)],
        caret: caret, maxCharacters: 200)
    #expect(out?.text == "Lunch at noon")
}

@Test func signatureIsStableAndOrderIndependent() {
    let a = ScreenTextPipeline.signature(of: ["Hello  world", "第二行"])
    let b = ScreenTextPipeline.signature(of: ["第二行", "hello world"])
    let c = ScreenTextPipeline.signature(of: ["Hello world", "第三行"])
    #expect(a == b)
    #expect(a != c)
    let lines = [line("Alpha beta", y: 480), line("Gamma delta", y: 520)]
    let s1 = ScreenTextPipeline.process(lines: lines, caret: caret, maxCharacters: 200)?.signature
    let s2 = ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: 0, y: 700), maxCharacters: 200)?.signature
    #expect(s1 == s2)
}

@Test func emptyAndZeroBudgetYieldNil() {
    #expect(ScreenTextPipeline.process(lines: [], caret: caret, maxCharacters: 100) == nil)
    #expect(ScreenTextPipeline.process(lines: [line("Hello there", y: 1)], caret: caret, maxCharacters: 0) == nil)
}

@Test func throttleAllowsOnePerIntervalPerField() {
    var t = CaptureThrottle(interval: .seconds(3))
    let f1 = FieldID(pid: 1, elementHash: 1, generation: 0)
    let f2 = FieldID(pid: 1, elementHash: 2, generation: 0)
    let t0 = ContinuousClock.now
    #expect(t.mayCapture(field: f1, now: t0))
    t.recordCapture(field: f1, at: t0)
    #expect(!t.mayCapture(field: f1, now: t0 + .seconds(2)))
    #expect(t.mayCapture(field: f1, now: t0 + .seconds(3)))
    #expect(t.mayCapture(field: f2, now: t0 + .seconds(1)))
}

@Test func geometryBandClampsAndConvertsCoordinates() {
    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let field = CGRect(x: 100, y: 800, width: 400, height: 40)
    let band = CaptureGeometry.band(fieldFrame: field, caretRect: .zero, container: display)
    #expect(band == CGRect(x: 0, y: 200, width: 1440, height: 700))
    let r = CaptureGeometry.screenRect(normalized: CGRect(x: 0.5, y: 0.0, width: 0.1, height: 0.1),
                                       in: CGRect(x: 0, y: 200, width: 1000, height: 700))
    #expect(r == CGRect(x: 500, y: 830, width: 100, height: 70))
    #expect(CaptureGeometry.band(fieldFrame: nil, caretRect: CGRect(x: 5, y: 5000, width: 1, height: 10),
                                 container: display) == nil)
}

// MARK: - Window selection and cache purge

private func win(_ id: UInt32, pid: pid_t, _ f: CGRect, layer: Int = 0, on: Bool = true) -> WindowInfo {
    WindowInfo(id: id, pid: pid, frame: f, layer: layer, isOnScreen: on)
}
private let bandRect = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let anchorPt = CGPoint(x: 500, y: 400)

@Test func excludesOverlappingOtherAppWindow() {
    let ws = [win(1, pid: 99, CGRect(x: 0, y: 0, width: 1000, height: 800)),
              win(2, pid: 10, CGRect(x: 100, y: 100, width: 800, height: 600))]
    #expect(WindowSelection.select(windows: ws, targetPid: 10, ownPid: 1, anchor: anchorPt, band: bandRect)?.id == 2)
    #expect(WindowSelection.select(windows: [ws[0]], targetPid: 10, ownPid: 1, anchor: anchorPt, band: bandRect) == nil)
}

@Test func excludesNotificationLayerAndOffscreen() {
    let ws = [win(1, pid: 10, CGRect(x: 400, y: 300, width: 300, height: 200), layer: 25),
              win(2, pid: 10, CGRect(x: 0, y: 0, width: 1000, height: 800), on: false)]
    #expect(WindowSelection.select(windows: ws, targetPid: 10, ownPid: 1, anchor: anchorPt, band: bandRect) == nil)
}

@Test func excludesOwnPid() {
    let ws = [win(1, pid: 5, CGRect(x: 0, y: 0, width: 1000, height: 800))]
    #expect(WindowSelection.select(windows: ws, targetPid: 5, ownPid: 5, anchor: anchorPt, band: bandRect) == nil)
}

@Test func choosesWindowHoldingFieldAmongSeveral() {
    let ws = [win(1, pid: 10, CGRect(x: 0, y: 0, width: 300, height: 300)),
              win(2, pid: 10, CGRect(x: 350, y: 300, width: 500, height: 400)),
              win(3, pid: 10, CGRect(x: 0, y: 0, width: 1000, height: 300))]
    #expect(WindowSelection.select(windows: ws, targetPid: 10, ownPid: 1, anchor: anchorPt, band: bandRect)?.id == 2)
    // Anchor in no window: falls back to the largest overlap with the band.
    #expect(WindowSelection.select(windows: ws, targetPid: 10, ownPid: 1, anchor: CGPoint(x: 950, y: 790),
                                   band: bandRect)?.id == 3)
}

@Test func purgeEmptiesCacheAndThrottle() {
    var store = ExcerptCacheStore<String>(interval: .seconds(3))
    let field = FieldID(pid: 10, elementHash: 1, generation: 1)
    let now = ContinuousClock.now
    store.throttle.recordCapture(field: field, at: now)
    store.cached = (field, "text")
    #expect(!store.throttle.mayCapture(field: field, now: now))
    store.purge()
    #expect(store.cached == nil)
    #expect(store.throttle.mayCapture(field: field, now: now))
}

@Test func windowsSortedByStackingOrderBeforeSelection() {
    // ScreenCaptureKit listed the viewer (behind) before the compose window (front).
    let viewer = WindowInfo(id: 10, pid: 5, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), layer: 0, isOnScreen: true)
    let compose = WindowInfo(id: 20, pid: 5, frame: CGRect(x: 100, y: 100, width: 600, height: 500), layer: 0, isOnScreen: true)
    let anchor = CGPoint(x: 300, y: 200)
    let band = CGRect(x: 200, y: 190, width: 100, height: 30)
    #expect(WindowSelection.select(windows: [viewer, compose], targetPid: 5, ownPid: 1, anchor: anchor, band: band)?.id == 10)
    let sorted = WindowSelection.frontToBack([viewer, compose], order: [20: 0, 10: 3])
    #expect(sorted.map(\.id) == [20, 10])
    #expect(WindowSelection.select(windows: sorted, targetPid: 5, ownPid: 1, anchor: anchor, band: band)?.id == 20)
    // Unknown windows keep their relative order at the end.
    #expect(WindowSelection.frontToBack([viewer, compose], order: [:]).map(\.id) == [10, 20])
}

// MARK: - Field column (chat window with the field at the bottom, sidebar on the left)

private let chatField = CGRect(x: 380, y: 1040, width: 820, height: 40)
private func at(_ t: String, x: CGFloat, y: CGFloat, w: CGFloat) -> OCRLine {
    OCRLine(text: t, confidence: 0.9, rect: CGRect(x: x, y: y, width: w, height: 16))
}

@Test func fieldColumnDropsSidebarAndPrefersTextJustAbove() {
    let lines = [
        at("older message far up", x: 430, y: 100, w: 300),
        at("newest message just above", x: 430, y: 990, w: 300),
        at("a wide message running past the field", x: 430, y: 900, w: 920),   // 770 of 920 inside
        at("general", x: 84, y: 1030, w: 120),                                  // sidebar, level with the field
        at("Invisible", x: 40, y: 1060, w: 80),
        at("Reply in thread", x: 1000, y: 1100, w: 150),                         // below the field
        at("Message #hermes-room", x: 430, y: 1052, w: 200),                     // the field's placeholder
    ]
    let all = ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: 400, y: 1060), field: chatField,
                                         maxCharacters: 500)
    #expect(all?.text == "older message far up\na wide message running past the field\nnewest message just above\nReply in thread")

    // A tight budget keeps the lines nearest the field's top edge (the newest messages).
    let tight = ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: 400, y: 1060), field: chatField,
                                           maxCharacters: 70)
    #expect(tight?.text == "a wide message running past the field\nnewest message just above")
}

@Test func linesAboveFieldComeBeforeLinesBelow() {
    // 5 pt below still loses to 600 pt above.
    let lines = [at("toolbar below", x: 400, y: 1085, w: 200), at("message above", x: 400, y: 424, w: 200)]
    let out = ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: 400, y: 1060), field: chatField,
                                         maxCharacters: 14)
    #expect(out?.text == "message above")
}

@Test func dropsWebAddresses() {
    let out = ScreenTextPipeline.process(lines: [
        line("www.google.com/search?q=Alex+Morgan&oq=Alex+Morgan", y: 440),
        line("Source: https://example.com/a for the details", y: 460),
        line("How can I help you today?", y: 480),
    ], caret: caret, maxCharacters: 500)
    #expect(out?.text == "Source: for the details\nHow can I help you today?")
}

@Test func secretFilterUsesSharedSanitizer() {
    // Synthetic, digit-free key: too regular for the long-token heuristic, caught by `SecretSanitizer`.
    let key = "AKIA" + "FAKEFAKEFAKEFAKE"
    #expect(SecretFilter.sanitize("aws key \(key) here") == "aws key [redacted] here")
    #expect(SecretFilter.sanitize("Password: sommerregen") == "Password: [redacted]")
}

// MARK: - Reply previews (Discord)

private func chat(_ texts: [String]) -> [OCRLine] {
    texts.enumerated().map { line($1, y: CGFloat(100 + $0 * 20)) }
}
private let chatCaret = CGPoint(x: 10, y: 600)

@Test func dropsTruncatedReplyPreviewWhenOriginalVisible() {
    let out = ScreenTextPipeline.process(lines: chat([
        "Nora 10:14 AM",
        "Tried it once and it was too sweet. They had some sort of matcha drink after bed",
        "Sam 10:20 AM",
        "@Nora Tried it once and it was too sweet. They had some sort of matcha ...",
        "Which place was that?",
    ]), caret: chatCaret, maxCharacters: 1000)
    #expect(out?.text == """
        Nora 10:14 AM
        Tried it once and it was too sweet. They had some sort of matcha drink after bed
        Sam 10:20 AM
        Which place was that?
        """)
    #expect(out?.previewsDropped == 1 && out?.previewsKept == 0 && out?.lineCount == 4)
}

@Test func dropsReplyPreviewWithMangledAvatarAndUnicodeEllipsis() {
    let out = ScreenTextPipeline.process(lines: chat([
        "Nora 10:14 AM",
        "Tried it once and it was too sweet at all",
        "© @Nora Tried it once and it was too sweet…",
        "Why not?",
    ]), caret: chatCaret, maxCharacters: 1000)
    #expect(out?.text == "Nora 10:14 AM\nTried it once and it was too sweet at all\nWhy not?")
}

@Test func dropsReplyPreviewWhenOriginalWrapsAcrossLines() {
    let out = ScreenTextPipeline.process(lines: chat([
        "Nora 10:14 AM",
        "Tried it once and it was too sweet. They had",
        "some sort of matcha drink after bed",
        "Sam 10:20 AM",
        "@Nora Tried it once and it was too sweet. They had some sort of matcha drink after bed",
        "Which place was that?",
    ]), caret: chatCaret, maxCharacters: 1000)
    #expect(out?.text == """
        Nora 10:14 AM
        Tried it once and it was too sweet. They had
        some sort of matcha drink after bed
        Sam 10:20 AM
        Which place was that?
        """)
}

@Test func keepsReplyPreviewWhenOriginalScrolledAway() {
    let out = ScreenTextPipeline.process(lines: chat([
        "Sam 10:20 AM",
        "@Nora Tried it once and it was too sweet. They had some sort of matcha ...",
        "Which place was that?",
    ]), caret: chatCaret, maxCharacters: 1000)
    #expect(out?.text.contains("@Nora Tried it once and it was too sweet.") == true)
}

@Test func keepsOrdinaryLinesStartingWithMention() {
    let out = ScreenTextPipeline.process(lines: chat([
        "Nora 10:14 AM",
        "Tried it once and it was too sweet at all",
        "Sam 10:20 AM",
        "@Nora thanks, see you at the cafe at five",
    ]), caret: chatCaret, maxCharacters: 1000)
    #expect(out?.text.contains("@Nora thanks, see you at the cafe at five") == true)
}

// MARK: - Discord reply chain (OCR of a real window layout, text replaced)

/// OCR lines in screen points (origin top-left). The user's own name is too short and styled for OCR,
/// so their headers are a bare time; a badge between "Nora" and the time splits that row, and splits
/// each `@Nora` reply preview from its text.
private let replyChain: [OCRLine] = {
    func ocr(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> OCRLine {
        OCRLine(text: text, confidence: 1, rect: CGRect(x: x, y: y, width: w, height: h))
    }
    return [
        ocr("10:58 AM", 207, 46, 101, 23),
        ocr("ignore the dusty shelf", 138, 83, 256, 35),
        ocr("@al ignore the dusty shelf", 184, 170, 265, 29),
        ocr("Nora", 138, 215, 87, 31),
        ocr("12:43 PM", 377, 222, 98, 23),
        ocr("we aren't ignoring it", 138, 259, 276, 35),
        ocr("@Nora", 181, 342, 98, 26),
        ocr("we aren't ignoring it", 380, 343, 245, 32),
        ocr("12:43 PM", 210, 394, 95, 25),
        ocr("well guess what knocked the vase over then", 138, 435, 558, 32),
        ocr("@al well guess what knocked the vase over then", 184, 518, 530, 29),
        ocr("Nora", 138, 564, 87, 30),
        ocr("12:43 PM", 374, 570, 98, 24),
        ocr("the cat or a draft from the window", 138, 604, 562, 39),
        ocr("@Nora", 181, 694, 98, 23),
        ocr("the cat or a draft from the window", 383, 691, 495, 32),
        ocr("12:44 PM", 207, 743, 101, 24),
        ocr("yeah probably the cat i keep that window shut", 138, 780, 829, 38),
        ocr("@al yeah probably the cat i keep that window shut", 184, 867, 766, 32),
        ocr("Nora", 138, 913, 86, 29),
        ocr("12:45 PM", 377, 918, 98, 24),
        ocr("you don't open your windows?", 138, 956, 541, 37),
        ocr("damn", 141, 1008, 78, 29),
        ocr("bro living in a cave", 141, 1062, 311, 32),
        ocr("@Nora", 181, 1143, 98, 29),
        ocr("you don't open your windows?", 383, 1142, 475, 35),
        ocr("12:54 PM", 210, 1197, 95, 24),
        ocr("oh no i do", 141, 1235, 138, 30),
        ocr("i meant that one window, the others open fine", 328, 1232, 1117, 38),
        ocr("+", 52, 1362, 40, 37),
        ocr("Message #general", 132, 1362, 780, 40),
    ]
}()

@Test func replyChainKeepsHeadersAndDropsQuotedCopies() {
    let out = ScreenTextPipeline.process(lines: replyChain, caret: CGPoint(x: 145, y: 1380),
                                         field: CGRect(x: 15, y: 1325, width: 1965, height: 110), maxCharacters: 3500)
    #expect(out?.text == """
        10:58 AM
        ignore the dusty shelf
        Nora 12:43 PM
        we aren't ignoring it
        12:43 PM
        well guess what knocked the vase over then
        Nora 12:43 PM
        the cat or a draft from the window
        12:44 PM
        yeah probably the cat i keep that window shut
        Nora 12:45 PM
        you don't open your windows?
        damn
        bro living in a cave
        12:54 PM
        oh no i do i meant that one window, the others open fine
        """)
    #expect(out?.previewsDropped == 6)
}
