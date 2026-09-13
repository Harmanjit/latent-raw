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
    /// files at a time, then the keys are recorded in one transaction.
    ///
    /// `progress` is called on each completion with (done, total).
    /// `editedRenderer` makes thumbnails for images with edits; without
    /// one, those are skipped (their embedded thumbnail stays).
    public func generateMissingThumbnails(
        concurrency: Int = 4,
        editedRenderer: (any EditedThumbnailRenderer)? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ThumbnailReport {
        let start = Date()
        var report = ThumbnailReport()
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
        }
        let jobs = needed.map { job in
            Work(relPath: job.record.relPath,
                 source: fileURL(forRelPath: job.record.relPath),
                 destination: thumbnailURL(forRelPath: job.record.relPath),
                 editStackJSON: job.editStackJSON,
                 key: job.expectedKey)
        }
        let total = jobs.count

        let results: [(relPath: String, error: String?)] = await withTaskGroup(
            of: (String, String?).self
        ) { group in
            var results: [(String, String?)] = []
            var next = 0
            var done = 0

            func enqueue() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask(priority: .utility) {
                    do {
                        if let json = job.editStackJSON, let renderer = editedRenderer {
                            let image = try renderer.renderThumbnail(rawFileAt: job.source,
                                                                     editStackJSON: json)
                            try Thumbnailer.write(image, to: job.destination)
                        } else {
                            try Thumbnailer.makeFromEmbeddedPreview(rawFileAt: job.source,
                                                                    to: job.destination)
                        }
                        return (job.relPath, nil)
                    } catch {
                        return (job.relPath, "\(error)")
                    }
                }
            }
            for _ in 0..<min(concurrency, jobs.count) { enqueue() }
            for await result in group {
                results.append(result)
                done += 1
                progress?(done, total)
                enqueue()
            }
            return results
        }

        let succeeded = Set(results.filter { $0.error == nil }.map(\.relPath))
        report.failures = results.compactMap { r in r.error.map { (r.relPath, $0) } }
        let keys = jobs.filter { succeeded.contains($0.relPath) }.map { ($0.relPath, $0.key) }

        // In an async context GRDB resolves to its async write overload.
        try await dbQueue.write { db in
            for (relPath, key) in keys {
                try db.execute(sql: "UPDATE images SET thumb_key = ? WHERE rel_path = ?",
                               arguments: [key, relPath])
            }
        }
        report.generated = succeeded.count
        report.regeneratedRelPaths = keys.map(\.0)
        report.duration = Date().timeIntervalSince(start)
        return report
    }
}
