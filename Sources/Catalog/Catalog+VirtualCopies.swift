import Foundation
import GRDB

/// Everything a virtual copy holds of its own, enough to put it back exactly
/// as it was: the undo of removing a copy, and the redo of making one.
public struct VirtualCopyArchive: Sendable, Equatable {
    public struct Snapshot: Sendable, Equatable {
        public var name: String
        public var stackJSON: String
    }

    public struct HistoryStep: Sendable, Equatable {
        public var stackJSON: String
        public var createdAt: Int64
    }

    /// The copy's row id. Put back under the same id, so undo actions filed
    /// against it (a rating, say) still find it.
    public var id: Int64
    public var masterID: Int64
    public var key: VirtualCopy.Key
    public var rating: Int
    public var label: String?
    public var flag: Int
    public var userRotation: Int
    public var keywords: [String]
    public var edit: StoredEdit?
    public var snapshots: [Snapshot]
    public var history: [HistoryStep]
}

/// A virtual copy could not be made or changed.
public enum VirtualCopyError: Error, CustomStringConvertible, Equatable {
    case noSuchImage
    case notAVirtualCopy
    case masterGone

    public var description: String {
        switch self {
        case .noSuchImage: "The image is no longer in the catalog."
        case .notAVirtualCopy: "The image is not a virtual copy."
        case .masterGone: "The photo the copy belongs to is no longer in the catalog."
        }
    }
}

extension Catalog {
    // MARK: Reading

    /// The master's row id of a copy, nil for any other image.
    public func masterID(ofImageID id: Int64) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT master_id FROM images WHERE id = ?", arguments: [id])
        }
    }

    /// Ids of a master's virtual copies, by copy number.
    public func virtualCopyIDs(ofMaster id: Int64) throws -> [Int64] {
        try dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM images WHERE master_id = ? ORDER BY rel_path",
                               arguments: [id])
        }
    }

    /// The copy as it is now, or nil when `id` is not a virtual copy.
    public func virtualCopyArchive(id: Int64) throws -> VirtualCopyArchive? {
        try dbQueue.read { db in try Self.archive(id: id, in: db) }
    }

    static func archive(id: Int64, in db: Database) throws -> VirtualCopyArchive? {
        guard let row = try ImageRecord.fetchOne(db, key: id),
              let masterID = try Int64.fetchOne(db, sql: "SELECT master_id FROM images WHERE id = ?", arguments: [id]),
              let key = VirtualCopy.parse(row.relPath)?.key else { return nil }
        let data = try Self.ownData(of: id, in: db)
        return VirtualCopyArchive(id: id, masterID: masterID, key: key, rating: row.rating, label: row.label,
                                  flag: row.flag, userRotation: row.userRotation, keywords: data.keywords,
                                  edit: data.edit, snapshots: data.snapshots, history: data.history)
    }

    /// What a row holds outside the `images` table.
    private static func ownData(of id: Int64, in db: Database) throws
        -> (keywords: [String], edit: StoredEdit?, snapshots: [VirtualCopyArchive.Snapshot],
            history: [VirtualCopyArchive.HistoryStep]) {
        let keywords = try String.fetchAll(db, sql: """
            SELECT k.name FROM keywords k JOIN image_keywords ik ON ik.keyword_id = k.id
            WHERE ik.image_id = ? ORDER BY k.name
            """, arguments: [id])
        let edit = try Row.fetchOne(db, sql: """
            SELECT params_json, schema_version, process_version FROM edits WHERE image_id = ?
            """, arguments: [id]).map { row in
            StoredEdit(json: row["params_json"], schemaVersion: row["schema_version"] ?? 1,
                       processVersion: row["process_version"] ?? "1.0")
        }
        let snapshots = try Row.fetchAll(db, sql: "SELECT name, params_json FROM snapshots WHERE image_id = ? ORDER BY name",
                                         arguments: [id])
            .map { VirtualCopyArchive.Snapshot(name: $0["name"], stackJSON: $0["params_json"]) }
        let history = try Row.fetchAll(db, sql: "SELECT params_json, created_at FROM history WHERE image_id = ? ORDER BY step",
                                       arguments: [id])
            .map { VirtualCopyArchive.HistoryStep(stackJSON: $0["params_json"], createdAt: $0["created_at"] ?? 0) }
        return (keywords, edit, snapshots, history)
    }

    /// Replaces what a row holds outside the `images` table.
    fileprivate static func replaceOwnData(of id: Int64, keywords: [String], edit: StoredEdit?,
                                       snapshots: [VirtualCopyArchive.Snapshot],
                                       history: [VirtualCopyArchive.HistoryStep], in db: Database) throws {
        try replaceKeywords(keywords, forImageID: id, in: db)
        if let edit {
            try db.execute(sql: """
                INSERT OR REPLACE INTO edits (image_id, schema_version, process_version, params_json, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id, edit.schemaVersion, edit.processVersion, edit.json, ImageRecord.milliseconds(Date())])
        } else {
            try db.execute(sql: "DELETE FROM edits WHERE image_id = ?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM snapshots WHERE image_id = ?", arguments: [id])
        for snapshot in snapshots {
            try db.execute(sql: "INSERT INTO snapshots (image_id, name, params_json) VALUES (?, ?, ?)",
                           arguments: [id, snapshot.name, snapshot.stackJSON])
        }
        try db.execute(sql: "DELETE FROM history WHERE image_id = ?", arguments: [id])
        for (step, entry) in history.enumerated() {
            try db.execute(sql: "INSERT INTO history (image_id, step, params_json, created_at) VALUES (?, ?, ?, ?)",
                           arguments: [id, step, entry.stackJSON, entry.createdAt])
        }
    }

    // MARK: Making and removing

    /// Makes a virtual copy of the image `id` and writes its sidecar. A copy
    /// of a copy is another copy of the same master, as in Lightroom.
    ///
    /// The new copy starts with the image's edit, rating, label, flag,
    /// rotation and keywords (what you see is what you copy), and with an
    /// empty history and no snapshots of its own. It takes the next number
    /// among its master's copies, and the image's thumbnail, which already
    /// shows that edit.
    public func createVirtualCopy(of id: Int64) throws -> VirtualCopyArchive {
        let archive: VirtualCopyArchive = try dbQueue.write { db in
            guard let source = try ImageRecord.fetchOne(db, key: id) else { throw VirtualCopyError.noSuchImage }
            let masterID = try Int64.fetchOne(db, sql: "SELECT master_id FROM images WHERE id = ?", arguments: [id]) ?? id
            guard let master = try ImageRecord.fetchOne(db, key: masterID) else { throw VirtualCopyError.masterGone }
            let siblings = try String.fetchAll(db, sql: "SELECT rel_path FROM images WHERE master_id = ?",
                                               arguments: [masterID])
            let number = (siblings.compactMap { VirtualCopy.parse($0)?.key.number }.max() ?? 0) + 1
            var token = VirtualCopy.Key.randomToken()
            while try Self.tokenIsTaken(token, in: db) { token = VirtualCopy.Key.randomToken() }
            let data = try Self.ownData(of: id, in: db)
            return try VirtualCopyArchive(id: 0, masterID: masterID, key: VirtualCopy.Key(number: number, token: token),
                                      rating: source.rating, label: source.label, flag: source.flag,
                                      userRotation: source.userRotation, keywords: data.keywords, edit: data.edit,
                                      snapshots: [], history: [])
                .inserting(from: master, thumbKey: source.thumbKey, in: db)
        }
        // The source's thumbnail already shows this edit; the key recorded
        // with it is the one this edit calls for, so no pass remakes it.
        // A copy's thumbnail is named by its key alone (VirtualCopy).
        let thumbnail = thumbnailURL(forRelPath: VirtualCopy.relPath(master: "x", key: archive.key))
        if let sourceRow = try dbQueue.read({ db in try ImageRecord.fetchOne(db, key: id) }) {
            let source = thumbnailURL(forRelPath: sourceRow.relPath)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                if (try? FileManager.default.copyItem(at: source, to: thumbnail)) == nil {
                    try dbQueue.write { db in
                        try db.execute(sql: "UPDATE images SET thumb_key = NULL WHERE id = ?", arguments: [archive.id])
                    }
                }
            }
        }
        try writeSidecar(forImageID: archive.id)
        return archive
    }

    private static func tokenIsTaken(_ token: String, in db: Database) throws -> Bool {
        let paths = try String.fetchAll(db, sql: "SELECT rel_path FROM images WHERE master_id IS NOT NULL")
        return paths.contains { VirtualCopy.parse($0)?.key.token == token }
    }

    /// Puts a copy back from its archive, under its old id when that is
    /// free, and writes its sidecar. Its master must still be here.
    @discardableResult
    public func restoreVirtualCopy(_ archive: VirtualCopyArchive) throws -> Int64 {
        let id: Int64 = try dbQueue.write { db in
            guard let master = try ImageRecord.fetchOne(db, key: archive.masterID),
                  !master.isVirtualCopy else { throw VirtualCopyError.masterGone }
            let path = VirtualCopy.relPath(master: master.relPath, key: archive.key)
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM images WHERE rel_path = ?", arguments: [path]) {
                return existing
            }
            return try archive.inserting(from: master, thumbKey: nil, in: db).id
        }
        try writeSidecar(forImageID: id)
        return id
    }

    /// Takes a copy out of the catalog and returns it as it was. Its sidecar
    /// and thumbnail go too: they are Latent's own files, and a sidecar left
    /// behind would bring the copy back on the next reconcile. The raw file
    /// is its master's and is never touched. Nil when `id` is not a copy.
    @discardableResult
    public func removeVirtualCopy(id: Int64) throws -> VirtualCopyArchive? {
        let removed: (VirtualCopyArchive, String)? = try dbQueue.write { db in
            guard let archive = try Self.archive(id: id, in: db),
                  let row = try ImageRecord.fetchOne(db, key: id) else { return nil }
            try db.execute(sql: "DELETE FROM image_keywords WHERE image_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM images WHERE id = ?", arguments: [id])
            return (archive, row.relPath)
        }
        guard let removed else { return nil }
        removeCompanions(ofCopyAt: removed.1)
        return removed.0
    }

    /// Deletes a copy's sidecar and thumbnail, if they are there.
    func removeCompanions(ofCopyAt relPath: String) {
        for url in [sidecarURL(forRelPath: relPath), thumbnailURL(forRelPath: relPath)]
            where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Set Copy as Master

    /// Lightroom's Set Copy as Master: the copy's edit, rating, label, flag,
    /// rotation, keywords, history and snapshots become the master's, and
    /// the master's become the copy's. Both rows keep their ids and paths,
    /// so the copy keeps its number. Doing it twice puts everything back,
    /// which is its undo. Both thumbnails are remade. Returns the master's id.
    @discardableResult
    public func setCopyAsMaster(copyID: Int64) throws -> Int64 {
        let masterID: Int64 = try dbQueue.write { db in
            guard let copy = try ImageRecord.fetchOne(db, key: copyID) else { throw VirtualCopyError.noSuchImage }
            guard let masterID = try Int64.fetchOne(db, sql: "SELECT master_id FROM images WHERE id = ?", arguments: [copyID])
            else { throw VirtualCopyError.notAVirtualCopy }
            guard let master = try ImageRecord.fetchOne(db, key: masterID) else { throw VirtualCopyError.masterGone }
            let copyData = try Self.ownData(of: copyID, in: db)
            let masterData = try Self.ownData(of: masterID, in: db)
            var newMaster = master, newCopy = copy
            (newMaster.rating, newCopy.rating) = (copy.rating, master.rating)
            (newMaster.label, newCopy.label) = (copy.label, master.label)
            (newMaster.flag, newCopy.flag) = (copy.flag, master.flag)
            (newMaster.userRotation, newCopy.userRotation) = (copy.userRotation, master.userRotation)
            newMaster.thumbKey = nil
            newCopy.thumbKey = nil
            try newMaster.update(db)
            try newCopy.update(db)
            try Self.replaceOwnData(of: masterID, keywords: copyData.keywords, edit: copyData.edit,
                                    snapshots: copyData.snapshots, history: copyData.history, in: db)
            try Self.replaceOwnData(of: copyID, keywords: masterData.keywords, edit: masterData.edit,
                                    snapshots: masterData.snapshots, history: masterData.history, in: db)
            return masterID
        }
        try writeSidecar(forImageID: masterID)
        try writeSidecar(forImageID: copyID)
        return masterID
    }

    // MARK: Rebuilding from sidecars

    /// Makes a row for every copy sidecar whose copy the database doesn't
    /// have, when a master with the content it was written for is here: a
    /// database rebuilt after damage, or a master moved out of the folder
    /// and back. The new row has no sidecar time, so the sidecar pass that
    /// follows applies the sidecar to it as to any new photo's. Copies are
    /// numbered and tokened by their sidecar's name. Returns how many.
    func restoreVirtualCopiesFromSidecars(report: inout ReconcileReport) -> Int {
        let folder = xmpDirectory.appendingPathComponent(VirtualCopy.companionFolder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        let keys = names.filter { $0.hasSuffix(".xmp") }.compactMap(VirtualCopy.key(fromCompanionName:))
        guard !keys.isEmpty else { return 0 }
        var restored = 0
        do {
            try dbQueue.write { db in
                let paths = try String.fetchAll(db, sql: "SELECT rel_path FROM images WHERE master_id IS NOT NULL")
                let known = Set(paths.compactMap { VirtualCopy.parse($0)?.key.token })
                let missing = keys.filter { !known.contains($0.token) }.sorted { $0.number < $1.number }
                guard !missing.isEmpty else { return }
                let masters = try ImageRecord.filter(sql: "master_id IS NULL").order(Column("rel_path")).fetchAll(db)
                for key in missing {
                    let url = folder.appendingPathComponent(key.stem + ".xmp")
                    guard let fields = try? XMPSidecar.read(from: url), !fields.sourceHash.isEmpty else { continue }
                    // The first master (by path) whose content the copy was made of.
                    guard let master = masters.first(where: { $0.hashString == fields.sourceHash }),
                          let masterID = master.id else { continue }
                    let path = VirtualCopy.relPath(master: master.relPath, key: key)
                    guard try Int64.fetchOne(db, sql: "SELECT id FROM images WHERE rel_path = ?", arguments: [path]) == nil
                    else { continue }
                    var row = master
                    row.id = nil
                    row.relPath = path
                    row.preservedName = nil
                    row.sidecarMtime = nil
                    row.thumbKey = nil
                    try row.insert(db)
                    try db.execute(sql: "UPDATE images SET master_id = ? WHERE id = ?", arguments: [masterID, row.id])
                    restored += 1
                }
            }
        } catch {
            report.failures.append((VirtualCopy.companionFolder, "virtual copies not restored: \(error)"))
        }
        return restored
    }
}

extension VirtualCopyArchive {
    /// Inserts the copy's row from its master's (the file's facts) and this
    /// archive (what the user did), under `id` when it is not 0, and returns
    /// the archive with the id the row got.
    fileprivate func inserting(from master: ImageRecord, thumbKey: Data?, in db: Database) throws -> VirtualCopyArchive {
        var row = master
        row.id = id == 0 ? nil : id
        if let wanted = row.id, try ImageRecord.exists(db, key: wanted) { row.id = nil }
        row.relPath = VirtualCopy.relPath(master: master.relPath, key: key)
        row.preservedName = nil
        row.rating = rating
        row.label = label
        row.flag = flag
        row.userRotation = userRotation
        row.sidecarMtime = nil
        row.thumbKey = thumbKey
        try row.insert(db)
        guard let newID = row.id else { throw VirtualCopyError.noSuchImage }
        try db.execute(sql: "UPDATE images SET master_id = ? WHERE id = ?", arguments: [master.id, newID])
        try Catalog.replaceOwnData(of: newID, keywords: keywords, edit: edit, snapshots: snapshots,
                                   history: history, in: db)
        var result = self
        result.id = newID
        return result
    }
}
