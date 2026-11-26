import CoreGraphics
import Foundation
import HunchCore
import Testing
@testable import HunchFocus

// MARK: TextWindow

@Test func sliceBasicCaretAtEnd() {
    let s = TextWindow.slice("Hello world", caretUTF16: 11, selectionUTF16: 0, limits: ContextLimits())
    #expect(s.before == "Hello world")
    #expect(s.after == "")
    #expect(s.caretAtLineEnd)
    #expect(!s.containsNewline)
    #expect(s.selectionLength == 0)
}

@Test func sliceMidLineRespectsLimits() {
    let s = TextWindow.slice("abcdefghij", caretUTF16: 5, selectionUTF16: 0,
                             limits: ContextLimits(beforeChars: 3, afterChars: 2))
    #expect(s.before == "cde")
    #expect(s.after == "fg")
    #expect(!s.caretAtLineEnd)
}

@Test func sliceSaysWhichSidesTheLimitsCut() {
    let cut = TextWindow.slice("abcdefghij", caretUTF16: 5, selectionUTF16: 0,
                               limits: ContextLimits(beforeChars: 3, afterChars: 2))
    #expect(cut.beforeIsCut)
    #expect(cut.afterIsCut)
    let whole = TextWindow.slice("abcdefghij", caretUTF16: 5, selectionUTF16: 0, limits: ContextLimits())
    #expect(!whole.beforeIsCut)
    #expect(!whole.afterIsCut)
}

@Test func sliceOfAWindowedReadIsCutAtTheWindowEdges() {
    let s = TextWindow.slice("abcdefghij", caretUTF16: 5, selectionUTF16: 0, limits: ContextLimits(),
                             endsAtDocumentEnd: false, startsAtDocumentStart: false)
    #expect(s.beforeIsCut)
    #expect(s.afterIsCut)
}

@Test func sliceCaretBeforeNewlineIsLineEnd() {
    let s = TextWindow.slice("one\ntwo", caretUTF16: 3, selectionUTF16: 0, limits: ContextLimits())
    #expect(s.before == "one")
    #expect(s.after == "\ntwo")
    #expect(s.caretAtLineEnd)
    #expect(s.containsNewline)
}

@Test func sliceCRLFCountsAsNewline() {
    let s = TextWindow.slice("one\r\ntwo", caretUTF16: 3, selectionUTF16: 0, limits: ContextLimits())
    #expect(s.caretAtLineEnd)
}

@Test func sliceHandlesSurrogatePairsAndGraphemes() {
    // "a👍🏽b": a(1) + 👍(2) + 🏽(2) + b(1) UTF-16 units; the emoji is one Character.
    let text = "a👍🏽b"
    let s = TextWindow.slice(text, caretUTF16: 5, selectionUTF16: 0, limits: ContextLimits())
    #expect(s.before == "a👍🏽")
    #expect(s.after == "b")
    // A caret inside the grapheme rounds down to its start.
    let inside = TextWindow.slice(text, caretUTF16: 2, selectionUTF16: 0, limits: ContextLimits())
    #expect(inside.before == "a")
    #expect(inside.after == "👍🏽b")
    // A one-Character limit keeps the whole emoji.
    let one = TextWindow.slice(text, caretUTF16: 5, selectionUTF16: 0, limits: ContextLimits(beforeChars: 1, afterChars: 0))
    #expect(one.before == "👍🏽")
    #expect(one.after == "")
}

@Test func sliceWithSelection() {
    let s = TextWindow.slice("hello world", caretUTF16: 6, selectionUTF16: 5, limits: ContextLimits())
    #expect(s.before == "hello ")
    #expect(s.after == "")
    #expect(s.selectionLength == 5)
    #expect(s.caretAtLineEnd)
}

@Test func sliceSelectionEndingInsideGraphemeRoundsUp() {
    let s = TextWindow.slice("x👍🏽y", caretUTF16: 1, selectionUTF16: 1, limits: ContextLimits())
    #expect(s.selectionLength == 4)
    #expect(s.after == "y")
}

@Test func sliceClampsOutOfRangeCaret() {
    let s = TextWindow.slice("abc", caretUTF16: 99, selectionUTF16: 3, limits: ContextLimits())
    #expect(s.before == "abc")
    #expect(s.after == "")
    let neg = TextWindow.slice("abc", caretUTF16: -4, selectionUTF16: 0, limits: ContextLimits())
    #expect(neg.before == "")
    #expect(neg.after == "abc")
}

@Test func sliceWindowNotAtDocumentEndIsNotLineEnd() {
    let s = TextWindow.slice("abc", caretUTF16: 3, selectionUTF16: 0, limits: ContextLimits(), endsAtDocumentEnd: false)
    #expect(!s.caretAtLineEnd)
}

@Test func emptyTextAndZeroLimits() {
    let s = TextWindow.slice("", caretUTF16: 0, selectionUTF16: 0, limits: ContextLimits())
    #expect(s.before == "" && s.after == "" && s.caretAtLineEnd)
    let z = TextWindow.slice("abc", caretUTF16: 1, selectionUTF16: 0, limits: ContextLimits(beforeChars: 0, afterChars: 0))
    #expect(z.before == "" && z.after == "")
}

@Test func previousCharacterNewline() {
    #expect(TextWindow.previousCharacterIsNewlineOrStart("ab\ncd", caretUTF16: 3))
    #expect(!TextWindow.previousCharacterIsNewlineOrStart("ab\ncd", caretUTF16: 2))
    #expect(TextWindow.previousCharacterIsNewlineOrStart("ab", caretUTF16: 0))
}

@Test func fetchRangeIsBounded() {
    let limits = ContextLimits(beforeChars: 10, afterChars: 5)
    let r = TextWindow.fetchRange(caretUTF16: 1000, selectionUTF16: 0, totalUTF16: 100_000, limits: limits)
    #expect(r.location == 960)
    #expect(r.location + r.length == 1021)
    let start = TextWindow.fetchRange(caretUTF16: 3, selectionUTF16: 0, totalUTF16: 10, limits: limits)
    #expect(start.location == 0 && start.length == 10)
}

// MARK: Surface / editability / geometry rule

@Test func surfaceClassification() {
    #expect(SurfaceClassifier.classify(bundleID: "com.apple.mail", role: "AXTextArea", subrole: nil) == .email)
    #expect(SurfaceClassifier.classify(bundleID: "com.tinyspeck.slackmacgap", role: nil, subrole: nil) == .chat)
    #expect(SurfaceClassifier.classify(bundleID: "com.apple.MobileSMS", role: nil, subrole: nil) == .chat)
    #expect(SurfaceClassifier.classify(bundleID: "com.apple.Notes", role: nil, subrole: nil) == .note)
    #expect(SurfaceClassifier.classify(bundleID: "com.apple.TextEdit", role: nil, subrole: nil) == .document)
    #expect(SurfaceClassifier.classify(bundleID: "com.apple.mail", role: "AXTextField", subrole: "AXSearchField") == .search)
    #expect(SurfaceClassifier.classify(bundleID: "com.example.unknown", role: "AXTextField", subrole: nil) == .unknown)
}

@Test func editability() {
    #expect(EditabilityRule.isEditable(role: "AXTextArea", subrole: nil, valueSettable: false))
    #expect(EditabilityRule.isEditable(role: "AXTextField", subrole: "AXSearchField", valueSettable: false))
    #expect(EditabilityRule.isEditable(role: "AXGroup", subrole: nil, valueSettable: true))
    #expect(!EditabilityRule.isEditable(role: "AXButton", subrole: nil, valueSettable: false))
    #expect(!EditabilityRule.isEditable(role: nil, subrole: nil, valueSettable: false))
    // A web dropdown (Claude settings' font picker): AXComboBox, settable value, no text, no caret.
    #expect(!EditabilityRule.isEditable(role: "AXComboBox", subrole: nil, valueSettable: true,
                                        characterCount: 0, caretLine: Int.max))
    #expect(!EditabilityRule.isEditable(role: "AXComboBox", subrole: nil, valueSettable: true,
                                        characterCount: 0, caretLine: nil))
    // Real combo box inputs: empty with a caret, or holding text.
    #expect(EditabilityRule.isEditable(role: "AXComboBox", subrole: nil, valueSettable: true,
                                       characterCount: 0, caretLine: 0))
    #expect(EditabilityRule.isEditable(role: "AXComboBox", subrole: nil, valueSettable: true,
                                       characterCount: 5, caretLine: nil))
    // Unknown count (attribute unsupported) keeps the old behavior.
    #expect(EditabilityRule.isEditable(role: "AXComboBox", subrole: nil, valueSettable: false))
    // Only combo boxes get the check: an empty text field before its caret settles stays editable.
    #expect(EditabilityRule.isEditable(role: "AXTextField", subrole: nil, valueSettable: true,
                                       characterCount: 0, caretLine: nil))
}

// MARK: Signature

@Test func fnvKnownVectors() {
    var empty = FNV1a64()
    #expect(empty.value == 0xcbf2_9ce4_8422_2325)
    empty.combine(bytes: Array("a".utf8))
    #expect(empty.value == 0xaf63_dc4c_8601_ec8c)
    var foobar = FNV1a64()
    foobar.combine(bytes: Array("foobar".utf8))
    #expect(foobar.value == 0x8594_4171_f739_67e8)
}

@Test func signatureStableAndSensitive() {
    let a = ContentSignature.make(before: "ab", after: "c", selectionLength: 0)
    #expect(a == ContentSignature.make(before: "ab", after: "c", selectionLength: 0))
    #expect(a != ContentSignature.make(before: "a", after: "bc", selectionLength: 0))
    #expect(a != ContentSignature.make(before: "ab", after: "c", selectionLength: 1))
}

// MARK: Caret math

@Test func flipToAppKit() {
    let r = CaretMath.flipToAppKit(CGRect(x: 10, y: 100, width: 2, height: 20), primaryScreenHeight: 1000)
    #expect(r == CGRect(x: 10, y: 880, width: 2, height: 20))
    // Round trip.
    #expect(CaretMath.flipToAppKit(r, primaryScreenHeight: 1000) == CGRect(x: 10, y: 100, width: 2, height: 20))
}

@Test func plausibility() {
    let field = CGRect(x: 100, y: 100, width: 300, height: 30)
    #expect(CaretMath.isPlausible(CGRect(x: 150, y: 105, width: 0, height: 18), fieldFrame: field))
    #expect(!CaretMath.isPlausible(.zero, fieldFrame: field))
    #expect(!CaretMath.isPlausible(CGRect(x: 150, y: 105, width: 0, height: 0), fieldFrame: field))
    #expect(!CaretMath.isPlausible(CGRect(x: 2000, y: 2000, width: 1, height: 18), fieldFrame: field))
    #expect(!CaretMath.isPlausible(CGRect(x: CGFloat.nan, y: 1, width: 1, height: 18), fieldFrame: nil))
    #expect(CaretMath.isPlausible(CGRect(x: 2000, y: 2000, width: 1, height: 18), fieldFrame: nil))
}

@Test func derivedCaretRects() {
    let ch = CGRect(x: 10, y: 20, width: 8, height: 16)
    #expect(CaretMath.caretAfterCharacter(ch) == CGRect(x: 18, y: 20, width: 1, height: 16))
    #expect(CaretMath.caretBeforeCharacter(ch) == CGRect(x: 10, y: 20, width: 1, height: 16))
    #expect(CaretMath.caretFromInsertionBounds(CGRect(x: 5, y: 6, width: 0, height: 14)).width == 1)
}

@Test func estimatedCaretInsideField() {
    let single = CGRect(x: 100, y: 100, width: 300, height: 24)
    let c = CaretMath.estimatedCaret(fieldFrame: single)
    #expect(single.contains(CGPoint(x: c.minX, y: c.midY)))
    let tall = CGRect(x: 0, y: 0, width: 500, height: 400)
    #expect(CaretMath.estimatedCaret(fieldFrame: tall).minY == 4)
}

@Test func fontHints() {
    #expect(FontHintParser.hint(family: nil, name: nil, size: nil) == nil)
    let menlo = FontHintParser.hint(family: "Menlo", name: "Menlo-Regular", size: 12)
    #expect(menlo?.isMonospaced == true)
    #expect(menlo?.pointSize == 12)
    #expect(FontHintParser.hint(family: "Helvetica Neue", name: nil, size: 13)?.isMonospaced == false)
}

// MARK: Scheduling

@Test func pollBackoff() {
    let s = PollSchedule()
    #expect(s.interval(sinceActivity: .milliseconds(10)) == .milliseconds(50))
    #expect(s.interval(sinceActivity: .seconds(3)) == .milliseconds(250))
    #expect(s.interval(sinceActivity: .seconds(60)) == .seconds(1))
}

@Test func hangBackoffDoublesAndResets() {
    var b = HangBackoff(base: .milliseconds(500), maximum: .seconds(2))
    #expect(timeout(&b) == .milliseconds(500))
    #expect(timeout(&b) == .seconds(1))
    #expect(timeout(&b) == .seconds(2))
    #expect(timeout(&b) == .seconds(2))
    b.recordSuccess()
    #expect(timeout(&b) == .milliseconds(500))
}

@Test func durationSeconds() {
    #expect(Duration.milliseconds(250).seconds == 0.25)
}

// MARK: Dedup and URL host

private func context(_ before: String, field: FieldID) -> TextContext {
    TextContext(app: AppIdentity(bundleID: "a.b", pid: field.pid, localizedName: nil), field: field,
                before: before, after: "",
                contentSignature: ContentSignature.make(before: before, after: "", selectionLength: 0))
}

@Test func dedupSuppressesUnchangedState() {
    var d = EmissionDeduper()
    let f = FieldID(pid: 1, elementHash: 2, generation: 1)
    let geo = CaretGeometry(caretRect: CGRect(x: 10, y: 10, width: 1, height: 16), quality: .exact)
    #expect(emits(&d, .context(context("hi", field: f), geo)))
    #expect(!emits(&d, .context(context("hi", field: f), geo)))
    // Sub-point jitter is ignored; real movement is not.
    let jitter = CaretGeometry(caretRect: CGRect(x: 10.2, y: 10, width: 1, height: 16), quality: .exact)
    #expect(!emits(&d, .context(context("hi", field: f), jitter)))
    let moved = CaretGeometry(caretRect: CGRect(x: 30, y: 10, width: 1, height: 16), quality: .exact)
    #expect(emits(&d, .context(context("hi", field: f), moved)))
    #expect(emits(&d, .context(context("hi!", field: f), moved)))
    // A new generation is a new field.
    let f2 = FieldID(pid: 1, elementHash: 2, generation: 2)
    #expect(emits(&d, .context(context("hi!", field: f2), moved)))
    #expect(emits(&d, .blocked(.secureRole, nil)))
    #expect(!emits(&d, .blocked(.secureRole, nil)))
    #expect(emits(&d, .focusLost))
    #expect(!emits(&d, .focusLost))
    d.reset()
    #expect(emits(&d, .focusLost))
}

@Test func dedupRecordSuppressesFollowUp() {
    var d = EmissionDeduper()
    d.record(.blocked(.trackingPaused, nil))
    #expect(!emits(&d, .blocked(.trackingPaused, nil)))
}

@Test func urlHosts() {
    #expect(URLHostExtractor.host(from: "https://Mail.Google.com/mail/u/0/") == "mail.google.com")
    #expect(URLHostExtractor.host(from: "http://localhost:8080/x") == "localhost")
    #expect(URLHostExtractor.host(from: "file:///Users/x/a.html") == nil)
    #expect(URLHostExtractor.host(from: "about:blank") == nil)
    #expect(URLHostExtractor.host(from: "not a url") == nil)
}

private func emits(_ d: inout EmissionDeduper, _ e: FocusEvent) -> Bool { d.shouldEmit(e) }
private func timeout(_ b: inout HangBackoff) -> Duration { b.recordTimeout() }

// MARK: FocusEmissionGate

@Test func emissionGateDropsContextOnlyWhenPaused() {
    #expect(FocusEmissionGate.shouldDeliver(.focusLost, paused: true))
    #expect(FocusEmissionGate.shouldDeliver(.blocked(.trackingPaused, nil), paused: true))
    #expect(FocusEmissionGate.shouldDeliver(.focusLost, paused: false))
}

// MARK: Host font configs

@Test func hostFontPickPrefersFirstWithinHalfPointThenClosest() {
    let a = HostFontConfigs.Candidate(name: "A", size: 12, advance: 7.0)
    let b = HostFontConfigs.Candidate(name: "B", size: 13, advance: 7.8)
    let c = HostFontConfigs.Candidate(name: "C", size: 14, advance: 7.9)
    // No measurement: the first (preferred) profile.
    #expect(HostFontConfigs.pick([a, b, c], cellWidth: nil) == a)
    #expect(HostFontConfigs.pick([a, b, c], cellWidth: 0) == a)
    // Both B and C are within 0.5 of 7.85: the earlier one wins, not the closer one.
    #expect(HostFontConfigs.pick([a, b, c], cellWidth: 7.85) == b)
    #expect(HostFontConfigs.pick([a, c, b], cellWidth: 7.85) == c)
    // Nothing within 0.5: the closest.
    #expect(HostFontConfigs.pick([a, b, c], cellWidth: 9.0) == c)
    #expect(HostFontConfigs.pick([c, b, a], cellWidth: 6.0) == a)
}

@Test func hostFontSourcesCoverTerminalsAndVSCodeForks() {
    #expect(HostFontConfigs.source(for: "com.apple.Terminal")?.isTerminal == true)
    #expect(HostFontConfigs.source(for: "com.googlecode.iterm2")?.isTerminal == true)
    #expect(HostFontConfigs.source(for: "com.mitchellh.ghostty")?.isTerminal == true)
    #expect(HostFontConfigs.source(for: "net.kovidgoyal.kitty")?.isTerminal == true)
    #expect(HostFontConfigs.source(for: "com.microsoft.VSCode")?.isTerminal == false)
    #expect(HostFontConfigs.source(for: "com.todesktop.230313mzl4w4u92")?.isTerminal == false)
    #expect(HostFontConfigs.source(for: "com.apple.TextEdit") == nil)
}

@Test func fontFamilyResolutionStopsAtFirstInstalledOrGeneric() {
    let installed = ["menlo": "Menlo", "fira code": "Fira Code"]
    let lookup: (String) -> String? = { installed[$0.lowercased()] }
    #expect(FontConfigParsers.resolveFamily(["Nope", "fira CODE", "Menlo"], installed: lookup) == .installed("Fira Code"))
    #expect(FontConfigParsers.resolveFamily(["Nope", "monospace", "Menlo"], installed: lookup) == .systemMonospaced)
    #expect(FontConfigParsers.resolveFamily(["Nope", "sans-serif"], installed: lookup) == .system)
    #expect(FontConfigParsers.resolveFamily(["Nope", "Other"], installed: lookup) == nil)
    #expect(FontConfigParsers.resolveFamily([], installed: lookup) == nil)
}

// MARK: VS Code settings

@Test func vsCodeSettingsToleratesCommentsAndTrailingCommas() {
    let text = """
    {
        // line comment with "quotes" and a , comma
        "editor.fontFamily": "'Fira Code', Menlo, monospace", /* block
        comment */
        "url": "http://example.com/*not a comment*/",
        "editor.fontSize": 14,
        "nested": { "a": [1, 2, ], },
    }
    """
    let font = FontConfigParsers.vsCode(settings: text)
    #expect(font?.families == ["Fira Code", "Menlo", "monospace"])
    #expect(font?.size == 14)
    #expect(font?.postScriptName == nil)
    #expect(font?.widthSpacing == 1)
}

@Test func vsCodeStripKeepsStringsIntact() {
    let stripped = FontConfigParsers.stripJSONC(#"{"a": "x // y, ]", "b": "q\"/*", "c": [1,],}"#)
    let data = stripped.data(using: .utf8)!
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["a"] as? String == "x // y, ]")
    #expect(object?["b"] as? String == "q\"/*")
    #expect((object?["c"] as? [Int]) == [1])
}

@Test func vsCodeZoomScalesFontSize() {
    let up = FontConfigParsers.vsCode(settings: #"{"editor.fontSize": 13, "window.zoomLevel": 1}"#)
    #expect(abs((up?.size ?? 0) - 15.6) < 0.0001)
    let down = FontConfigParsers.vsCode(settings: #"{"editor.fontSize": 12, "window.zoomLevel": -2}"#)
    #expect(abs((down?.size ?? 0) - 12 / 1.44) < 0.0001)
    let half = FontConfigParsers.vsCode(settings: #"{"window.zoomLevel": 0.5}"#)
    #expect(abs((half?.size ?? 0) - 12 * 1.2.squareRoot()) < 0.0001)
    // A zoom of exactly 1 must not be mistaken for a boolean.
    let one = FontConfigParsers.vsCode(settings: #"{"editor.fontSize": 10, "window.zoomLevel": 1}"#)
    #expect(abs((one?.size ?? 0) - 12) < 0.0001)
}

@Test func vsCodeMissingKeysUseDefaults() {
    let font = FontConfigParsers.vsCode(settings: "{}")
    #expect(font?.families == ["Menlo", "Monaco", "Courier New", "monospace"])
    #expect(font?.size == 12)
    // Out-of-range and non-numeric sizes: clamped, or the default.
    #expect(FontConfigParsers.vsCode(settings: #"{"editor.fontSize": 200}"#)?.size == 100)
    #expect(FontConfigParsers.vsCode(settings: #"{"editor.fontSize": 2}"#)?.size == 6)
    #expect(FontConfigParsers.vsCode(settings: #"{"editor.fontSize": 0}"#)?.size == 12)
    #expect(FontConfigParsers.vsCode(settings: #"{"editor.fontSize": true}"#)?.size == 12)
    #expect(FontConfigParsers.vsCode(settings: #"{"editor.fontFamily": ""}"#)?.families.first == "Menlo")
}

@Test func vsCodeMalformedSettingsGiveNil() {
    #expect(FontConfigParsers.vsCode(settings: "") == nil)
    #expect(FontConfigParsers.vsCode(settings: "{ \"editor.fontSize\": ") == nil)
    #expect(FontConfigParsers.vsCode(settings: "[1, 2]") == nil)
    #expect(FontConfigParsers.vsCode(settings: "{ /* unclosed") == nil)
    #expect(FontConfigParsers.vsCode(settings: "not json") == nil)
}

@Test func cssFamilyListHandlesQuotesAndSpaces() {
    #expect(FontConfigParsers.cssFamilies(#" "JetBrains Mono" ,'Source Code Pro',Menlo,, monospace "#)
            == ["JetBrains Mono", "Source Code Pro", "Menlo", "monospace"])
    #expect(FontConfigParsers.cssFamilies(#""A, B", C"#) == ["A, B", "C"])
    #expect(FontConfigParsers.cssFamilies("") == [])
}

// MARK: Ghostty config

@Test func ghosttyFirstFamilyWinsLastSizeWins() {
    let files = ["/h/.config/ghostty/config": """
    # comment = ignored
    font-family = "Fira Code"
    font-family = Menlo
    font-size = 12
    not a key line
    font-size = 14.5
    font-size = big
    """]
    let font = FontConfigParsers.ghostty(roots: ["/h/.config/ghostty/config"], home: "/h") { files[$0] }
    #expect(font?.families == ["Fira Code", "Menlo"])
    #expect(font?.size == 14.5)
}

@Test func ghosttyEmptyValueResetsAndMissingKeysUseDefaults() {
    let files = ["/c": "font-family = Fira Code\nfont-family =\nfont-family = Menlo\nfont-size = 15\nfont-size =\n"]
    let font = FontConfigParsers.ghostty(roots: ["/c"], home: "/h") { files[$0] }
    #expect(font?.families == ["Menlo"])
    #expect(font?.size == 13)
    let bare = FontConfigParsers.ghostty(roots: ["/c"], home: "/h") { _ in "theme = dark\n" }
    #expect(bare?.families == ["JetBrains Mono"])
    #expect(bare?.size == 13)
}

@Test func ghosttyMissingFilesGiveNil() {
    #expect(FontConfigParsers.ghostty(roots: ["/a", "/b"], home: "/h") { _ in nil } == nil)
    #expect(FontConfigParsers.ghostty(roots: [], home: "/h") { _ in "font-size = 12" } == nil)
}

@Test func ghosttyLaterRootsOverrideAndAppend() {
    let files = ["/xdg/config": "font-family = A\nfont-size = 11",
                 "/mac/config": "font-family = B\nfont-size = 16"]
    let font = FontConfigParsers.ghostty(roots: ["/xdg/config.ghostty", "/xdg/config", "/mac/config"],
                                         home: "/h") { files[$0] }
    #expect(font?.families == ["A", "B"])
    #expect(font?.size == 16)
}

@Test func ghosttyIncludesResolveRelativeAndLoadAfterTheFile() {
    let files = [
        "/h/.config/ghostty/config": """
        config-file = fonts/main
        config-file = ?missing
        config-file = ~/abs
        font-size = 12
        font-family = Root
        """,
        "/h/.config/ghostty/fonts/main": "font-size = 18\nfont-family = Included\nconfig-file = ../deeper",
        "/h/abs": "font-family = Home",
        "/h/.config/ghostty/deeper": "font-size = 20",
    ]
    let font = FontConfigParsers.ghostty(roots: ["/h/.config/ghostty/config"], home: "/h") { files[$0] }
    // Includes load after the including file (so they override its size), breadth first.
    #expect(font?.families == ["Root", "Included", "Home"])
    #expect(font?.size == 20)
}

@Test func ghosttyIncludeCyclesAndDepthAreBounded() {
    let cyclic = ["/a": "font-family = A\nconfig-file = /b", "/b": "font-family = B\nconfig-file = /a\nconfig-file = ./b"]
    let font = FontConfigParsers.ghostty(roots: ["/a"], home: "/h") { cyclic[$0] }
    #expect(font?.families == ["A", "B"])

    // /0 includes /1 includes ... /6; depth 4 is the deepest followed.
    var chain: [String: String] = [:]
    for i in 0...6 { chain["/\(i)"] = "font-size = \(10 + i)\nconfig-file = /\(i + 1)" }
    let deep = FontConfigParsers.ghostty(roots: ["/0"], home: "/h") { chain[$0] }
    #expect(deep?.size == 14)
}

@Test func ghosttyQuotedIncludeKeepsLiteralQuestionMark() {
    var asked: [String] = []
    _ = FontConfigParsers.ghostty(roots: ["/d/config"], home: "/h") { path in
        asked.append(path)
        return path == "/d/config" ? "config-file = \"?odd\"\nconfig-file = ?opt" : nil
    }
    #expect(asked == ["/d/config", "/d/?odd", "/d/opt"])
}

// MARK: kitty config

@Test func kittyLastValueWinsAndFamilyForms() {
    let font = FontConfigParsers.kitty("""
    # font_family Commented
    font_family      Fira Code
    font_size 12.0
    font_family family="JetBrains Mono" style=Regular
    font_size 13.5
    font_size huge
    """)
    #expect(font.families == ["JetBrains Mono"])
    #expect(font.size == 13.5)
    #expect(FontConfigParsers.kitty("font_family family='Source Code Pro'").families == ["Source Code Pro"])
    #expect(FontConfigParsers.kitty("font_family family=Hack features=+zero").families == ["Hack"])
}

@Test func kittyDefaultsAndMalformedValues() {
    let empty = FontConfigParsers.kitty("")
    #expect(empty.families == ["Menlo"])
    #expect(empty.size == 11)
    #expect(FontConfigParsers.kitty("font_family monospace").families == ["Menlo"])
    #expect(FontConfigParsers.kitty("font_family auto\nfont_size -3").families == ["Menlo"])
    #expect(FontConfigParsers.kitty("font_size -3").size == 11)
    #expect(FontConfigParsers.kitty("font_family family=\"Unclosed").families == ["Menlo"])
}

// MARK: iTerm2 profiles

@Test func iTerm2DefaultProfileFirstThenStoredOrder() {
    let bookmarks: [[String: Any]] = [
        ["Guid": "g1", "Normal Font": "Monaco 12"],
        ["Guid": "g2", "Normal Font": "MesloLGS-NF-Regular 13", "Horizontal Spacing": 1.1],
        ["Guid": "g3", "Normal Font": "Menlo-Regular 11.5", "Horizontal Spacing": 0],
    ]
    let fonts = FontConfigParsers.iTerm2(bookmarks: bookmarks, defaultGuid: "g2")
    #expect(fonts.map(\.postScriptName) == ["MesloLGS-NF-Regular", "Monaco", "Menlo-Regular"])
    #expect(fonts.map(\.size) == [13, 12, 11.5])
    #expect(fonts.map(\.widthSpacing) == [1.1, 1, 1])
    #expect(FontConfigParsers.iTerm2(bookmarks: bookmarks, defaultGuid: nil).first?.postScriptName == "Monaco")
    #expect(FontConfigParsers.iTerm2(bookmarks: bookmarks, defaultGuid: "unknown").count == 3)
}

@Test func iTerm2MalformedFontsAreDropped() {
    let bookmarks: [[String: Any]] = [
        ["Guid": "a", "Normal Font": "Monaco"],
        ["Guid": "b", "Normal Font": "Monaco twelve"],
        ["Guid": "c", "Normal Font": 12],
        ["Guid": "d"],
        ["Guid": "e", "Normal Font": " 12"],
        ["Guid": "f", "Normal Font": "Monaco 0"],
    ]
    #expect(FontConfigParsers.iTerm2(bookmarks: bookmarks, defaultGuid: "a").isEmpty)
    #expect(FontConfigParsers.iTerm2(bookmarks: [], defaultGuid: nil).isEmpty)
    #expect(FontConfigParsers.iTerm2FontSpec("Fira Code Retina 14")! == ("Fira Code Retina", 14))
}

@Test func sliceKeepsTheSelectedText() {
    let s = TextWindow.slice("keep fix this keep", caretUTF16: 5, selectionUTF16: 8, limits: ContextLimits())
    #expect(s.selected == "fix this")
    #expect(s.before == "keep ")
    #expect(s.after == " keep")
    let none = TextWindow.slice("abc", caretUTF16: 1, selectionUTF16: 0, limits: ContextLimits())
    #expect(none.selected.isEmpty)
}

// MARK: CatalystScale

@Test func catalystIPadIdiomScalesReportedSize() {
    // Draw Things: UIDeviceFamily [2], AX says 17.25 pt for text drawn at ~13.3 pt.
    #expect(CatalystScale.factor(deviceFamily: [2]) == 0.77)
    #expect(CatalystScale.factor(deviceFamily: [1, 2]) == 0.77)
    #expect(abs(17.25 * CatalystScale.factor(deviceFamily: [2]) - 13.28) < 0.01)
}

@Test func macIdiomAndAppKitAppsKeepReportedSize() {
    #expect(CatalystScale.factor(deviceFamily: nil) == 1)
    #expect(CatalystScale.factor(deviceFamily: [6]) == 1)
    #expect(CatalystScale.factor(deviceFamily: [2, 6]) == 1)
    #expect(CatalystScale.factor(deviceFamily: [Int]()) == 1)
    #expect(CatalystScale.factor(deviceFamily: "junk") == 1)
}

@Test func appleCatalystAppsWithMacIdiomFlagKeepReportedSize() {
    // Messages: UIDeviceFamily [2] but UIUserInterfaceIdiomMac true; it draws at full size.
    #expect(CatalystScale.factor(deviceFamily: [2], macIdiom: true) == 1)
    #expect(CatalystScale.factor(deviceFamily: [2], macIdiom: false) == 0.77)
}
