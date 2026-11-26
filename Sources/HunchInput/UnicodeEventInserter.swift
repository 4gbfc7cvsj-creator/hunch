import AppKit
import Carbon.HIToolbox
import CoreGraphics
import HunchCore

@MainActor
public protocol KeyEventPosting: AnyObject {
    /// Posts one keyDown/keyUp pair carrying `units` as its Unicode string.
    func postUnicode(_ units: [UInt16]) -> Bool
    /// Posts Cmd+V, or Option+Shift+Cmd+V when `matchStyle`.
    func postPaste(matchStyle: Bool) -> Bool
    /// Posts one Backspace (delete backward) press.
    func postDeleteBackward() -> Bool
    /// Posts one press (down+up) of a virtual key with no modifiers or characters.
    func postKey(keyCode: UInt16) -> Bool
}

public extension KeyEventPosting {
    func postKey(keyCode: UInt16) -> Bool { false }
    /// One press of a virtual key with these modifier flags (Shift+Left to select). Posters that
    /// can't add flags refuse anything but a plain press.
    func postKey(keyCode: UInt16, flags: CGEventFlags) -> Bool { flags.isEmpty ? postKey(keyCode: keyCode) : false }
}

/// Posts synthetic key events from a private event source, tagged with `EventMarker`.
///
/// Events go to the session event tap location: after hardware-level remappers and HID taps (so
/// a key remapper can't rewrite our synthesized V or text), yet through normal key-focus routing.
/// A private source state plus explicit flags keeps a still-held Option (from Option+Tab) from
/// leaking into the inserted characters or turning Cmd+V into Option+Cmd+V.
@MainActor
public final class CGKeyEventPoster: KeyEventPosting {
    private let source: CGEventSource?

    public init() {
        source = CGEventSource(stateID: .privateState)
        source?.userData = EventMarker.userData
    }

    public func postUnicode(_ units: [UInt16]) -> Bool {
        guard !units.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        post(down, flags: [])
        post(up, flags: [])
        return true
    }

    public func postPaste(matchStyle: Bool) -> Bool {
        let keyV = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else { return false }
        let flags: CGEventFlags = matchStyle ? [.maskCommand, .maskAlternate, .maskShift] : [.maskCommand]
        post(down, flags: flags)
        post(up, flags: flags)
        return true
    }

    public func postDeleteBackward() -> Bool {
        let key = CGKeyCode(kVK_Delete)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        post(down, flags: [])
        post(up, flags: [])
        return true
    }

    public func postKey(keyCode: UInt16) -> Bool { postKey(keyCode: keyCode, flags: []) }

    public func postKey(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        else { return false }
        post(down, flags: flags)
        post(up, flags: flags)
        return true
    }

    private func post(_ event: CGEvent, flags: CGEventFlags) {
        event.flags = flags
        EventMarker.tag(event)
        event.post(tap: .cgSessionEventTap)
    }
}

/// Live checks re-run before and during insertion (secure-field gate + focus guard).
public struct InsertionEnvironment: Sendable {
    public var secureInputEnabled: @MainActor @Sendable () -> Bool
    public var frontmostPID: @MainActor @Sendable () -> pid_t?

    public init(secureInputEnabled: @escaping @MainActor @Sendable () -> Bool,
                frontmostPID: @escaping @MainActor @Sendable () -> pid_t?) {
        self.secureInputEnabled = secureInputEnabled
        self.frontmostPID = frontmostPID
    }

    public static let live = InsertionEnvironment(
        secureInputEnabled: { IsSecureEventInputEnabled() },
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
}

/// Inserts accepted text by Unicode keyboard events (default) or a guarded clipboard paste.
/// Never logs the text.
@MainActor
public final class UnicodeEventInserter: TextInserting {
    private let poster: any KeyEventPosting
    private let clipboard: ClipboardSwap
    private let environment: InsertionEnvironment
    private let interChunkDelay: Duration
    private let pasteRestoreDelay: Duration

    public init(poster: (any KeyEventPosting)? = nil, pasteboard: (any PasteboardAccess)? = nil,
                environment: InsertionEnvironment = .live,
                interChunkDelay: Duration = .milliseconds(2), pasteRestoreDelay: Duration = .milliseconds(300)) {
        self.poster = poster ?? CGKeyEventPoster()
        self.clipboard = ClipboardSwap(board: pasteboard ?? SystemPasteboard())
        self.environment = environment
        self.interChunkDelay = interChunkDelay
        self.pasteRestoreDelay = pasteRestoreDelay
    }

    public func insert(_ text: String, into app: AppIdentity, mode: InsertionMode, chunkSize: Int) async -> InsertionOutcome {
        await insert(text, into: app, mode: mode, chunkSize: chunkSize, workarounds: InsertionWorkarounds())
    }

    public func insert(_ text: String, into app: AppIdentity, mode: InsertionMode, chunkSize: Int,
                       workarounds: InsertionWorkarounds) async -> InsertionOutcome {
        await insert(text, into: app, mode: mode, chunkSize: chunkSize, workarounds: workarounds, holdClipboard: false)
    }

    public func insertHoldingClipboard(_ text: String, into app: AppIdentity, mode: InsertionMode, chunkSize: Int,
                                       workarounds: InsertionWorkarounds) async -> InsertionOutcome {
        await insert(text, into: app, mode: mode, chunkSize: chunkSize, workarounds: workarounds, holdClipboard: true)
    }

    public func releaseClipboard(restore: Bool) {
        if restore { clipboard.restoreNow() } else { clipboard.keepStaged() }
    }

    private func insert(_ text: String, into app: AppIdentity, mode: InsertionMode, chunkSize: Int,
                        workarounds: InsertionWorkarounds, holdClipboard: Bool) async -> InsertionOutcome {
        guard !text.isEmpty else { return .inserted }
        if let reason = blockReason(for: app) { return .failed(reason) }

        switch mode {
        case .unicodeEvents:
            let runs = InsertionTextTransform.runs(text, workarounds: workarounds, chunkSize: chunkSize)
            let typed = await type(runs, app: app)
            if typed.posted == runs.count { return .inserted }
            if let reason = typed.abortReason { return .failed(reason) }
            // Posting failed part-way: paste what's left.
            let rest = InsertionTextTransform.text(of: runs[typed.posted...])
            return paste(rest, matchStyle: false, hold: holdClipboard) ? .fellBack(.paste) : .failed("could not post key events")
        case .paste, .pasteMatchStyle:
            if paste(text, matchStyle: mode == .pasteMatchStyle, hold: holdClipboard) {
                // Some hosts add a stray character or newline after a paste; take it back.
                if workarounds.backspaceAfterPaste, blockReason(for: app) == nil { _ = poster.postDeleteBackward() }
                return .inserted
            }
            let runs = InsertionTextTransform.runs(text, workarounds: workarounds, chunkSize: chunkSize)
            let typed = await type(runs, app: app)
            if typed.posted == runs.count { return .fellBack(.unicodeEvents) }
            return .failed(typed.abortReason ?? "could not paste or post key events")
        }
    }

    public func replace(deletingBackward count: Int, with text: String, into app: AppIdentity, mode: InsertionMode,
                        chunkSize: Int) async -> InsertionOutcome {
        await replace(deletingBackward: count, with: text, into: app, mode: mode, chunkSize: chunkSize,
                      workarounds: InsertionWorkarounds())
    }

    public func replace(deletingBackward count: Int, with text: String, into app: AppIdentity, mode: InsertionMode,
                        chunkSize: Int, workarounds: InsertionWorkarounds) async -> InsertionOutcome {
        // Re-check before every Backspace, then insert right away (no pause), so focus or Secure
        // Input can't change between deleting the trigger and typing its replacement.
        for _ in 0..<max(0, count) {
            if let reason = blockReason(for: app) { return .failed(reason) }
            guard poster.postDeleteBackward() else { return .failed("could not post Backspace") }
        }
        return await insert(text, into: app, mode: mode, chunkSize: chunkSize, workarounds: workarounds)
    }

    public func pressKey(_ keyCode: UInt16, into app: AppIdentity) -> Bool {
        guard blockReason(for: app) == nil else { return false }
        return poster.postKey(keyCode: keyCode)
    }

    /// One press of `keyCode`, with Shift held when `shift` (arrow-key selection). Same checks as
    /// `pressKey`.
    public func pressKey(_ keyCode: UInt16, shift: Bool, into app: AppIdentity) -> Bool {
        guard blockReason(for: app) == nil else { return false }
        return poster.postKey(keyCode: keyCode, flags: shift ? .maskShift : [])
    }

    private func blockReason(for app: AppIdentity) -> String? {
        if environment.secureInputEnabled() { return "secure input is on" }
        if environment.frontmostPID() != app.pid { return "target app is no longer frontmost" }
        return nil
    }

    private func type(_ runs: [InsertionTextTransform.Run], app: AppIdentity) async -> (posted: Int, abortReason: String?) {
        var posted = 0
        for run in runs {
            if posted > 0 {
                try? await Task.sleep(for: interChunkDelay)
                // Focus or secure state may change between chunks; stop rather than type elsewhere.
                if let reason = blockReason(for: app) { return (posted, reason) }
            }
            let ok: Bool
            switch run {
            case .unicode(let units): ok = poster.postUnicode(units)
            case .key(let keyCode): ok = poster.postKey(keyCode: keyCode)
            }
            guard ok else { return (posted, nil) }
            posted += 1
        }
        return (posted, nil)
    }

    /// Puts the user's clipboard back now if a paste restore is still pending (quit path). Guarded
    /// by the same changeCount check as the delayed restore.
    public func restorePendingClipboard() { clipboard.restoreNow() }

    /// `hold`: no timed restore; the caller ends it with `releaseClipboard(restore:)`.
    private func paste(_ text: String, matchStyle: Bool, hold: Bool = false) -> Bool {
        guard clipboard.stage(text) else { return false }
        guard poster.postPaste(matchStyle: matchStyle) else {
            clipboard.restoreNow()
            return false
        }
        if !hold { clipboard.scheduleRestore(after: pasteRestoreDelay) }
        return true
    }
}
