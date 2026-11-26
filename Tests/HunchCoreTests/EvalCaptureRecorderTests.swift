import Foundation
import Testing
@testable import HunchCore

@MainActor
struct EvalCaptureRecorderTests {
    let app = AppIdentity(bundleID: "com.example.chat", pid: 7, localizedName: "Claude")
    let field = FieldID(pid: 7, elementHash: 1, generation: 1)
    let other = FieldID(pid: 7, elementHash: 2, generation: 1)
    let message = "can you redo the table but only with the laptops under 1800"

    func context(_ before: String, field: FieldID? = nil, surface: SurfaceKind = .agentPrompt) -> TextContext {
        TextContext(app: app, field: field ?? self.field, urlHost: "claude.ai", before: before, after: "",
                    metadata: FieldMetadata(surface: surface), contentSignature: 0, windowTitle: "Laptop picks")
    }

    func recorder(enabled: Bool = true) -> (EvalCaptureRecorder, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evalcap-\(UUID().uuidString).jsonl")
        return (EvalCaptureRecorder(isEnabled: { enabled }, fileURL: url), url)
    }

    func lines(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// Types `message` one word at a time, sending a screen excerpt with the first request.
    func type(_ r: EvalCaptureRecorder, screen: String? = "earlier conversation") {
        r.noteContext(context(""))
        var typed = ""
        for word in message.split(separator: " ") {
            typed += (typed.isEmpty ? "" : " ") + word
            r.noteContext(context(typed))
            r.noteRequest(context(typed), screen: screen)
        }
    }

    @Test func sentMessageIsSavedAsReplayCase() {
        let (r, url) = recorder()
        type(r)
        r.noteContext(context(""))   // sent: the box emptied
        let saved = lines(url)
        #expect(saved.count == 1)
        #expect(saved.first?["text"] as? String == message)
        #expect(saved.first?["screen"] as? String == "earlier conversation")
        #expect(saved.first?["surface"] as? String == "agentPrompt")
        #expect(saved.first?["windowTitle"] as? String == "Laptop picks")
        #expect(saved.first?["prefix"] == nil)
    }

    @Test func focusLossFinishesAndKeepsTheGreeting() {
        let (r, url) = recorder()
        r.noteContext(context("Hi Grace,\n\n", surface: .email))
        r.noteContext(context("Hi Grace,\n\n" + message, surface: .email))
        r.noteRequest(context("Hi Grace,\n\n" + message, surface: .email), screen: "From: Grace Kim")
        r.focusEnded()
        let saved = lines(url)
        #expect(saved.first?["prefix"] as? String == "Hi Grace,\n\n")
        #expect(saved.first?["text"] as? String == message)
    }

    @Test func nothingSavedWhenOffShortOrWithoutScreen() {
        let (off, offURL) = recorder(enabled: false)
        type(off)
        off.focusEnded()
        #expect(lines(offURL).isEmpty)

        let (noScreen, noScreenURL) = recorder()
        type(noScreen, screen: nil)
        noScreen.focusEnded()
        #expect(lines(noScreenURL).isEmpty)

        let (short, shortURL) = recorder()
        short.noteContext(context(""))
        short.noteContext(context("ok thanks"))
        short.noteRequest(context("ok thanks"), screen: "earlier conversation")
        short.focusEnded()
        #expect(lines(shortURL).isEmpty)
    }

    @Test func desktopAIAppsAndWebmailAreCaptured() {
        let desktop = AppIdentity(bundleID: "com.anthropic.claudefordesktop", pid: 7, localizedName: "Claude")
        let claude = TextContext(app: desktop, field: field, before: "", after: "",
                                 metadata: FieldMetadata(surface: .unknown), contentSignature: 0)
        #expect(EvalCaptureRecorder.captureSurface(claude) == .agentPrompt)
        let browser = AppIdentity(bundleID: "com.google.Chrome", pid: 8, localizedName: "Chrome")
        let gmail = TextContext(app: browser, field: field, urlHost: "mail.google.com", before: "", after: "",
                                metadata: FieldMetadata(surface: .unknown), contentSignature: 0)
        #expect(EvalCaptureRecorder.captureSurface(gmail) == .email)
        let other = TextContext(app: browser, field: field, urlHost: "example.com", before: "", after: "",
                                metadata: FieldMetadata(surface: .unknown), contentSignature: 0)
        #expect(EvalCaptureRecorder.captureSurface(other) == nil)
    }

    @Test func otherSurfacesAreIgnoredAndFieldChangeFinishes() {
        let (r, url) = recorder()
        r.noteContext(context("", surface: .chat))
        r.noteContext(context(message, surface: .chat))
        r.noteRequest(context(message, surface: .chat), screen: "thread")
        r.focusEnded()
        #expect(lines(url).isEmpty)

        type(r)
        r.noteContext(context("", field: other))   // moved to another field
        #expect(lines(url).count == 1)
    }

    @Test func messageWithASecretIsNotSaved() {
        let (r, url) = recorder()
        r.noteContext(context(""))
        let typed = "here is the key sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 can you check it"
        r.noteContext(context(typed))
        r.noteRequest(context(typed), screen: "earlier conversation")
        r.noteContext(context(""))
        #expect(lines(url).isEmpty)
    }

    @Test func idsDifferWithinTheSameSecond() {
        let (r, url) = recorder()
        type(r)
        r.noteContext(context(""))
        type(r)
        r.focusEnded()
        let ids = lines(url).compactMap { $0["id"] as? String }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    @Test func countAndDelete() throws {
        let (r, url) = recorder()
        #expect(EvalCaptureRecorder.savedCount(at: url) == nil)
        type(r)
        r.noteContext(context(""))
        #expect(EvalCaptureRecorder.savedCount(at: url) == 1)
        try EvalCaptureRecorder.deleteSaved(at: url)
        #expect(EvalCaptureRecorder.savedCount(at: url) == nil)
    }
}
