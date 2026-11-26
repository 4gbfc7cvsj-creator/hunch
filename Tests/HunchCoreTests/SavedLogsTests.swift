import Foundation
import Testing
@testable import HunchCore

@Suite struct SavedLogsTests {
    private func file(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SavedLogsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("log.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    @Test func readsNewestFirstWithDateAppAndPreview() throws {
        let url = try file([
            #"{"capturedAt":"2026-11-19T01:00:00Z","app":"Mail","text":"Hi Alex,\nsee you","surface":"email"}"#,
            "not json",
            #"{"capturedAt":"2026-11-20T01:00:00.250Z","app":"Notes","text":"second"}"#,
        ])
        let entries = SavedLogs.entries(.evalCaptures, at: url)
        #expect(entries.map(\.preview) == ["second", "Hi Alex, see you"])
        #expect(entries.map(\.app) == ["Notes", "Mail"])
        #expect(entries.allSatisfy { $0.date != nil })
        #expect(entries[1].fields.first == SavedLogEntry.Field(name: "Text", value: "Hi Alex,\nsee you"))
        #expect(SavedLogs.count(.evalCaptures, at: url) == 3)
    }

    @Test func outcomePreviewsByKind() {
        func preview(_ line: String) -> String? { SavedLogs.entry(.outcomes, line: line, index: 0)?.preview }
        #expect(preview(#"{"kind":"suggestion","suggestion":"see you","result":"accepted"}"#)
                == "Suggestion \u{201C}see you\u{201D} \u{2013} accepted")
        #expect(preview(#"{"kind":"fix","from":"teh","to":"the","fixOutcome":"kept"}"#)
                == "Fix \u{201C}teh\u{201D} \u{2192} \u{201C}the\u{201D} \u{2013} kept")
        #expect(preview(#"{"kind":"typing","keys":12}"#) == "Typing \u{2013} 12 keys")
    }

    @Test func typingSampleKeysAreCountedNotListed() throws {
        let line = #"{"typed":"teh cat","final":"the cat","keys":[{"c":"t"},{"c":"e"}],"fixes":[],"verified":true}"#
        let entry = try #require(SavedLogs.entry(.typingSamples, line: line, index: 0))
        #expect(entry.preview == "the cat")
        #expect(entry.fields.contains(.init(name: "Keys", value: "2 key presses")))
        #expect(entry.fields.contains(.init(name: "Verified", value: "yes")))
        #expect(entry.fields.contains(.init(name: "Fixes", value: "none")))
    }

    @Test func removingEntriesKeepsTheRestAndOwnerOnly() throws {
        let a = #"{"at":"2026-11-19T01:00:00Z","raw":"one"}"#
        let b = #"{"at":"2026-11-19T02:00:00Z","raw":"two"}"#
        let c = #"{"at":"2026-11-19T03:00:00Z","raw":"three"}"#
        let url = try file([a, b, c])
        try SavedLogs.remove(lines: [b], from: .dictations, at: url)
        #expect(SavedLogs.entries(.dictations, at: url).map(\.preview) == ["three", "one"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try SavedLogs.remove(lines: [a, c], from: .dictations, at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try SavedLogs.removeAll(.dictations, at: url)  // already gone: no error
    }

    @Test func listsOnlyPlainTextLogs() throws {
        let url = try file(["x"])
        let dir = url.deletingLastPathComponent()
        try Data("12345".utf8).write(to: dir.appendingPathComponent("perf.log"))
        try Data("1".utf8).write(to: dir.appendingPathComponent("alignment.log"))
        #expect(SavedLogs.debugLogFiles(in: dir).map(\.name) == ["perf.log", "alignment.log"])
    }

    @Test func labels() {
        #expect(SavedLogs.label("windowTitle") == "Window title")
        #expect(SavedLogs.label("text") == "Text")
    }
}
