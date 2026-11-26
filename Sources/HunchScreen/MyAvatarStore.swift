import Foundation
import HunchCore

/// The writer's own avatars in list chats (Discord), learned from groups holding a message they sent
/// (`ChatSides.assignList`), saved per app (and site) so they survive relaunches. Holds avatar
/// fingerprints and the names read beside them, never message text. A new avatar is learned the next
/// time a sent message shows up under it; old ones drop out by count and age. Main-thread use only.
public final class MyAvatarStore {
    /// Avatars kept per app: several, since each Discord server can show its own (server profile).
    public static let perApp = 8
    /// An avatar not learned again for this long is dropped.
    public static let maxAge: TimeInterval = 180 * 24 * 3600

    private let fileURL: URL?
    private var byApp: [String: [MyAvatar]] = [:]
    /// Called after every change (learned, deleted), for Settings.
    public var onChange: (() -> Void)?

    /// `fileURL` nil keeps everything in memory (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([String: [MyAvatar]].self, from: data) else { return }
        byApp = saved
    }

    public func avatars(app: String, now: Date = Date()) -> [MyAvatar] {
        (byApp[app] ?? []).filter { now.timeIntervalSince($0.learnedAt) <= Self.maxAge }
    }

    /// Adds or refreshes avatars learned on one read. Writes only when something changed.
    public func learn(_ learned: [MyAvatar], app: String, now: Date = Date()) {
        guard !learned.isEmpty else { return }
        var list = avatars(app: app, now: now)
        let before = list
        for entry in learned {
            if let i = list.firstIndex(where: { $0.print.distance(to: entry.print) <= ChatSides.avatarMatch }) {
                var e = list.remove(at: i)
                for n in entry.names where !e.names.contains(n) { e.names.append(n) }
                e.names = Array(e.names.suffix(6))
                // The newest look at the avatar, so a slowly changed picture keeps matching.
                e.print = entry.print
                e.learnedAt = now
                list.append(e)
            } else {
                list.append(MyAvatar(print: entry.print, names: entry.names, learnedAt: now))
            }
        }
        list = Array(list.suffix(Self.perApp))
        guard list != before else { return }
        byApp[app] = list
        write()
    }

    /// Every saved avatar, with its app key (`ScreenContextController.sentKey`), newest first.
    public func all(now: Date = Date()) -> [(app: String, avatar: MyAvatar)] {
        byApp.keys.flatMap { app in avatars(app: app, now: now).map { (app: app, avatar: $0) } }
            .sorted { $0.avatar.learnedAt > $1.avatar.learnedAt }
    }

    /// Forgets one saved avatar.
    public func delete(app: String, print: AvatarPrint) {
        guard let list = byApp[app], list.contains(where: { $0.print == print }) else { return }
        let rest = list.filter { $0.print != print }
        byApp[app] = rest.isEmpty ? nil : rest
        write()
    }

    /// Forgets every saved avatar.
    public func clear() {
        guard !byApp.isEmpty else { return }
        byApp = [:]
        write()
    }

    private func write() {
        onChange?()
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(byApp) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
