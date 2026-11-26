import HunchCore

/// Picks inline vs card. Preference wins; otherwise inline needs a trustworthy caret and end-of-line.
/// Mirror is never automatic: only a `.mirror` preference with every precondition met gets it, and
/// any failed precondition falls back to the card (an inline ghost is what that app opted out of).
public struct DefaultGhostModeChooser: GhostModeChoosing {
    public init() {}
    /// Without the field's selection and marked-text state a mirror can't be shown safely, so a
    /// `.mirror` preference gets the card here.
    public func mode(for geometry: CaretGeometry, caretAtLineEnd: Bool, preference: OverlayPreference) -> GhostMode {
        guard preference != .mirror else { return .card }
        return mode(for: geometry, caretAtLineEnd: caretAtLineEnd, preference: preference,
                    hasSelection: false, hasMarkedText: false)
    }

    public func mode(for geometry: CaretGeometry, caretAtLineEnd: Bool, preference: OverlayPreference,
                     hasSelection: Bool, hasMarkedText: Bool) -> GhostMode {
        switch preference {
        case .inline: return .inline
        case .card: return .card
        case .automatic:
            return (geometry.quality >= .derived && caretAtLineEnd) ? .inline : .card
        case .mirror:
            return Self.canMirror(geometry, caretAtLineEnd: caretAtLineEnd, hasSelection: hasSelection,
                                  hasMarkedText: hasMarkedText) ? .mirror : .card
        }
    }

    /// The mirror redraws the line from its first character to the caret, so it needs the exact
    /// caret, the line's start, nothing after the caret, and nothing the host draws specially.
    static func canMirror(_ geometry: CaretGeometry, caretAtLineEnd: Bool, hasSelection: Bool,
                          hasMarkedText: Bool) -> Bool {
        geometry.quality >= .exact && caretAtLineEnd && !hasSelection && !hasMarkedText
            && geometry.lineStartX != nil
    }
}
