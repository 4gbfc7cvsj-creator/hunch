import AppKit
import HunchCore
import HunchModels
import SwiftUI

// MARK: Welcome + models

/// The first page: what Hunch is, then one pick per model kind. Continue starts the downloads.
struct WelcomePage: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 18) {
            PageHeader(
                art: .appIcon, title: "Welcome to Hunch",
                message: "Hunch predicts what you\u{2019}ll type next, polishes your drafts and turns speech "
                    + "into text, in almost any app. It runs on AI models on this Mac, so nothing you type or say "
                    + "leaves it. Choose the models to download to get started.")
            HStack(alignment: .top, spacing: 14) {
                ModelPickSection(
                    title: "Language model", symbol: "text.cursor",
                    caption: "Typing and writing") {
                    if let own = model.currentOwnModel {
                        PickRow(selected: model.languagePick == OnboardingModel.currentModelPick,
                                name: own.name, badge: false, trailing: .text("In use")) {
                            model.languagePick = OnboardingModel.currentModelPick
                        }
                        Divider().padding(.leading, 38)
                    }
                    rows(model.languageRows, pick: $model.languagePick)
                }
                ModelPickSection(
                    title: "Speech to text", symbol: "mic",
                    caption: "Dictation, optional") {
                    rows(model.speechRows, pick: $model.speechPick)
                    Divider().padding(.leading, 38)
                    PickRow(selected: model.speechPick == nil, name: "Not now", badge: false, trailing: .none) {
                        model.speechPick = nil
                    }
                }
            }
            folderLine
        }
        .onAppear { model.preparePicks() }
    }

    @ViewBuilder
    private func rows(_ rows: [CatalogRow], pick: Binding<String?>) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { Divider().padding(.leading, 38) }
            PickRow(selected: pick.wrappedValue == row.id, name: row.name, badge: row.isRecommended,
                    trailing: trailing(row)) {
                pick.wrappedValue = row.id
            }
        }
    }

    private func trailing(_ row: CatalogRow) -> PickRow.Trailing {
        switch row.state {
        case .available: .text(row.size)
        case .downloaded: .text("On this Mac")
        case .downloading(let fraction, _): .progress(fraction)
        case .failed: .retry { model.models.download(row.id) }
        }
    }

    private var folderLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text("Saved in \(Self.abbreviated(model.models.folderPath ?? AppDelegate.defaultModelsFolder.path))")
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Button("Change\u{2026}") { model.chooseFolder() }.buttonStyle(.link)
            Spacer()
            Text("Downloaded from \(ModelCatalog.host)").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }

    static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// A titled card of model rows.
private struct ModelPickSection<Rows: View>: View {
    let title: String
    let symbol: String
    let caption: String
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Spacer()
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            TourCard { rows }
        }
    }
}

/// One choice in a model card: a radio mark, the name (with the Recommended badge) and its state.
private struct PickRow: View {
    enum Trailing {
        case none
        case text(String)
        case progress(Double)
        case retry(() -> Void)
    }

    let selected: Bool
    let name: String
    let badge: Bool
    let trailing: Trailing
    let pick: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).lineLimit(1)
                        if badge {
                            Text("Recommended").font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            switch trailing {
            case .none:
                EmptyView()
            case .text(let text):
                Text(text).foregroundStyle(.secondary).monospacedDigit()
            case .progress(let fraction):
                ProgressView(value: fraction).frame(width: 44)
                Text("\(Int((fraction * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
            case .retry(let retry):
                Text("Failed").foregroundStyle(.red)
                Button("Retry", action: retry).controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .font(.callout)
    }
}

// MARK: Permissions

struct PermissionsPage: View {
    let permissions: PermissionsModel

    var body: some View {
        VStack(spacing: 22) {
            PageHeader(
                art: .symbol("hand.raised"), title: "Allow Hunch to help",
                message: "Hunch needs to read the text around your cursor and see the keys you use to accept "
                    + "suggestions. Everything stays on this Mac.")
            TourCard {
                ForEach(Array(PermissionsModel.Kind.tourKinds.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Divider().padding(.leading, 44) }
                    row(kind)
                }
            }
            Text("Continue unlocks once Accessibility and Input Monitoring are on. macOS may ask you to reopen Hunch.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func row(_ kind: PermissionsModel.Kind) -> some View {
        let granted = permissions.isGranted(kind)
        let required = kind == .accessibility || kind == .inputMonitoring
        return HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : (required ? "circle" : "circle.dashed"))
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 20)
                .accessibilityLabel(granted ? "Granted" : "Not granted")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.title)
                    Text(required ? "Required" : "Optional")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
                Text(Self.caption(kind)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                if permissions.requested.contains(kind) {
                    Button("Open Settings") { permissions.openSystemSettings(kind) }.buttonStyle(.link)
                }
                Button("Allow\u{2026}") { permissions.request(kind) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Captions without the "Optional:" prefix (the badge says it).
    static func caption(_ kind: PermissionsModel.Kind) -> String {
        switch kind {
        case .accessibility: "Read the text you\u{2019}re typing and where the cursor is."
        case .inputMonitoring: "See Tab and the other shortcuts that accept suggestions."
        case .screenRecording: "Read text near the cursor for better suggestions (Screen Awareness)."
        case .microphone: "Hear you while you dictate."
        }
    }
}

// MARK: Open at login

/// The Startup section's toggle without its header.
struct LoginItemPage: View {
    @State private var model = LoginItemModel()

    var body: some View {
        VStack(spacing: 22) {
            PageHeader(
                art: .symbol("menubar.arrow.up.rectangle"), title: "Always ready",
                message: "Hunch lives in the menu bar. Open it at login so it\u{2019}s there whenever you type. "
                    + "Next, a quick look at what it can do.")
            TourCard {
                Toggle(isOn: Binding(get: { model.isOn }, set: { model.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Hunch at login")
                        Text("You can change this in Settings \u{2192} General.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .frame(maxWidth: 440)
            if model.needsApproval {
                VStack(spacing: 6) {
                    Text("Approve Hunch in System Settings \u{2192} General \u{2192} Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") { model.openLoginItems() }
                }
            }
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
        }
    }
}
