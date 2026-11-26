import Carbon
import Foundation
import HunchCore
import HunchSession

/// What kind of input source is selected: a plain layout, or an input method that buffers its
/// composition (Zhuyin, Kotoeri) or commits as it goes (Pinyin, Cangjie, Korean). Read on the main
/// thread; refreshed when the selected source changes.
@MainActor
final class InputMethodState {
    static let shared = InputMethodState()

    private(set) var kind = InputMethodKind.plainLayout
    /// The selected input source's main language ("en", "zh-Hant"), nil when it names none.
    private(set) var language: String?
    private var observer: NSObjectProtocol?

    /// The preferred languages a prompt should name: those the selected keyboard types.
    var promptLanguages: [String] {
        InputLanguage.promptLanguages(inputSource: language, preferred: Locale.preferredLanguages)
    }

    func start() {
        refresh()
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    func refresh() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            kind = .plainLayout
            language = nil
            return
        }
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            language = (Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String])?.first
        } else {
            language = nil
        }
        kind = InputMethodKind.classify(id: Self.string(source, kTISPropertyInputSourceID),
                                        type: Self.string(source, kTISPropertyInputSourceType))
    }

    /// Makes the input method finalize its composition without sending the app a key: selects the
    /// plain keyboard layout for a moment, then switches back (macOS input methods commit their
    /// composing text when deselected). False when the switch didn't happen; the original source
    /// is restored in every case where it was changed.
    func commitCompositionBySwitching() async -> Bool {
        guard let original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let plain = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              TISSelectInputSource(plain) == noErr else { return false }
        try? await Task.sleep(for: .milliseconds(30))
        if TISSelectInputSource(original) != noErr {
            try? await Task.sleep(for: .milliseconds(30))
            _ = TISSelectInputSource(original)
        }
        refresh()
        return true
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
