import AppKit
import CoreServices
import Foundation

/// FSEvents stream on a directory. Does not keep the volume busy, so ejecting still works.
final class FSEventsWatcher: @unchecked Sendable {
    private final class Box { let handler: @Sendable () -> Void; init(_ h: @escaping @Sendable () -> Void) { handler = h } }
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "hunch.models.fsevents")

    init?(path: String, latency: TimeInterval = 0.3, handler: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(handler))
        var ctx = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil,
                                       release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } },
                                       copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().handler()
        }
        let flags = UInt32(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            box.release()
            return nil
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        if !FSEventStreamStart(s) {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            return nil
        }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

enum VolumeEvent: Sendable { case didMount, didUnmount, willUnmount(volumePath: String?), didRename }

/// Forwards NSWorkspace mount notifications. Removes its observers on deinit.
final class WorkspaceVolumeObserver: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    init(handler: @escaping @Sendable (VolumeEvent) -> Void) {
        let nc = NSWorkspace.shared.notificationCenter
        func add(_ name: Notification.Name, _ make: @escaping @Sendable (Notification) -> VolumeEvent) {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: nil) { handler(make($0)) })
        }
        add(NSWorkspace.didMountNotification) { _ in .didMount }
        add(NSWorkspace.didUnmountNotification) { _ in .didUnmount }
        add(NSWorkspace.didRenameVolumeNotification) { _ in .didRename }
        add(NSWorkspace.willUnmountNotification) {
            .willUnmount(volumePath: ($0.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path)
        }
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.forEach { nc.removeObserver($0) }
    }
}
