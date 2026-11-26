import CoreGraphics
import Foundation
import HunchCore
import HunchPolicy
import HunchScreen
import HunchText

/// Opt-in screen context (track S) for the focused field. Fetches an excerpt when a field gains
/// focus and after typing pauses for `ScreenContextDecision.typingPause`, always with a FRESH gate
/// pass from the focus tracker. Requests never wait for OCR: they take the latest cached excerpt
/// for their field. Only one excerpt (for the current field) is held; it is dropped on focus loss.
@MainActor
final class ScreenContextController {
    /// Enough for the whole field column of a large window; the framer's token budget decides how
    /// much of it (newest lines, just above the field, first) actually reaches the prompt.
    static let maxCharacters = 16_000

    private let provider: ScreenContextProvider
    private let freshPass: @Sendable (FieldID) async -> SecureGatePass?
    private let settings: () -> HunchSettings

    private var context: TextContext?
    private var geometry: CaretGeometry?
    private var policy = AppPolicy.default
    private var cache: (field: FieldID, excerpt: ScreenExcerpt)?
    private var lastActivity = ContinuousClock.now
    private var pauseTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var fetchGeneration: UInt64 = 0
    /// The system dictionary's verdict on a lowercase word, for `ScreenWords` (set by the app).
    var isMisspelled: (@Sendable (String) -> Bool)?
    /// Distinctive words of the cached excerpt, built once per excerpt (never per key press).
    private var wordsCache: (signature: UInt64, capturedAt: ContinuousClock.Instant, words: ScreenWords)?
    /// The writer's sent messages per app, in memory only: speaker evidence for chat screens.
    private var sent = SentMessages()
    /// A message was just sent from `context`'s box: its text and the screen text it answered (the
    /// latest usable read of that box, from before it was sent), for learned replies.
    var onSent: (@MainActor (_ text: String, _ context: TextContext, _ screen: String?) -> Void)?

    /// The writer's avatars in list chats (Discord), learned from their sent messages, saved.
    private let myAvatars: MyAvatarStore

    init(provider: ScreenContextProvider, freshPass: @escaping @Sendable (FieldID) async -> SecureGatePass?,
         settings: @escaping () -> HunchSettings, myAvatars: MyAvatarStore) {
        self.myAvatars = myAvatars
        self.provider = provider
        self.freshPass = freshPass
        self.settings = settings
    }

    /// Sent messages are kept per app, and per site in a browser.
    static func sentKey(_ context: TextContext) -> String {
        context.app.bundleID + (context.urlHost.map { "|" + $0 } ?? "")
    }

    /// The app's sent messages (for a fresh screen read elsewhere, such as suggested replies).
    func sentMessages(for context: TextContext) -> [String] { sent.messages(app: Self.sentKey(context)) }

    private var globallyEnabled: Bool {
        let s = settings()
        return s.enabled && s.screenContextEnabled
    }

    // MARK: Inputs (from the suggestion coordinator)

    /// A gated context arrived (focus or a change in the same field).
    func noteContext(_ context: TextContext, geometry: CaretGeometry, policy: AppPolicy) {
        let isNewField = self.context?.field != context.field
        if let message = sent.note(app: Self.sentKey(context), field: context.field,
                                   text: context.looksEmpty ? "" : context.before + context.after) {
            onSent?(message, context, excerptText(for: context.field, policy: policy))
        }
        self.context = context
        self.geometry = geometry
        self.policy = policy
        guard globallyEnabled else { return clear() }
        if isNewField {
            cache = nil
            wordsCache = nil
            fetchTask?.cancel()
            fetchTask = nil
            fetch(.fieldFocused)
        } else {
            schedulePauseCheck()
        }
    }

    func noteTyping() {
        lastActivity = .now
        if context != nil { schedulePauseCheck() }
    }

    /// Focus lost or blocked: forget the field and its excerpt.
    func focusEnded() {
        sent.focusEnded()
        context = nil
        geometry = nil
        clear()
    }

    /// Feature turned off: drop everything.
    func clear() {
        cache = nil
        wordsCache = nil
        pauseTask?.cancel()
        pauseTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        let provider = self.provider
        Task { await provider.purge() }
    }

    /// Interface lines left out of the latest usable excerpt for `field` (diagnostics).
    func excerptInterfaceDropped(for field: FieldID, policy: AppPolicy) -> Int {
        ScreenContextDecision.usableExcerpt(cachedField: cache?.field, excerpt: cache?.excerpt, field: field,
                                            globallyEnabled: globallyEnabled, policy: policy)?.interfaceDropped ?? 0
    }

    /// The latest usable excerpt text for `field`, or nil. Never waits.
    func excerptText(for field: FieldID, policy: AppPolicy) -> String? {
        ScreenContextDecision.usableExcerpt(cachedField: cache?.field, excerpt: cache?.excerpt, field: field,
                                            globallyEnabled: globallyEnabled, policy: policy)?.text
    }

    /// Suggested replies: the excerpt for `field` when it is at most `maxAge` old, else a fresh one
    /// fetched now (waiting at most `timeout`). Nil under the same gates as `excerptText`.
    func freshExcerptText(for field: FieldID, policy: AppPolicy, maxAge: Duration,
                          timeout: Duration) async -> String? {
        await freshExcerpt(for: field, policy: policy, maxAge: maxAge, timeout: timeout)?.text
    }

    /// A screen read for suggested replies and how it was got, for the diagnostic console.
    struct FreshRead {
        var text: String
        /// Read now (false: the cached read was recent enough).
        var fetched: Bool
        /// How old the read was when handed over.
        var age: Duration
        /// Time spent waiting for it.
        var waited: Duration
        /// Speaker evidence from sent messages: remembered for this app, blocks they confirmed as
        /// "Me", and blocks whose "Me" label they took away (nil when unknown, as for a re-ask).
        var sent: (remembered: Int, confirmed: Int, vetoed: Int)? = nil
    }

    /// `freshExcerptText` with how the read was got.
    func freshExcerpt(for field: FieldID, policy: AppPolicy, maxAge: Duration, timeout: Duration) async -> FreshRead? {
        let started = ContinuousClock.now
        func read(fetched: Bool) -> FreshRead? {
            guard let cache, let text = excerptText(for: field, policy: policy) else { return nil }
            let now = ContinuousClock.now
            let remembered = context.map { sent.messages(app: Self.sentKey($0)).count } ?? 0
            return FreshRead(text: text, fetched: fetched, age: now - cache.excerpt.capturedAt, waited: now - started,
                             sent: (remembered, cache.excerpt.sentConfirmed, cache.excerpt.sentVetoed))
        }
        if let cache, cache.field == field, ContinuousClock.now - cache.excerpt.capturedAt <= maxAge {
            return read(fetched: false)
        }
        if fetchTask == nil, context?.field == field { fetch(.fieldFocused) }
        let deadline = ContinuousClock.now + timeout
        while fetchTask != nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard let cache, cache.field == field, ContinuousClock.now - cache.excerpt.capturedAt <= maxAge + timeout
        else { return nil }
        return read(fetched: true)
    }

    /// The distinctive words on screen for `field`, empty unless the same gates as `excerptText` hold
    /// (global switch, the app's "Allow screen context", fresh excerpt). Cached per excerpt.
    func screenWords(for field: FieldID, policy: AppPolicy) -> ScreenWords {
        guard let isMisspelled,
              let excerpt = ScreenContextDecision.usableExcerpt(
                  cachedField: cache?.field, excerpt: cache?.excerpt, field: field,
                  globallyEnabled: globallyEnabled, policy: policy)
        else { return .empty }
        if let c = wordsCache, c.signature == excerpt.signature, c.capturedAt == excerpt.capturedAt { return c.words }
        let words = ScreenWords(text: excerpt.text, isMisspelled: isMisspelled)
        wordsCache = (excerpt.signature, excerpt.capturedAt, words)
        return words
    }

    // MARK: Fetching

    private func schedulePauseCheck() {
        lastActivity = .now
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: ScreenContextDecision.typingPause)
            guard !Task.isCancelled, let self else { return }
            self.fetch(.typingPaused(ContinuousClock.now - self.lastActivity))
        }
    }

    private func fetch(_ trigger: ScreenContextDecision.Trigger) {
        guard fetchTask == nil, let context, let geometry,
              ScreenContextDecision.shouldFetch(globallyEnabled: globallyEnabled, policy: policy,
                                                permitted: provider.isPermitted(), trigger: trigger)
        else { return }
        let field = context.field
        let provider = self.provider
        let freshPass = self.freshPass
        let sentMessages = sent.messages(app: Self.sentKey(context))
        let listChat = ChatSides.isListChat(bundleID: context.app.bundleID, urlHost: context.urlHost)
        let avatarKey = Self.sentKey(context)
        let mine = listChat ? myAvatars.avatars(app: avatarKey) : []
        fetchGeneration &+= 1
        let generation = fetchGeneration
        fetchTask = Task { [weak self] in
            defer { if self?.fetchGeneration == generation { self?.fetchTask = nil } }
            // A pass minted just now on the AX thread for the still-focused field; nil → no capture.
            guard let pass = await freshPass(field), !Task.isCancelled else { return }
            // Geometry arrives in AppKit coordinates; capture and OCR work in the global top-left
            // space that ScreenCaptureKit uses.
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            let flip = { (r: CGRect) in CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
            let excerpt = await provider.excerpt(
                app: context.app, fieldFrame: geometry.fieldFrame.map(flip), caretRect: flip(geometry.caretRect),
                pass: pass,
                maxCharacters: Self.maxCharacters, fieldBefore: context.before, fieldAfter: context.after,
                chatSides: ChatSides.applies(surface: context.metadata.surface, bundleID: context.app.bundleID,
                                               urlHost: context.urlHost),
                bubbleApp: ChatSides.isBubbleApp(bundleID: context.app.bundleID, urlHost: context.urlHost),
                sentMessages: sentMessages,
                senderNames: ChatSides.hasSenderNames(surface: context.metadata.surface, bundleID: context.app.bundleID,
                                                      urlHost: context.urlHost),
                listChat: listChat, myAvatars: mine)
            guard let self else { return }
            // Like the rest of Learned data, new avatars are saved only with Learn from my writing on.
            if let learned = excerpt?.learnedAvatars, !learned.isEmpty, self.settings().learning.enabled {
                self.myAvatars.learn(learned, app: avatarKey)
            }
            guard !Task.isCancelled, self.context?.field == field, self.globallyEnabled else { return }
            if let excerpt { self.cache = (field, excerpt) }
        }
    }
}
