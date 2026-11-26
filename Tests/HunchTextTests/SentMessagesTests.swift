import Testing
import HunchCore
@testable import HunchText

private let box = FieldID(pid: 1, elementHash: 1, generation: 0)
private let other = FieldID(pid: 1, elementHash: 2, generation: 0)

@Test func aBoxEmptiedAtOnceIsASentMessage() {
    var s = SentMessages()
    for text in ["S", "See you", "See you at six!"] { s.note(app: "chat", field: box, text: text) }
    s.note(app: "chat", field: box, text: "")
    #expect(s.messages(app: "chat") == ["See you at six!"])
    #expect(s.messages(app: "mail").isEmpty)
}

@Test func deletingLittleByLittleOrLeavingIsNotSending() {
    var s = SentMessages()
    for text in ["Never mind", "Never", "Ne", ""] { s.note(app: "chat", field: box, text: text) }
    s.note(app: "chat", field: box, text: "Draft")
    s.focusEnded()
    s.note(app: "chat", field: box, text: "")
    s.note(app: "chat", field: box, text: "Other draft")
    s.note(app: "chat", field: other, text: "")
    #expect(s.messages(app: "chat").isEmpty)
}

@Test func keepsTheLastTenPerApp() {
    var s = SentMessages()
    for i in 1...12 {
        s.note(app: "chat", field: box, text: "message \(i)")
        s.note(app: "chat", field: box, text: "  ")
    }
    #expect(s.messages(app: "chat").count == SentMessages.perApp)
    #expect(s.messages(app: "chat").first == "message 3" && s.messages(app: "chat").last == "message 12")
}

// Discord's emptied box still holds U+FEFF and a newline; a web editor may report its placeholder.
@Test func aBoxEmptiedToInvisibleCharactersOrItsPlaceholderIsSent() {
    var s = SentMessages()
    s.note(app: "discord", field: box, text: "\u{FEFF}Sounds good")
    s.note(app: "discord", field: box, text: "\u{FEFF}\n")
    #expect(s.messages(app: "discord") == ["Sounds good"])
    s.note(app: "codex", field: other, text: "Run the tests")
    s.note(app: "codex", field: other, text: "Ask Codex anything", placeholder: "Ask Codex anything")
    #expect(s.messages(app: "codex") == ["Run the tests"])
}

@Test func aBoxShowingItsLabelAsTextIsEmpty() {
    func ctx(_ before: String, _ after: String, label: String?) -> TextContext {
        TextContext(app: AppIdentity(bundleID: "com.openai.codex", pid: 1, localizedName: nil), field: box,
                    before: before, after: after, selectionLength: 0,
                    metadata: FieldMetadata(label: label, surface: .unknown), contentSignature: 0)
    }
    #expect(ctx("", "Ask ChatGPT\n", label: "Ask ChatGPT Ask ChatGPT").looksEmpty)
    #expect(ctx("\u{FEFF}", "\n", label: nil).looksEmpty)
    #expect(!ctx("Ask ChatGPT", "", label: "Ask ChatGPT").looksEmpty)   // typed it: caret after it
    #expect(!ctx("", "Ask ChatGPT about this", label: "Ask ChatGPT").looksEmpty)
}
