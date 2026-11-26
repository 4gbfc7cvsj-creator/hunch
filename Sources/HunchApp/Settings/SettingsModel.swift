import Foundation
import HunchCore
import Observation

/// Observable mirror of the settings store for SwiftUI. Writes go through the store; external
/// changes (other code calling `store.update`) flow back through `changes()`.
@MainActor
@Observable
final class SettingsModel {
    private(set) var settings: HunchSettings
    @ObservationIgnored private let store: any SettingsStoring
    @ObservationIgnored private let onChange: (HunchSettings) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: any SettingsStoring, onChange: @escaping (HunchSettings) -> Void = { _ in }) {
        self.store = store
        self.settings = store.current()
        self.onChange = onChange
        let stream = store.changes()
        task = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                if value != self.settings { self.settings = value }
            }
        }
    }

    deinit { task?.cancel() }

    func set<V: Sendable>(_ keyPath: WritableKeyPath<HunchSettings, V> & Sendable, to value: V) {
        try? store.update { $0[keyPath: keyPath] = value }
        let fresh = store.current()
        if fresh != settings { settings = fresh }
        onChange(fresh)
    }
}

import SwiftUI

extension SettingsModel {
    func bind<V: Sendable>(_ keyPath: WritableKeyPath<HunchSettings, V> & Sendable) -> Binding<V> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { self.set(keyPath, to: $0) })
    }
}
