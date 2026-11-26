import CoreGraphics
import HunchCore
import HunchScreen
import Observation
import SwiftUI

@MainActor
@Observable
final class ScreenPaneModel {
    @ObservationIgnored private let settings: SettingsModel

    init(settings: SettingsModel) {
        self.settings = settings
    }

    var enabled: Binding<Bool> {
        Binding(get: { self.settings.settings.screenContextEnabled }, set: { self.setEnabled($0) })
    }

    /// Asks for Screen Recording only when the user turns the feature on.
    func setEnabled(_ on: Bool) {
        settings.set(\.screenContextEnabled, to: on)
        if on, !CGPreflightScreenCaptureAccess() {
            ScreenContextProvider.requestPermission()
        }
    }
}
