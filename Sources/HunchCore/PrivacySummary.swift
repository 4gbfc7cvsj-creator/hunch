import Foundation

/// The Privacy pane's "What stays on this Mac" list. Pure, so every switch combination is tested:
/// the pane is a promise and each sentence must hold.
public enum PrivacySummary {
    /// Shown under the Debug logging switch while it is on: what the logs keep, and where.
    public static let debugLoggingDisclaimer =
        "Saves in plain text, on this Mac only: each AI chat and email message you type, with the screen text "
        + "near it; messages with a misspelling, a Backspace or an autocorrect fix, as typed and as they ended "
        + "up; what became of each suggestion and automatic fix (its words, not the rest of your text), kept "
        + "90 days; and what you dictated, with the cleaned text. Also logs timings, sizes and details about the "
        + "fields you type in. Files are in ~/Library/Logs/Hunch and ~/Library/Application Support/Hunch. "
        + "Turning this off stops logging; saved logs stay until you delete them in Saved logs."

    /// `logsSaved`: whether any saved log is on disk (they stay after Debug logging is turned off).
    public static func kept(settings: HunchSettings, logsSaved: Bool = false) -> [String] {
        var out: [String] = []
        // Dictation fixes are kept under Dictation's own switch, whatever "Learn from my writing" says.
        let fixes = settings.dictation.enabled && settings.dictation.learnFromFixes
        if settings.learning.enabled {
            out.append("Learned words and phrases"
                       + (settings.learning.styleExamplesEnabled ? ", and a few sentences you wrote," : "")
                       + " are saved encrypted. Review or delete them in Personalization \u{2192} Learned data.")
        } else if fixes {
            out.append("Learn from my writing is off, so the words and sentences you type aren\u{2019}t saved, "
                       + "except the dictation fixes below.")
        } else {
            out.append("Learning is off, so nothing you type is saved.")
        }
        if fixes {
            out.append("When you correct a word you dictated, the word heard and the word you wrote are saved as a "
                       + "dictation fix (not encrypted)"
                       + (settings.learning.enabled ? ", and the word is added to your learned words" : "")
                       + ". Turn this off with Dictation \u{2192} Learn from fixes.")
        }
        if settings.screenContextEnabled && settings.learning.enabled {
            out.append("In Discord, a small color sample of your own avatar and the name read beside it are saved "
                       + "(not encrypted) to tell your messages apart on screen: never the picture or your messages. "
                       + "Review or delete them in Personalization \u{2192} Learned data.")
        }
        if !settings.aboutMe.isEmpty || !settings.customInstructions.isEmpty {
            out.append("What you wrote in About me and How I write is saved in Hunch\u{2019}s settings.")
        }
        out.append("The apps and sites you type in are listed for Settings \u{2192} Apps, and how text is drawn in "
                   + "each app (sizes and positions) is saved to place suggestions. App names, site addresses "
                   + "and numbers only, never what you type.")
        if settings.debugLogging {
            out.append("Debug logging is on: diagnostic logs are saved in plain text on this Mac, including messages "
                       + "you type and what you dictate. Review or delete them in Diagnostics \u{2192} Saved logs.")
        } else if logsSaved {
            out.append("Debug logging is off, but logs saved earlier are still on this Mac. Review or delete them in "
                       + "Diagnostics \u{2192} Saved logs.")
        }
        return out
    }
}
