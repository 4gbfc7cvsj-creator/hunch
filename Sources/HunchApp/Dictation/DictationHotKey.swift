import Carbon.HIToolbox
import Foundation
import HunchCore

/// A system-wide hotkey through Carbon's `RegisterEventHotKey`: it reports both the press and the
/// release (which tap-or-hold needs), and the key never reaches the frontmost app, so ⌘⇧` doesn't
/// also cycle that app's windows. Used for the dictation shortcut, and for Escape while dictating.
@MainActor
final class DictationHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private(set) var chord: KeyChord?

    private static var handlerInstalled = false
    private static var byID: [UInt32: DictationHotKey] = [:]
    private static var nextID: UInt32 = 1

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void = {}) {
        id = Self.nextID
        Self.nextID += 1
        self.onPress = onPress
        self.onRelease = onRelease
        Self.installHandler()
    }

    /// Registers `chord` (unregistering the old one); nil unregisters. False when the system refused
    /// it (another app or the system holds the same keys).
    @discardableResult
    func register(_ chord: KeyChord?) -> Bool {
        if chord == self.chord, chord == nil || ref != nil { return true }
        unregister()
        self.chord = chord
        guard let chord else { return true }
        let hotKeyID = EventHotKeyID(signature: OSType(0x484E_4454), id: id)  // "HNDT"
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(chord.keyCode), Self.carbonModifiers(chord.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            self.chord = nil
            return false
        }
        ref = newRef
        Self.byID[id] = self
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        chord = nil
        Self.byID[id] = nil
    }

    /// CGEventFlags bits (as `KeyChord` stores them) to Carbon's modifier bits.
    static func carbonModifiers(_ flags: UInt64) -> UInt32 {
        var out: UInt32 = 0
        if flags & 0x100000 != 0 { out |= UInt32(cmdKey) }
        if flags & 0x20000 != 0 { out |= UInt32(shiftKey) }
        if flags & 0x80000 != 0 { out |= UInt32(optionKey) }
        if flags & 0x40000 != 0 { out |= UInt32(controlKey) }
        return out
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard got == noErr else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            // Carbon calls this on the main thread.
            MainActor.assumeIsolated {
                guard let key = DictationHotKey.byID[id] else { return }
                pressed ? key.onPress() : key.onRelease()
            }
            return noErr
        }, types.count, &types, nil, nil)
    }
}
