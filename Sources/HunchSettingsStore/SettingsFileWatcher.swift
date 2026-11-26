import Darwin
import Foundation

/// Watches one file for changes made by other processes, using DispatchSource vnode sources.
///
/// Two sources: one on the file itself (in-place writes) and one on its directory (creation,
/// deletion, and atomic replaces, where an editor writes a temporary file and renames it over the
/// original). When the file is deleted, renamed, or replaced, the file source is re-armed on
/// whatever now lives at the path. `onChange` runs on a private serial queue; it may fire several
/// times per save and for the owner's own writes, so it must be idempotent.
final class SettingsFileWatcher: @unchecked Sendable {
    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "Hunch.SettingsFileWatcher")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let fileURL: URL
    private let onChange: @Sendable () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedInode: ino_t?
    private var watchedDirectoryInode: ino_t?
    /// Polls for the settings folder to come back after it was deleted or renamed away.
    private var retryTimer: DispatchSourceTimer?
    private var stopped = false

    init(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    func start() {
        onQueue {
            guard !stopped else { return }
            armDirectory()
            armFileIfNeeded()
        }
    }

    /// Safe from any thread, including from inside `onChange`.
    func stop() {
        onQueue {
            stopped = true
            directorySource?.cancel()
            directorySource = nil
            retryTimer?.cancel()
            retryTimer = nil
            disarmFile()
        }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
    }

    // MARK: Queue-confined

    private func armDirectory() {
        let fd = open(fileURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleDirectoryRetry()
            return
        }
        var opened = stat()
        watchedDirectoryInode = fstat(fd, &opened) == 0 ? opened.st_ino : nil
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .link, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak self] in self?.directoryChanged() }
        source.setCancelHandler { close(fd) }
        directorySource = source
        source.resume()
    }

    private func directoryChanged() {
        guard !stopped else { return }
        var st = stat()
        let dirPath = fileURL.deletingLastPathComponent().path
        if stat(dirPath, &st) != 0 || st.st_ino != watchedDirectoryInode {
            // The folder itself was deleted or replaced: our descriptor points at a dead directory.
            directorySource?.cancel()
            directorySource = nil
            disarmFile()
            armDirectory()  // re-arms at once if a new folder is already there, else starts polling
            armFileIfNeeded()
        } else {
            armFileIfNeeded()
        }
        onChange()
    }

    private func scheduleDirectoryRetry() {
        guard retryTimer == nil, !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            guard access(self.fileURL.deletingLastPathComponent().path, F_OK) == 0 else { return }
            self.retryTimer?.cancel()
            self.retryTimer = nil
            self.armDirectory()
            self.armFileIfNeeded()
            self.onChange()
        }
        retryTimer = timer
        timer.resume()
    }

    /// Points the file source at the file currently at the path, if that's a different file.
    private func armFileIfNeeded() {
        var st = stat()
        let exists = stat(fileURL.path, &st) == 0
        if exists, fileSource != nil, watchedInode == st.st_ino { return }
        disarmFile()
        guard exists else { return }
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.fileChanged(source.data)
        }
        source.setCancelHandler { close(fd) }
        fileSource = source
        var opened = stat()
        watchedInode = fstat(fd, &opened) == 0 ? opened.st_ino : st.st_ino
        source.resume()
    }

    private func fileChanged(_ events: DispatchSource.FileSystemEvent) {
        guard !stopped else { return }
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            // The watched inode is gone from the path (atomic replace or delete): follow the path.
            disarmFile()
            armFileIfNeeded()
        }
        onChange()
    }

    private func disarmFile() {
        fileSource?.cancel()
        fileSource = nil
        watchedInode = nil
    }
}
