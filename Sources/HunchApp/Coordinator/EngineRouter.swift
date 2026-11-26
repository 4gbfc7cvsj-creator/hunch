import Foundation
import HunchCore
import HunchEndpoint
import HunchModels
import HunchPolicy

/// Picks the engine for each request. Each model use (autocomplete, writing, speech to text) has
/// its own source: the local model from `ModelController`, or its own endpoint, rebuilt whenever
/// that endpoint's configuration changes. An endpoint that fails is skipped for
/// `EndpointHealth.retryAfter`; meanwhile requests go to a local model of the same use.
@MainActor
final class EngineRouter {
    /// One use's endpoint: its config, its engine, and whether it is answering.
    final class Slot {
        fileprivate(set) var config: EndpointConfig?
        fileprivate(set) var engine: EndpointCompletionEngine?
        /// Why the configured endpoint can't be used (invalid URL or a disallowed host), if it can't.
        fileprivate(set) var problem: String?
        fileprivate(set) var source: EngineKind = .local
        fileprivate var health = EndpointHealth()

        /// The source is the endpoint and it is configured, whether or not it is answering.
        var selected: Bool { source == .endpoint && engine != nil }
        /// The endpoint to use now: selected, and not inside a failure's cooldown.
        var available: EndpointCompletionEngine? { selected && health.isAvailable() ? engine : nil }
        /// Selected but skipped after a failure.
        var unavailable: Bool { selected && !health.isAvailable() }
    }

    private let models: ModelController
    private var slots: [ModelUse: Slot] = Dictionary(uniqueKeysWithValues: ModelUse.allCases.map { ($0, Slot()) })
    /// Called when an endpoint starts or stops being skipped (for the menu bar status).
    var onAvailabilityChange: (() -> Void)?

    init(models: ModelController) {
        self.models = models
    }

    func slot(_ use: ModelUse) -> Slot { slots[use]! }

    func apply(settings: HunchSettings) {
        apply(.autocomplete, source: settings.engine, config: settings.endpoint)
        apply(.writing, source: settings.writeEngine, config: settings.writeEndpoint)
        apply(.speechToText, source: settings.speechEngine, config: settings.speechEndpoint)
    }

    private func apply(_ use: ModelUse, source: EngineKind, config: EndpointConfig?) {
        let slot = slot(use)
        if source != slot.source, slot.source == .endpoint {
            // Switching away from the endpoint: stop its in-flight streams. (Its cancellation only
            // affects requests already running, so per-app endpoint overrides keep working.)
            Self.cancelInFlight(slot.engine)
        }
        slot.source = source
        guard config != slot.config else { return }
        slot.config = config
        // The old engine is dropped; make sure nothing it started keeps streaming.
        Self.cancelInFlight(slot.engine)
        slot.engine?.shutdown()
        slot.engine = nil
        slot.problem = nil
        slot.health = EndpointHealth()
        guard let config else { return }
        do {
            try EndpointURLPolicy.validate(config.baseURL, allowNonLoopback: config.allowNonLoopback)
            slot.engine = EndpointCompletionEngine(config: config)
        } catch {
            slot.problem = error.localizedDescription
        }
    }

    // MARK: Health

    /// A request to `use`'s endpoint failed (not cancelled): skip it for a while.
    func noteFailure(_ use: ModelUse) {
        let slot = slot(use)
        let wasAvailable = slot.health.isAvailable()
        slot.health.markFailed()
        if wasAvailable { onAvailabilityChange?() }
        // Tell the status when the cooldown ends, so it doesn't keep saying "unavailable".
        Task { [weak self] in
            try? await Task.sleep(for: EndpointHealth.retryAfter)
            self?.onAvailabilityChange?()
        }
    }

    func noteSuccess(_ use: ModelUse) {
        let slot = slot(use)
        guard slot.health.failedAt != nil else { return }
        slot.health.markSucceeded()
        onAvailabilityChange?()
    }

    // MARK: Autocomplete

    /// The engine kind an autocomplete request with this policy would use now.
    func kind(for policy: AppPolicy) -> EngineKind {
        let slot = slot(.autocomplete)
        return EngineSelection.kind(globalEngine: slot.source, endpointConfigured: slot.available != nil,
                                    appOverride: policy.engineOverride)
    }

    func engine(for policy: AppPolicy) -> (any CompletionEngine)? {
        switch kind(for: policy) {
        case .endpoint:
            guard let endpoint = slot(.autocomplete).available else { return nil }
            return ReportingEngine(base: endpoint) { [weak self] ok in
                Task { @MainActor in ok ? self?.noteSuccess(.autocomplete) : self?.noteFailure(.autocomplete) }
            }
        case .local:
            // Loading is deferred while the endpoint serves everything; a local request (or the
            // endpoint failing) wakes it.
            if models.engine == nil { models.loadOnDemand() }
            return models.engine
        }
    }

    /// Cancels every request the endpoint engine has in flight. Not used for the local engine: its
    /// executor treats `cancel(olderThan:)` as a watermark, so `.max` would reject all later
    /// requests; the coordinator's per-request cancellation covers it instead.
    private static func cancelInFlight(_ engine: EndpointCompletionEngine?) {
        engine?.cancel(olderThan: RequestID(.max))
    }

    /// True when autocomplete's choice is the endpoint and it is usable now.
    var usesEndpointGlobally: Bool { slot(.autocomplete).available != nil }
    /// Autocomplete's endpoint, for callers that need the configured engine itself.
    var endpointEngine: EndpointCompletionEngine? { slot(.autocomplete).engine }
    var endpointProblem: String? { slot(.autocomplete).problem }
}

/// An endpoint engine that reports whether each request worked (cancellations count as neither).
private struct ReportingEngine: CompletionEngine {
    let base: EndpointCompletionEngine
    let report: @Sendable (Bool) -> Void

    var kind: EngineKind { base.kind }

    func complete(_ request: CompletionRequest,
                  partial: @escaping @Sendable (String) -> Void) async throws -> CompletionResult {
        do {
            let result = try await base.complete(request, partial: partial)
            report(true)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !Task.isCancelled { report(false) }
            throw error
        }
    }

    func prewarm(_ request: CompletionRequest) async { await base.prewarm(request) }
    func cancel(olderThan id: RequestID) { base.cancel(olderThan: id) }
}
