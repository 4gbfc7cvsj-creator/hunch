import CoreGraphics
import Foundation
import HunchCore
import HunchFocus
import HunchOverlay
import HunchHistory
import HunchText

/// Autocorrect beyond the fix shown for the word just typed (design §13):
/// - **Catch-up**: fixes that were shown and typed past wait in a short list (`MissedFixTracker`);
///   the catch-up shortcut fixes the newest one in place and leaves the caret where it was.
/// - **Fix automatically**: every finished word is looked at once (`UnsettledSpan`), also when no
///   read came right after it (fast typing, or while another fix went in); a misspelled one is fixed
///   at once, behind the caret if the user typed on. Backspace straight after restores it and counts
///   keeps the word in that field (`AutoFixUndo`). A clean rejection (undo or delete the fix and
///   keep the word, `FixRejectionWatch`) is learned: two and the word is never fixed again.
/// - **Ambiguous words** (Fix automatically): a word the system can only guess at ("fo") waits for
///   the next word; then the suggestion model scores the word as typed and each candidate with that
///   next word, and the clear winner replaces it. A close call goes to catch-up instead; the word as
///   typed winning, nothing happens.
/// - **Undo a fix later**: every fix made in the field (Tab, catch-up, automatic; every kind) is
///   kept until focus leaves it (`FixHistory`). The revert shortcut puts back what was typed for the
///   newest one, again for the one before; a faint line under each fixed word offers the same on a
///   click (`FixUnderlinePresenter`). Found again by its text; anything changed around it, nothing
///   happens.
///
/// Automatic fixes delete back to the word and type the fix and the rest again (`SpanFix`). A
/// catch-up fix is made by selecting the word, through Accessibility where the host takes it, else
/// with Left/Shift+Left, then typing the fix over the selection and putting the caret back.
/// Every change Hunch makes is announced once (`editApplied`) to what follows the field's text.
/// Every step that would change text is preceded by a check that the field holds exactly the text
/// expected; anything else does nothing. The user's key presses are held while text changes and
/// replayed afterwards. The decisions live in HunchText; this class only wires them to the host.
@MainActor
final class AutocorrectFollowUp {
    /// Why a checked Accessibility step did not happen.
    enum AXStepFailure: Error, Sendable, Equatable {
        /// The field holds other text than expected: do nothing.
        case textDiffers
        /// The host refused or ignored the selection (Electron, web areas): try the arrow keys.
        case refused
        /// Focus moved or a gate blocked.
        case gone
    }

    /// Host access, from the app delegate (focus tracker, keyboard monitor, inserter, overlay).
    struct Hooks {
        var setCatchUpWaiting: (Bool) -> Void = { _ in }
        var armBackspaceUndo: (Bool) -> Void = { _ in }
        var holdKeys: () -> Void = {}
        var releaseHeldKeys: () -> Void = {}
        var isHoldingKeys: () -> Bool = { false }
        /// One direct read of the field (also when nothing changed since the last emitted one).
        var readNow: (FieldID) async -> TextContext? = { _ in nil }
        /// Checks `span` ends at the caret and selects its start `word`; the caret's UTF-16 offset.
        var selectBehindCaret: (FieldID, _ span: String, _ word: String) async -> Result<Int, AXStepFailure> = { _, _, _ in
            .failure(.refused)
        }
        /// Collapses the caret at an offset, checking the text before it; highlight bounds on success.
        var placeCaret: (FieldID, _ location: Int, _ expectedBefore: String, _ highlightBack: Int,
                         _ highlightLength: Int) async -> Result<CGRect?, AXStepFailure> = { _, _, _, _, _ in
            .failure(.refused)
        }
        var boundsBehindCaret: (FieldID, _ back: Int, _ length: Int) async -> Result<CGRect, BehindCaret.BoundsMiss> = { _, _, _ in
            .failure(.noBounds)
        }
        /// One key press, with Shift when asked (arrow-key selection).
        var pressKey: (UInt16, _ shift: Bool, AppIdentity) -> Bool = { _, _, _ in false }
        var flash: (CGRect) -> Void = { _ in }
        /// Whether the revert shortcut has a fix to put back (the keyboard monitor consumes it only then).
        var setRevertWaiting: (Bool) -> Void = { _ in }
        /// The faint lines under fixed words that can still be put back (empty: none).
        var showFixMarks: ([FixMark]) -> Void = { _ in }
        /// Moves the collapsed caret forward over text the host holds, checking the text before it.
        var moveCaretForward: (FieldID, _ forward: Int, _ expectedBefore: String) async -> Bool = { _, _, _ in false }
        /// Bounds of `word`, which starts `textToCaret` before the caret (Chromium: through text
        /// markers, checked to read as that text).
        var wordBounds: (FieldID, _ textToCaret: String, _ word: String) async -> Result<CGRect, BehindCaret.BoundsMiss> = { _, _, _ in
            .failure(.noBounds)
        }
        /// Makes `app` the frontmost app again if it isn't (the menu under a fixed word had the
        /// keyboard); true once it is. Typing and key presses go only to the frontmost app.
        var ensureFrontmost: (AppIdentity) async -> Bool = { _ in true }
        /// A key reached the app: an open Revert offer closes (the marks stay).
        var dismissFixOffer: () -> Void = {}
    }

    private let hooks: Hooks
    private let inserter: any TextInserting
    private let learning: LearningController?
    private let settings: () -> HunchSettings

    private var missed = MissedFixTracker<FieldID>()
    /// Opt-in typing samples for the autocorrect eval (sees every read and every own edit).
    private lazy var samples = TypingSampleLog(isEnabled: { [settings] in settings().debugLogging })
    private var undo = AutoFixUndo<FieldID>()
    /// Tells a deliberate rejection of the latest automatic fix from backspacing to rephrase.
    private var rejections = FixRejectionWatch<FieldID>()
    /// The words not looked at yet, and an ambiguous word waiting for the next one.
    private var span = UnsettledSpan<FieldID>()
    /// Every fix made in the field the user is in, for putting one back later.
    private var history = FixHistory<FieldID>()
    /// The last delayed fix seen in the field, watched for a few seconds: logs when the field stops
    /// showing it other than by typing on (the host put the text back).
    private var watchedFix: (field: FieldID, before: String, at: ContinuousClock.Instant)?
    /// Work that changed the field is over: the coordinator handles the newest read it skipped
    /// meanwhile, if that read shows `expectedBefore` (nil: any read).
    var onFinished: ((_ expectedBefore: String?) -> Void)?
    /// A change to the field begins (keys held, reads skipped): the coordinator hides a visible
    /// ghost but keeps its accept keys, so a Tab pressed meanwhile isn't handed to the app.
    var onEditStarted: (() -> Void)?
    /// A fix is being applied: the coordinator ignores reads meanwhile (the caret is moved around).
    private(set) var busy = false
    /// How sure fix-as-you-type is of a fix of a typed word to a replacement (the field's finder,
    /// `CorrectionFinder.confidence`), recorded with each automatic fix for the Strong pass.
    var fixConfidence: ((String, String) -> FixConfidence)?
    private var lastWaiting = false

    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    /// How long to wait for the host to show a step (a selection, typed text).
    static let stepWait: Duration = .milliseconds(450)
    static let pollInterval: Duration = .milliseconds(15)

    init(hooks: Hooks, inserter: any TextInserting, learning: LearningController?,
         settings: @escaping () -> HunchSettings) {
        self.hooks = hooks
        self.inserter = inserter
        self.learning = learning
        self.settings = settings
    }

    private var catchUpOn: Bool { settings().bindings.catchUp != nil }
    private var revertKeyOn: Bool { settings().bindings.revertFix != nil }
    /// Needs the main Autocorrect switch too: an app that turns autocorrect on for itself while the
    /// main switch is off gets the struck-through fix and Tab, not automatic fixes.
    /// "Apply Corrections Automatically" here: on in general (with general autocorrect), and autocorrect and Fix
    /// automatically both on for this app or site.
    func fixesAutomatically(_ policy: AppPolicy) -> Bool {
        settings().autocorrectEnabled && settings().autocorrectFixAutomatically
            && policy.autocorrectEnabled && policy.fixAutomaticallyAllowed
    }

    // MARK: Coordinator events

    /// Before the learning controller sees a new field: entries of the old field leave now, so a
    /// pending skip is counted for the field it happened in.
    func preContext(_ context: TextContext) {
        samples.noteContext(context)
        guard !busy else { return }
        if let watched = rejections.watchedField, watched != context.field, let word = rejections.leave() {
            fixRejected(word, field: nil)  // left the field: the learning controller still has the old one
        }
        if missed.trackedField != nil, missed.trackedField != context.field { countSkips(missed.reset()) }
    }

    /// Every read the coordinator handles. `skipped`: the word the skip tracker counted as typed past.
    func noteContext(_ context: TextContext, skipped: String?) {
        guard !busy else { return }
        watchDelayedFix(context)
        if let word = rejections.update(field: context.field, before: context.before) {
            fixRejected(word, field: context.field)
        }
        if let kept = rejections.takeKept() { learning?.noteFixKept(word: kept.word, fix: kept.fix) }
        undo.update(field: context.field, before: context.before)
        if !undo.isArmed { disarmUndo() }
        let historyChanged = history.update(field: context.field, before: context.before, after: context.after)
        marksRead = (context.field, context.before, context.after, context.selectionLength)
        if historyChanged || !history.isEmpty || marksShown { refreshMarks(field: context.field) }
        publishRevertWaiting()
        countSkips(missed.update(field: context.field, before: context.before, skipped: skipped,
                                 deferSkips: catchUpOn))
        publishWaiting(field: context.field, before: context.before)
    }

    /// A fix is shown for the word just finished.
    func noteShown(_ context: TextContext, proposal: CorrectionProposal) {
        guard catchUpOn, Self.catchUpSurface(context.metadata.surface) else { return }
        missed.shown(field: context.field, before: context.before, word: proposal.misspelled,
                     replacement: proposal.replacement, trailingCount: proposal.trailing.count)
    }

    func noteEscaped() { missed.escaped() }
    func noteAccepted() { missed.accepted() }

    /// A key the taps let through reached the app: Backspace no longer undoes an automatic fix.
    func noteKeyDown() {
        undo.otherKey()
        hooks.dismissFixOffer()
        undoPublished = false  // the monitor ends it on any key by itself
    }

    private var undoPublished = false

    private func disarmUndo() {
        guard undoPublished else { return }
        undoPublished = false
        hooks.armBackspaceUndo(false)
    }

    /// Focus left the field, it was blocked, or secure input began: forget everything.
    func focusEnded() {
        samples.focusEnded()
        if let word = rejections.leave() { fixRejected(word, field: nil) }
        choice?.task.cancel()
        choice = nil
        span.reset()
        countSkips(missed.reset())
        undo.reset()
        history.reset()
        rewriteChecked = nil
        lastPass = nil
        clearMarks()
        publishRevertWaiting()
        undoPublished = true
        disarmUndo()
        lastWaiting = false
        hooks.setCatchUpWaiting(false)
    }

    // MARK: Catch-up

    /// The catch-up shortcut was consumed (the keyboard monitor is holding keys since).
    func catchUp(field: FieldID?, app: AppIdentity?, policy: AppPolicy?) {
        // Already applying one: the press was held and comes back when that one is done.
        guard !busy else { return }
        guard let field, let app, let policy else {
            hooks.releaseHeldKeys()
            return
        }
        busy = true
        Task { @MainActor in
            defer { finish(field: field) }
            guard let fresh = await hooks.readNow(field), fresh.field == field, fresh.selectionLength == 0,
                  !fresh.hasMarkedText, Self.catchUpSurface(fresh.metadata.surface) else {
                Self.log("catch-up: no usable read")
                return
            }
            guard let entry = missed.newest(field: field, before: fresh.before) else {
                Self.log("catch-up: nothing matches the field")
                return
            }
            guard let plan = CatchUpPlan.make(entry, before: fresh.before) else {
                countSkips([missed.abandon(id: entry.id)].compactMap { $0 })
                Self.log("catch-up: text before the word changed")
                return
            }
            if await replaceBehindCaret(plan, fresh: fresh, app: app, policy: policy) {
                missed.applied(id: entry.id)
                history.record(field: field, beforeFix: fresh.before, original: plan.word,
                               replacement: plan.replacement, tail: plan.tail, automatic: false)
                editApplied(field: field, after: plan.fixedBefore(fresh.before), from: plan.span,
                            to: plan.replacement + plan.tail, missedDone: true, historyDone: true)
                // The skip counted only on leaving was never counted: this occurrence is a fix taken.
                learning?.noteCorrectionAccepted(entry.word)
            } else if let word = missed.abandon(id: entry.id) {
                countSkips([word])
            }
        }
    }

    // MARK: Undo a fix later

    /// A fix taken with Tab went in: `before` was the text before the caret then, its last
    /// `deleteCount` characters were replaced with `replacement`.
    func noteTabFix(field: FieldID, before: String, deleteCount: Int, replacement: String) {
        guard !busy, deleteCount > 0, deleteCount <= before.count else { return }
        let original = String(before.suffix(deleteCount))
        history.record(field: field, beforeFix: before, original: original, replacement: replacement, tail: "",
                       automatic: false)
        publishRevertWaiting()
    }

    /// The revert shortcut was consumed (the keyboard monitor is holding keys since): put back what
    /// was typed for the newest fix still in the field.
    func revertNewest(field: FieldID?, app: AppIdentity?, policy: AppPolicy?) {
        // The newest fix is from a rewrite pass: the whole pass goes back.
        if let pass = lastPass, pass.field == field, let home = history.home,
           let newest = history.newest(field: pass.field, before: home), pass.ids.contains(newest.id),
           let app, let policy {
            revertPass(pass, app: app, policy: policy)
            return
        }
        revert(id: nil, field: field, app: app, policy: policy)
    }

    /// Most characters walked with Right to bring the caret back to where the user was typing.
    static let maxCaretWalk = 300

    /// The caret was moved back over unchanged text (a click into the fixed word): put it back at
    /// `home`, through Accessibility, else with Right (Chromium refuses the caret move). The read
    /// there, or nil (logged).
    private func caretBackToEnd(field: FieldID, home: String, fix: RecordedFix, from read: TextContext,
                                app: AppIdentity) async -> TextContext? {
        let atHome: (TextContext) -> Bool = {
            $0.selectionLength == 0 && CatchUpPlan.unchanged(before: $0.before, originalBefore: home)
        }
        let utf16 = home.utf16.count - read.before.utf16.count
        let expected = String(home.suffix(fix.anchor.count + fix.span.count))
        if await hooks.moveCaretForward(field, utf16, expected), let moved = await awaitRead(field, until: atHome) {
            return moved
        }
        // Whatever the refused move left: read again, then walk the characters still between.
        guard let now = await hooks.readNow(field), now.field == field, now.selectionLength == 0 else {
            Self.log("revert: caret not back at the end (no read)")
            return nil
        }
        if atHome(now) { return now }
        guard home.hasPrefix(now.before), now.after.hasPrefix(home.dropFirst(now.before.count)) else {
            Self.log("revert: caret not back at the end (field changed)")
            return nil
        }
        let steps = home.count - now.before.count
        guard steps <= Self.maxCaretWalk else {
            Self.log("revert: caret too far from the end for arrow keys")
            return nil
        }
        for _ in 0..<steps where !hooks.pressKey(Self.rightArrow, false, app) {
            Self.log("revert: arrow key refused")
            return nil
        }
        guard let moved = await awaitRead(field, until: atHome) else {
            Self.log("revert: caret not back at the end after arrow keys")
            return nil
        }
        return moved
    }

    /// A word was picked in the menu under a fixed word: the word as typed (revert), another
    /// candidate, or one the user typed. `settle`: the menu had the keyboard; give the host a moment
    /// to take it back first.
    func changeMarked(id: Int, to word: String, settle: Bool, field: FieldID?, app: AppIdentity?, policy: AppPolicy?) {
        guard !busy else {
            Self.log("revert: busy, menu choice dropped")
            return
        }
        hooks.holdKeys()
        revert(id: id, to: word, settle: settle, field: field, app: app, policy: policy)
    }

    /// What the menu under fix `id` offers: the word as typed, the fix, and the other words it could
    /// be (`alternatives` gets the typed word, the text before it and the fix in place).
    func choices(id: Int, alternatives: (_ typed: String, _ head: String, _ current: String) -> [String]) -> FixChoices? {
        guard let fix = history.entry(id: id), let home = history.home, home.hasSuffix(fix.span),
              let field = history.trackedField else { return nil }
        menuSnapshot = (field, fix, home)
        let head = String(home.dropLast(fix.span.count))
        let others = FixHistory<FieldID>.isSingleWord(fix.original)
            ? alternatives(fix.original, head, fix.replacement) : []
        return FixChoices(typed: fix.original, current: fix.replacement, alternatives: others)
    }

    /// The fix whose menu is open, and the text it was found in: the menu takes the keyboard, and a
    /// host that reports a focus change meanwhile would otherwise lose the list.
    private var menuSnapshot: (field: FieldID, fix: RecordedFix, home: String)?

    /// Puts back fix `id` (nil: the newest still there), or puts `word` in its place. Checks the
    /// field holds exactly the fix and what was typed after it, with the text before it unchanged;
    /// the caret, moved back over unchanged text (a click into the word), goes back to the end
    /// first. Anything else: nothing.
    private func revert(id: Int?, to word: String? = nil, settle: Bool = false, field: FieldID?, app: AppIdentity?,
                        policy: AppPolicy?) {
        guard !busy else { return }
        guard let field, let app, let policy else {
            Self.log("revert: no field")
            hooks.releaseHeldKeys()
            return
        }
        busy = true
        clearMarks()
        Task { @MainActor in
            defer { finish(field: field) }
            // The menu had the keyboard: wait for the host to take it back (reads fail until then).
            var first: TextContext?
            if settle, !(await hooks.ensureFrontmost(app)) {
                Self.log("revert: \(app.bundleID) not frontmost after the menu")
                return
            }
            if settle {
                let deadline = ContinuousClock.now + .milliseconds(800)
                while ContinuousClock.now < deadline {
                    if let read = await hooks.readNow(field), read.field == field { first = read; break }
                    try? await Task.sleep(for: .milliseconds(40))
                }
            } else {
                first = await hooks.readNow(field)
            }
            guard var fresh = first, fresh.field == field, fresh.selectionLength == 0,
                  !fresh.hasMarkedText else {
                Self.log("revert: no usable read")
                return
            }
            var home = history.home
            var candidates = home.map { history.matching(field: field, before: $0) } ?? []
            if let id, !candidates.contains(where: { $0.id == id }), let snap = menuSnapshot,
               snap.field == field, snap.fix.id == id {
                home = snap.home
                candidates = [snap.fix]
            }
            menuSnapshot = nil
            guard let home, let back = FixHistory<FieldID>.caretBack(home: home, before: fresh.before, after: fresh.after)
            else {
                Self.log("revert: the field changed")
                return
            }
            guard let fix = id.map({ id in candidates.first { $0.id == id } }) ?? candidates.first else {
                Self.log("revert: nothing matches the field")
                return
            }
            if back > 0 {
                guard let moved = await caretBackToEnd(field: field, home: home, fix: fix, from: fresh, app: app) else {
                    return
                }
                fresh = moved
            }
            let target = word ?? fix.original
            guard target != fix.replacement else {
                Self.log("revert: the fix itself picked")
                return
            }
            guard let plan = FixHistory<FieldID>.revertPlan(fix, before: fresh.before, to: target) else {
                history.remove(id: fix.id)
                Self.log("revert: text around the fix changed")
                return
            }
            // Waiting for the host and walking the caret back may have used most of the hold: a
            // fresh one (it extends the running hold) covers the replacement.
            hooks.holdKeys()
            // Short tails: delete back to the word and type it again with what follows, the way
            // automatic fixes go in (works in every host, Chromium too). Long ones: select it.
            let done = plan.keyboardAllowed
                ? await retypeBehindCaret(plan, fresh: fresh, field: field, app: app, policy: policy)
                : await replaceBehindCaret(plan, fresh: fresh, app: app, policy: policy)
            guard done else {
                Self.log("revert: not applied")
                return
            }
            undo.reset()
            disarmUndo()
            let isRevert = target == fix.original
            if isRevert {
                history.remove(id: fix.id)
                editApplied(field: field, after: plan.fixedBefore(fresh.before), from: plan.span,
                            to: plan.replacement + plan.tail)
                reverted(fix, field: field, after: plan.fixedBefore(fresh.before))
            } else {
                // Still a fix of what was typed: kept, so it can be changed again.
                history.replace(id: fix.id, with: target)
                editApplied(field: field, after: plan.fixedBefore(fresh.before), from: plan.span,
                            to: plan.replacement + plan.tail, historyDone: true)
                changed(fix, to: target)
            }
            Self.log("revert: applied (\(isRevert ? "reverted" : "changed") \(fix.automatic ? "automatic" : "taken") fix, "
                     + "\(plan.tailCharacters) after it)")
        }
    }

    /// A fix was changed to another word the user picked or typed: the word as typed was a slip,
    /// just not for the fix Hunch chose. Not a rejection (the word stays fixable, so "learn from
    /// rejected fixes" hears nothing); the personal slip list hears the word and the right fix, like
    /// a fix kept (one word to one word only).
    private func changed(_ fix: RecordedFix, to word: String) {
        guard FixHistory<FieldID>.isSingleWord(fix.original), FixHistory<FieldID>.isSingleWord(word) else { return }
        learning?.noteFixKept(word: fix.original, fix: word)
    }

    /// A fix was put back. The word isn't fixed again in this field (like Escape or Backspace). An
    /// automatic fix of one word counts for "learn from rejected fixes" by that feature's own rule:
    /// with a word typed after it already, it is a clean rejection now (undo, then type on);
    /// otherwise it is watched like a Backspace undo (type on, or leave with it kept). A fix taken
    /// with Tab or catch-up was the user's own pick: nothing is learned.
    private func reverted(_ fix: RecordedFix, field: FieldID, after: String) {
        guard FixHistory<FieldID>.isSingleWord(fix.original) else { return }
        restoredWords.insert(field: field, word: fix.original)
        guard fix.automatic else { return }
        if FixHistory<FieldID>.typedOnAfter(fix) {
            fixRejected(fix.original, field: field, fix: fix.replacement)
        } else {
            rejections.fixApplied(field: field, beforeFix: after, word: fix.original, fix: fix.replacement,
                                  trailing: String(fix.tail))
            rejections.undone(field: field, word: fix.original)
        }
    }

    private var revertWaiting = false

    private func publishRevertWaiting() {
        var waiting = false
        if revertKeyOn, let field = history.trackedField, let home = history.home {
            waiting = !history.matching(field: field, before: home).isEmpty
        }
        guard waiting != revertWaiting else { return }
        revertWaiting = waiting
        hooks.setRevertWaiting(waiting)
    }

    /// Deletes `plan.span` before the caret and types the new word and the tail again. True when
    /// the field then shows it.
    private func retypeBehindCaret(_ plan: CatchUpPlan, fresh: TextContext, field: FieldID, app: AppIdentity,
                                   policy: AppPolicy) async -> Bool {
        let outcome = await inserter.replace(deletingBackward: plan.span.count, with: plan.replacement + plan.tail,
                                             into: app, mode: policy.insertion, chunkSize: policy.injectionChunkSize ?? 16,
                                             workarounds: policy.insertionWorkarounds)
        if case .failed(let reason) = outcome {
            Self.log("revert: typing refused (\(reason))")
            return false
        }
        let expected = plan.fixedBefore(fresh.before)
        guard let shown = await awaitRead(field, until: {
            CatchUpPlan.unchanged(before: $0.before, originalBefore: expected)
        }) else {
            Self.log("revert: retyped text not seen in the field")
            return false
        }
        await highlight(field: field, back: plan.replacement.utf16.count + plan.tailUTF16,
                        length: plan.replacement.utf16.count, when: shown)
        return true
    }

    // MARK: Marks under fixed words

    /// Most fixed words marked at once (the newest).
    static let maxMarks = 5
    static let marksDelay: Duration = .milliseconds(150)
    private var marksShown = false
    private var marksTask: Task<Void, Never>?
    /// Bumped by every new refresh and every clear: a refresh task works only while it holds the newest.
    private var marksGeneration = 0
    private var marksDirty = false
    /// The field a missing-marks line was logged for (once per field).
    private var marksMissLogged: FieldID?
    /// The last read handled, to place the marks without another read (nil after an own edit).
    private var marksRead: (field: FieldID, before: String, after: String, selection: Int)?

    /// Places the faint lines under the fixed words still in the field, where the host gives their
    /// bounds (none at all where it doesn't). One refresh at a time; reads meanwhile ask for another.
    private func refreshMarks(field: FieldID) {
        guard !busy else { return }
        guard marksTask == nil else {
            marksDirty = true
            return
        }
        marksGeneration &+= 1
        let generation = marksGeneration
        marksTask = Task { @MainActor in
            // Cancelled (focus left, an own edit) or replaced by a newer refresh: draws nothing and
            // leaves the newer task's handle alone.
            @MainActor func current() -> Bool {
                if Task.isCancelled { return false }
                return marksGeneration == generation
            }
            repeat {
                marksDirty = false
                // Typing bursts settle first: the bounds lookups share the Accessibility thread with reads.
                try? await Task.sleep(for: Self.marksDelay)
                guard current() else { return }
                let marks = await currentMarks(field: field)
                guard current(), !busy, history.trackedField == field else { break }
                hooks.showFixMarks(marks)
                marksShown = !marks.isEmpty
            } while marksDirty && current()
            if marksGeneration == generation { marksTask = nil }
        }
    }

    private func currentMarks(field: FieldID) async -> [FixMark] {
        guard let home = history.home, history.trackedField == field, !history.isEmpty else { return [] }
        var read = marksRead
        if read == nil || read?.field != field, let now = await hooks.readNow(field) {
            read = (now.field, now.before, now.after, now.selectionLength)
        }
        guard let read, read.field == field, read.selection == 0,
              let back = history.caretBack(before: read.before, after: read.after) else { return [] }
        var marks: [FixMark] = []
        var misses: [String] = []
        // The text the caret moved back over (a click into the text): not between the word and the caret.
        let moved = home.dropFirst(read.before.count)
        for fix in history.matching(field: field, before: home).prefix(Self.maxMarks) {
            let result: Result<CGRect, BehindCaret.BoundsMiss>
            if moved.count <= fix.tail.count {
                let textToCaret = String(fix.span.dropLast(moved.count))
                result = await hooks.wordBounds(field, textToCaret, fix.replacement)
            } else {
                // The caret is in or before the word: index ranges only.
                result = await hooks.boundsBehindCaret(field, fix.span.utf16.count - back, fix.replacement.utf16.count)
            }
            switch result {
            case .success(let rect): marks.append(FixMark(id: fix.id, rect: rect, typed: fix.original))
            case .failure(let miss): misses.append(miss.rawValue)
            }
        }
        if marks.isEmpty, !misses.isEmpty, marksMissLogged != field {
            marksMissLogged = field
            Self.log("marks: none (\(Set(misses).sorted().joined(separator: ","))) in \(field.pid)")
        }
        return marks
    }

    private func clearMarks() {
        marksTask?.cancel()
        marksTask = nil
        marksGeneration &+= 1
        guard marksShown else { return }
        marksShown = false
        hooks.showFixMarks([])
    }

    // MARK: Fix automatically

    /// Fixes the word just finished instead of showing the fix (right at the caret, nothing typed on).
    /// Never in terminals, agent prompts in a terminal, shells or code (stage 5): there the fix is
    /// only shown, and Tab takes it. True when it took the context.
    func autoFix(_ context: TextContext, proposal: CorrectionProposal, policy: AppPolicy) -> Bool {
        guard fixesAutomatically(policy), Self.catchUpSurface(context.metadata.surface), !busy,
              !wasRestored(field: context.field, word: proposal.misspelled) else { return false }
        let fix = SpanFix(before: context.before, word: proposal.misspelled, replacement: proposal.replacement,
                          tail: proposal.trailing)
        run(field: context.field) { [self] in
            await applyFix(fix, field: context.field, app: context.app, policy: policy, typedOn: false)
        }
        return true
    }

    /// Backspace straight after an automatic fix (consumed by the keyboard monitor).
    func undoAutoFix(field: FieldID?, app: AppIdentity?, policy: AppPolicy?) {
        undoPublished = false  // the monitor used it up
        guard let field, let app, let policy, !busy else {
            if let app { _ = hooks.pressKey(51, false, app) }  // pass the Backspace on
            return
        }
        busy = true
        hooks.holdKeys()
        Task { @MainActor in
            defer { finish(field: field) }
            guard let fresh = await hooks.readNow(field), fresh.field == field, fresh.selectionLength == 0,
                  let plan = undo.backspace(field: field, before: fresh.before) else {
                // Can't tell the fix is still there: the Backspace does what it always does.
                _ = hooks.pressKey(51, false, app)
                return
            }
            let fixed = String(fresh.before.suffix(plan.deleteCount))
            guard stillHolding("undo") else {
                _ = hooks.pressKey(51, false, app)  // the Backspace does what it always does
                return
            }
            _ = await inserter.replace(deletingBackward: plan.deleteCount, with: plan.text, into: app,
                                       mode: policy.insertion, chunkSize: policy.injectionChunkSize ?? 16,
                                       workarounds: policy.insertionWorkarounds)
            let restored = String(fresh.before.dropLast(plan.deleteCount)) + plan.text
            if let shown = await awaitRead(field, until: {
                CatchUpPlan.unchanged(before: $0.before, originalBefore: restored)
            }) {
                editApplied(field: field, after: restored, from: fixed, to: plan.text)
                await highlight(field: field, back: plan.text.utf16.count, length: plan.word.utf16.count, when: shown)
            }
            // Kept in this field; learned only once what follows shows a clean rejection.
            restoredWords.insert(field: field, word: plan.word)
            rejections.undone(field: field, word: plan.word)
        }
    }

    /// A clean rejection of an automatic fix: the word is not fixed again in this field (it may have
    /// just been typed again) and the learning controller hears it. `field` nil: focus is leaving.
    private func fixRejected(_ word: String, field: FieldID?, fix: String? = nil) {
        Self.log("fix rejected cleanly")
        if let field { restoredWords.insert(field: field, word: word) }
        learning?.noteFixRejected(word, fix: fix ?? rejections.lastRejectedFix)
    }

    /// Words restored with Backspace in this field are not fixed again there (like Escape).
    private var restoredWords = RestoredWords()

    func wasRestored(field: FieldID, word: String) -> Bool { restoredWords.contains(field: field, word: word) }

    // MARK: Ambiguous words

    /// Longest the model may take to choose; slower (busy, loading) counts as unavailable.
    static let scoreTimeout: Duration = .milliseconds(700)

    /// Fix automatically on fields read like a document: the next step for the words not looked at
    /// yet. A confident fix goes in at once (behind the caret when the user typed on); a waiting
    /// ambiguous word whose next word is finished is chosen by the model. True when it took the
    /// context. `checkWords` false settles new words without a look. `score` gets the text before the
    /// word and the continuations to compare (each candidate, then the next word); nil = no model.
    func step(_ context: TextContext, policy: AppPolicy, checkWords: Bool,
              finding: (String) -> CorrectionFinding?,
              score: @escaping @MainActor (_ head: String, _ continuations: [String]) async -> [Float]?) -> Bool {
        guard fixesAutomatically(policy), Self.catchUpSurface(context.metadata.surface) else { return false }
        guard !busy, choice == nil else { return false }
        let field = context.field
        let next = span.read(field: field, before: context.before, checkWords: checkWords) { stem in
            switch finding(stem) {
            case .fix(let p)? where wasRestored(field: field, word: p.misspelled): nil
            case .ambiguous(let t)? where wasRestored(field: field, word: t.misspelled): nil
            case let found: found
            }
        }
        switch next {
        case nil:
            return false
        case .fix(let fix)?:
            run(field: field) { [self] in
                await applyFix(fix, field: field, app: context.app, policy: policy, typedOn: true)
            }
        case .choose(let trigger)?:
            startChoice(trigger, field: field, app: context.app, policy: policy, score: score)
        }
        return true
    }

    /// The model is choosing for waiting words: the user's keys go on to the app meanwhile (nothing
    /// is held); the coordinator leaves reads for later, so no suggestion request supersedes the
    /// scoring. The pick then goes in like any fix typed past (`applyFix`, `typedOn`).
    private var choice: (field: FieldID, task: Task<SpanFix?, Never>)?
    var isChoosing: Bool { choice != nil }

    private func startChoice(_ trigger: StretchTrigger, field: FieldID, app: AppIdentity, policy: AppPolicy,
                             score: @escaping @MainActor (_ head: String, _ continuations: [String]) async -> [Float]?) {
        clearMarks()
        let task = Task { @MainActor [self] in
            await choose(trigger, field: field, score: score)
        }
        choice = (field, task)
        Task { @MainActor [self] in
            let fix = await task.value
            // Focus left meanwhile: the choice was dropped.
            guard let c = choice, c.task == task else { return }
            choice = nil
            if let fix, !busy {
                run(field: field) { [self] in
                    await applyFix(fix, field: field, app: app, policy: policy, typedOn: true)
                }
            } else {
                if fix != nil { Self.log("ambiguous words: another edit ran meanwhile, pick dropped") }
                onFinished?(nil)
            }
        }
    }

    /// Runs one change to the field: keys held meanwhile, reads ignored; afterwards the coordinator
    /// handles the newest read it skipped (`body` returns the text expected before the caret then).
    private func run(field: FieldID, _ body: @escaping @MainActor () async -> String?) {
        busy = true
        clearMarks()
        hooks.holdKeys()
        onEditStarted?()
        Task { @MainActor in
            var expected: String?
            defer {
                finish(field: field)
                onFinished?(expected)
            }
            expected = await body()
        }
    }

    /// The model chooses for the waiting words together (each as typed or one of its candidates,
    /// with the word after them); the fixes go in as one edit at the caret (`JointChoice`).
    private func choose(_ trigger: StretchTrigger, field: FieldID,
                        score: @escaping @MainActor (_ head: String, _ continuations: [String]) async -> [Float]?) async -> SpanFix? {
        let combos = JointChoice.combos(trigger.slots)
        let continuations = combos.map { JointChoice.continuation($0, trigger) }
        let scores = await Self.withTimeout(Self.scoreTimeout) { await score(trigger.head, continuations) }
        let resolution = JointChoice.resolve(trigger, combos: combos, scores: scores)
        Self.log("ambiguous words (\(trigger.slots.count), \(combos.count) scored): "
                 + resolution.choices.map(Self.describe).joined(separator: ", ")
                 + (scores == nil ? " (model unavailable)" : ""))
        if let fix = resolution.fix { return fix }
        if let offer = resolution.offer, !Task.isCancelled {
            offerForCatchUp(field: field, before: trigger.before, word: offer.word, pick: offer.pick, span: offer.span)
        }
        return nil
    }

    /// Replaces the word and what follows it at the caret (deletes back to the word, types the fix and
    /// the rest again), the way that works in every host; selecting behind the caret is unreliable in
    /// Chromium editors. The user may have typed on since the fix was decided (`typedOn` allows it).
    /// Arms Backspace to restore the word. The text before the caret afterwards, or nil.
    @discardableResult
    private func applyFix(_ fix: SpanFix, field: FieldID, app: AppIdentity, policy: AppPolicy,
                          typedOn: Bool) async -> String? {
        guard let fresh = await holdAndRead(field) else {
            Self.log("fix: no usable read")
            return nil
        }
        guard let edit = fix.edit(now: fresh.before), typedOn || edit.tail == fix.tail else {
            Self.log("fix: text after the word doesn't match")
            return nil
        }
        // Return (or Send) approves the text as shown: a fix never reaches back over a line break.
        guard !edit.tail.contains(where: \.isNewline) else {
            Self.log("fix: a line break was typed after the word, left as typed")
            return nil
        }
        guard stillHolding("fix") else { return nil }
        _ = await inserter.replace(deletingBackward: edit.original.count, with: edit.fixed, into: app,
                                   mode: policy.insertion, chunkSize: policy.injectionChunkSize ?? 16,
                                   workarounds: policy.insertionWorkarounds)
        guard let shown = await awaitRead(field, until: {
            CatchUpPlan.unchanged(before: $0.before, originalBefore: edit.after)
        }) else {
            Self.log("fix: not seen in the field")
            return nil
        }
        let typedOnCount = edit.tail.count - fix.tail.count
        Self.log("fix: applied (deleted \(edit.original.count), typed \(edit.fixed.count), typed on \(typedOnCount))")
        watchedFix = (field, shown.before, .now)
        history.record(field: field, beforeFix: fresh.before, original: fix.word, replacement: fix.replacement,
                       tail: edit.tail, automatic: true, confidence: fixConfidence?(fix.word, fix.replacement))
        editApplied(field: field, after: edit.after, from: edit.original, to: edit.fixed, historyDone: true)
        undo.applied(field: field, beforeFix: fresh.before, original: fix.word, fix: fix.replacement, trailing: edit.tail)
        rejections.fixApplied(field: field, beforeFix: fresh.before, word: fix.word, fix: fix.replacement,
                              trailing: edit.tail)
        hooks.armBackspaceUndo(true)
        undoPublished = true
        await highlight(field: field, back: edit.fixed.utf16.count, length: fix.replacement.utf16.count, when: shown)
        return edit.after
    }

    /// Hunch changed the end of the text before the caret: everything that follows the field's
    /// text hears it once (catch-up entries, the unsettled words, typing samples).
    private func editApplied(field: FieldID, after: String, from: String, to: String, missedDone: Bool = false,
                             historyDone: Bool = false) {
        if !missedDone { missed.rewriteEnd(from: from, to: to) }
        span.rewriteEnd(from: from, to: to)
        if !historyDone { history.rewriteEnd(from: from, to: to) }
        samples.ownEdit(field: field, after: after, from: from, to: to)
    }

    /// Logs when a delayed fix seen in the field is gone again within 3 s without the user editing
    /// before it (no text logged).
    private func watchDelayedFix(_ context: TextContext) {
        guard let w = watchedFix else { return }
        if w.field != context.field || ContinuousClock.now - w.at > .seconds(3) { watchedFix = nil; return }
        if context.before == w.before { return }
        if let more = MissedFixTracker<FieldID>.appended(from: w.before, to: context.before) {
            watchedFix = (w.field, w.before + more, w.at)
            return
        }
        let shrunk = w.before.count - context.before.count
        Self.log("ambiguous word: field changed after the fix (length \(w.before.count) → \(context.before.count), "
                 + "\(shrunk > 0 && w.before.hasPrefix(context.before) ? "backspaced" : "rewritten"))")
        watchedFix = nil
    }

    /// The model's pick, not applied: the catch-up shortcut can apply it while the text still matches.
    private func offerForCatchUp(field: FieldID, before: String, word: String, pick: String, span: String) {
        guard catchUpOn else { return }
        missed.offer(field: field, before: before, word: word, replacement: pick, span: span)
    }

    /// `body`'s answer, or nil when it takes longer than `limit` (the body is cancelled).
    static func withTimeout<T: Sendable>(_ limit: Duration,
                                         _ body: @escaping @MainActor () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func describe(_ choice: TypoChoice) -> String {
        switch choice {
        case .fix: "fixed"
        case .unsure: "offered (close call)"
        case .keep: "kept as typed"
        }
    }

    // MARK: Whole-field rewrite (Strong)

    /// The field's text before the caret as the last rewrite pass left it: sentences still the same
    /// aren't sent again.
    private var rewriteChecked: (field: FieldID, before: String)?
    /// A pass is waiting for the model (reads go on as usual meanwhile).
    private(set) var rewriting = false
    /// The last pass that went in, for putting it all back at once (Control+Shift+Z).
    private struct PassRecord {
        var field: FieldID
        var ids: Set<Int>
        /// Text before the changed stretch, the stretch as typed, and as the pass left it.
        var head: String
        var old: String
        var new: String
    }
    private var lastPass: PassRecord?
    /// Longest stretch, from the first change to the caret, that a pass retypes.
    static let maxPassStretch = 400
    /// Longest text typed after a pass that putting the pass back retypes.
    static let maxPassRevertTail = 300

    /// A pause (Strong strength): the model rereads the sentences of the caret's paragraph not
    /// checked yet, and the changes `FieldRewrite` allows go in, each word underlined like any fix.
    /// Keys are not held while the model works; changes go in only where the field still holds the
    /// text they were made for. `generate` answers with the model's copy of the target (nil: none).
    /// The model sees Hunch's own automatic fixes in the target as they were typed
    /// (`RewriteOwnFixes`): its answer may replace such a fix; where it agrees, nothing changes.
    /// `score`: where the model's real word was blocked over such a fix by slip cost or word count,
    /// the readings scored after the pass (`RewriteOwnFixes.arbitrate`); nil: the rule decides.
    func rewriteAtPause(_ context: TextContext, policy: AppPolicy, options: RewriteOptions,
                        lastKey: ContinuousClock.Instant,
                        generate: @escaping @MainActor (RewriteTarget) async -> String?,
                        score: (@MainActor (RewriteTarget, String, [String]) async -> [Float]?)? = nil) {
        guard fixesAutomatically(policy), Self.catchUpSurface(context.metadata.surface), !busy, !rewriting,
              choice == nil, context.selectionLength == 0, !context.hasMarkedText else { return }
        let field = context.field
        let checked = rewriteChecked?.field == field ? rewriteChecked?.before : nil
        guard let target = RewriteTarget.find(before: context.before, checked: checked) else { return }
        var options = options
        options.keptWords.formUnion(restoredWords.all(field: field))
        let sent = RewriteOwnFixes.asTyped(target, fixes: ownFixes(field: field, before: context.before))
        rewriting = true
        Task { @MainActor in
            defer { rewriting = false }
            guard let revised = await generate(sent.target) else {
                Self.log("rewrite: no answer")
                return
            }
            let result = FieldRewrite.edits(target: sent.target, revised: revised, options: options)
            let spelling = Self.spelling
            let isKnown = options.isKnownWord ?? { !spelling.isMisspelled($0, languages: ["en"]) }
            let collected = DisputeSink()
            var edits = RewriteOwnFixes.mapBack(result, revised: revised, on: sent, options: options,
                                                isKnownWord: isKnown, isCommonWord: { CommonEnglish.contains($0) },
                                                keptRules: Self.keptRules,
                                                arbitrated: score == nil ? [] : OwnFixDispute.Kind.app,
                                                disputes: { collected.items.append($0) })
            let disputes = collected.items
            if let score, !disputes.isEmpty {
                let started = ContinuousClock.now
                var verdicts: [Range<Int>: String] = [:]
                for d in disputes {
                    let (head, continuations) = d.scoring
                    guard let scores = await score(sent.target, head, continuations) else { continue }
                    if let v = RewriteOwnFixes.arbitrate(d, scores: scores) { verdicts[d.range] = v }
                    Self.log("rewrite: own fix \(d.kind.rawValue) " + zip(d.readings, scores).map { "\($0.0) \(String(format: "%.1f", $0.1))" }
                        .joined(separator: " / ") + " → \(verdicts[d.range] ?? d.readings[0])")
                }
                SuggestionCoordinator.perf("strong pass: scored \(disputes.count) own-fix readings in "
                                           + "\(SuggestionCoordinator.ms(since: started)) ms, \(verdicts.count) overruled")
                if !verdicts.isEmpty {
                    edits = RewriteOwnFixes.mapBack(result, revised: revised, on: sent, options: options,
                                                    isKnownWord: isKnown, isCommonWord: { CommonEnglish.contains($0) },
                                                    keptRules: Self.keptRules,
                                                    arbitrated: OwnFixDispute.Kind.app, verdicts: verdicts)
                }
            }
            Self.log("rewrite: \(edits.count) changes (\(edits.filter { $0.typed != nil }.count) over \(sent.placed.count) own "
                     + "fixes sent as typed), \(result.rejected.count) thrown out ("
                     + Set(result.rejected.map(\.reason.rawValue)).sorted().joined(separator: ", ") + ")")
            func perf(_ outcome: String) {
                SuggestionCoordinator.perf("strong pass: \(outcome), \(SuggestionCoordinator.ms(since: lastKey)) ms after the last key")
            }
            guard !edits.isEmpty else {
                rewriteChecked = (field, context.before)
                perf("no changes")
                return
            }
            guard !busy, choice == nil else {
                perf("dropped (autocorrect busy)")
                return
            }
            run(field: field) { [self] in
                let shown = await applyPass(edits, original: context.before, field: field, app: context.app, policy: policy)
                perf(shown == nil ? "dropped at apply" : "applied \(edits.count) changes")
                return shown
            }
        }
    }

    /// Own fixes the model kept as typed that the pass takes back: a typed real word (measured
    /// 2026-11-15), and a fix fix-as-you-type was unsure of (2026-11-16, `docs/features/autocorrect-rewrite.md`).
    private nonisolated static let keptRules: RewriteOwnFixes.KeptTypedRules = RewriteOwnFixes.KeptTypedRules.app.union(.unsureFix)

    /// Checks the words a rewrite pass puts in place of Hunch's own fixes when the pass has no
    /// spell check of its own (`RewriteOptions.isKnownWord`, which has the user's learned words).
    private static let spelling = SystemSpellChecker.cached()

    /// Collects the disputes a pass reports (a class: the pass's closure is main-actor isolated).
    @MainActor private final class DisputeSink { var items: [OwnFixDispute] = [] }

    /// Hunch's automatic fixes still in the field before the caret (not undone, not retyped).
    private func ownFixes(field: FieldID, before: String) -> [OwnFix] {
        let end = before.utf16.count
        return history.matching(field: field, before: before).filter(\.automatic).map { f in
            let to = end - String(f.tail).utf16.count
            return OwnFix(range: (to - f.replacement.utf16.count)..<to, typed: f.original, fixed: f.replacement, id: f.id,
                          confidence: f.confidence)
        }
    }

    /// Puts a pass's changes in as one edit at the caret: deletes back to the first change and types
    /// the corrected stretch (as automatic fixes go in), then records each change for its underline.
    private func applyPass(_ passEdits: [OwnFixEdit], original: String, field: FieldID, app: AppIdentity,
                           policy: AppPolicy) async -> String? {
        guard let fresh = await holdAndRead(field) else {
            Self.log("rewrite: no usable read")
            return nil
        }
        let still = FieldRewrite.stillApplicable(passEdits.map(\.edit), original: original, fresh: fresh.before)
        let changes = passEdits.filter { still.contains($0.edit) }
        let edits = changes.map(\.edit)
        guard let first = edits.first else {
            Self.log("rewrite: the field changed, nothing applied")
            return nil
        }
        let units = Array(fresh.before.utf16)
        let head = String(decoding: units[..<first.range.lowerBound], as: UTF16.self)
        let old = String(decoding: units[first.range.lowerBound...], as: UTF16.self)
        guard old.count <= Self.maxPassStretch else {
            Self.log("rewrite: stretch too long to retype")
            return nil
        }
        // A line break typed since the pass (Return during it): retyping back through it would undo
        // the new line, and in a list a new item (its number lands on the line above). That
        // paragraph is the writer's next one; the pass is dropped.
        guard !old.contains(where: \.isNewline) else {
            Self.log("rewrite: a line break was typed since the pass, nothing applied")
            return nil
        }
        let after = FieldRewrite.apply(edits, to: fresh.before)
        let new = String(after.dropFirst(head.count))
        guard stillHolding("rewrite") else { return nil }
        _ = await inserter.replace(deletingBackward: old.count, with: new, into: app, mode: policy.insertion,
                                   chunkSize: policy.injectionChunkSize ?? 16, workarounds: policy.insertionWorkarounds)
        guard let shown = await awaitRead(field, until: {
            CatchUpPlan.unchanged(before: $0.before, originalBefore: after)
        }) else {
            Self.log("rewrite: not seen in the field")
            return nil
        }
        // Each change on its own underline, recorded in order on the text as it was then.
        var state = fresh.before
        var shift = 0
        var ids = Set<Int>()
        for change in changes {
            let e = change.edit
            var moved = change
            moved.edit.range = (e.range.lowerBound + shift)..<(e.range.upperBound + shift)
            shift += e.replacement.utf16.count - e.range.count
            let next = FieldRewrite.apply([moved.edit], to: state)
            // A change over Hunch's own fix replaces that fix's entry; undo gives back what was typed.
            for id in change.replacesFixes { history.remove(id: id) }
            if change.revertsFix {
                // Taken back: no underline; the other entries follow the change.
                let at = moved.edit.range.lowerBound
                history.rewriteEnd(from: String(decoding: Array(state.utf16)[at...], as: UTF16.self),
                                   to: String(decoding: Array(next.utf16)[at...], as: UTF16.self))
            } else if let (r, typed) = moved.recordable(in: state) {
                let tail = String(decoding: Array(state.utf16)[r.range.upperBound...], as: UTF16.self)
                if let id = history.record(field: field, beforeFix: state, original: r.original,
                                           replacement: r.replacement, tail: tail, automatic: true,
                                           typed: change.typed == nil ? nil : typed) {
                    ids.insert(id)
                }
            }
            state = next
        }
        editApplied(field: field, after: after, from: old, to: new, historyDone: true)
        lastPass = PassRecord(field: field, ids: ids, head: head, old: old, new: new)
        rewriteChecked = (field, after)
        undo.reset()
        disarmUndo()
        Self.log("rewrite: applied \(edits.count) changes (retyped \(old.count) → \(new.count))")
        await highlight(field: field, back: new.utf16.count, length: new.utf16.count, when: shown)
        return after
    }

    /// Control+Shift+Z right after a pass (its fixes the newest): everything the pass changed goes back,
    /// with what was typed after it kept. The words put back stay as typed in this field.
    private func revertPass(_ pass: PassRecord, app: AppIdentity, policy: AppPolicy) {
        guard !busy else { return }
        busy = true
        clearMarks()
        Task { @MainActor in
            defer { finish(field: pass.field) }
            guard let fresh = await hooks.readNow(pass.field), fresh.field == pass.field, fresh.selectionLength == 0,
                  !fresh.hasMarkedText, fresh.before.hasPrefix(pass.head + pass.new) else {
                Self.log("revert pass: the field changed")
                return
            }
            let tail = String(fresh.before.dropFirst(pass.head.count + pass.new.count))
            guard tail.count <= Self.maxPassRevertTail, !tail.contains(where: \.isNewline) else {
                Self.log("revert pass: too much typed since (or a line break)")
                return
            }
            hooks.holdKeys()
            guard stillHolding("revert pass") else { return }
            _ = await inserter.replace(deletingBackward: pass.new.count + tail.count, with: pass.old + tail, into: app,
                                       mode: policy.insertion, chunkSize: policy.injectionChunkSize ?? 16,
                                       workarounds: policy.insertionWorkarounds)
            let restored = pass.head + pass.old + tail
            guard await awaitRead(pass.field, until: {
                CatchUpPlan.unchanged(before: $0.before, originalBefore: restored)
            }) != nil else {
                Self.log("revert pass: not seen in the field")
                return
            }
            for id in pass.ids {
                if let fix = history.entry(id: id) {
                    for w in fix.original.split(whereSeparator: \.isWhitespace) {
                        restoredWords.insert(field: pass.field, word: String(w))
                    }
                }
                history.remove(id: id)
            }
            editApplied(field: pass.field, after: restored, from: pass.new + tail, to: pass.old + tail, historyDone: true)
            lastPass = nil
            rewriteChecked = (pass.field, restored)
            Self.log("revert pass: \(pass.ids.count) changes put back")
        }
    }

    // MARK: Replacing a word behind the caret

    /// Replaces `plan.word` (ending `plan.tail` before the caret) with `plan.replacement` and puts the
    /// caret back. True when done and seen in the field. Never types unless the check before passed.
    private func replaceBehindCaret(_ plan: CatchUpPlan, fresh: TextContext, app: AppIdentity,
                                    policy: AppPolicy) async -> Bool {
        let field = fresh.field
        switch await hooks.selectBehindCaret(field, plan.span, plan.word) {
        case .success(let caret):
            return await finishAXReplacement(plan, caret: caret, fresh: fresh, app: app, policy: policy)
        case .failure(.textDiffers):
            Self.log("catch-up: field text differs, nothing done")
            return false
        case .failure(.gone):
            Self.log("catch-up: focus moved before the selection")
            return false
        case .failure(.refused):
            Self.log("catch-up: selection refused, trying arrow keys")
        }
        // The host refused the selection: make sure it left none behind before pressing keys (hosts
        // that apply a selection late get a moment to apply it and the restore).
        try? await Task.sleep(for: .milliseconds(120))
        guard let settled = await awaitRead(field, until: { $0.selectionLength == 0 }),
              CatchUpPlan.unchanged(before: settled.before, originalBefore: fresh.before) else {
            Self.log("catch-up: field changed after the refused selection")
            return false
        }
        guard plan.keyboardAllowed else {
            Self.log("catch-up: too far back for arrow keys")
            return false
        }
        return await keyboardReplacement(plan, fresh: fresh, app: app, policy: policy)
    }

    private func finishAXReplacement(_ plan: CatchUpPlan, caret: Int, fresh: TextContext, app: AppIdentity,
                                     policy: AppPolicy) async -> Bool {
        let field = fresh.field
        guard hooks.isHoldingKeys() else {
            Self.log("catch-up: key hold ran out before typing")
            // The hold timed out: the user's keys would land in the selection. Put the caret back.
            _ = await hooks.placeCaret(field, caret, plan.span, 0, 0)
            return false
        }
        let outcome = await inserter.insert(plan.replacement, into: app, mode: policy.insertion,
                                            chunkSize: policy.injectionChunkSize ?? 16,
                                            workarounds: policy.insertionWorkarounds)
        if case .failed = outcome {
            Self.log("catch-up: typing the fix failed")
            _ = await hooks.placeCaret(field, caret, plan.span, 0, 0)
            return false
        }
        // Wait until the host shows the fix before moving the caret, or the move could land first.
        guard await awaitRead(field, until: {
            $0.selectionLength == 0 && plan.replacementTyped(before: $0.before, after: $0.after, originalBefore: fresh.before)
        }) != nil else {
            Self.log("catch-up: typed fix not seen")
            return false
        }
        let location = caret - plan.wordUTF16 + plan.replacement.utf16.count
        switch await hooks.placeCaret(field, location, plan.replacement + plan.tail,
                                      plan.replacement.utf16.count + plan.tailUTF16, plan.replacement.utf16.count) {
        case .success(let rect):
            if let rect { hooks.flash(rect) } else { Self.log("highlight: no bounds after catch-up in \(app.bundleID)") }
            return true
        case .failure:
            // The host took the selection but not the caret move: walk back with the arrow keys.
            for _ in 0..<plan.tailCharacters where !hooks.pressKey(Self.rightArrow, false, app) { return false }
            guard let back = await awaitRead(field, until: {
                $0.selectionLength == 0 && plan.caretRestored(before: $0.before, originalBefore: fresh.before)
            }) else {
                Self.log("catch-up: fix typed, caret not back after it")
                return false
            }
            await highlight(field: field, back: plan.replacement.utf16.count + plan.tailUTF16,
                            length: plan.replacement.utf16.count, when: back)
            return true
        }
    }

    /// Left over the tail, Shift+Left over the word, check, type the fix, Right over the tail, check.
    private func keyboardReplacement(_ plan: CatchUpPlan, fresh: TextContext, app: AppIdentity,
                                     policy: AppPolicy) async -> Bool {
        let field = fresh.field
        for _ in 0..<plan.tailCharacters where !hooks.pressKey(Self.leftArrow, false, app) {
            Self.log("catch-up: arrow key refused (secure input, or \(app.bundleID) not frontmost)")
            await walkBack(plan, fresh: fresh, app: app)
            return false
        }
        for _ in 0..<plan.wordCharacters where !hooks.pressKey(Self.leftArrow, true, app) {
            Self.log("catch-up: arrow key refused (secure input, or \(app.bundleID) not frontmost)")
            await walkBack(plan, fresh: fresh, app: app)
            return false
        }
        guard await awaitRead(field, until: {
            plan.wordSelected(before: $0.before, selected: $0.selectedText, after: $0.after, originalBefore: fresh.before)
        }) != nil, hooks.isHoldingKeys() else {
            Self.log("catch-up: arrow-key selection not confirmed, moving back")
            await walkBack(plan, fresh: fresh, app: app)
            return false
        }
        let outcome = await inserter.insert(plan.replacement, into: app, mode: policy.insertion,
                                            chunkSize: policy.injectionChunkSize ?? 16,
                                            workarounds: policy.insertionWorkarounds)
        if case .failed = outcome {
            await walkBack(plan, fresh: fresh, app: app)
            return false
        }
        guard await awaitRead(field, until: {
            $0.selectionLength == 0 && plan.replacementTyped(before: $0.before, after: $0.after, originalBefore: fresh.before)
        }) != nil else {
            Self.log("catch-up: typed fix not seen")
            return false
        }
        for _ in 0..<plan.tailCharacters where !hooks.pressKey(Self.rightArrow, false, app) { return false }
        guard let back = await awaitRead(field, until: {
            $0.selectionLength == 0 && plan.caretRestored(before: $0.before, originalBefore: fresh.before)
        }) else {
            Self.log("catch-up: caret not back after the fix")
            return false
        }
        await highlight(field: field, back: plan.replacement.utf16.count + plan.tailUTF16,
                        length: plan.replacement.utf16.count, when: back)
        return true
    }

    /// Undoes the arrow-key moves: Right collapses a selection at its end (the word's end), then
    /// Right over the tail. Logged when the caret doesn't end up where it started.
    private func walkBack(_ plan: CatchUpPlan, fresh: TextContext, app: AppIdentity) async {
        let field = fresh.field
        guard let now = await hooks.readNow(field) else { return }
        if CatchUpPlan.unchanged(before: now.before, originalBefore: fresh.before), now.selectionLength == 0 { return }
        // How far back the caret is: the tail still after it, or the tail plus a selected word.
        let presses = now.selectionLength > 0 ? 1 + plan.tailCharacters : plan.tailCharacters
        for _ in 0..<presses where !hooks.pressKey(Self.rightArrow, false, app) { break }
        if await awaitRead(field, until: {
            $0.selectionLength == 0 && CatchUpPlan.unchanged(before: $0.before, originalBefore: fresh.before)
        }) == nil {
            Self.log("catch-up: caret may not be back where it was")
        }
    }

    // MARK: Helpers

    /// The read an edit starts from, with the key hold started afresh for the edit itself: waiting for
    /// the model before it must not eat into the hold's time limit (`KeyHoldQueue.maxHoldNanoseconds`).
    private func holdAndRead(_ field: FieldID) async -> TextContext? {
        hooks.holdKeys()
        guard let fresh = await hooks.readNow(field), fresh.field == field, fresh.selectionLength == 0,
              !fresh.hasMarkedText else { return nil }
        return fresh
    }

    /// Typing goes out only while the user's keys are still held: a hold that ran out has let their
    /// keys through, and synthesized keys would land among them.
    private func stillHolding(_ what: String) -> Bool {
        guard hooks.isHoldingKeys() else {
            Self.log("\(what): key hold ran out before typing")
            return false
        }
        return true
    }

    /// Reads the field directly until `done` accepts a read; nil after `stepWait`.
    private func awaitRead(_ field: FieldID, until done: (TextContext) -> Bool) async -> TextContext? {
        let deadline = ContinuousClock.now + Self.stepWait
        while ContinuousClock.now < deadline {
            if let read = await hooks.readNow(field), read.field == field, done(read) { return read }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return nil
    }

    /// Flashes the changed word. Logs why not when the host gives no bounds for it (host name only).
    private func highlight(field: FieldID, back: Int, length: Int, when read: TextContext) async {
        guard read.selectionLength == 0 else { return }
        switch await hooks.boundsBehindCaret(field, back, length) {
        case .success(let rect):
            hooks.flash(rect)
        case .failure(let miss):
            Self.log("highlight: none (\(miss.rawValue)) in \(read.app.bundleID)")
        }
    }

    private func finish(field: FieldID) {
        busy = false
        marksRead = nil
        hooks.releaseHeldKeys()
        publishRevertWaiting()
        refreshMarks(field: field)
        lastWaiting = !missed.isEmpty
        hooks.setCatchUpWaiting(lastWaiting && catchUpOn)
    }

    private func publishWaiting(field: FieldID, before: String) {
        let waiting = catchUpOn && missed.newest(field: field, before: before) != nil
        guard waiting != lastWaiting else { return }
        lastWaiting = waiting
        hooks.setCatchUpWaiting(waiting)
    }

    private func countSkips(_ words: [String]) {
        for word in words { learning?.noteCorrectionSkipped(word) }
    }

    /// Fields whose text is read and selected like a document's: not terminals (a screen dump),
    /// shell prompts or code.
    static func catchUpSurface(_ surface: SurfaceKind) -> Bool {
        switch surface {
        case .terminal, .agentPrompt, .shell, .code: false
        default: true
        }
    }

    private static func log(_ line: String) { SuggestionCoordinator.perf("autocorrect " + line) }
}

/// Words restored with Backspace after an automatic fix, for the field they were restored in.
private struct RestoredWords {
    private var field: FieldID?
    private var words: Set<String> = []

    mutating func insert(field: FieldID, word: String) {
        if self.field != field { self.field = field; words = [] }
        words.insert(word.lowercased())
    }

    func contains(field: FieldID, word: String) -> Bool {
        self.field == field && words.contains(word.lowercased())
    }

    func all(field: FieldID) -> Set<String> { self.field == field ? words : [] }
}
