import AppKit
import HunchCore
import HunchScreen
import Observation
import SwiftUI

/// The saved chat avatars (`MyAvatarStore`) as Settings shows them.
@MainActor
@Observable
final class ChatAvatarsPaneState {
    static let shared = ChatAvatarsPaneState()

    struct Row: Identifiable {
        var app: String
        var avatar: MyAvatar
        var id: String { app + "|" + avatar.print.cells.map(String.init).joined(separator: ",") }
    }

    private(set) var rows: [Row] = []
    private(set) var store: MyAvatarStore?

    func attach(_ store: MyAvatarStore) {
        self.store = store
        reload()
        store.onChange = { [weak self] in self?.reload() }
    }

    func reload() {
        rows = store?.all().map { Row(app: $0.app, avatar: $0.avatar) } ?? []
    }
}

/// "Chat avatars" in Learned data: the writer's own avatars learned in Discord, each drawn from its
/// fingerprint, with the names read beside it; delete one or all.
struct ChatAvatarsEditor: View {
    private let state = ChatAvatarsPaneState.shared
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(state.rows) {
                TableColumn("") { row in AvatarSwatch(print: row.avatar.print) }.width(34)
                TableColumn("App") { row in Text(Self.appName(row.app)) }.width(110)
                TableColumn("Name beside it") { row in
                    Text(Self.names(row.avatar.names)).foregroundStyle(.secondary)
                }
                TableColumn("Learned") { row in
                    Text(row.avatar.learnedAt, format: .relative(presentation: .named))
                }.width(110)
                TableColumn("") { row in
                    Button(role: .destructive) { state.store?.delete(app: row.app, print: row.avatar.print) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this avatar")
                }.width(30)
            }
            .frame(height: 160)
            HStack {
                Button("Delete All\u{2026}", role: .destructive) { confirmDeleteAll = true }
                    .disabled(state.rows.isEmpty)
                    .confirmationDialog("Delete all learned chat avatars?", isPresented: $confirmDeleteAll) {
                        Button("Delete All", role: .destructive) { state.store?.clear() }
                    } message: {
                        Text("Your messages in Discord stay unlabeled until you send one again. This can't be undone.")
                    }
            }
            Text("In Discord everyone's messages sit on the left, so Hunch tells yours apart by your avatar: "
                 + "when a message you sent shows up on screen, a small color sample of the avatar beside it is "
                 + "saved (never the picture or your messages). Only with Screen awareness and Learn from my writing on. Each server "
                 + "avatar is learned the first time you send a message in that server.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { state.reload() }
    }

    /// "Discord" for `com.hnc.Discord|discord.com`, the site for a browser key.
    static func appName(_ key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        if let id = parts.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            let app = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            if ChatSides.isListChat(bundleID: id) || parts.count == 1 { return app }
            return app + " · " + parts[1]
        }
        return parts.last ?? key
    }

    static func names(_ names: [String]) -> String {
        let read = names.filter { !$0.isEmpty }
        if read.isEmpty { return "not readable" }
        return read.joined(separator: ", ") + (read.count < names.count ? ", sometimes not readable" : "")
    }
}

/// The fingerprint's colored squares, in a circle as Discord draws avatars.
private struct AvatarSwatch: View {
    let print: AvatarPrint

    var body: some View {
        Canvas { context, size in
            let n = AvatarPrint.side
            guard print.cells.count == n * n * 3 else { return }
            let cell = size.width / CGFloat(n)
            context.clip(to: Path(ellipseIn: CGRect(origin: .zero, size: size)))
            for i in 0..<(n * n) {
                let c = print.cells[(i * 3)..<(i * 3 + 3)].map { Double($0) / 255 }
                let rect = CGRect(x: CGFloat(i % n) * cell, y: CGFloat(i / n) * cell, width: cell + 0.5, height: cell + 0.5)
                context.fill(Path(rect), with: .color(Color(red: c[0], green: c[1], blue: c[2])))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel("Avatar color sample")
    }
}
