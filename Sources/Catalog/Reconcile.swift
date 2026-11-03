import Foundation
import GRDB
import RawCore

/// What a reconciliation pass found and did.
public struct ReconcileReport: Sendable, CustomStringConvertible {
    public var added = 0
    /// Rows of the files added this pass (see `RecentlyAdded`).
    public var addedIDs: [Int64] = []
    public var modified = 0
    public var renamed = 0
    public var removed = 0
    public var unchanged = 0
    public var sidecarsRead = 0
    /// Unchanged files whose Finder tags changed since the last pass.
    public var tagsChanged = 0
    /// Subfolders with no decision yet (mode `ask`), relative paths.
    public var undecidedSubfolders: [String] = []
    /// New or changed files whose contents are in iCloud (or another file
    /// provider) and not on this Mac. Reading them would download them, so
    /// they're left for a pass after they've been downloaded.
    public var notDownloaded: [String] = []
    /// Files that couldn't be read, with the reason. They're skipped, not
    /// fatal — one corrupt file must not stop a folder from opening.
    public var failures: [(relPath: String, reason: String)] = []
    public var duration: TimeInterval = 0

    public var description: String {
        var parts = ["\(unchanged) unchanged", "\(added) added", "\(modified) modified",
                     "\(renamed) renamed", "\(removed) removed", "\(sidecarsRead) sidecars read"]
        if !undecidedSubfolders.isEmpty { parts.append("\(undecidedSubfolders.count) subfolders awaiting a decision") }
        if !notDownloaded.isEmpty { parts.append("\(notDownloaded.count) not downloaded") }
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
        /// Its contents are in the cloud, not on this Mac.
        var isDataless = false
    }

    /// Tests stand in for iCloud with this: a dataless file can't be made
    /// on purpose. Nil in the app.
    nonisolated(unsafe) static var datalessOverrideForTesting: (@Sendable (URL) -> Bool)?

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

        // 2. What the database thinks.
        let known = try dbQueue.read { db in try ImageRecord.fetchAll(db) }
        var knownByPath = Dictionary(uniqueKeysWithValues: known.map { ($0.relPath, $0) })

        // 3. Sort into buckets.
        var newFiles: [DiskFile] = []
        var modifiedFiles: [(DiskFile, ImageRecord)] = []
        var tagChanges: [(id: Int64, tags: String?)] = []
        var unchangedPaths: [String] = []
        // Sizes of the files left in iCloud this pass (step 5).
        var pendingSizes = Set<Int64>()
        for file in onDisk {
            if let record = knownByPath.removeValue(forKey: file.relPath) {
                if record.size == file.size && record.mtime == file.mtime {
                    report.unchanged += 1
                    unchangedPaths.append(file.relPath)
                    // Tagging in Finder moves no mtime, so tags are compared
                    // on every pass; only changed rows are written.
                    if record.finderTags != file.finderTags, let id = record.id {
                        tagChanges.append((id, file.finderTags))
                    }
                } else if file.isDataless {
                    // Changed, but hashing it would download it. The row
                    // stays as it is until the file is on this Mac.
                    report.notDownloaded.append(file.relPath)
                    pendingSizes.insert(file.size)
                    unchangedPaths.append(file.relPath)
                } else {
                    modifiedFiles.append((file, record))
                }
            } else if file.isDataless {
                report.notDownloaded.append(file.relPath)
                pendingSizes.insert(file.size)
            } else {
                newFiles.append(file)
            }
        }

        // 4. Expensive work, outside any transaction: hash the files that
        //    need it.
        var hashedNew: [(file: DiskFile, hash: Data)] = []
        for file in newFiles {
            do {
                hashedNew.append((file, ImageRecord.hashData(try FileHash.xxh64(ofFileAt: fileURL(forRelPath: file.relPath)))))
            } catch {
                report.failures.append((file.relPath, "hash failed: \(error)"))
            }
        }
        var hashedModified: [(file: DiskFile, previous: ImageRecord, hash: Data)] = []
        // A modified file that can't be read keeps its row as it is.
        var heldPaths: [String] = []
        for (file, previous) in modifiedFiles {
            do {
                hashedModified.append((file, previous, ImageRecord.hashData(try FileHash.xxh64(ofFileAt: fileURL(forRelPath: file.relPath)))))
            } catch {
                report.failures.append((file.relPath, "hash failed: \(error)"))
                heldPaths.append(file.relPath)
            }
        }

        // 5. Renames. A row can be claimed by a file with its content when
        //    its own file is gone, or when its path now holds other content
        //    (a rename chain or a swap: B.NEF to C.NEF, then A.NEF to
        //    B.NEF). Rows are queued per hash, so byte-identical copies
        //    renamed together each find a row.
        //
        //    A file left in iCloud can't be hashed, so it can't claim the
        //    row it was renamed from. A row that would go and has the size
        //    of such a file is kept for a later pass instead (a rename never
        //    changes the size). When a kept row's path holds another file
        //    now, that file is held too, along with the row it would have
        //    taken, so the plan is redone until nothing more needs holding.
        var heldModified = Set<String>()
        var keptIDs = Set<Int64>()
        var renames: [(from: ImageRecord, to: DiskFile)] = []
        var toInsert: [(file: DiskFile, hash: Data)] = []
        var toUpdate: [(file: DiskFile, previous: ImageRecord, hash: Data)] = []
        var removals: [ImageRecord] = []
        while true {
            let modified = hashedModified.filter { !heldModified.contains($0.file.relPath) }
            var claimable: [Data: [ImageRecord]] = [:]
            for record in knownByPath.values.sorted(by: { $0.relPath < $1.relPath }) {
                claimable[record.xxhash, default: []].append(record)
            }
            for entry in modified where entry.hash != entry.previous.xxhash {
                claimable[entry.previous.xxhash, default: []].append(entry.previous)
            }
            func claim(_ hash: Data, for relPath: String) -> ImageRecord? {
                guard var candidates = claimable[hash], !candidates.isEmpty else { return nil }
                // Of identical copies, the one with the same name (moved to
                // another subfolder) is the likeliest.
                let name = (relPath as NSString).lastPathComponent
                let index = candidates.firstIndex { ($0.relPath as NSString).lastPathComponent == name } ?? 0
                let record = candidates.remove(at: index)
                claimable[hash] = candidates.isEmpty ? nil : candidates
                return record
            }

            renames = []
            toInsert = []
            toUpdate = []
            var renamedTo = Set<String>()
            for entry in modified where entry.hash != entry.previous.xxhash {
                if let record = claim(entry.hash, for: entry.file.relPath) {
                    renames.append((record, entry.file))
                    renamedTo.insert(entry.file.relPath)
                }
            }
            for entry in hashedNew {
                if let record = claim(entry.hash, for: entry.file.relPath) {
                    renames.append((record, entry.file))
                    renamedTo.insert(entry.file.relPath)
                } else {
                    toInsert.append(entry)
                }
            }
            let claimedIDs = Set(renames.compactMap { $0.from.id })

            // A modified file that took no other row is either the same photo
            // with new content (its row stays and keeps what the user did to
            // it) or, when its row was claimed by a file elsewhere, a new photo.
            for entry in modified where !renamedTo.contains(entry.file.relPath) {
                if let id = entry.previous.id, claimedIDs.contains(id) {
                    toInsert.append((entry.file, entry.hash))
                } else {
                    toUpdate.append(entry)
                    if var queue = claimable[entry.previous.xxhash],
                       let index = queue.firstIndex(where: { $0.id == entry.previous.id }) {
                        queue.remove(at: index)
                        claimable[entry.previous.xxhash] = queue.isEmpty ? nil : queue
                    }
                }
            }

            // Whatever no file claimed has gone, unless it may be in iCloud
            // under another name.
            removals = []
            var replan = false
            for record in claimable.values.flatMap({ $0 }) {
                let keep = pendingSizes.contains(record.size) || record.id.map(keptIDs.contains) == true
                guard keep else {
                    removals.append(record)
                    continue
                }
                if renamedTo.contains(record.relPath) {
                    heldModified.insert(record.relPath)
                    if let taken = renames.first(where: { $0.to.relPath == record.relPath })?.from.id {
                        keptIDs.insert(taken)
                    }
                    replan = true
                }
            }
            if !replan { break }
        }
        // A held file's row stays as it is, like one that couldn't be read.
        heldPaths.append(contentsOf: heldModified)

        // 6. Move sidecars and thumbnails for renames before touching the
        //    database. A rename whose sidecar can't be moved is left for
        //    the next pass, with its row pointing at the old name.
        let moved = moveCompanions(of: renames, report: &report)
        renames = moved.renames
        toInsert.removeAll { moved.blockedPaths.contains($0.file.relPath) }

        // 7. Metadata for new and changed files.
        var inserts: [ImageRecord] = []
        for entry in toInsert {
            do {
                inserts.append(try makeRecord(for: entry.file, hash: entry.hash))
            } catch {
                report.failures.append((entry.file.relPath, "\(error)"))
            }
        }
        var updates: [ImageRecord] = []
        for (file, previous, hash) in toUpdate {
            do {
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
                fresh.title = previous.title
                fresh.caption = previous.caption
                fresh.creator = previous.creator
                fresh.copyright = previous.copyright
                fresh.sidecarMtime = previous.sidecarMtime
                fresh.thumbKey = nil   // pixels changed; thumbnail is stale
                updates.append(fresh)
            } catch {
                report.failures.append((file.relPath, "\(error)"))
            }
        }

        // 8. One transaction for all the row changes. Removals go first and
        //    renamed rows pass through a placeholder path, so a chain or a
        //    swap never has two rows on one path at once.
        let addedIDs = try dbQueue.write { db -> [Int64] in
            for record in removals {
                // image_keywords has no foreign key to cascade with.
                if let id = record.id {
                    try db.execute(sql: "DELETE FROM image_keywords WHERE image_id = ?", arguments: [id])
                }
                try record.delete(db)
            }
            for (previous, _) in renames {
                guard let id = previous.id else { continue }
                try db.execute(sql: "UPDATE images SET rel_path = ? WHERE id = ?",
                               arguments: ["\u{1}reconcile-\(id)", id])
            }
            for (previous, file) in renames {
                var row = previous
                row.relPath = file.relPath
                row.size = file.size
                row.mtime = file.mtime
                row.finderTags = file.finderTags
                if let id = previous.id, moved.thumbnailsLost.contains(id) { row.thumbKey = nil }
                try row.update(db)
            }
            for record in updates {
                try record.update(db)
            }
            var addedIDs: [Int64] = []
            for var record in inserts {
                try record.insert(db)
                if let id = record.id { addedIDs.append(id) }
            }
            for change in tagChanges {
                try db.execute(sql: "UPDATE images SET finder_tags = ? WHERE id = ?",
                               arguments: [change.tags, change.id])
            }
            // A pass that added nothing leaves the last batch in place.
            if !addedIDs.isEmpty { try Self.recordRecentlyAdded(addedIDs, at: start, in: db) }
            return addedIDs
        }
        report.added = inserts.count
        report.addedIDs = addedIDs
        report.modified = updates.count
        report.renamed = renames.count
        report.removed = removals.count
        report.tagsChanged = tagChanges.count

        // A removed row's thumbnail is a cache nothing will read again,
        // unless its path (in any letter case) is now some other row's.
        let livePaths = Set((unchangedPaths + heldPaths + renames.map(\.to.relPath)
                             + inserts.map(\.relPath) + updates.map(\.relPath)
                             + moved.blockedPaths).map { $0.lowercased() })
        for record in removals where !livePaths.contains(record.relPath.lowercased()) {
            try? FileManager.default.removeItem(at: thumbnailURL(forRelPath: record.relPath))
        }

        // A file renamed outside Latent keeps its place in the custom order.
        if !renames.isEmpty {
            do {
                try renameInCustomOrder(renames.map { ($0.from.relPath, $0.to.relPath) })
            } catch {
                report.failures.append((CustomOrder.fileName, "custom order not updated: \(error)"))
            }
        }

        // 9. Sidecars: re-read only those whose mtime moved.
        report.sidecarsRead = try syncSidecars(report: &report, leaving: moved.sidecarsMissing)

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
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .contentModificationDateKey, .nameKey,
                                      .ubiquitousItemDownloadingStatusKey]
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
                // A package (a Photos library, an app) is one document to
                // Finder and the sidebar, and its insides belong to the app
                // that made it. Rewriting files in there would damage it.
                if values.isPackage == true { continue }
                // Independent by existence, under either container name, as
                // the sidebar and transfers see it.
                if FolderAccess.hasCatalog(entry) { continue }

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
            // A named pipe or device called *.nef would block the read
            // that hashes it, and the whole catalog with it.
            guard values.isRegularFile == true else { continue }
            files.append(DiskFile(
                relPath: relPath,
                size: Int64(values.fileSize ?? 0),
                mtime: ImageRecord.milliseconds(values.contentModificationDate ?? .distantPast),
                finderTags: FinderTag.encode(FinderTag.read(from: entry)),
                isDataless: Self.isDataless(entry, values)))
        }
    }

    /// Whether a file's contents are only in the cloud: evicted by
    /// Optimize Mac Storage, or a placeholder from another file provider.
    /// Opening one would download it.
    static func isDataless(_ url: URL, _ values: URLResourceValues) -> Bool {
        if let override = datalessOverrideForTesting { return override(url) }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded { return true }
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_flags & UInt32(SF_DATALESS)) != 0
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

    /// What moving the companions of a pass's renames came to.
    struct CompanionMoves {
        /// The renames that can go ahead.
        var renames: [(from: ImageRecord, to: DiskFile)] = []
        /// Paths still held by rows whose rename waits for the next pass.
        var blockedPaths: [String] = []
        /// Rows whose thumbnail couldn't follow them; they get a new one.
        var thumbnailsLost = Set<Int64>()
        /// New paths whose sidecar couldn't be put in place. Their rows are
        /// not reset to defaults for want of one (the sidecar is reported
        /// where it is).
        var sidecarsMissing = Set<String>()
    }

    /// Same-volume renames of each renamed file's sidecar and thumbnail.
    /// Nothing is copied (DESIGN.md §5.2) and nothing is overwritten.
    ///
    /// Every companion first moves to a hidden name beside itself, then on
    /// to its new name, so chains, swaps and changes of letter case on a
    /// case-insensitive volume never find their destination still taken
    /// by another source (or by themselves). A sidecar already at a new
    /// name was left by a deleted file; it is set aside under a dated name,
    /// never deleted. A thumbnail there is a cache and is replaced.
    func moveCompanions(of renames: [(from: ImageRecord, to: DiskFile)],
                        report: inout ReconcileReport) -> CompanionMoves {
        struct Staged { let from: URL; let hidden: URL; let to: URL; let isSidecar: Bool }
        let fm = FileManager.default
        var staged: [[Staged]] = Array(repeating: [], count: renames.count)
        var failed = Set<Int>()

        // Phase 1: everything out of the way.
        for (i, rename) in renames.enumerated() {
            let pairs = [(sidecarURL(forRelPath: rename.from.relPath), sidecarURL(forRelPath: rename.to.relPath), true),
                         (thumbnailURL(forRelPath: rename.from.relPath), thumbnailURL(forRelPath: rename.to.relPath), false)]
            for (from, to, isSidecar) in pairs where FileOperations.itemExists(from) {
                let hidden = from.deletingLastPathComponent()
                    .appendingPathComponent(".latent-rename-\(UUID().uuidString)")
                do {
                    try FileOperations.renameExclusively(from, to: hidden)
                    staged[i].append(Staged(from: from, hidden: hidden, to: to, isSidecar: isSidecar))
                } catch where isSidecar {
                    report.failures.append((rename.to.relPath, "sidecar not moved from \(rename.from.relPath): \(error)"))
                    failed.insert(i)
                    break
                } catch {
                    // Only a thumbnail; the row gets a new one.
                }
            }
        }

        // A rename that waits keeps its row on the old path, so a rename
        // onto that path (a chain or a swap) has to wait too.
        var held = Set(failed.map { renames[$0].from.relPath })
        var changed = !failed.isEmpty
        while changed {
            changed = false
            for (i, rename) in renames.enumerated() where !failed.contains(i) && held.contains(rename.to.relPath) {
                failed.insert(i)
                held.insert(rename.from.relPath)
                report.failures.append((rename.to.relPath, "rename from \(rename.from.relPath) waits for \(rename.to.relPath) to be free"))
                changed = true
            }
        }

        var result = CompanionMoves()
        for i in failed.sorted() {
            for item in staged[i] where (try? FileOperations.renameExclusively(item.hidden, to: item.from)) == nil {
                report.failures.append((renames[i].from.relPath, "companion left at \(item.hidden.path)"))
            }
            result.blockedPaths.append(renames[i].from.relPath)
        }

        // Phase 2: everything to its new name.
        for (i, rename) in renames.enumerated() where !failed.contains(i) {
            result.renames.append(rename)
            var thumbnailMoved = false
            for item in staged[i] {
                do {
                    try fm.createDirectory(at: item.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileOperations.itemExists(item.to) {
                        if item.isSidecar {
                            let aside = try Self.setAside(item.to)
                            report.failures.append((rename.to.relPath, "a sidecar left by a deleted file was moved to \(aside.lastPathComponent)"))
                        } else {
                            try fm.removeItem(at: item.to)
                        }
                    }
                    try FileOperations.renameExclusively(item.hidden, to: item.to)
                    if !item.isSidecar { thumbnailMoved = true }
                } catch {
                    let back = (try? FileOperations.renameExclusively(item.hidden, to: item.from)) != nil
                    let left = back ? item.from : item.hidden
                    if item.isSidecar {
                        report.failures.append((rename.to.relPath, "sidecar not moved, left at \(left.path): \(error)"))
                        result.sidecarsMissing.insert(rename.to.relPath)
                    }
                }
            }
            let hadThumbnail = rename.from.thumbKey != nil
            if hadThumbnail && !thumbnailMoved, let id = rename.from.id { result.thumbnailsLost.insert(id) }
        }
        return result
    }

    /// Renames a sidecar that must make way to `<name>.orphaned-<date>.xmp`
    /// beside it (numbered if that is taken), and returns the new URL.
    static func setAside(_ sidecar: URL, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let folder = sidecar.deletingLastPathComponent()
        let stem = sidecar.deletingPathExtension().lastPathComponent
        let stamp = formatter.string(from: now)
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let target = folder.appendingPathComponent("\(stem).orphaned-\(stamp)\(suffix).xmp")
            do {
                try FileOperations.renameExclusively(sidecar, to: target)
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists && attempt < 100 {
                attempt += 1
            }
        }
    }

    // MARK: - Sidecars

    /// Applies any sidecar whose mtime differs from what the row recorded.
    /// Sidecars are authoritative (DESIGN.md §5.3), so their rating, label,
    /// keywords and edit stack overwrite the row's. Returns how many were
    /// read. Rows at `missing` lost their sidecar to a move that failed
    /// this pass and keep what they have.
    private func syncSidecars(report: inout ReconcileReport, leaving missing: Set<String> = []) throws -> Int {
        let records = try dbQueue.read { db in try ImageRecord.fetchAll(db) }
        let fm = FileManager.default
        var applied: [(ImageRecord, XMPSidecar.Fields?, Int64?)] = []

        for record in records {
            let url = sidecarURL(forRelPath: record.relPath)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date else {
                // No sidecar. If there used to be one, its metadata is gone
                // with it: the row goes back to defaults.
                if record.sidecarMtime != nil && !missing.contains(record.relPath) {
                    applied.append((record, nil, nil))
                }
                continue
            }
            let mtime = ImageRecord.milliseconds(date)
            guard mtime != record.sidecarMtime else { continue }
            let fields: XMPSidecar.Fields
            do {
                fields = try XMPSidecar.read(from: url)
            } catch {
                report.failures.append((record.relPath + ".xmp", "sidecar unreadable: \(error)"))
                continue
            }
            // A row that has never had a sidecar meeting one written for
            // other content: a file deleted earlier left it, and a new photo
            // has taken its name. Applying it would give the new photo the
            // old one's rating and edits, so it is set aside instead.
            if record.sidecarMtime == nil, !fields.sourceHash.isEmpty, fields.sourceHash != record.hashString {
                do {
                    let aside = try Self.setAside(url)
                    report.failures.append((record.relPath + ".xmp",
                                            "sidecar was written for another file; moved to \(aside.lastPathComponent)"))
                } catch {
                    report.failures.append((record.relPath + ".xmp",
                                            "sidecar was written for another file and not applied: \(error)"))
                }
                continue
            }
            applied.append((record, fields, mtime))
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
                // Title, caption, creator and copyright too: the sidecar
                // is the truth, and one without them clears them.
                row.title = fields?.title
                row.caption = fields?.caption
                row.creator = fields?.creator
                row.copyright = fields?.copyright
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
