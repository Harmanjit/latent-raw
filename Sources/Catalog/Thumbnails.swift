import Foundation
import GRDB
import CoreGraphics

/// Renders a thumbnail for an *edited* image. The catalog can't run the
/// pipeline itself (it doesn't depend on PixelEngine), so the app plugs
/// one of these in. Must return an image no larger than
/// `Thumbnailer.size` on its long edge, already in the camera's
/// orientation (manual rotation is applied at display time).
public protocol EditedThumbnailRenderer: Sendable {
    func renderThumbnail(rawFileAt url: URL, editStackJSON: String) throws -> CGImage
}

/// What a thumbnail pass did.
public struct ThumbnailReport: Sendable, CustomStringConvertible {
    public var generated = 0
    /// Images whose thumbnail file changed, so caches can drop them.
    public var regeneratedRelPaths: [String] = []
    /// The subset that overwrote an existing thumbnail file. Only these can
    /// be in a memory cache with old pixels.
    public var replacedRelPaths: [String] = []
    public var failures: [(relPath: String, reason: String)] = []
    public var duration: TimeInterval = 0

    public var description: String {
        var s = "\(generated) thumbnails generated"
        if !failures.isEmpty { s += ", \(failures.count) failed" }
        return s + String(format: " (%.2fs)", duration)
    }
}

extension Catalog {
    /// An image whose thumbnail must be (re)made, with the edit it should
    /// reflect (nil = the embedded preview) and the key to record.
    public struct ThumbnailJob: Sendable {
        public let record: ImageRecord
        public let editStackJSON: String?
        public var expectedKey: Data { Thumbnailer.expectedKey(editStackJSON: editStackJSON) }
    }

    /// Images whose thumbnail is missing or stale: the recorded key doesn't
    /// match what the current edit state calls for, or the file is gone.
    public func thumbnailJobs() throws -> [ThumbnailJob] {
        let rows: [(ImageRecord, String?)] = try dbQueue.read { db in
            let records = try ImageRecord.fetchAll(db)
            let edits = try Row.fetchAll(db, sql: "SELECT image_id, params_json FROM edits")
            var json: [Int64: String] = [:]
            for row in edits { json[row["image_id"]] = row["params_json"] }
            return records.map { ($0, $0.id.flatMap { json[$0] }) }
        }
        let fm = FileManager.default
        return rows.compactMap { record, edit in
            let job = ThumbnailJob(record: record, editStackJSON: edit)
            let stale = record.thumbKey != job.expectedKey
                || !fm.fileExists(atPath: thumbnailURL(forRelPath: record.relPath).path)
            return stale ? job : nil
        }
    }

    /// Convenience for callers that only want the records.
    public func imagesNeedingThumbnails() throws -> [ImageRecord] {
        try thumbnailJobs().map(\.record)
    }

    /// Generates every missing thumbnail. The file work runs off the actor
    /// at utility priority — efficiency cores, per DESIGN.md §11 — a few
    /// files at a time, and the keys are recorded every few files.
    ///
    /// One pass runs at a time: a pass started while another runs (every
    /// settled edit starts one) waits for it, then lists only what is still
    /// stale. Cancelling a pass stops it taking new files; those already
    /// under way finish and their keys are recorded, so the next pass
    /// doesn't make them again. Before this, overlapping passes each made
    /// every file the others hadn't yet recorded, and keys were written
    /// only when a whole pass ended.
    ///
    /// `progress` is called on each completion with (done, total).
    /// `editedRenderer` makes thumbnails for images with edits; without
    /// one, those are skipped (their embedded thumbnail stays). `quality`
    /// and `priority` come from Settings › Performance (utility, the
    /// efficiency cores, unless the user asked for otherwise).
    public func generateMissingThumbnails(
        concurrency: Int = 4,
        quality: Double = Thumbnailer.defaultQuality,
        priority: TaskPriority = .utility,
        editedRenderer: (any EditedThumbnailRenderer)? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ThumbnailReport {
        await beginThumbnailPass()
        defer { endThumbnailPass() }
        let start = Date()
        var report = ThumbnailReport()
        guard !Task.isCancelled else { return report }
        let needed = try thumbnailJobs().filter { $0.editStackJSON == nil || editedRenderer != nil }
        guard !needed.isEmpty else { return report }

        // Absolute paths resolved here, on the actor; the workers get
        // plain values and never touch catalog state.
        struct Work: Sendable {
            let relPath: String
            let source: URL
            let destination: URL
            let editStackJSON: String?
            let key: Data
            let replaces: Bool
        }
        let jobs = needed.map { job in
            Work(relPath: job.record.relPath,
                 source: fileURL(forRelPath: job.record.relPath),
                 destination: thumbnailURL(forRelPath: job.record.relPath),
                 editStackJSON: job.editStackJSON,
                 key: job.expectedKey,
                 replaces: FileManager.default.fileExists(atPath: thumbnailURL(forRelPath: job.record.relPath).path))
        }
        let byPath = Dictionary(jobs.map { ($0.relPath, $0) }, uniquingKeysWith: { first, _ in first })
        let total = jobs.count
        // Keys go to the database this many files at a time.
        let batchSize = 16

        try await withThrowingTaskGroup(of: (String, String?).self) { group in
            var next = 0
            var done = 0
            var unrecorded: [Work] = []

            func enqueue() {
                // A cancelled pass takes no more files.
                guard next < jobs.count, !Task.isCancelled else { return }
                let job = jobs[next]
                next += 1
                group.addTask(priority: priority) {
                    do {
                        if let json = job.editStackJSON, let renderer = editedRenderer {
                            let image = try renderer.renderThumbnail(rawFileAt: job.source,
                                                                     editStackJSON: json)
                            try Thumbnailer.write(image, to: job.destination, quality: quality)
                        } else {
                            try Thumbnailer.makeFromEmbeddedPreview(rawFileAt: job.source,
                                                                    to: job.destination, quality: quality)
                        }
                        return (job.relPath, nil)
                    } catch {
                        return (job.relPath, "\(error)")
                    }
                }
            }

            for _ in 0..<min(max(1, concurrency), jobs.count) { enqueue() }
            while let (relPath, error) = try await group.next() {
                done += 1
                if let error {
                    report.failures.append((relPath, error))
                } else if let job = byPath[relPath] {
                    unrecorded.append(job)
                    report.generated += 1
                    report.regeneratedRelPaths.append(relPath)
                    if job.replaces { report.replacedRelPaths.append(relPath) }
                }
                progress?(done, total)
                // Written inline, not through a local function: Swift 6.1
                // treats a local function that captures `unrecorded` as
                // nonisolated and refuses to send the array to it.
                if unrecorded.count >= batchSize {
                    try recordThumbnailKeys(unrecorded.map { ($0.relPath, $0.key) })
                    unrecorded = []
                }
                enqueue()
            }
            if !unrecorded.isEmpty {
                try recordThumbnailKeys(unrecorded.map { ($0.relPath, $0.key) })
            }
        }
        report.duration = Date().timeIntervalSince(start)
        return report
    }

    /// Synchronous on purpose: GRDB's async write gives up when the task is
    /// cancelled, and a cancelled pass must still record the files it made.
    private func recordThumbnailKeys(_ keys: [(String, Data)]) throws {
        try dbQueue.write { db in
            for (relPath, key) in keys {
                try db.execute(sql: "UPDATE images SET thumb_key = ? WHERE rel_path = ?",
                               arguments: [key, relPath])
            }
        }
    }

    /// Waits until no other thumbnail pass runs, then counts this one as
    /// running. The waiter is handed the turn directly, so a pass starting
    /// meanwhile can't slip in between.
    func beginThumbnailPass() async {
        if thumbnailPassRunning {
            await withCheckedContinuation { thumbnailPassWaiters.append($0) }
        } else {
            thumbnailPassRunning = true
        }
    }

    func endThumbnailPass() {
        if thumbnailPassWaiters.isEmpty {
            thumbnailPassRunning = false
        } else {
            thumbnailPassWaiters.removeFirst().resume()
        }
    }
}
