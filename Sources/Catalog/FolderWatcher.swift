import Foundation
import CoreServices

/// Tells its owner when files that matter to a catalog appear, go or are
/// renamed anywhere under a folder, subfolders included, through FSEvents.
///
/// FSEvents reads the system's own change journal: nothing here opens,
/// lists or polls the folder, so a quiet folder costs nothing, and a
/// volume that sleeps stays asleep. The owner decides what to do about a
/// change; this only filters out what can't matter (see `isRelevant`) and
/// calls `handler` on a private queue, at most once per `latency`.
///
/// The stream is stopped by `stop()` or when the watcher is released.
public final class FolderWatcher: @unchecked Sendable {
    /// What the stream's C callback reaches: retained by the stream while
    /// it runs, so the watcher itself can go at any time.
    private final class Box: @unchecked Sendable {
        let root: String
        let handler: @Sendable () -> Void
        init(root: String, handler: @escaping @Sendable () -> Void) {
            self.root = root
            self.handler = handler
        }
    }

    public let root: URL
    private let queue = DispatchQueue(label: "com.latent.folder-watcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var info: UnsafeMutableRawPointer?

    /// Starts watching `root`. Nil when FSEvents refuses the folder.
    public init?(root: URL, latency: TimeInterval = 0.3, handler: @escaping @Sendable () -> Void) {
        // FSEvents reports real paths (/private/var for /var, say), so the
        // root is compared in the same form. Not `resolvingSymlinksInPath`,
        // which strips /private again.
        let resolved = Self.realPath(root)
        self.root = resolved
        let box = Box(root: resolved.path, handler: handler)
        let info = Unmanaged.passRetained(box).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            for index in 0..<count {
                guard let path = list[index] as? String else { continue }
                if FolderWatcher.isRelevant(path: path, flags: flags[index], root: box.root) {
                    box.handler()
                    return
                }
            }
        }
        let options = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(nil, callback, &context, [resolved.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(options)) else {
            Unmanaged<Box>.fromOpaque(info).release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            Unmanaged<Box>.fromOpaque(info).release()
            return nil
        }
        self.stream = stream
        self.info = info
    }

    deinit { stop() }

    /// The folder's path with every symbolic link resolved, as FSEvents
    /// reports paths under it; the path as given when that fails.
    static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.standardizedFileURL.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Stops the stream; no handler call starts after this returns.
    public func stop() {
        lock.lock()
        let stream = self.stream, info = self.info
        self.stream = nil
        self.info = nil
        lock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // After any callback already running on the queue.
        if let info {
            let address = UInt(bitPattern: info)
            queue.async {
                guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                Unmanaged<Box>.fromOpaque(pointer).release()
            }
        }
    }

    /// Whether an event can change what a catalog of `root` lists.
    ///
    /// Anything inside a `_latent` (or old `_rawhead`) container is
    /// Latent's own bookkeeping: sidecars, thumbnails and the database
    /// change every time a photo is rated, and reacting to them would
    /// rescan after every key press. Hidden names are skipped likewise:
    /// .DS_Store, and the hidden temporary names Latent's own moves and
    /// copies use before a file takes its real name. Of files, only those
    /// reconcile indexes count; a folder counts whatever happened to it,
    /// since a folder moved in or out takes its photos along. When the
    /// system says events were lost, or the folder itself was moved, a
    /// rescan is the only safe answer.
    public static func isRelevant(path: String, flags: FSEventStreamEventFlags, root: String) -> Bool {
        let flags = Int(flags)
        let mustRescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        if flags & mustRescan != 0 { return true }
        // Compared without regard to case: a folder opened under another
        // spelling on a case-insensitive volume is the same folder.
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.count > prefix.count,
              path.prefix(prefix.count).lowercased() == prefix.lowercased() else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/")
        guard let name = parts.last else { return false }
        for part in parts where part.hasPrefix(".") || part == Catalog.containerName || part == Catalog.legacyContainerName {
            return false
        }
        if flags & kFSEventStreamEventFlagItemIsDir != 0 { return true }
        return Catalog.indexedExtensions.contains((String(name) as NSString).pathExtension.lowercased())
    }
}
