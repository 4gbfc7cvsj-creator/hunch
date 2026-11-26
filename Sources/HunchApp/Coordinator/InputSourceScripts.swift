import Carbon
import Foundation
import HunchCore
import HunchText
import os

/// Writing systems the user can type, from the enabled keyboard input sources. TIS is read on the main
/// thread only; requests read the cached value. Refreshed when the enabled sources change and every 60 s.
@MainActor
final class InputSourceScripts {
    static let shared = InputSourceScripts()

    private(set) var allowed: Set<String> = [ScriptGuard.Script.latin.rawValue]
    private(set) var preferredHan: HanVariant?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    /// Starts observing and reads once; logs the result when `debug` is on.
    func start(debug: Bool) {
        refresh()
        if debug {
            Logger(subsystem: "app.hunch", category: "scripts")
                .debug("keyboard scripts: \(self.allowed.sorted().joined(separator: ","), privacy: .public)")
        }
        guard timer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        var languages: [String] = []
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        if let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] {
            for source in list {
                guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { continue }
                let array = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
                languages.append(contentsOf: array)
            }
        }
        var scripts = ScriptGuard.scripts(forLanguages: languages)
        scripts.insert(ScriptGuard.Script.latin.rawValue)
        allowed = scripts
        preferredHan = HanPreference.variant(forLanguages: languages)
    }
}
