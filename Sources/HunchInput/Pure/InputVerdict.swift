import HunchCore

/// Global shortcuts that are not acceptance (design §13).
/// Interim HunchInput-local type until TypingEvent gains matching cases.
public enum GlobalShortcut: Sendable, Equatable {
    case forceActivate
    case toggleCurrentApp
    case toggleGlobal
    /// Turn the instruction at the caret (or the selection) into a draft, or polish it.
    case writeForMe
    /// Autocorrect catch-up: apply the newest fix typed past. Consumed only while one is waiting.
    case catchUp
    /// Autocorrect: put back what was typed for the newest fix still in the field (again: the one
    /// before). Consumed only while such a fix is waiting.
    case revertFix
}

/// Signals that TypingEvent cannot express yet. Delivered through `KeyboardMonitor.commands()`.
public enum InputCommand: Sendable, Equatable {
    /// Escape was consumed while a ghost was visible. The coordinator hides the ghost and, for
    /// `EscapeBehavior.dismissAndPauseBriefly`, pauses briefly.
    case escapeDismissed
    case shortcut(GlobalShortcut)
    /// Next/previous-alternative chord consumed while a ghost was visible.
    case cycleAlternative(forward: Bool)
    /// Style-down (`up: false`) or style-up chord consumed while a ghost was visible.
    case switchStyle(forward: Bool)
    /// Backspace straight after an automatic spelling fix was consumed: restore the original word.
    case undoAutoFix
    /// A key the suggested-replies bubble took (Tab, Return, Escape).
    case reply(ReplyKey)
}

/// Richer decision than `TapVerdict`; the monitor maps it to consume/pass plus emitted events.
public enum InputVerdict: Sendable, Equatable {
    case accept(AcceptAction)
    case dismiss
    case shortcut(GlobalShortcut)
    case cycleAlternative(forward: Bool)
    case switchStyle(forward: Bool)
    case passThrough

    public var consumes: Bool { self != .passThrough }

    public var tapVerdict: TapVerdict {
        if case .accept(let action) = self { return .consume(action) }
        return .passThrough
    }
}

/// The pure decision table behind `DefaultAcceptanceArbiter`.
public enum ArbiterRules {
    /// Acceptance and Escape need a fresh snapshot with a visible ghost. Global shortcuts are
    /// recognized regardless of ghost state. Anything unrecognized passes through (fail open).
    ///
    /// The accept chords are the app's own keys (`snapshot.wordKey`, `fullKey`) or, by default, the
    /// Shortcuts bindings. With Tab not allowed (`snapshot.tabAllowed`: an input method is
    /// composing, or a shell prompt), only the unmodified Tab key passes to the app; a binding on
    /// Tab with modifiers, such as the default full-accept chord Option+Tab, keeps accepting.
    public static func decide(chord: KeyChord, snapshot: ArbiterSnapshot?, bindings: AcceptBindings,
                              now: UInt64, maxAgeTicks: UInt64) -> InputVerdict {
        let ghostLive: Bool = {
            guard let snapshot, snapshot.hasGhost else { return false }
            // A hold (no visible ghost, next suggestion pending) is owned for two thirds of the window.
            let maxAge = snapshot.holdOnly ? maxAgeTicks / 3 * 2 : maxAgeTicks
            return Freshness.isFresh(publishedAt: snapshot.publishedAt, now: now, maxAgeTicks: maxAge)
        }()

        if ghostLive, let snapshot {
            let acceptable: (KeyChord?) -> Bool = { binding in
                guard let binding, ChordMatcher.matches(chord, binding) else { return false }
                return snapshot.tabAllowed || !ChordMatcher.isPlainTab(binding)
            }
            if snapshot.shellKeys {
                if ChordMatcher.matches(chord, .rightArrow) { return .accept(.word) }
                if ChordMatcher.matches(chord, .optionRight) { return .accept(.full) }
            }
            if acceptable(snapshot.wordKey.resolved(bindings.word)) { return .accept(.word) }
            if acceptable(snapshot.fullKey.resolved(bindings.full)) { return .accept(.full) }
            if !snapshot.holdOnly {
                if ChordMatcher.matches(chord, .escape) { return .dismiss }
                // Style keys before alternatives: a user may bind both to the same chord.
                if snapshot.styleNextAvailable, ChordMatcher.matches(chord, bindings.styleNext) { return .switchStyle(forward: true) }
                if snapshot.stylePreviousAvailable, ChordMatcher.matches(chord, bindings.stylePrevious) { return .switchStyle(forward: false) }
                if snapshot.alternativesAvailable {
                    if ChordMatcher.matches(chord, bindings.nextAlternative) { return .cycleAlternative(forward: true) }
                    if ChordMatcher.matches(chord, bindings.previousAlternative) { return .cycleAlternative(forward: false) }
                }
            }
        }
        if let shortcut = shortcut(for: chord, bindings: bindings) { return .shortcut(shortcut) }
        return .passThrough
    }

    public static func shortcut(for chord: KeyChord, bindings: AcceptBindings) -> GlobalShortcut? {
        if ChordMatcher.matches(chord, bindings.forceActivate) { return .forceActivate }
        if ChordMatcher.matches(chord, bindings.toggleCurrentApp) { return .toggleCurrentApp }
        if ChordMatcher.matches(chord, bindings.toggleGlobal) { return .toggleGlobal }
        if ChordMatcher.matches(chord, bindings.writeForMe) { return .writeForMe }
        if ChordMatcher.matches(chord, bindings.catchUp) { return .catchUp }
        if ChordMatcher.matches(chord, bindings.revertFix) { return .revertFix }
        return nil
    }
}

/// What the consuming tap does, given whether the coordinator says a ghost is visible and
/// whether focus is in an editable text field Hunch is tracking.
public enum TapRules {
    /// The consuming tap runs while a ghost is visible, while editable focus exists and any
    /// global shortcut is bound, or whenever toggle-global is bound (a deliberate binding that
    /// works regardless of focus). Otherwise system-wide chords such as Control+Tab are never held.
    public static func tapShouldRun(ghostVisible: Bool, editableFocus: Bool, bindings: AcceptBindings) -> Bool {
        ghostVisible
            || (editableFocus && hasGlobalShortcuts(bindings))
            || bindings.toggleGlobal != nil
    }

    public static func hasGlobalShortcuts(_ bindings: AcceptBindings) -> Bool {
        !globalShortcutChords(bindings).isEmpty
    }

    public static func globalShortcutChords(_ bindings: AcceptBindings) -> [KeyChord] {
        [bindings.forceActivate, bindings.toggleCurrentApp, bindings.toggleGlobal, bindings.writeForMe,
         bindings.catchUp, bindings.revertFix].compactMap { $0 }
    }

    /// Whether a recognized shortcut with no ghost visible is consumed: only with editable
    /// focus, except toggle-global which is focus independent.
    public static func shortcutConsumed(_ shortcut: GlobalShortcut, editableFocus: Bool,
                                        catchUpWaiting: Bool = false, revertWaiting: Bool = false) -> Bool {
        if shortcut == .catchUp { return editableFocus && catchUpWaiting }
        if shortcut == .revertFix { return editableFocus && revertWaiting }
        return shortcut == .toggleGlobal || editableFocus
    }

    /// Catch-up's key is the app's own unless a missed fix is waiting; the revert key unless a fix
    /// that can be put back is.
    public static func gate(_ verdict: InputVerdict, catchUpWaiting: Bool, revertWaiting: Bool = false) -> InputVerdict {
        if verdict == .shortcut(.catchUp), !catchUpWaiting { return .passThrough }
        if verdict == .shortcut(.revertFix), !revertWaiting { return .passThrough }
        return verdict
    }

    /// Without a visible ghost only exact global-shortcut matches are consumed (and only per
    /// `shortcutConsumed`); Tab, Option+Tab and Escape keep their ghost-gated behavior.
    public static func decide(ghostVisible: Bool, editableFocus: Bool, chord: KeyChord, snapshot: ArbiterSnapshot?,
                              bindings: AcceptBindings, now: UInt64, maxAgeTicks: UInt64,
                              catchUpWaiting: Bool = false, revertWaiting: Bool = false) -> InputVerdict {
        guard ghostVisible else {
            guard let shortcut = ArbiterRules.shortcut(for: chord, bindings: bindings),
                  shortcutConsumed(shortcut, editableFocus: editableFocus, catchUpWaiting: catchUpWaiting,
                                   revertWaiting: revertWaiting)
            else { return .passThrough }
            return .shortcut(shortcut)
        }
        return gate(ArbiterRules.decide(chord: chord, snapshot: snapshot, bindings: bindings, now: now,
                                        maxAgeTicks: maxAgeTicks), catchUpWaiting: catchUpWaiting,
                    revertWaiting: revertWaiting)
    }
}

/// A key the suggested-replies bubble takes while it shows (`KeyboardMonitor.setReplyKeys`).
public enum ReplyKey: Sendable, Equatable {
    /// Tab: highlight the next reply.
    case next
    /// Return with a reply highlighted: insert it (nothing is sent).
    case insert
    /// Escape: close the bubble.
    case dismiss
    /// An arrow key along the bubble's layout once a reply is highlighted: the next (down, right) or
    /// previous (up, left) reply, stopping at the ends.
    case step(forward: Bool)
}

/// The arrow keys the bubble takes once a reply is highlighted, along how its replies are laid out:
/// up/down for replies stacked top to bottom, left/right for replies side by side, both when they
/// wrap over several lines.
public struct ReplyArrows: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let vertical = ReplyArrows(rawValue: 1)
    public static let horizontal = ReplyArrows(rawValue: 2)
}

/// What the bubble's keys do. Only plain Tab, Return (or keypad Enter), Escape and the arrows along
/// `arrows` count; Return and the arrows only once Tab has highlighted a reply, so before that they
/// reach the app as usual. Anything else passes through (and closes the bubble as typing).
public enum ReplyKeyRules {
    public static let returnKeyCode: UInt16 = 36
    public static let enterKeyCode: UInt16 = 76
    public static let leftKeyCode: UInt16 = 123
    public static let rightKeyCode: UInt16 = 124
    public static let downKeyCode: UInt16 = 125
    public static let upKeyCode: UInt16 = 126

    public static func decide(_ chord: KeyChord, shown: Bool, highlighted: Bool,
                              arrows: ReplyArrows = []) -> ReplyKey? {
        guard shown, ChordMatcher.mask(chord.modifiers) == 0 else { return nil }
        switch chord.keyCode {
        case ChordMatcher.tabKeyCode: return .next
        case ChordMatcher.escapeKeyCode: return .dismiss
        case returnKeyCode, enterKeyCode: return highlighted ? .insert : nil
        case upKeyCode, downKeyCode:
            return highlighted && arrows.contains(.vertical) ? .step(forward: chord.keyCode == downKeyCode) : nil
        case leftKeyCode, rightKeyCode:
            return highlighted && arrows.contains(.horizontal) ? .step(forward: chord.keyCode == rightKeyCode) : nil
        default: return nil
        }
    }
}
