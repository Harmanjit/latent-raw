import Foundation
import GRDB

/// What a thumbnail pass did.
public struct ThumbnailReport: Sendable, CustomStringConvertible {
    public var generated = 0
    public var failures: [(relPath: String, reason: String)] = []
    public var duration: TimeInterval = 0

    public var description: String {
        var s = "\(generated) thumbnails generated"
        if !failures.isEmpty { s += ", \(failures.count) failed" }
        return s + String(format: " (%.2fs)", duration)
    }
}

extension Catalog {
    /// Images whose thumbnail is missing or stale: no `thumb_key`, a key
    /// that doesn't match the embedded-preview key (edited thumbnails come
    /// later), or a key with no file behind it.
    public func imagesNeedingThumbnails() throws -> [ImageRecord] {
        let all = try dbQueue.read { db in try ImageRecord.fetchAll(db) }
        let fm = FileManager.default
        return all.filter { record in
            record.thumbKey != Thumbnailer.embeddedPreviewKey
                || !fm.fileExists(atPath: thumbnailURL(forRelPath: record.relPath).path)
        }
    }

    /// Generates every missing thumbnail. The file work runs off the actor
    /// at utility priority — efficiency cores, per DESIGN.md §11 — a few
    /// files at a time, then the keys are recorded in one transaction.
    ///
    /// `progress` is called on each completion with (done, total).
    public func generateMissingThumbnails(
        concurrency: Int = 4,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ThumbnailReport {
        let start = Date()
        var report = ThumbnailReport()
        let needed = try imagesNeedingThumbnails()
        guard !needed.isEmpty else { return report }

        // Absolute paths resolved here, on the actor; the workers get
        // plain values and never touch catalog state.
        let jobs = needed.map { record in
            (relPath: record.relPath,
             source: fileURL(forRelPath: record.relPath),
             destination: thumbnailURL(forRelPath: record.relPath))
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
                        try Thumbnailer.makeFromEmbeddedPreview(rawFileAt: job.source,
                                                                to: job.destination)
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

        let succeeded = results.filter { $0.error == nil }.map(\.relPath)
        report.failures = results.compactMap { r in r.error.map { (r.relPath, $0) } }

        // In an async context GRDB resolves to its async write overload.
        try await dbQueue.write { db in
            for relPath in succeeded {
                try db.execute(sql: "UPDATE images SET thumb_key = ? WHERE rel_path = ?",
                               arguments: [Thumbnailer.embeddedPreviewKey, relPath])
            }
        }
        report.generated = succeeded.count
        report.duration = Date().timeIntervalSince(start)
        return report
    }
}
