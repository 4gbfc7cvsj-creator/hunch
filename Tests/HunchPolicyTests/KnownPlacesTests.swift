import Foundation
import HunchCore
import Testing
@testable import HunchPolicy

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gt-places-\(UUID().uuidString).json")
}

@Suite struct KnownPlacesTests {
    @Test func autoAddOnceAndPersist() {
        let url = tempFile()
        let s = KnownPlacesStore(fileURL: url)
        s.noteUsed(.app(bundleID: "com.openai.chat"), name: "ChatGPT")
        s.noteUsed(.app(bundleID: "com.openai.chat"), name: "Other")
        #expect(s.places.count == 1)
        #expect(s.places.first?.name == "ChatGPT")
        #expect(s.places.first?.manual == false)
        let again = KnownPlacesStore(fileURL: url)
        #expect(again.contains(.app(bundleID: "com.openai.chat")))
        #expect(again.places.first?.name == "ChatGPT")
    }

    @Test func removedStaysRemovedUntilPlus() {
        let url = tempFile()
        let s = KnownPlacesStore(fileURL: url)
        let k = PolicyKey.domain(pattern: "chatgpt.com")
        s.noteUsed(k)
        s.remove(k)
        s.noteUsed(k)
        #expect(!s.contains(k))
        #expect(!KnownPlacesStore(fileURL: url).contains(k))
        s.add(k)
        #expect(s.contains(k))
        #expect(s.places.first?.manual == true)
        s.remove(k)
        let reloaded = KnownPlacesStore(fileURL: url)
        reloaded.noteUsed(k)
        #expect(!reloaded.contains(k))
    }

    @Test func adoptListsKeysWithSettings() {
        let s = KnownPlacesStore(fileURL: nil)
        s.adopt([.app(bundleID: "a"), .domain(pattern: "*.example.com")])
        #expect(s.places.count == 2)
    }

    @Test func siteKeyNormalizes() {
        #expect(KnownPlacesStore.siteKey("WWW.Example.com") == .domain(pattern: "example.com"))
        #expect(KnownPlacesStore.siteKey(" ") == nil)
    }
}

@Test func siteInputParsing() {
    #expect(KnownPlacesStore.siteKey(fromInput: " Example.com ") == .domain(pattern: "example.com"))
    #expect(KnownPlacesStore.siteKey(fromInput: "www.github.com") == .domain(pattern: "github.com"))
    #expect(KnownPlacesStore.siteKey(fromInput: "*.Notion.so") == .domain(pattern: "*.notion.so"))
    #expect(KnownPlacesStore.siteKey(fromInput: "https://mail.google.com/mail/u/0") == .domain(pattern: "mail.google.com"))
    #expect(KnownPlacesStore.siteKey(fromInput: "localhost") == nil)
    #expect(KnownPlacesStore.siteKey(fromInput: "not a site") == nil)
    #expect(KnownPlacesStore.siteKey(fromInput: "a.com/path") == nil)
    #expect(KnownPlacesStore.siteKey(fromInput: "*.") == nil)
}

@Test func instructionsReplaceGlobalLayers() {
    var app = AppPolicyPatch(); app.customInstructions = "Formal."; app.instructionsReplaceGlobal = true
    var site = AppPolicyPatch(); site.customInstructions = "Short replies."
    let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.apple.Safari"): app, .domain(pattern: "chat.example.com"): site]
    let r = DefaultPolicyResolver(completionsEnabledByDefault: true, seeds: [:], userPatches: { patches })
    #expect(r.resolve(bundleID: "com.apple.Safari", urlHost: nil).policy.instructionsReplaceGlobal == true)
    // A site in that browser keeps the browser's choice unless it sets its own.
    let p = r.resolve(bundleID: "com.apple.Safari", urlHost: "chat.example.com").policy
    #expect(p.customInstructions == "Short replies." && p.instructionsReplaceGlobal == true)
    #expect(r.resolve(bundleID: "com.example.notes", urlHost: nil).policy.instructionsReplaceGlobal == false)
}

@Test func writeShapeLayersLikeOtherChoices() {
    var app = AppPolicyPatch()
    app.writeShape = .message
    var site = AppPolicyPatch()
    site.writeShape = .email
    let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.google.Chrome"): app,
                                                .domain(pattern: "mail.google.com"): site]
    let r = DefaultPolicyResolver(completionsEnabledByDefault: true, seeds: [:], userPatches: { patches })
    #expect(r.resolve(bundleID: "com.other", urlHost: nil).policy.writeShape == .adaptive)
    #expect(r.resolve(bundleID: "com.google.Chrome", urlHost: nil).policy.writeShape == .message)
    #expect(r.resolve(bundleID: "com.google.Chrome", urlHost: "mail.google.com").policy.writeShape == .email)
    #expect(InheritedPolicy(bundleID: "com.other", settings: HunchSettings(), seeds: [:]).writeShape == .adaptive)
}

@Test func customWriteShapeLayersAndPresetsReplaceIt() {
    let id = UUID()
    var browser = AppPolicyPatch()
    browser.writeCustomShapeID = id
    var site = AppPolicyPatch()
    site.writeShape = .email
    var old = AppPolicyPatch()
    old.writeShape = .paragraph
    let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.google.Chrome"): browser,
                                                .domain(pattern: "mail.google.com"): site,
                                                .app(bundleID: "com.old"): old]
    let r = DefaultPolicyResolver(completionsEnabledByDefault: true, seeds: [:], userPatches: { patches })
    // A site with no shape of its own keeps the browser's custom shape; one with a preset drops it.
    #expect(r.resolve(bundleID: "com.google.Chrome", urlHost: "example.com").policy.writeCustomShapeID == id)
    let mail = r.resolve(bundleID: "com.google.Chrome", urlHost: "mail.google.com").policy
    #expect(mail.writeCustomShapeID == nil && mail.writeShape == .email)
    // Paragraph is no longer a choice: an older file's Paragraph reads as Default.
    #expect(r.resolve(bundleID: "com.old", urlHost: nil).policy.writeShape == .adaptive)
}
