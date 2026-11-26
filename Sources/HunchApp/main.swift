import AppKit
import HunchCore

// Composition root. M1 skeleton: a menu-bar agent that reports permission status.
// The SuggestionCoordinator is wired in M1 step 12 (design §10).

// Before anything opens a file: carry the user's data over from the app's old name.
RenameMigration.runAtLaunch()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
EditMenu.install()
AutocorrectPageSnapshot.writeIfRequested()
app.run()
