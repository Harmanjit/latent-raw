import Foundation
import RawCore
import LensKit

/// One raw decode on a background thread (plan fix #17). Opening a photo
/// used to decode on the main thread, freezing the window for 250-300 ms
/// per switch; the editor now waits for one of these instead and applies
/// the result on main.
///
/// A job waits on its queue until a thread is free; one cancelled before
/// then never decodes, so a held arrow key decodes the photos it lands
/// on, not every one it passes. One already decoding finishes (LibRaw
/// can't be stopped part way) and its result is simply not used.
final class RawDecodeJob: @unchecked Sendable {
    enum Lane: Sendable {
        /// The photo being opened.
        case open
        /// A neighbour decoded ahead of time.
        case prefetch
    }

    let url: URL
    let lane: Lane

    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var outcome: Result<RawFile, any Error>?
    private var waiters: [CheckedContinuation<RawFile, any Error>] = []

    /// Opens wait for the decode one at a time on a user-initiated queue;
    /// neighbours decode on a utility queue, so the photo being opened
    /// never queues behind them (the decoder service runs requests side
    /// by side).
    private static let openQueue = DispatchQueue(label: "latent.decode.open", qos: .userInitiated)
    private static let prefetchQueue = DispatchQueue(label: "latent.decode.prefetch", qos: .utility)

    /// What a decode runs; tests put a stand-in here.
    nonisolated(unsafe) static var decode: @Sendable (URL) throws -> RawFile = { url in
        try EditorModel.decodeForOpening(url)
    }

    init(url: URL, lane: Lane) {
        self.url = url
        self.lane = lane
    }

    /// Queues the decode on its lane's queue.
    func start() {
        let queue = lane == .open ? Self.openQueue : Self.prefetchQueue
        queue.async { [self] in run() }
    }

    private func run() {
        let proceed = lock.withLock {
            guard !cancelled, outcome == nil else { return false }
            started = true
            return true
        }
        guard proceed else { return }
        finish(Result { try Self.decode(url) })
    }

    /// Whether the decode has begun (or ended); a job that hasn't can be
    /// dropped without wasting work.
    var hasStarted: Bool { lock.withLock { started || outcome != nil } }

    /// The decoded file, or nil while it is still running or queued.
    var file: RawFile? {
        lock.withLock {
            if case .success(let file)? = outcome { return file }
            return nil
        }
    }

    /// True once it has finished, decoded or not.
    var isFinished: Bool { lock.withLock { outcome != nil } }

    /// Stops a job that hasn't begun; its waiters get `CancellationError`.
    /// A running decode is left to finish.
    func cancel() {
        let stop = lock.withLock {
            cancelled = true
            return !started && outcome == nil
        }
        if stop { finish(.failure(CancellationError())) }
    }

    /// The decoded file, waiting for it.
    func value() async throws -> RawFile {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<RawFile, any Error>? = lock.withLock {
                if outcome == nil { waiters.append(continuation) }
                return outcome
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    private func finish(_ result: Result<RawFile, any Error>) {
        let waiting: [CheckedContinuation<RawFile, any Error>] = lock.withLock {
            guard outcome == nil else { return [] }
            outcome = result
            defer { waiters = [] }
            return waiters
        }
        for continuation in waiting { continuation.resume(with: result) }
    }

    /// Bytes the decoded file holds (its sensor or linear plane), for the
    /// cache's budget; 0 until it has decoded.
    var byteCount: Int {
        guard let file else { return 0 }
        return file.sensorPlane?.allocationLength ?? file.linearPlane?.allocationLength ?? 0
    }
}

/// The open photo's decode and its neighbours', kept so that stepping to
/// the next or previous photo needs no decode at all (plan fix #17).
///
/// Bounded: at most `maxEntries` files and `maxBytes` of planes (a D750
/// raw is about 49 MB), the oldest dropped first. Emptied when memory runs
/// short and when the catalog changes (`removeAll`). A file changed on
/// disk since its decode (another size or modification date) is decoded
/// again.
@MainActor
final class RawDecodeCache {
    /// The open photo and a neighbour on each side.
    let maxEntries: Int
    let maxBytes: Int

    private struct Entry {
        let job: RawDecodeJob
        let identity: FileIdentity?
        var lastUse: Int
    }

    /// What identifies a file's contents cheaply: a raw rewritten in place
    /// (by a tool that edits its metadata, say) is decoded again.
    struct FileIdentity: Equatable {
        let size: Int
        let modified: Date

        init?(url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            self.size = size
            self.modified = modified
        }
    }

    private var entries: [String: Entry] = [:]
    private var clock = 0

    init(maxEntries: Int = 3, maxBytes: Int = 400 << 20) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// The job decoding `url` for an open: the kept or prefetched one if
    /// there is one for the file as it is now, else a new one, started.
    /// A neighbour's decode still queued behind another is replaced by
    /// one on the open lane rather than waited for.
    func jobForOpening(_ url: URL) -> RawDecodeJob {
        // Latest wins: opens of other photos still queued (a held arrow
        // key passing them) are dropped before they decode.
        let key = Self.key(url)
        for (other, entry) in entries where other != key && entry.job.lane == .open && !entry.job.hasStarted {
            entry.job.cancel()
            entries[other] = nil
        }
        return job(for: url, lane: .open)
    }

    /// Starts decoding `urls` ahead of time, unless kept or under way.
    /// Neighbours queued for an earlier photo and not wanted now are
    /// dropped before they start.
    func prefetch(_ urls: [URL], keeping current: URL?) {
        let wanted = Set((urls + (current.map { [$0] } ?? [])).map(Self.key))
        for (key, entry) in entries where !wanted.contains(key) && entry.job.lane == .prefetch && !entry.job.hasStarted {
            entry.job.cancel()
            entries[key] = nil
        }
        for url in urls { _ = job(for: url, lane: .prefetch) }
        trim(protecting: wanted)
    }

    /// The decoded file for `url` if it is kept and finished.
    func decodedFile(for url: URL) -> RawFile? {
        guard let entry = entries[Self.key(url)], entry.identity == FileIdentity(url: url) else { return nil }
        return entry.job.file
    }

    /// Drops everything, stopping decodes that haven't begun. A catalog
    /// change and a close call this; the open photo keeps its own file
    /// through its session. Memory pressure keeps an open's decode still
    /// under way (`keepingOpens`): a photo being opened is still wanted.
    func removeAll(keepingOpens: Bool = false) {
        for (key, entry) in entries {
            if keepingOpens, entry.job.lane == .open, !entry.job.isFinished { continue }
            entry.job.cancel()
            entries[key] = nil
        }
    }

    /// Stops and drops one file's job, for an open that was superseded
    /// before its decode began.
    func cancelIfNotStarted(_ url: URL) {
        let key = Self.key(url)
        guard let entry = entries[key], !entry.job.hasStarted else { return }
        entry.job.cancel()
        entries[key] = nil
    }

    /// Kept files, for tests.
    var count: Int { entries.count }
    var keptPaths: Set<String> { Set(entries.keys) }

    private func job(for url: URL, lane: RawDecodeJob.Lane) -> RawDecodeJob {
        let key = Self.key(url)
        let identity = FileIdentity(url: url)
        clock += 1
        if var entry = entries[key], entry.identity == identity, !Self.failedOrCancelled(entry.job) {
            // A neighbour still waiting behind another decode: the open
            // goes on its own lane instead.
            if lane == .open, entry.job.lane == .prefetch, !entry.job.hasStarted {
                entry.job.cancel()
            } else {
                entry.lastUse = clock
                entries[key] = entry
                return entry.job
            }
        }
        entries[key]?.job.cancel()
        let job = RawDecodeJob(url: url, lane: lane)
        entries[key] = Entry(job: job, identity: identity, lastUse: clock)
        job.start()
        if lane == .open { trim(protecting: [key]) }
        return job
    }

    private static func failedOrCancelled(_ job: RawDecodeJob) -> Bool {
        job.isFinished && job.file == nil
    }

    /// Drops the least recently used entries beyond the count and byte
    /// budgets, never one in `protecting`.
    private func trim(protecting: Set<String>) {
        func total() -> Int { entries.values.reduce(0) { $0 + $1.job.byteCount } }
        while entries.count > maxEntries || total() > maxBytes {
            guard let victim = entries.filter({ !protecting.contains($0.key) })
                .min(by: { $0.value.lastUse < $1.value.lastUse }) else { return }
            victim.value.job.cancel()
            entries[victim.key] = nil
        }
    }
}

extension EditorModel {
    /// Decodes `url` for opening, off the main thread. Also makes sure the
    /// Lensfun database has been read: `ImageSession` looks the lens up
    /// there, and the first use parses the bundled database (about 140 ms),
    /// which should wait here rather than on main.
    nonisolated static func decodeForOpening(_ url: URL) throws -> RawFile {
        let file = try RawFile(path: url.path)
        _ = LensfunDatabase.shared
        return file
    }
}
