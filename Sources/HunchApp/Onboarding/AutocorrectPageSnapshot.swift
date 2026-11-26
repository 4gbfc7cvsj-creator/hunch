import AppKit
import HunchCore
import HunchSettingsStore
import SwiftUI

/// Opt-in, for looking at the Autocorrect page without the app running: with
/// `GT_SNAPSHOT_AUTOCORRECT_PAGE=<folder>` set, the app writes the page as PNGs (a few toggle
/// states, light and dark, in the tour's page area), then the Quick replies page in each layout and a
/// few other pages, and exits.
@MainActor
enum AutocorrectPageSnapshot {
    static func writeIfRequested() {
        guard let folder = ProcessInfo.processInfo.environment["GT_SNAPSHOT_AUTOCORRECT_PAGE"] else { return }
        let dir = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let states: [(String, @Sendable (inout HunchSettings) -> Void, Int, Int)] = [
            ("all-on", { _ in }, 1, 8),
            ("before-landing", { _ in }, 1, 7),
            ("auto-off-landing", { $0.autocorrectFixAutomatically = false }, 1, 8),
            ("auto-off", { $0.autocorrectFixAutomatically = false }, 1, 5),
            ("shorthand-off", { $0.autocorrectLeaveChatShorthand = false }, 0, 5),
            ("suggest-off", { $0.autocorrectEnabled = false }, 1, 9),
        ]
        for (name, change, sentence, words) in states {
            let file = dir.appendingPathComponent("settings-\(name).json")
            try? FileManager.default.removeItem(at: file)
            let store = JSONSettingsStore(fileURL: file)
            try? store.update {
                $0.autocorrectEnabled = true
                $0.autocorrectFixAutomatically = true
                $0.autocorrectCapitalization = true
                $0.fixPunctuation = true
                $0.autocorrectFixConfusedWords = true
                $0.autocorrectLeaveChatShorthand = true
                change(&$0)
            }
            let model = SettingsModel(store: store)
            for dark in [false, true] {
                render(AutocorrectPage(settings: model, frozen: (sentence, words)),
                       to: dir.appendingPathComponent("autocorrect-\(name)-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }
        writeQuickRepliesPage(to: dir)
        writeOtherPages(to: dir)
        exit(0)
    }

    /// The Quick replies page: each layout with the replies up (none and the second highlighted) and
    /// after Return, and Quick replies off.
    private static func writeQuickRepliesPage(to dir: URL) {
        typealias Phase = QuickRepliesDemo.Phase
        var states: [(String, Bool, SuggestedRepliesLayout, Int, Phase)] = []
        for layout in SuggestedRepliesLayout.allCases {
            states += [("\(layout.rawValue)-shown", true, layout, 0, .replies(highlighted: nil)),
                       ("\(layout.rawValue)-tab", true, layout, 1, .replies(highlighted: 1)),
                       ("\(layout.rawValue)-inserted", true, layout, 1, .inserted)]
        }
        states.append(("off", false, .verticalStack, 0, .message))
        // The longest reason Quick replies can't run, to check that the note fits under the switches.
        states.append(("blocked", true, .verticalStack, 0, .replies(highlighted: nil)))
        for (name, on, layout, conversation, phase) in states {
            SuggestedRepliesStatus.shared.blockedReason = name == "blocked"
                ? "Needs an instruct model: the Language Model is a base model. Turn on a separate writing model in "
                    + "Settings → Models." : nil
            let file = dir.appendingPathComponent("settings-quickreplies-\(name).json")
            try? FileManager.default.removeItem(at: file)
            let store = JSONSettingsStore(fileURL: file)
            try? store.update {
                $0.suggestedRepliesEnabled = on
                $0.suggestedRepliesLayout = layout
            }
            let model = SettingsModel(store: store)
            for dark in [false, true] {
                render(QuickRepliesPage(settings: model, frozen: (conversation, phase)),
                       to: dir.appendingPathComponent("quickreplies-\(name)-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }
        SuggestedRepliesStatus.shared.blockedReason = nil
    }

    /// The pages whose header text was shortened, for a look at the layout.
    private static func writeOtherPages(to dir: URL) {
        let file = dir.appendingPathComponent("settings-others.json")
        try? FileManager.default.removeItem(at: file)
        let store = JSONSettingsStore(fileURL: file)
        let settings = SettingsModel(store: store)
        let onboarding = OnboardingModel(permissions: PermissionsModel(), models: ModelsPaneModel(), settings: settings)
        settings.set(\.suggestedRepliesEnabled, to: true)
        SuggestedRepliesStatus.shared.blockedReason = "Needs an instruct model: the Language Model is a base model. "
            + "Turn on a separate writing model in Settings → Models."
        for step in [OnboardingFlow.Step.quickReplies, .autocorrect] {
            onboarding.step = step
            for dark in [false, true] {
                render(OnboardingView(model: onboarding), to: dir.appendingPathComponent(
                    "window-\(step)-\(dark ? "dark" : "light").png"), dark: dark, whole: true)
            }
        }
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            render(SuggestionsPage(model: onboarding), to: dir.appendingPathComponent("suggestions-\(tag).png"), dark: dark)
            render(WriteForMePage(settings: settings), to: dir.appendingPathComponent("writeforme-\(tag).png"), dark: dark)
            render(AppearancePage(settings: settings), to: dir.appendingPathComponent("appearance-\(tag).png"), dark: dark)
            render(IntroVideoPage(), to: dir.appendingPathComponent("intro-\(tag).png"), dark: dark)
        }
    }

    /// `whole`: `view` is the whole tour window, drawn as is; else a page, padded like the tour pads it.
    private static func render<V: View>(_ view: V, to url: URL, dark: Bool, whole: Bool = false) {
        let size = whole ? OnboardingView.size
            : CGSize(width: OnboardingView.size.width, height: OnboardingView.size.height - 110)
        let page = view
            .padding(.horizontal, whole ? 0 : 48)
            .padding(.bottom, whole ? 0 : 30)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: page)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
