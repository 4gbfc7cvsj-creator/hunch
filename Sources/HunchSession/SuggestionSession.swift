import Foundation
import HunchCore

/// The visible (or pending) suggestion as the coordinator needs it for presentation and the arbiter.
public struct GhostState: Sendable, Equatable {
    public var field: FieldID
    public var app: AppIdentity
    public var urlHost: String?
    /// Suggestion text still to be typed or accepted, continuing at the caret.
    public var remaining: String
    public var geometry: CaretGeometry
    public var caretAtLineEnd: Bool

    public init(field: FieldID, app: AppIdentity, urlHost: String?, remaining: String, geometry: CaretGeometry,
                caretAtLineEnd: Bool) {
        self.field = field
        self.app = app
        self.urlHost = urlHost
        self.remaining = remaining
        self.geometry = geometry
        self.caretAtLineEnd = caretAtLineEnd
    }
}

/// Inputs to the session. Time is passed in so the machine stays pure.
public enum SessionEvent: Sendable {
    /// A gated focus context. `midLineEnabled` comes from the resolved app policy; no suggestion is
    /// requested or shown until the caret's line has `minWords` words.
    case context(TextContext, CaretGeometry, midLineEnabled: Bool, minWords: Int = 0)
    case blocked
    case focusLost
    /// An engine result for request `id`, made from `requestContext`. `text` is nil when suppressed.
    case result(id: RequestID, text: String?, requestContext: TextContext)
    /// The start of request `id`'s suggestion while it is still written (whole, checked words).
    /// Only the first one is shown; its `.result` follows and replaces, shortens or hides it.
    case partial(id: RequestID, text: String, requestContext: TextContext)
    case accept(AcceptAction, WordUnitOptions)
    /// The insert the session last asked for finished.
    case insertFinished(success: Bool)
    /// The insert looked successful, but the field never showed `text` (a swallowing input method,
    /// a host that ignored the events): put it back at the front of the ghost.
    case insertLost(String)
    case escape(pauseBriefly: Bool)
    /// Autocorrect took the field to change text behind the caret (the coordinator skips reads
    /// meanwhile). A visible ghost is hidden, but its accept keys stay owned (`holdAccept`) until the
    /// edit is done: a Tab pressed then goes onto the suggestion that follows instead of reaching the
    /// app (where it would move focus). Without a visible ghost this is a plain dismiss.
    case editBehindCaret
    /// A character key reached the app. Ends a hold for an edit behind the caret: the presses queued
    /// before it no longer belong to the next suggestion.
    case characterTyped
    case forceActivate
    case mouseDown
    case secureInputChanged(Bool)
    /// Periodic tick while a ghost is visible; answers whether the arbiter snapshot needs refreshing.
    case republishTick
    /// Option+Down (forward) / Option+Up (backward) on a visible ghost.
    case cycleAlternative(forward: Bool)
    /// Alternatives for request `id` (issued by `.requestAlternatives`), made from `requestContext`.
    case alternatives(id: RequestID, list: [String], requestContext: TextContext)
}

/// Side effects for the coordinator to execute, in order.
public enum SessionCommand: Sendable, Equatable {
    /// Draw the ghost and publish a fresh arbiter snapshot for its field.
    case present(GhostState)
    /// Remove the ghost and publish a nil arbiter snapshot.
    case hide
    /// Re-publish the arbiter snapshot for the visible ghost (keeps it inside the freshness window).
    case republish(GhostState)
    /// Start a (debounced) completion request; it supersedes any older one.
    case request(RequestID, TextContext, refill: Bool)
    case cancelRequest
    /// Insert accepted text. At most one insert is outstanding; the next one follows `insertFinished`.
    case insert(String, app: AppIdentity, urlHost: String?)
    /// The last word was just accepted: keep owning the accept chords for `field` for a short
    /// window (published as a hold-only arbiter snapshot) while the next suggestion loads.
    case holdAccept(field: FieldID, app: AppIdentity, urlHost: String?)
    /// Fetch alternative suggestions for this context (first-token fan-out); answer with
    /// `.alternatives`. Emitted at most once per ghost.
    case requestAlternatives(RequestID, TextContext)
}

/// Pure suggestion state machine (design §3 request lifecycle, §3.4 type-through and refill).
public struct SuggestionSession: Sendable {
    /// Escape's optional pause length.
    public static let escapePause: Duration = .seconds(3)
    /// Refill once fewer than this many acceptance units remain.
    public static let refillBelowWords = 2
    /// How long accept presses are still owned after the last word was accepted (matches the
    /// arbiter's hold freshness, two thirds of its 1.5 s window).
    public static let acceptHold: Duration = .milliseconds(1000)
    /// Accept presses queued during a hold, replayed onto the next suggestion.
    public static let maxPendingAccepts = 2
    /// The most an accept hold for an autocorrect edit lasts before the edit's first read (a model
    /// choice for ambiguous words can take a while).
    public static let editHold: Duration = .milliseconds(3000)

    private struct Track: Sendable {
        var ghost: GhostState
        /// Before-caret text last confirmed by the field (or the request context).
        var anchor: String
        /// Accepted text that the field hasn't reported yet (insert in flight or AX lagging).
        var accepted: String
        /// Set once part of the ghost was accepted or typed through: the alternatives (which belong
        /// to the untouched suggestion at the original caret) are then no longer offered.
        var partial = false
        /// Some of it was accepted with the accept keys (not just typed through).
        var tabbed = false
        var alt = Alternatives()
        /// The request still writing this ghost (it came from `.partial`); nil once finished.
        var streamID: RequestID?
        var visible: Bool { ghost.remaining.contains { !$0.isWhitespace } }
    }

    /// Alternative-cycling state of one untouched ghost.
    private struct Alternatives: Sendable {
        var requestID: RequestID?
        /// Direction of the press made while the alternatives were loading.
        var pendingForward: Bool?
        /// Original ghost text first, then the distinct alternatives.
        var ring: [String] = []
        var index = 0
    }

    private var track: Track?
    private var presented = false
    private var live: (context: TextContext, geometry: CaretGeometry)?
    private var nextRequest: UInt64 = 0
    public private(set) var latestRequestID = RequestID(0)
    /// The newest id this session has handed out, alternatives requests included. Work that borrows
    /// the Language Model's executor (write for me, dictation cleanup) takes this one: the executor
    /// rejects any id below the newest it has seen, and an alternatives request is newer than
    /// `latestRequestID`.
    public var newestRequestID: RequestID { RequestID(nextRequest) }
    /// Results for requests up to here are void (cancelled with `.cancelRequest`).
    private var voidThrough = RequestID(0)
    /// The request whose result made the current ghost: an older late result never replaces it.
    private var shownRequestID = RequestID(0)
    /// Newest request whose final result arrived: its partials are over.
    private var finalThrough = RequestID(0)
    private var refillSignature: UInt64?
    public private(set) var pausedUntil: ContinuousClock.Instant?
    private var insertInFlight = false
    private var insertQueue: [(text: String, app: AppIdentity, urlHost: String?)] = []

    /// Set when the last word of a ghost is accepted. `anchor` is the before-caret text expected once
    /// every accepted insert has landed; any other text means the user moved on. nil while autocorrect
    /// edits behind the caret: the first read after the edit becomes the anchor.
    private struct Hold: Sendable {
        var field: FieldID
        var anchor: String?
        var until: ContinuousClock.Instant
        /// Started for an autocorrect edit (not by accepting the last word).
        var forEdit = false
    }
    private var hold: Hold?
    private var pendingAccepts: [(AcceptAction, WordUnitOptions)] = []

    public init() {}

    /// The ghost currently on screen, if any.
    public var visibleGhost: GhostState? {
        guard presented, let track, track.visible else { return nil }
        return track.ghost
    }

    /// True while a ghost is shown in the field the latest context came from: the arbiter
    /// snapshot must then be kept fresh.
    public var shouldRepublish: Bool {
        guard let ghost = visibleGhost, let live else { return false }
        return live.context.field == ghost.field
    }

    public var hasPendingInsert: Bool { insertInFlight || !insertQueue.isEmpty }

    /// Accepted text the field hasn't shown yet (insert in flight or AX lagging): until it lands, the
    /// field's text before the caret stops short of where the ghost continues.
    public var acceptedTextLanding: Bool { !(track?.accepted.isEmpty ?? true) }

    public mutating func handle(_ event: SessionEvent, now: ContinuousClock.Instant) -> [SessionCommand] {
        switch event {
        case let .context(context, geometry, midLineEnabled, minWords):
            return handleContext(context, geometry, midLineEnabled: midLineEnabled, minWords: minWords, now: now)
        case .blocked, .focusLost:
            live = nil
            return [cancelRequest()] + reset()
        case .secureInputChanged(let on):
            guard on else { return [] }
            live = nil
            return [cancelRequest()] + reset()
        case let .result(id, text, requestContext):
            return handleResult(id: id, text: text, requestContext: requestContext, now: now)
        case let .partial(id, text, requestContext):
            return handlePartial(id: id, text: text, requestContext: requestContext, now: now)
        case let .accept(action, options):
            return accept(action, options: options, now: now)
        case .insertFinished(let success):
            return insertFinished(success: success)
        case .insertLost(let text):
            return restore(lost: text)
        case .escape(let pause):
            if pause { pausedUntil = now + Self.escapePause }
            clearHold()
            return [cancelRequest()] + dropGhost()
        case .editBehindCaret:
            if let ghost = visibleGhost, let live, live.context.field == ghost.field {
                let commands = [cancelRequest()] + dropGhost()
                hold = Hold(field: ghost.field, anchor: nil, until: now + Self.editHold, forEdit: true)
                pendingAccepts = []
                return commands + [.holdAccept(field: ghost.field, app: ghost.app, urlHost: ghost.urlHost)]
            }
            // Already held for this edit (the edit's start is reported twice): keep it.
            if let hold, hold.forEdit, hold.anchor == nil, now <= hold.until {
                return [cancelRequest()] + dropGhost()
            }
            // Fixes one after another: presses waiting from the last one wait for this one too.
            if var hold, hold.forEdit, !pendingAccepts.isEmpty, now <= hold.until,
               live?.context.field == hold.field, let app = live?.context.app {
                hold.anchor = nil
                hold.until = now + Self.editHold
                self.hold = hold
                return [cancelRequest()] + dropGhost()
                    + [.holdAccept(field: hold.field, app: app, urlHost: live?.context.urlHost)]
            }
            clearHold()
            return [cancelRequest()] + dropGhost()
        case .characterTyped:
            if let hold, hold.anchor == nil { clearHold() }
            return []
        case .forceActivate:
            pausedUntil = nil
            guard let live, !live.context.hasMarkedText else { return [] }
            return dropGhost() + [request(live.context, refill: false)]
        case .mouseDown:
            clearHold()
            return dropGhost()
        case .republishTick:
            guard shouldRepublish, let ghost = visibleGhost else { return [] }
            return [.republish(ghost)]
        case .cycleAlternative(let forward):
            return cycle(forward: forward)
        case let .alternatives(id, list, requestContext):
            return handleAlternatives(id: id, list: list, requestContext: requestContext)
        }
    }

    // MARK: Context

    private mutating func handleContext(_ context: TextContext, _ geometry: CaretGeometry, midLineEnabled: Bool,
                                        minWords: Int, now: ContinuousClock.Instant) -> [SessionCommand] {
        var commands: [SessionCommand] = []
        // A context from another field invalidates the ghost and any queued inserts at once.
        if let track, track.ghost.field != context.field {
            commands += reset()
        }
        if var hold {
            if hold.anchor == nil, hold.field == context.field, now <= hold.until {
                // The first read after an autocorrect edit: the presses wait for its suggestion.
                hold.anchor = context.before
                hold.until = now + Self.acceptHold
                self.hold = hold
            } else {
                // Still landing (a prefix of the expected text) keeps the hold; anything else ends it.
                let landing = hold.field == context.field && hold.anchor?.hasPrefix(context.before) == true
                if !landing { clearHold() }
            }
        }

        if context.hasMarkedText || context.selectionLength > 0 || (!context.caretAtLineEnd && !midLineEnabled) {
            live = nil
            return commands + [cancelRequest()] + dropGhost()
        }
        live = (context, geometry)

        if let pausedUntil {
            if now < pausedUntil { return commands + dropGhost() }
            self.pausedUntil = nil
        }

        // Completion, not "what to say": nothing until a couple of words are on the line. Our own
        // accepted text is still landing when the field lags, so that case keeps the ghost.
        if minWords > 0, (track?.accepted.isEmpty ?? true),
           TypedWords.onCurrentLine(context.before, surface: context.metadata.surface) < minWords {
            return commands + [cancelRequest()] + dropGhost()
        }

        guard var current = track else {
            return commands + [request(context, refill: false)]
        }

        let continuation = current.accepted + current.ghost.remaining
        switch AnchorMatcher.match(before: context.before, anchor: current.anchor, continuation: continuation) {
        case .diverged:
            return commands + reset() + [request(context, refill: false)]
        case .extended(let delta):
            current.ghost.geometry = geometry
            current.ghost.caretAtLineEnd = context.caretAtLineEnd
            current.ghost.urlHost = context.urlHost
            if delta.count < current.accepted.count {
                // Our own insert is still landing: keep everything, no request, no hide.
                track = current
                return commands
            }
            let typed = delta.dropFirst(current.accepted.count)
            let progressed = !delta.isEmpty
            current.ghost.remaining = String(current.ghost.remaining.dropFirst(typed.count))
            if !typed.isEmpty { current.partial = true; current.alt = Alternatives() }
            current.anchor = context.before
            current.accepted = ""
            track = current

            guard current.visible else {
                // Exhausted (or dismissed while inserting): start over from here.
                return commands + dropGhost() + [request(context, refill: false)]
            }
            commands.append(.present(current.ghost))
            presented = true
            if progressed, current.streamID == nil, refillSignature != context.contentSignature,
               WordUnits.count(in: current.ghost.remaining, limit: Self.refillBelowWords) < Self.refillBelowWords {
                refillSignature = context.contentSignature
                commands.append(request(context, refill: true))
            }
            return commands
        }
    }

    // MARK: Results

    private mutating func handleResult(id: RequestID, text: String?, requestContext: TextContext,
                                       now: ContinuousClock.Instant) -> [SessionCommand] {
        let finishesStream = track?.streamID == id
        let commands = showResult(id: id, text: text, requestContext: requestContext, now: now)
        // A hold for an edit still running waits for the request made after it.
        guard id == latestRequestID, let hold, hold.anchor != nil else { return commands }
        // The stream whose last word was just taken finished with nothing more: the presses wait for
        // the request made once those words land.
        if finishesStream, commands.isEmpty { return commands }
        // The suggestion the held presses were waiting for: replay them onto it (or drop them when
        // nothing is shown or the hold already expired).
        let replay = (commands.isEmpty || now > hold.until) ? [] : pendingAccepts
        clearHold()
        return replay.reduce(commands) { $0 + accept($1.0, options: $1.1, now: now) }
    }

    private mutating func handlePartial(id: RequestID, text: String, requestContext: TextContext,
                                        now: ContinuousClock.Instant) -> [SessionCommand] {
        guard id == latestRequestID, id > voidThrough, id > finalThrough, let live,
              live.context.field == requestContext.field,
              live.context.contentSignature == requestContext.contentSignature,
              track?.accepted.isEmpty ?? true,
              text.contains(where: { !$0.isWhitespace }) else { return [] }
        if let pausedUntil, now < pausedUntil { return [] }
        // Only the first words stream; the rest arrives with the finished result in one piece
        // (word-by-word growth was distracting). Never replaces another suggestion.
        if let track, track.visible || track.streamID == id { return [] }
        let ghost = GhostState(field: live.context.field, app: live.context.app, urlHost: live.context.urlHost,
                               remaining: text, geometry: live.geometry, caretAtLineEnd: live.context.caretAtLineEnd)
        track = Track(ghost: ghost, anchor: live.context.before, accepted: "", streamID: id)
        shownRequestID = id
        presented = true
        return [.present(ghost)]
    }

    /// The final result for a request whose stream made the visible ghost: it replaces the streamed
    /// text (continuing after whatever was typed through since), or hides it when suppressed or no
    /// longer matching.
    private mutating func finishStream(_ current: Track, text: String?, requestContext: TextContext,
                                       live: (context: TextContext, geometry: CaretGeometry)) -> [SessionCommand] {
        var current = current
        current.streamID = nil
        // Words of the streamed ghost were already accepted with Tab: the user is working
        // through it, so a finished result that doesn't continue it keeps the streamed rest rather
        // than pulling the ghost away mid-accept (the next Tab would reach the app).
        guard let text, text.contains(where: { !$0.isWhitespace }) else { return keepStreamed(current) }
        if !current.accepted.isEmpty {
            // Accepted words are still landing. Every streamed word taken: the finished result's
            // words after them become the ghost (the hold's presses then go onto it).
            if !current.visible {
                let full = requestContext.before + text, taken = current.anchor + current.accepted
                if full.hasPrefix(taken) {
                    let rest = String(full.dropFirst(taken.count))
                    if rest.contains(where: { !$0.isWhitespace }) {
                        current.ghost.remaining = rest
                        current.ghost.geometry = live.geometry
                        track = current
                        presented = true
                        return [.present(current.ghost)]
                    }
                }
            }
            // Otherwise keep the streamed rest; the next context decides.
            track = current
            return []
        }
        let remaining = live.context.contentSignature == requestContext.contentSignature
            ? text : Self.lateRemainder(text, requestContext: requestContext, live: live.context)
        guard let remaining else { return keepStreamed(current) }
        current.ghost.remaining = remaining
        current.ghost.geometry = live.geometry
        current.anchor = live.context.before
        track = current
        presented = true
        return [.present(current.ghost)]
    }

    private mutating func keepStreamed(_ current: Track) -> [SessionCommand] {
        guard current.tabbed, current.visible || !current.accepted.isEmpty else { return dropGhost() }
        track = current
        return []
    }

    private mutating func showResult(id: RequestID, text: String?, requestContext: TextContext,
                                     now: ContinuousClock.Instant) -> [SessionCommand] {
        if id > finalThrough { finalThrough = id }
        if let current = track, current.streamID == id, let live, live.context.field == requestContext.field {
            return finishStream(current, text: text, requestContext: requestContext, live: live)
        }
        guard id > voidThrough, let live,
              live.context.field == requestContext.field,
              track?.accepted.isEmpty ?? true,
              let text, text.contains(where: { !$0.isWhitespace }) else { return [] }
        if let pausedUntil, now < pausedUntil { return [] }
        let remaining: String
        if id == latestRequestID {
            guard live.context.contentSignature == requestContext.contentSignature else { return [] }
            remaining = text
        } else {
            guard let rest = Self.lateRemainder(text, requestContext: requestContext, live: live.context),
                  id > shownRequestID, !(track?.visible ?? false) else { return [] }
            remaining = rest
        }
        let ghost = GhostState(field: live.context.field, app: live.context.app, urlHost: live.context.urlHost,
                               remaining: remaining, geometry: live.geometry, caretAtLineEnd: live.context.caretAtLineEnd)
        track = Track(ghost: ghost, anchor: live.context.before, accepted: "", partial: id != latestRequestID)
        shownRequestID = id
        presented = true
        return [.present(ghost)]
    }

    /// A superseded request's result is still useful when the text typed since its request is the
    /// start of it, like typing through a ghost: the rest of it, or nil.
    static func lateRemainder(_ text: String, requestContext: TextContext, live: TextContext) -> String? {
        guard live.after == requestContext.after, live.selectionLength == 0, !live.hasMarkedText,
              case .extended(let typed) = AnchorMatcher.match(before: live.before, anchor: requestContext.before,
                                                              continuation: text),
              !typed.isEmpty else { return nil }
        let rest = String(text.dropFirst(typed.count))
        return rest.contains(where: { !$0.isWhitespace }) ? rest : nil
    }

    // MARK: Alternatives

    private mutating func cycle(forward: Bool) -> [SessionCommand] {
        guard presented, var current = track, current.visible, !current.partial, current.accepted.isEmpty,
              current.streamID == nil, let live, live.context.field == current.ghost.field else { return [] }
        if current.alt.ring.count > 1 {
            let count = current.alt.ring.count
            current.alt.index = (current.alt.index + (forward ? 1 : count - 1)) % count
            current.ghost.remaining = current.alt.ring[current.alt.index]
            track = current
            return [.present(current.ghost)]
        }
        if current.alt.requestID != nil {
            // Already requested (still loading, or nothing came back): remember one press only.
            if current.alt.ring.isEmpty, current.alt.pendingForward == nil { current.alt.pendingForward = forward }
            track = current
            return []
        }
        nextRequest += 1
        let id = RequestID(nextRequest)
        current.alt.requestID = id
        current.alt.pendingForward = forward
        track = current
        return [.requestAlternatives(id, live.context)]
    }

    private mutating func handleAlternatives(id: RequestID, list: [String], requestContext: TextContext) -> [SessionCommand] {
        guard presented, var current = track, current.visible, !current.partial, current.accepted.isEmpty,
              current.alt.requestID == id, current.alt.ring.isEmpty,
              let live, live.context.field == requestContext.field,
              live.context.contentSignature == requestContext.contentSignature,
              current.ghost.field == requestContext.field else { return [] }
        let forward = current.alt.pendingForward ?? true
        current.alt.pendingForward = nil
        func key(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
        var ring = [current.ghost.remaining]
        var seen: Set<String> = [key(current.ghost.remaining)]
        for text in list where text.contains(where: { !$0.isWhitespace }) && seen.insert(key(text)).inserted {
            ring.append(text)
        }
        guard ring.count > 1 else {
            track = current
            return []
        }
        current.alt.ring = ring
        current.alt.index = forward ? 1 : ring.count - 1
        current.ghost.remaining = ring[current.alt.index]
        track = current
        return [.present(current.ghost)]
    }

    // MARK: Accept and insert

    private mutating func accept(_ action: AcceptAction, options: WordUnitOptions,
                                 now: ContinuousClock.Instant) -> [SessionCommand] {
        guard presented, var current = track, current.visible,
              let live, live.context.field == current.ghost.field else {
            // No ghost yet, but a hold is active: queue the press for the next suggestion.
            if let hold, now <= hold.until, live?.context.field == hold.field,
               pendingAccepts.count < Self.maxPendingAccepts {
                pendingAccepts.append((action, options))
            }
            return []
        }
        let unit = action == .full ? current.ghost.remaining : WordUnits.next(in: current.ghost.remaining, options: options)
        guard !unit.isEmpty else { return [] }
        current.ghost.remaining = String(current.ghost.remaining.dropFirst(unit.count))
        current.accepted += unit
        current.partial = true
        current.tabbed = true
        current.alt = Alternatives()
        track = current

        var commands: [SessionCommand] = []
        if current.visible {
            commands.append(.present(current.ghost))
        } else {
            current.ghost.remaining = ""
            track = current
            commands += hideIfPresented()
            hold = Hold(field: current.ghost.field, anchor: current.anchor + current.accepted,
                        until: now + Self.acceptHold)
            pendingAccepts = []
            commands.append(.holdAccept(field: current.ghost.field, app: current.ghost.app,
                                        urlHost: current.ghost.urlHost))
        }
        insertQueue.append((unit, current.ghost.app, current.ghost.urlHost))
        commands += pumpInsert()
        return commands
    }

    private mutating func insertFinished(success: Bool) -> [SessionCommand] {
        insertInFlight = false
        guard success else {
            // The field won't contain what we expected; drop the ghost and the rest of the queue.
            return reset()
        }
        return pumpInsert()
    }

    /// Puts accepted-but-lost text back in front of the ghost. Only when the session still counts it
    /// as landing (the field hasn't reported anything newer); otherwise it's unclear what happened.
    private mutating func restore(lost text: String) -> [SessionCommand] {
        guard !text.isEmpty, var current = track, current.accepted.hasSuffix(text),
              let live, live.context.field == current.ghost.field else { return [] }
        current.accepted = String(current.accepted.dropLast(text.count))
        current.ghost.remaining = text + current.ghost.remaining
        track = current
        clearHold()
        presented = true
        return [.present(current.ghost)]
    }

    private mutating func pumpInsert() -> [SessionCommand] {
        guard !insertInFlight, !insertQueue.isEmpty else { return [] }
        let next = insertQueue.removeFirst()
        insertInFlight = true
        return [.insert(next.text, app: next.app, urlHost: next.urlHost)]
    }

    // MARK: Helpers

    private mutating func cancelRequest() -> SessionCommand {
        voidThrough = latestRequestID
        return .cancelRequest
    }

    private mutating func request(_ context: TextContext, refill: Bool) -> SessionCommand {
        nextRequest += 1
        latestRequestID = RequestID(nextRequest)
        if !refill { refillSignature = nil }
        return .request(latestRequestID, context, refill: refill)
    }

    private mutating func hideIfPresented() -> [SessionCommand] {
        guard presented else { return [] }
        presented = false
        return [.hide]
    }

    /// Hides the ghost. Tracking survives only while accepted text is still landing.
    private mutating func dropGhost() -> [SessionCommand] {
        if var current = track {
            if current.accepted.isEmpty {
                track = nil
            } else {
                current.ghost.remaining = ""
                track = current
            }
        }
        return hideIfPresented()
    }

    /// Forgets the ghost and queued (not yet started) inserts.
    private mutating func reset() -> [SessionCommand] {
        track = nil
        insertQueue.removeAll()
        refillSignature = nil
        clearHold()
        return hideIfPresented()
    }

    private mutating func clearHold() {
        hold = nil
        pendingAccepts = []
    }

    /// Whether accept presses are currently being held for the next suggestion (for tests and the
    /// coordinator's tap bookkeeping).
    public func isHoldingAccept(now: ContinuousClock.Instant) -> Bool {
        guard let hold else { return false }
        // After an autocorrect edit only presses already waiting count: with none, the next fix
        // needn't wait for the suggestion.
        if hold.forEdit, pendingAccepts.isEmpty { return false }
        return now <= hold.until
    }

    /// An accept hold for an autocorrect edit that hasn't been read back yet: the coordinator keeps
    /// the hold-only arbiter snapshot fresh meanwhile.
    public func isHoldingForEdit(now: ContinuousClock.Instant) -> Bool {
        guard let hold, hold.anchor == nil else { return false }
        return now <= hold.until
    }
}
