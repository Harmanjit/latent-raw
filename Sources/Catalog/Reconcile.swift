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
    /// New photos that took their rating, label and keywords from another
    /// application's sidecar beside them (ForeignSidecar).
    public var foreignSidecarsRead = 0
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
    /// File extensions Latent indexes: every raw format, and the ordinary
    /// picture formats this Mac's ImageIO decodes (JPEG, HEIC, TIFF, PNG,
    /// and WebP, AVIF and JPEG XL where available; `RenderedImageFormat`).
    public static let indexedExtensions: Set<String> = rawExtensions.union(RenderedImageFormat.extensions)

    /// The raw formats, which LibRaw reads.
    public static let rawExtensions: Set<String> = [
        "nef", "nrw",                       // Nikon
        "arw", "srf", "sr2",                // Sony
        "cr2", "cr3", "crw",                // Canon
        "dng",                              // Adobe / phones / Leica
        "raf", "orf", "rw2", "pef", "srw",  // Fuji, Olympus, Panasonic, Pentax, Samsung
        "3fr", "fff", "iiq", "mos", "mrw", "x3f",
        // Rarer and older formats LibRaw also reads: ARRI, Casio, Phase One
        // and Leaf, Kodak, Epson, Mamiya, GoPro, Logitech, Apple QuickTake,
        // Sinar, Minolta, Leica and Panasonic, and others.
        "ari", "bay", "bmq", "cap", "cine", "cs1", "dc2", "dcr", "erf", "gpr", "ia",
        "k25", "kc2", "kdc", "mdc", "mef", "pxn", "qtk", "raw", "rdc", "rw1", "sti",
    ]

    /// A file as seen on disk during the scan.
    struct DiskFile: Sendable {
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

    /// Tests stand in for a card's exFAT or FAT volume with this: whether
    /// the Finder-tag memo may be trusted for a directory. Nil in the app.
    nonisolated(unsafe) static var tagMemoTrustOverrideForTesting: (@Sendable (URL) -> Bool)?

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
        //    Virtual copies have no file of their own: they follow their
        //    master's row (VirtualCopySchema), so only masters are matched
        //    against the disk.
        let everything = try dbQueue.read { db in try ImageRecord.fetchAll(db) }
        let known = everything.filter { !$0.isVirtualCopy }
        let copies = everything.filter(\.isVirtualCopy)
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
                    // on every pass (read again where the status-change time
                    // moved, or always off APFS, see `finderTags(of:...)`);
                    // only changed rows are written.
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

        // 4. Expensive work, outside any transaction, in one pass over each
        //    new or changed file, a few files at once (ImportWorkers): its
        //    hash, read in large chunks, then its metadata while its header
        //    is still in memory. Metadata is read now only for files that
        //    can't be a rename: a rename keeps the size, so a file whose
        //    size no claimable row has is new or changed in place. The rest
        //    wait for the plan (step 5) and are read in step 7 if needed.
        let claimableSizes = Set(knownByPath.values.map(\.size)).union(modifiedFiles.map(\.1.size))
        let jobs: [(file: DiskFile, url: URL, wantsRecord: Bool)] = (newFiles + modifiedFiles.map(\.0)).map {
            ($0, fileURL(forRelPath: $0.relPath), !claimableSizes.contains($0.size))
        }
        let width = ImportWorkers.width(forFolderAt: rootPath)
        let passed = ImportWorkers.map(count: jobs.count, width: width) {
            index, buffer -> (hash: Result<Data, any Error>, record: Result<ImageRecord, any Error>?) in
            let job = jobs[index]
            let hash = Result { ImageRecord.hashData(try FileHash.xxh64(ofFileAt: job.url, uncached: false, buffer: buffer)) }
            guard job.wantsRecord, case .success(let value) = hash else { return (hash, nil) }
            return (hash, Result { try Self.makeRecord(for: job.file, at: job.url, hash: value) })
        }
        let hashes = passed.map(\.hash)
        var readRecords: [String: Result<ImageRecord, any Error>] = [:]
        for (job, result) in zip(jobs, passed) where result.record != nil {
            readRecords[job.file.relPath] = result.record
        }
        var hashedNew: [(file: DiskFile, hash: Data)] = []
        for (file, result) in zip(newFiles, hashes) {
            switch result {
            case .success(let hash): hashedNew.append((file, hash))
            case .failure(let error): report.failures.append((file.relPath, "hash failed: \(error)"))
            }
        }
        var hashedModified: [(file: DiskFile, previous: ImageRecord, hash: Data)] = []
        // A modified file that can't be read keeps its row as it is.
        var heldPaths: [String] = []
        for ((file, previous), result) in zip(modifiedFiles, hashes.dropFirst(newFiles.count)) {
            switch result {
            case .success(let hash): hashedModified.append((file, previous, hash))
            case .failure(let error):
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

        // 7. Metadata for new and changed files: read in step 4 for most,
        //    read now for those step 4 left for the plan.
        let late = (toInsert.map { ($0.file, $0.hash) } + toUpdate.map { ($0.file, $0.hash) })
            .filter { readRecords[$0.0.relPath] == nil }
            .map { (file: $0.0, url: fileURL(forRelPath: $0.0.relPath), hash: $0.1) }
        let lateRecords = ImportWorkers.map(count: late.count, width: width) {
            index, _ -> Result<ImageRecord, any Error> in
            Result { try Self.makeRecord(for: late[index].file, at: late[index].url, hash: late[index].hash) }
        }
        for (job, result) in zip(late, lateRecords) { readRecords[job.file.relPath] = result }

        var inserts: [ImageRecord] = []
        for entry in toInsert {
            do {
                guard let read = readRecords[entry.file.relPath] else { continue }
                inserts.append(try read.get())
            } catch {
                report.failures.append((entry.file.relPath, "\(error)"))
            }
        }
        var updates: [ImageRecord] = []
        for (file, previous, _) in toUpdate {
            do {
                guard let read = readRecords[file.relPath] else { continue }
                var fresh = try read.get()
                // Content changed but it's the same photo as far as the
                // user is concerned: keep everything they've done to it.
                fresh.id = previous.id
                fresh.rating = previous.rating
                fresh.label = previous.label
                fresh.flag = previous.flag
                fresh.userRotation = previous.userRotation
                fresh.preservedName = previous.preservedName
                fresh.mergeJSON = previous.mergeJSON
                fresh.copyDescriptive(from: previous)
                fresh.carryGeoTime(from: previous)
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
        // Their virtual copies went with them (the rows by cascade). Their
        // thumbnails go; their sidecars stay, like the masters', so a file
        // that comes back brings its copies back.
        let removedPaths = Set(removals.map(\.relPath))
        for copy in copies where VirtualCopy.parse(copy.relPath).map({ removedPaths.contains($0.masterRelPath) }) == true {
            try? FileManager.default.removeItem(at: thumbnailURL(forRelPath: copy.relPath))
        }

        // A file renamed outside Latent keeps its place in the custom order.
        if !renames.isEmpty {
            do {
                try renameInCustomOrder(renames.map { ($0.from.relPath, $0.to.relPath) })
            } catch {
                report.failures.append((CustomOrder.fileName, "custom order not updated: \(error)"))
            }
        }

        // 9. Sidecars: re-read only those whose mtime moved. Copies whose
        //    sidecar is here but whose row is not (a rebuilt database) get a
        //    row first, for this pass to fill.
        let restored = restoreVirtualCopiesFromSidecars(report: &report)
        // A pass that changed no row reuses the rows it read in step 2.
        let rowsUnchanged = restored == 0 && removals.isEmpty && renames.isEmpty && updates.isEmpty
            && inserts.isEmpty && tagChanges.isEmpty
        report.sidecarsRead = try syncSidecars(report: &report, leaving: moved.sidecarsMissing,
                                               rows: rowsUnchanged ? everything : nil)
        // 10. Photos that arrived with another application's sidecar and
        //     none of Latent's (ForeignSidecar), and EXIF extras for rows
        //     made before they were read (ExifExtras), a batch per pass.
        report.foreignSidecarsRead = importForeignSidecars(forNewImageIDs: addedIDs, report: &report)
        _ = try? backfillExifExtras()

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
        nextScanTagMemo = [:]
        try scan(directory: rootPath, relPrefix: "", defaultMode: defaultMode,
                 into: &files, report: &report)
        // Only files seen this pass are remembered, so the memo never
        // outgrows the folder.
        scanTagMemo = nextScanTagMemo
        nextScanTagMemo = [:]
        return files.sorted { $0.relPath < $1.relPath }
    }

    private func scan(directory: URL, relPrefix: String, defaultMode: SubfolderMode,
                      into files: inout [DiskFile], report: inout ReconcileReport) throws {
        // One bulk listing: name, kind, size, times and flags for every
        // entry, no per-file calls but the Finder-tag read, and that only
        // for files whose status-change time moved since the last pass.
        let entries = try DirectoryListing.entries(of: directory)
            .sorted { $0.name < $1.name }
        // Asked per directory: a subfolder can be another volume's mount.
        let tagMemoTrusted = Self.tagMemoTrusted(for: directory)

        for entry in entries {
            // `.skipsHiddenFiles`, as the listing used to ask for.
            if entry.isHidden { continue }
            let name = entry.name
            let relPath = relPrefix.isEmpty ? name : relPrefix + "/" + name

            // A symlink could point anywhere on the disk; a catalog is one
            // folder and stays inside it. Files that are links are skipped
            // for the same reason: their sidecar would be written here for
            // a photo that lives elsewhere.
            if entry.kind == .symbolicLink { continue }

            if entry.kind == .directory {
                if name == Self.containerName || name == Self.legacyContainerName { continue }
                let url = directory.appendingPathComponent(name, isDirectory: true)
                // A package (a Photos library, an app) is one document to
                // Finder and the sidebar, and its insides belong to the app
                // that made it. Rewriting files in there would damage it.
                if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { continue }
                // Independent by existence, under either container name, as
                // the sidebar and transfers see it.
                if FolderAccess.hasCatalog(url) { continue }

                var mode = try subfolderMode(forRelPath: relPath)
                if mode == nil {
                    // First sighting: record the default so the decision
                    // is visible and editable in the subfolders table.
                    mode = defaultMode
                    try setSubfolderMode(defaultMode, forRelPath: relPath)
                }
                switch mode! {
                case .included:
                    try scan(directory: url, relPrefix: relPath, defaultMode: defaultMode,
                             into: &files, report: &report)
                case .independent:
                    continue
                case .ask:
                    report.undecidedSubfolders.append(relPath)
                }
                continue
            }

            guard Self.indexedExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            // A named pipe or device called *.nef would block the read
            // that hashes it, and the whole catalog with it.
            guard entry.kind == .file else { continue }
            let url = directory.appendingPathComponent(name, isDirectory: false)
            files.append(DiskFile(
                relPath: relPath,
                size: entry.size,
                mtime: ImageRecord.milliseconds(DirectoryListing.date(entry.modified)),
                finderTags: finderTags(of: url, relPath: relPath, changed: entry.changed,
                                       memoTrusted: tagMemoTrusted),
                isDataless: Self.isDataless(url, flags: entry.flags)))
        }
    }

    /// The file's Finder tags in stored form. On APFS, setting a tag (an
    /// extended attribute) moves the file's status-change time, kept to the
    /// nanosecond, so tags read on an earlier pass of this catalog still
    /// hold while that time hasn't moved, and a refresh of an unchanged
    /// folder reads none. Elsewhere the memo is not used: on exFAT and FAT
    /// (camera cards) the attribute goes into the `._` AppleDouble file and
    /// neither time moves, and HFS+ keeps whole seconds only.
    private func finderTags(of url: URL, relPath: String, changed: timespec, memoTrusted: Bool) -> String? {
        if memoTrusted, let known = scanTagMemo[relPath], known.changed.tv_sec == changed.tv_sec,
           known.changed.tv_nsec == changed.tv_nsec {
            nextScanTagMemo[relPath] = known
            return known.tags
        }
        let tags = FinderTag.encode(FinderTag.read(from: url))
        if memoTrusted { nextScanTagMemo[relPath] = (changed, tags) }
        return tags
    }

    /// Whether the volume holding `directory` moves a file's status-change
    /// time, at nanosecond resolution, when an extended attribute is set:
    /// APFS only. Unknown is untrusted.
    static func tagMemoTrusted(for directory: URL) -> Bool {
        if let override = tagMemoTrustOverrideForTesting { return override(directory) }
        var fs = statfs()
        guard statfs(directory.path, &fs) == 0 else { return false }
        let name = withUnsafeBytes(of: &fs.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name == "apfs"
    }

    /// Whether a file's contents are only in the cloud: evicted by
    /// Optimize Mac Storage, or a placeholder from another file provider.
    /// Opening one would download it.
    static func isDataless(_ url: URL, flags: UInt32) -> Bool {
        if let override = datalessOverrideForTesting { return override(url) }
        return flags & UInt32(SF_DATALESS) != 0
    }

    static func isDataless(_ url: URL, _ values: URLResourceValues) -> Bool {
        if let override = datalessOverrideForTesting { return override(url) }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded { return true }
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_flags & UInt32(SF_DATALESS)) != 0
    }

    // MARK: - Metadata

    /// Reads what the catalog needs from a raw file without decoding it.
    /// Static and touching nothing of the catalog's, so import workers can
    /// run it off the actor.
    static func makeRecord(for file: DiskFile, at url: URL, hash: Data) throws -> ImageRecord {
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
        var record = ImageRecord(
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
        record.apply(ExifExtras.read(from: url))
        return record
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
    ///
    /// `rows` is every row as it stands, when the caller has them; they're
    /// read here otherwise.
    private func syncSidecars(report: inout ReconcileReport, leaving missing: Set<String> = [],
                              rows: [ImageRecord]? = nil) throws -> Int {
        let records = try rows ?? dbQueue.read { db in try ImageRecord.fetchAll(db) }
        var applied: [(ImageRecord, XMPSidecar.Fields?, Int64?)] = []

        for record in records {
            let url = sidecarURL(forRelPath: record.relPath)
            // `lstat` rather than `attributesOfItem` (which also doesn't
            // follow links) at a tenth of the cost, its time converted as
            // Foundation converts it.
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                // No sidecar. If there used to be one, its metadata is gone
                // with it: the row goes back to defaults.
                if record.sidecarMtime != nil && !missing.contains(record.relPath) {
                    applied.append((record, nil, nil))
                }
                continue
            }
            let mtime = ImageRecord.milliseconds(DirectoryListing.date(info.st_mtimespec))
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
                for field in DescriptiveField.more { field.set(fields?.more[field], on: &row) }
                // A capture-time correction and a geotag likewise (GeoTime).
                row.applyGeoTime(from: fields)
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
