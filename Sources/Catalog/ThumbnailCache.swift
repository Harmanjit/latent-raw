import Foundation
import GRDB

/// How thumbnails are made, from Settings › Performance. The defaults are
/// what Latent always did: HEIC at 0.8, four files at a time at utility
/// priority (the efficiency cores, DESIGN.md §11).
public struct ThumbnailGenerationSettings: Equatable, Sendable {
    /// The HEIC quality thumbnails are written at. Applies to thumbnails
    /// made from now on; Rebuild Thumbnails remakes existing ones.
    public enum Quality: String, CaseIterable, Sendable, Identifiable {
        case low, standard, high

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .low: "Low"
            case .standard: "Standard"
            case .high: "High"
            }
        }
        public var heicQuality: Double {
            switch self {
            case .low: 0.6
            case .standard: Thumbnailer.defaultQuality
            case .high: 0.92
            }
        }
    }

    /// How hard background thumbnail generation works, against how much of
    /// the Mac it leaves to everything else.
    public enum Priority: String, CaseIterable, Sendable, Identifiable {
        case low, normal, high

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .low: "Low"
            case .normal: "Normal"
            case .high: "High"
            }
        }
        public var taskPriority: TaskPriority {
            switch self {
            case .low: .background
            case .normal: .utility
            case .high: .userInitiated
            }
        }
        /// Files made at once. High leaves two cores for the window and the
        /// grid's own decoding, as the thumbnail loader does.
        public func concurrency(activeProcessors: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
            switch self {
            case .low: 2
            case .normal: 4
            case .high: max(4, activeProcessors - 2)
            }
        }
    }

    public var quality: Quality = .standard
    public var priority: Priority = .normal

    public init(quality: Quality = .standard, priority: Priority = .normal) {
        self.quality = quality
        self.priority = priority
    }
}

/// What the open catalog's thumbnail folder holds on disk.
public struct ThumbnailCacheUsage: Equatable, Sendable {
    public var files = 0
    public var bytes: Int64 = 0
    /// Files no image of the catalog will read again: left by a crash, an
    /// interrupted write, or a subfolder that became a catalog of its own.
    public var orphanFiles = 0
    public var orphanBytes: Int64 = 0

    public init() {}
}

extension Catalog {
    /// Makes the thumbnails of these images stale, so the next pass makes
    /// them again (Library › Rebuild Thumbnails). The files stay until then:
    /// the grid keeps showing the old picture rather than a blank cell.
    public func discardThumbnailKeys(forRelPaths relPaths: [String]) throws {
        guard !relPaths.isEmpty else { return }
        try dbQueue.write { db in
            for relPath in relPaths {
                try db.execute(sql: "UPDATE images SET thumb_key = NULL WHERE rel_path = ?", arguments: [relPath])
            }
        }
    }

    /// Sizes up the thumbnail folder, and finds the files in it that no
    /// image of the catalog will read. Doesn't wait for a running pass (the
    /// first pass over a big folder takes minutes); the half-written file
    /// of one is never counted as an orphan.
    public func thumbnailCacheUsage() throws -> ThumbnailCacheUsage {
        try scanThumbnailFolder(removingOrphans: false)
    }

    /// Removes the files `thumbnailCacheUsage` counts as orphans; nothing
    /// an image uses. Returns what was there before, orphans included.
    @discardableResult
    public func purgeOrphanThumbnails() throws -> ThumbnailCacheUsage {
        try scanThumbnailFolder(removingOrphans: true)
    }

    /// Empties the thumbnail folder and forgets every key, so the next pass
    /// makes every thumbnail again at the current settings. Thumbnails are
    /// a cache: nothing else lives in that folder.
    public func discardAllThumbnails() async throws {
        await beginThumbnailPass()
        defer { endThumbnailPass() }
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: thumbnailDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        try clearAllThumbnailKeys()
    }

    /// Synchronous, as `recordThumbnailKeys`: inside an async function GRDB
    /// would pick its async write, which gives up when the task is cancelled.
    private func clearAllThumbnailKeys() throws {
        try dbQueue.write { db in try db.execute(sql: "UPDATE images SET thumb_key = NULL") }
    }

    private func scanThumbnailFolder(removingOrphans: Bool) throws -> ThumbnailCacheUsage {
        let relPaths = try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT rel_path FROM images") }
        let directory = thumbnailDirectory.standardizedFileURL
        let expected = Set(relPaths.map { Self.thumbnailURL(forRelPath: $0, in: directory).standardizedFileURL.path })
        var usage = ThumbnailCacheUsage()
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return usage
        }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            usage.files += 1
            usage.bytes += bytes
            guard !expected.contains(url.standardizedFileURL.path) else { continue }
            // A pass writes beside the real name, then renames
            // (`Thumbnailer.writeHEIC`): that file is in use, not orphaned.
            if thumbnailPassRunning, url.pathExtension == "tmp", url.lastPathComponent.hasPrefix(".") { continue }
            usage.orphanFiles += 1
            usage.orphanBytes += bytes
            if removingOrphans { try? FileManager.default.removeItem(at: url) }
        }
        return usage
    }
}

/// Lets through at most one progress report per `interval`, plus the first
/// and the last. A thumbnail pass finishes files far faster than anyone can
/// read a counter, and every report the Library publishes redraws each view
/// that watches it: the whole main window.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last: TimeInterval = -.infinity
    private let clock: @Sendable () -> TimeInterval

    init(interval: TimeInterval, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.interval = interval
        self.clock = clock
    }

    func shouldReport(done: Int, total: Int) -> Bool {
        lock.withLock {
            let now = clock()
            guard done <= 1 || done >= total || now - last >= interval else { return false }
            last = now
            return true
        }
    }
}
