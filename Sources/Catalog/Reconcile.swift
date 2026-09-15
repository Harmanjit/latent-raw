import Foundation
import GRDB
import RawCore

/// What a reconciliation pass found and did.
public struct ReconcileReport: Sendable, CustomStringConvertible {
    public var added = 0
    public var modified = 0
    public var renamed = 0
    public var removed = 0
    public var unchanged = 0
    public var sidecarsRead = 0
    /// Unchanged files whose Finder tags changed since the last pass.
    public var tagsChanged = 0
    /// Subfolders with no decision yet (mode `ask`), relative paths.
    public var undecidedSubfolders: [String] = []
    /// Files that couldn't be read, with the reason. They're skipped, not
    /// fatal — one corrupt file must not stop a folder from opening.
    public var failures: [(relPath: String, reason: String)] = []
    public var duration: TimeInterval = 0

    public var description: String {
        var parts = ["\(unchanged) unchanged", "\(added) added", "\(modified) modified",
                     "\(renamed) renamed", "\(removed) removed", "\(sidecarsRead) sidecars read"]
        if !undecidedSubfolders.isEmpty { parts.append("\(undecidedSubfolders.count) subfolders awaiting a decision") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        return parts.joined(separator: ", ") + String(format: " (%.2fs)", duration)
    }
}

extension Catalog {
    /// File extensions Latent indexes. Raw formats only for now: the
    /// pipeline can't yet render a JPEG or TIFF, and indexing what can't
    /// be opened would just be a row with a broken thumbnail.
    public static let indexedExtensions: Set<String> = [
        "nef", "nrw",                       // Nikon
        "arw", "srf", "sr2",                // Sony
        "cr2", "cr3", "crw",                // Canon
        "dng",                              // Adobe / phones / Leica
        "raf", "orf", "rw2", "pef", "srw",  // Fuji, Olympus, Panasonic, Pentax, Samsung
        "3fr", "fff", "iiq", "mos", "mrw", "x3f",
    ]

    /// A file as seen on disk during the scan.
    struct DiskFile {
        let relPath: String
        let size: Int64
        let mtime: Int64
        /// Finder tags in their stored form (`FinderTag.encode`).
        var finderTags: String? = nil
    }

    /// Brings the database in line with the folder (DESIGN.md §5.3).
    ///
    /// Cheap by design: unchanged files are recognised by name, size and
    /// mtime alone and never opened. Only new and modified files are
    /// hashed and have their metadata read, and only sidecars whose mtime
    /// moved are re-parsed. All database changes land in one transaction
    /// at the end, so a crash mid-way leaves the previous state intact.
    public func reconcile() throws -> ReconcileReport {
        let start = Date()
        var report = ReconcileReport()

        // 1. What's on disk.
        let onDisk = try scanFiles(report: &report)
        let onDiskByPath = Dictionary(uniqueKeysWithValues: onDisk.map { ($0.relPath, $0) })

        // 2. What the database thinks.
        let known = try dbQueue.read { db in try ImageRecord.fetchAll(db) }
        var knownByPath = Dictionary(uniqueKeysWithValues: known.map { ($0.relPath, $0) })

        // 3. Sort into buckets.
        var newFiles: [DiskFile] = []
        var modifiedFiles: [(DiskFile, ImageRecord)] = []
        var tagChanges: [(id: Int64, tags: String?)] = []
        for file in onDisk {
            if let record = knownByPath.removeValue(forKey: file.relPath) {
                if record.size == file.size && record.mtime == file.mtime {
                    report.unchanged += 1
                    // Tagging in Finder moves no mtime, so tags are compared
                    // on every pass; only changed rows are written.
                    if record.finderTags != file.finderTags, let id = record.id {
                        tagChanges.append((id, file.finderTags))
                    }
                } else {
                    modifiedFiles.append((file, record))
                }
            } else {
                newFiles.append(file)
            }
        }
        // Whatever is left in knownByPath has no file any more — unless a
        // new file turns out to have the same content (a rename).
        var missingByHash: [Data: ImageRecord] = [:]
        for record in knownByPath.values { missingByHash[record.xxhash] = record }

        // 4. Expensive work, outside any transaction: hash and read
        //    metadata for the files that need it.
        var inserts: [ImageRecord] = []
        var updates: [ImageRecord] = []
        var renames: [(from: ImageRecord, to: DiskFile)] = []

        for file in newFiles {
            let url = fileURL(forRelPath: file.relPath)
            let hash: Data
            do {
                hash = ImageRecord.hashData(try FileHash.xxh64(ofFileAt: url))
            } catch {
                report.failures.append((file.relPath, "hash failed: \(error)"))
                continue
            }
            if let previous = missingByHash.removeValue(forKey: hash) {
                renames.append((previous, file))
                continue
            }
            do {
                inserts.append(try makeRecord(for: file, hash: hash))
            } catch {
                report.failures.append((file.relPath, "\(error)"))
            }
        }

        for (file, previous) in modifiedFiles {
            let url = fileURL(forRelPath: file.relPath)
            do {
                let hash = ImageRecord.hashData(try FileHash.xxh64(ofFileAt: url))
                var fresh = try makeRecord(for: file, hash: hash)
                // Content changed but it's the same photo as far as the
                // user is concerned: keep everything they've done to it.
                fresh.id = previous.id
                fresh.rating = previous.rating
                fresh.label = previous.label
                fresh.flag = previous.flag
                fresh.userRotation = previous.userRotation
                fresh.preservedName = previous.preservedName
                fresh.mergeJSON = previous.mergeJSON
                fresh.sidecarMtime = previous.sidecarMtime
                fresh.thumbKey = nil   // pixels changed; thumbnail is stale
                updates.append(fresh)
            } catch {
                report.failures.append((file.relPath, "\(error)"))
            }
        }

        let removals = Array(missingByHash.values)

        // 5. Move sidecars and thumbnails for renames before touching the
        //    database, so a failure here leaves the DB pointing at files
        //    that still exist under the old name.
        for (previous, file) in renames {
            try moveCompanions(from: previous.relPath, to: file.relPath)
        }

        // 6. One transaction for all the row changes.
        try dbQueue.write { db in
            for var record in inserts {
                try record.insert(db)
            }
            for record in updates {
                try record.update(db)
            }
            for (previous, file) in renames {
                var moved = previous
                moved.relPath = file.relPath
                moved.size = file.size
                moved.mtime = file.mtime
                moved.finderTags = file.finderTags
                try moved.update(db)
            }
            for change in tagChanges {
                try db.execute(sql: "UPDATE images SET finder_tags = ? WHERE id = ?",
                               arguments: [change.tags, change.id])
            }
            for record in removals {
                try record.delete(db)
            }
        }
        report.added = inserts.count
        report.modified = updates.count
        report.renamed = renames.count
        report.removed = removals.count
        report.tagsChanged = tagChanges.count

        // A file renamed outside Latent keeps its place in the custom order.
        if !renames.isEmpty {
            do {
                try renameInCustomOrder(renames.map { ($0.from.relPath, $0.to.relPath) })
            } catch {
                report.failures.append((CustomOrder.fileName, "custom order not updated: \(error)"))
            }
        }

        // 7. Sidecars: re-read only those whose mtime moved.
        report.sidecarsRead = try syncSidecars(report: &report)

        report.duration = Date().timeIntervalSince(start)
        return report
    }

    // MARK: - Scanning

    /// Lists indexable files under the root, descending into subfolders
    /// according to their mode (DESIGN.md §5.2). A subfolder with its own
    /// `_latent/` is always a separate catalog and never entered.
    private func scanFiles(report: inout ReconcileReport) throws -> [DiskFile] {
        var files: [DiskFile] = []
        let defaultMode = try defaultSubfolderMode()
        try scan(directory: rootPath, relPrefix: "", defaultMode: defaultMode,
                 into: &files, report: &report)
        return files.sorted { $0.relPath < $1.relPath }
    }

    private func scan(directory: URL, relPrefix: String, defaultMode: SubfolderMode,
                      into files: inout [DiskFile], report: inout ReconcileReport) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .nameKey]
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])

        for entry in entries {
            let values = try entry.resourceValues(forKeys: Set(keys))
            let name = values.name ?? entry.lastPathComponent
            let relPath = relPrefix.isEmpty ? name : relPrefix + "/" + name

            // A symlink could point anywhere on the disk; a catalog is one
            // folder and stays inside it. Files that are links are skipped
            // for the same reason: their sidecar would be written here for
            // a photo that lives elsewhere.
            if values.isSymbolicLink == true { continue }

            if values.isDirectory == true {
                if name == Self.containerName || name == Self.legacyContainerName { continue }
                let hasOwnContainer = fm.fileExists(
                    atPath: entry.appendingPathComponent(Self.containerName).path)
                if hasOwnContainer { continue }   // independent by existence

                var mode = try subfolderMode(forRelPath: relPath)
                if mode == nil {
                    // First sighting: record the default so the decision
                    // is visible and editable in the subfolders table.
                    mode = defaultMode
                    try setSubfolderMode(defaultMode, forRelPath: relPath)
                }
                switch mode! {
                case .included:
                    try scan(directory: entry, relPrefix: relPath, defaultMode: defaultMode,
                             into: &files, report: &report)
                case .independent:
                    continue
                case .ask:
                    report.undecidedSubfolders.append(relPath)
                }
                continue
            }

            guard Self.indexedExtensions.contains(entry.pathExtension.lowercased()) else { continue }
            files.append(DiskFile(
                relPath: relPath,
                size: Int64(values.fileSize ?? 0),
                mtime: ImageRecord.milliseconds(values.contentModificationDate ?? .distantPast),
                finderTags: FinderTag.encode(FinderTag.read(from: entry))))
        }
    }

    // MARK: - Metadata

    /// Reads what the catalog needs from a raw file without decoding it.
    private func makeRecord(for file: DiskFile, hash: Data) throws -> ImageRecord {
        let url = fileURL(forRelPath: file.relPath)
        let raw = try RawFile(path: url.path, metadataOnly: true)
        let s = raw.summary
        // TODO(Photo Merge): a merge result copied in from Finder arrives
        // without its sidecar, but the DNG carries the same latent:Merge
        // block in its embedded XMP packet (tag 700). Once RawCore hands
        // that packet over, read the block here into `mergeJSON`, so the
        // recipe isn't lost; `syncSidecars` leaves a row with no sidecar
        // alone, and the next write from the row puts it in a sidecar.
        // Until then such a file is catalogued as a plain DNG.
        let camera = [s.cameraMake, s.cameraModel]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return ImageRecord(
            id: nil, relPath: file.relPath, preservedName: nil,
            size: file.size, mtime: file.mtime, xxhash: hash,
            captureTime: s.captureTime.timeIntervalSince1970 > 0
                ? Int64(s.captureTime.timeIntervalSince1970) : nil,
            camera: camera.isEmpty ? nil : camera,
            lens: s.lensModel.isEmpty ? nil : s.lensModel,
            lensId: nil,
            iso: s.iso > 0 ? Int(s.iso) : nil,
            shutter: s.shutter > 0 ? s.shutter : nil,
            aperture: s.aperture > 0 ? s.aperture : nil,
            focal: s.focalLength > 0 ? s.focalLength : nil,
            width: s.width, height: s.height, orientation: s.orientation,
            rating: 0, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil,
            finderTags: file.finderTags)
    }

    // MARK: - Renames

    /// Same-volume renames of a file's sidecar and thumbnail. Nothing is
    /// copied (DESIGN.md §5.2).
    private func moveCompanions(from oldRelPath: String, to newRelPath: String) throws {
        let fm = FileManager.default
        for (from, to) in [(sidecarURL(forRelPath: oldRelPath), sidecarURL(forRelPath: newRelPath)),
                           (thumbnailURL(forRelPath: oldRelPath), thumbnailURL(forRelPath: newRelPath))] {
            guard fm.fileExists(atPath: from.path) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.moveItem(at: from, to: to)
        }
    }

    // MARK: - Sidecars

    /// Applies any sidecar whose mtime differs from what the row recorded.
    /// Sidecars are authoritative (DESIGN.md §5.3), so their rating, label,
    /// keywords and edit stack overwrite the row's. Returns how many were
    /// read.
    private func syncSidecars(report: inout ReconcileReport) throws -> Int {
        let records = try dbQueue.read { db in try ImageRecord.fetchAll(db) }
        let fm = FileManager.default
        var applied: [(ImageRecord, XMPSidecar.Fields?, Int64?)] = []

        for record in records {
            let url = sidecarURL(forRelPath: record.relPath)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date else {
                // No sidecar. If there used to be one, its metadata is gone
                // with it: the row goes back to defaults.
                if record.sidecarMtime != nil { applied.append((record, nil, nil)) }
                continue
            }
            let mtime = ImageRecord.milliseconds(date)
            guard mtime != record.sidecarMtime else { continue }
            do {
                applied.append((record, try XMPSidecar.read(from: url), mtime))
            } catch {
                report.failures.append((record.relPath + ".xmp", "sidecar unreadable: \(error)"))
            }
        }
        guard !applied.isEmpty else { return 0 }

        try dbQueue.write { db in
            for (record, fields, mtime) in applied {
                guard let id = record.id else { continue }
                var row = record
                row.rating = fields?.rating ?? 0
                row.label = fields?.label
                row.flag = fields?.flag ?? 0
                row.userRotation = fields?.rotation ?? 0
                row.preservedName = fields?.preservedFileName ?? row.preservedName
                // A merge result's recipe, like its edit, comes from the
                // sidecar; an image whose sidecar has none isn't a merge.
                row.mergeJSON = fields.flatMap { $0.mergeJSON.isEmpty ? nil : $0.mergeJSON }
                row.sidecarMtime = mtime
                try row.update(db)

                try Self.replaceKeywords(fields?.keywords ?? [], forImageID: id, in: db)

                if let fields, !fields.editStackJSON.isEmpty {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO edits
                          (image_id, schema_version, process_version, params_json, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [id, fields.schemaVersion, fields.processVersion,
                                         fields.editStackJSON, mtime ?? 0])
                } else {
                    try db.execute(sql: "DELETE FROM edits WHERE image_id = ?", arguments: [id])
                }

                // Snapshots and history come back from the sidecar too.
                try db.execute(sql: "DELETE FROM snapshots WHERE image_id = ?", arguments: [id])
                for snap in Self.parseSnapshots(fields?.snapshotsJSON ?? "") {
                    try db.execute(sql: "INSERT INTO snapshots (image_id, name, params_json) VALUES (?, ?, ?)",
                                   arguments: [id, snap.name, snap.stackJSON])
                }
                try db.execute(sql: "DELETE FROM history WHERE image_id = ?", arguments: [id])
                for (i, step) in Self.parseHistory(fields?.historyJSON ?? "").enumerated() {
                    try db.execute(sql: "INSERT INTO history (image_id, step, params_json, created_at) VALUES (?, ?, ?, ?)",
                                   arguments: [id, i, step.stackJSON, step.createdAt])
                }
            }
        }
        return applied.count
    }

    static func replaceKeywords(_ names: [String], forImageID id: Int64, in db: Database) throws {
        try db.execute(sql: "DELETE FROM image_keywords WHERE image_id = ?", arguments: [id])
        for name in Set(names) {
            var keywordID = try Int64.fetchOne(
                db, sql: "SELECT id FROM keywords WHERE name = ? AND parent_id IS NULL", arguments: [name])
            if keywordID == nil {
                try db.execute(sql: "INSERT INTO keywords (name) VALUES (?)", arguments: [name])
                keywordID = db.lastInsertedRowID
            }
            try db.execute(sql: "INSERT INTO image_keywords (image_id, keyword_id) VALUES (?, ?)",
                           arguments: [id, keywordID])
        }
    }
}
