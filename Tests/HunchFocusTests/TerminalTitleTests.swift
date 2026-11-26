import Testing
@testable import HunchFocus

@Suite struct TerminalTitleTests {
    private func kind(_ title: String?) -> TerminalTitleKind { TerminalTitleClassifier.classify(title) }

    @Test func shellsAreShells() {
        #expect(kind("alex — -zsh — 80×24") == .shell)       // Terminal.app
        #expect(kind("-bash") == .shell)
        #expect(kind("Default (zsh)") == .shell)             // iTerm session (job)
        #expect(kind("/opt/homebrew/bin/fish") == .shell)
        #expect(kind("Hunch — zsh") == .shell)
    }

    @Test func agentCLIsAreAgents() {
        #expect(kind("✳ Claude Code") == .agent)
        #expect(kind("✳ Fix the caret math") == .agent)     // Claude Code's task title
        #expect(kind("⠐ Reading files") == .agent)           // its spinner while working
        #expect(kind("alex — claude — 80×24") == .agent)
        #expect(kind("Gemini - Hunch") == .agent)
        #expect(kind("codex") == .agent)
        #expect(kind("aider ◂ -zsh") == .agent)              // the agent beats the shell beside it
    }

    @Test func otherProgramsGetNothing() {
        #expect(kind("alex — vim notes.md ◂ -zsh — 80×24") == .otherProgram)
        #expect(kind("ssh alex@build-box") == .otherProgram)
        #expect(kind("python3") == .otherProgram)
        #expect(kind("man ls") == .otherProgram)
        #expect(kind("R") == .otherProgram)
    }

    @Test func noClueLeavesItToTheScreen() {
        #expect(kind(nil) == .unknown)
        #expect(kind("") == .unknown)
        #expect(kind("~/Projects/Hunch") == .unknown)    // Ghostty with only the folder
        #expect(kind("Ghostty") == .unknown)
        #expect(kind("make test") == .unknown)
        #expect(kind("reading notes") == .unknown)            // "r" is not R
    }
}
