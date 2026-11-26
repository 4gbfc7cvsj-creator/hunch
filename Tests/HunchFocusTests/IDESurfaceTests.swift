import HunchCore
import HunchPolicy
import Testing
@testable import HunchFocus

// Fixture attribute sets modelled on Monaco / VS Code accessibility strings (Chromium maps
// aria-label to AXDescription, placeholder to AXPlaceholderValue, aria-roledescription to
// AXRoleDescription). Not measured on a live Cursor: see docs/features/ide-support.md.

private func classify(role: String = "AXTextArea", description: String? = nil, placeholder: String? = nil,
                      roleDescription: String? = nil) -> IDESurface {
    IDESurfaceClassifier.classify(role: role, description: description, placeholder: placeholder,
                                  roleDescription: roleDescription)
}

@Suite struct IDESurfaceClassifierTests {
    @Test func monacoEditorTextareaIsACodeBuffer() {
        #expect(classify(description: "Editor content;Press Alt+F1 for Accessibility Options.") == .codeBuffer)
        #expect(classify(description: "Editor content") == .codeBuffer)
        // editor.accessibilitySupport off: Monaco says so in the label; still the code buffer.
        #expect(classify(description: "The editor is not accessible at this time. Press Alt+F1 for options.") == .codeBuffer)
        #expect(classify(description: nil, roleDescription: "editor") == .codeBuffer)
    }

    @Test func xcodeSourceEditorIsACodeBuffer() {
        #expect(classify(description: "Source Editor") == .codeBuffer)
    }

    @Test func chatComposersAreAIChat() {
        #expect(classify(description: "Chat Input") == .aiChat)
        #expect(classify(placeholder: "Ask Copilot") == .aiChat)
        #expect(classify(placeholder: "Plan, search, build anything") == .aiChat)
        #expect(classify(placeholder: "Ask anything (⌘L)") == .aiChat)
    }

    @Test func commitMessageBoxIsProse() {
        #expect(classify(description: "Source Control Input", placeholder: "Message (⌘Enter to commit on 'main')") == .proseInput)
        #expect(classify(placeholder: "Message (⌘Enter to commit on 'main')") == .proseInput)
    }

    @Test func findWidgetAndPaletteAreProse() {
        #expect(classify(role: "AXTextField", description: "Find") == .proseInput)
        #expect(classify(role: "AXTextField", placeholder: "Replace") == .proseInput)
        #expect(classify(role: "AXTextField", description: "Type the name of a command to run.") == .proseInput)
        // A single-line field with no recognizable label is prose, never a source buffer.
        #expect(classify(role: "AXTextField") == .proseInput)
    }

    @Test func integratedTerminalIsATerminal() {
        #expect(classify(description: "Terminal input") == .terminal)
        #expect(classify(description: "Terminal 1, zsh") == .terminal)
    }

    @Test func unlabelledTextAreaIsUnknown() {
        #expect(classify() == .unknown)
        #expect(classify(description: "") == .unknown)
    }

    @Test func descriptionWinsOverPlaceholderAndOrderIsTerminalProseCode() {
        // The description decides first; a prose marker beats the editor marker.
        #expect(classify(description: "Editor content", placeholder: "Ask anything") == .codeBuffer)
        #expect(classify(description: "Terminal input", placeholder: "Message") == .terminal)
    }
}

@Suite struct SurfaceClassifierCodeTests {
    @Test func everySeededCodeEditorIsACodeSurface() {
        for id in Seeds.codeEditors {
            #expect(SurfaceClassifier.classify(bundleID: id, role: "AXTextArea", subrole: nil) == .code, "\(id)")
        }
        #expect(SurfaceClassifier.code == Set(Seeds.codeEditors))
    }

    @Test func ideSurfaceDecidesTheKindInsideAnEditor() {
        let cursor = "com.todesktop.230313mzl4w4u92"
        #expect(SurfaceClassifier.classify(bundleID: cursor, role: "AXTextArea", subrole: nil, ideSurface: .codeBuffer) == .code)
        #expect(SurfaceClassifier.classify(bundleID: cursor, role: "AXTextArea", subrole: nil, ideSurface: .unknown) == .code)
        #expect(SurfaceClassifier.classify(bundleID: cursor, role: "AXTextArea", subrole: nil, ideSurface: .proseInput) == .unknown)
        #expect(SurfaceClassifier.classify(bundleID: cursor, role: "AXTextArea", subrole: nil, ideSurface: .aiChat) == .unknown)
        #expect(SurfaceClassifier.classify(bundleID: cursor, role: "AXTextArea", subrole: nil, ideSurface: .terminal) == .terminal)
        // Search fields keep their role-based kind; other apps ignore the IDE surface.
        #expect(SurfaceClassifier.classify(bundleID: cursor, role: "AXSearchField", subrole: nil, ideSurface: .codeBuffer) == .search)
        #expect(SurfaceClassifier.classify(bundleID: "com.apple.Notes", role: "AXTextArea", subrole: nil, ideSurface: .codeBuffer) == .note)
    }
}

@Suite struct CodeLineEndTests {
    @Test func trailingClosersCountAsLineEnd() {
        #expect(CodeLineEnd.isEffectiveLineEnd(after: ""))
        #expect(CodeLineEnd.isEffectiveLineEnd(after: ")"))
        #expect(CodeLineEnd.isEffectiveLineEnd(after: ")\n    bar()"))
        #expect(CodeLineEnd.isEffectiveLineEnd(after: "\")"))
        #expect(CodeLineEnd.isEffectiveLineEnd(after: "]);"))
        #expect(CodeLineEnd.isEffectiveLineEnd(after: " }"))
        #expect(CodeLineEnd.isEffectiveLineEnd(after: "')  \n"))
        #expect(CodeLineEnd.isEffectiveLineEnd(after: "  \nnext"))
    }

    @Test func textAfterTheCaretIsMidLine() {
        #expect(!CodeLineEnd.isEffectiveLineEnd(after: "x)"))
        #expect(!CodeLineEnd.isEffectiveLineEnd(after: ") + 1"))
        #expect(!CodeLineEnd.isEffectiveLineEnd(after: "(foo"))
        #expect(!CodeLineEnd.isEffectiveLineEnd(after: ", b)"))
    }
}
