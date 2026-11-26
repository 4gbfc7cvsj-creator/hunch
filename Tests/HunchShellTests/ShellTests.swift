import Foundation
import Testing
@testable import HunchShell

@Suite struct ShellHistoryTests {
    @Test func parsesExtendedZshHistory() {
        let data = Data("""
        : 1697040000:0;git status
        : 1697040010:3;swift test --filter Foo
        plain line
        : 1697040020:0;echo one \\
        two
        : 1697040030:0;git status

        """.utf8)
        #expect(ShellHistory.parseZsh(data) == ["git status", "swift test --filter Foo", "plain line", "echo one \ntwo",
                                                "git status"])
    }

    @Test func undoesZshMetafication() {
        // "é" is C3 A9; zsh writes A9 as 83 89 (A9 ^ 20).
        var bytes = Array(": 1:0;echo caf".utf8)
        bytes += [0xC3, 0x83, 0x89, 0x0A]
        #expect(ShellHistory.parseZsh(Data(bytes)) == ["echo café"])
        // Traditional Chinese passes through: 台 is E5 8F B0, no metafied bytes.
        #expect(ShellHistory.parseZsh(Data(": 1:0;echo 台北\n".utf8)) == ["echo 台北"])
    }

    @Test func parsesBashHistorySkippingTimestamps() {
        #expect(ShellHistory.parseBash(Data("#1697040000\nls -la\ncd ~/src\n".utf8)) == ["ls -la", "cd ~/src"])
    }

    @Test func newestMatchWinsAndDuplicatesCollapse() {
        let h = ShellHistory(commands: ["git status", "git stash", "git status", "git log --oneline"])
        #expect(h.commands == ["git stash", "git status", "git log --oneline"])
        #expect(h.completion(for: "git st") == "atus")
        #expect(h.completion(for: "git l") == "og --oneline")
        #expect(h.completion(for: "git status") == nil)   // nothing longer
        #expect(h.completion(for: "  ") == nil)
        #expect(h.completion(for: "Git") == nil)          // exact case
        #expect(h.recent(2) == ["git status", "git log --oneline"])
    }

    @Test func dropsSecretsAndMultilineCommands() {
        let key = "sk-" + String(repeating: "a1B2c3D4", count: 5)
        let h = ShellHistory(commands: ["export OPENAI_API_KEY=\(key)", "echo one \ntwo", "ls"])
        #expect(h.commands == ["ls"])
    }
}

@Suite struct ShellCommandCheckTests {
    @Test func findsEveryCommandWord() {
        #expect(ShellCommandCheck.commandWords("git status") == ["git"])
        #expect(ShellCommandCheck.commandWords("FOO=1 BAR=2 make test") == ["make"])
        #expect(ShellCommandCheck.commandWords("cat a.txt | grep -i 'x y' && echo done; ls") == ["cat", "grep", "echo", "ls"])
        #expect(ShellCommandCheck.commandWords("echo \"a | b\" > out.txt 2>&1") == ["echo"])
        #expect(ShellCommandCheck.commandWords("echo $(date +%s)") == ["echo", "date"])
        #expect(ShellCommandCheck.commandWords("(cd src && swift build)") == ["cd", "swift"])
        #expect(ShellCommandCheck.commandWords("./scripts/build-app.sh --release") == ["./scripts/build-app.sh"])
        #expect(ShellCommandCheck.commandWords("") == [])
    }

    @Test func knownCommandsUseBuiltinsAndLookup() {
        let known: (String) -> Bool = { ["git", "grep", "swift"].contains($0) }
        #expect(ShellCommandCheck.commandsKnown("cd src && git pull", isKnown: known))
        #expect(ShellCommandCheck.commandsKnown("git log | grep fix", isKnown: known))
        #expect(!ShellCommandCheck.commandsKnown("gti status", isKnown: known))
        #expect(!ShellCommandCheck.commandsKnown("git log | grpe fix", isKnown: known))
        // Prose is not a command.
        #expect(!ShellCommandCheck.commandsKnown("Thanks for the help", isKnown: known))
    }

    @Test func riskyCommands() {
        for risky in ["sudo rm /tmp/x", "rm -rf build", "rm -fr ~/x", "rm -r dir", "rm --recursive x",
                      "git push --force", "git push -f origin main", "git push origin +main", "git reset --hard HEAD~1",
                      "git clean -fd", "curl -fsSL https://example.com/i.sh | sh", "wget -qO- x | sudo bash",
                      "dd if=/dev/zero of=/dev/disk2", "diskutil eraseDisk APFS X disk2", "chmod -R 777 .",
                      "ls && shutdown -h now", "killall Finder", "kill -9 -1"] {
            #expect(ShellCommandCheck.isRisky(risky), Comment(rawValue: risky))
        }
        for safe in ["rm file.txt", "git push", "git push origin main", "git reset HEAD~1", "curl -O https://x/y.zip",
                     "ls -la", "swift test", "echo sudo"] {
            #expect(!ShellCommandCheck.isRisky(safe), Comment(rawValue: safe))
        }
    }

    @Test func zshSyntaxCheckDoesNotRunAnything() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("gt-shell-\(UUID().uuidString)")
        #expect(ShellEnvironment.parses("touch \(marker.path)"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!ShellEnvironment.parses("echo \"unclosed"))
        #expect(!ShellEnvironment.parses("ls |"))
        #expect(!ShellEnvironment.parses("if true; then echo"))
        #expect(ShellEnvironment.parses("for f in *.log; do gzip \"$f\"; done"))
    }

    @Test func validSuggestionNeedsRealCommands() {
        let env = ShellEnvironment(shell: "/bin/zsh")
        #expect(env.isValidSuggestion("ls -la"))
        #expect(env.isValidSuggestion("cd /tmp && ls"))
        #expect(!env.isValidSuggestion("definitelynotacommand123 --help"))
        #expect(!env.isValidSuggestion("rm -rf /tmp/x"))
        #expect(!env.isValidSuggestion("I think we should"))
        #expect(!env.isValidSuggestion("echo \"unclosed"))
    }
}
