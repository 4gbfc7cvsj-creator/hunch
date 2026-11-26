import Foundation
import HunchCore
import HunchPolicy
import Testing
@testable import HunchFocus

@Test func everySeededTerminalHasAProfile() {
    for id in Seeds.terminals {
        #expect(TerminalHosts.profile(for: id) != nil, "no profile for \(id)")
    }
    #expect(Set(TerminalHosts.profiles.keys) == Set(Seeds.terminals))
}

@Test func terminalProfiles() {
    for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.cmuxterm.app"] {
        #expect(TerminalHosts.profile(for: id) == .axScreen, "\(id)")
    }
    #expect(TerminalHosts.profile(for: "dev.warp.Warp-Stable") == .axTextField)
    for id in ["net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm"] {
        #expect(TerminalHosts.profile(for: id) == .unsupported, "\(id)")
    }
    #expect(TerminalHosts.profile(for: "com.apple.TextEdit") == nil)
}

@Test func terminalSurfaceFollowsSeeds() {
    #expect(SurfaceClassifier.terminal == Set(Seeds.terminals))
    for id in Seeds.terminals {
        #expect(SurfaceClassifier.classify(bundleID: id, role: "AXTextArea", subrole: nil) == .terminal, "\(id)")
    }
}

@Test func screenWindowOnlyForLongScreens() {
    #expect(TerminalHosts.screenWindow(caretUTF16: 500, totalUTF16: 1_000) == nil)
    let range = try! #require(TerminalHosts.screenWindow(caretUTF16: 90_000, totalUTF16: 100_000))
    // At least 60 lines of 300 columns before the caret and 5 after.
    #expect(range.location <= 90_000 - 60 * 300)
    #expect(range.location + range.length >= 90_000 + 5 * 300)
    #expect(range.location + range.length <= 100_000)
}

@Test func wholeLinesDropsTheCutFirstLine() {
    let window = "tail of a line\nfull line\n❯ draft"
    let caret = 1_000 + (window as NSString).length
    let (text, local) = TerminalHosts.wholeLines(window, windowStart: 1_000, caretUTF16: caret)
    #expect(text == "full line\n❯ draft")
    #expect(local == (text as NSString).length)
    // A window from the start of the screen is kept whole.
    #expect(TerminalHosts.wholeLines(window, windowStart: 0, caretUTF16: 3) == (window, 3))
}

@Test func terminalDumpIsOffByDefault() {
    #expect(TerminalScreenDump.fromEnvironment([:]) == nil)
    #expect(TerminalScreenDump.fromEnvironment([TerminalScreenDump.variable: ""]) == nil)
    #expect(TerminalScreenDump.path(from: "relative/dump.jsonl") == nil)
    #expect(TerminalScreenDump.path(from: "/tmp/dump.jsonl")?.path == "/tmp/dump.jsonl")
    #expect(TerminalScreenDump.path(from: "~/dump.jsonl")
        == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dump.jsonl"))
}

@Test func terminalDumpWritesOneLinePerChangedScreen() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-terminal-dump-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let dump = TerminalScreenDump(url: url)
    dump.record(bundleID: "com.apple.Terminal", screen: "❯\u{00A0}hi", caretUTF16: 4, caretLine: 0, windowStart: 0, totalUTF16: 4)
    dump.record(bundleID: "com.apple.Terminal", screen: "❯\u{00A0}hi", caretUTF16: 4, caretLine: 0, windowStart: 0, totalUTF16: 4)
    dump.record(bundleID: "com.apple.Terminal", screen: "❯\u{00A0}hi!", caretUTF16: 5, caretLine: 0, windowStart: 0, totalUTF16: 5)
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    #expect(first?["screen"] as? String == "❯\u{00A0}hi")
    #expect(first?["caretUTF16"] as? Int == 4)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}
