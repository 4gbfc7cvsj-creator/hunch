import Testing
@testable import HunchCore

@Suite struct PrivacySummaryTests {
    private func settings(learning: Bool, dictation: Bool, fixes: Bool) -> HunchSettings {
        var s = HunchSettings()
        s.learning.enabled = learning
        s.dictation.enabled = dictation
        s.dictation.learnFromFixes = fixes
        return s
    }

    @Test func neverSaysNothingIsSavedWhileFixesAreKept() {
        for learning in [false, true] {
            for dictation in [false, true] {
                for fixes in [false, true] {
                    let lines = PrivacySummary.kept(settings: settings(learning: learning, dictation: dictation,
                                                                       fixes: fixes))
                    let text = lines.joined(separator: "\n")
                    let kept = dictation && fixes
                    #expect(text.contains("dictation fix") == kept)
                    if kept { #expect(!text.contains("nothing you type is saved")) }
                    #expect(text.contains("nothing you type is saved") == (!learning && !kept))
                    // Learned words from dictation only with Learn from my writing on.
                    #expect(text.contains("added to your learned words") == (kept && learning))
                }
            }
        }
    }

    @Test func listsTheFilesWrittenWhateverTheSwitches() {
        let s = settings(learning: false, dictation: false, fixes: false)
        let text = PrivacySummary.kept(settings: s).joined()
        #expect(text.contains("Settings \u{2192} Apps"))
        #expect(text.contains("sizes and positions"))
        #expect(!text.contains("Debug logging"))
    }

    @Test func debugLoggingAndLogsLeftBehindAreMentioned() {
        var s = settings(learning: false, dictation: false, fixes: false)
        let left = PrivacySummary.kept(settings: s, logsSaved: true).joined()
        #expect(left.contains("Debug logging is off") && left.contains("Saved logs"))
        s.debugLogging = true
        let on = PrivacySummary.kept(settings: s, logsSaved: true).joined()
        #expect(on.contains("Debug logging is on") && on.contains("messages you type") && on.contains("dictate"))
        #expect(!on.contains("Debug logging is off"))
    }

    @Test func chatAvatarsOnlyWithScreenAwarenessAndLearning() {
        for screen in [false, true] {
            for learning in [false, true] {
                var s = settings(learning: learning, dictation: false, fixes: false)
                s.screenContextEnabled = screen
                let text = PrivacySummary.kept(settings: s).joined()
                #expect(text.contains("your own avatar") == (screen && learning))
            }
        }
    }

    @Test func disclaimerNamesEveryLogKept() {
        let d = PrivacySummary.debugLoggingDisclaimer
        for part in ["AI chat and email", "screen text", "misspelling", "suggestion", "90 days", "dictated",
                     "plain text", "~/Library/Logs/Hunch"] {
            #expect(d.contains(part), "\(part)")
        }
    }
}
