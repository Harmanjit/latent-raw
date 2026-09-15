import Foundation
import GRDB

/// User metadata edits: rating, flag, label, keywords, rotation.
///
/// Every change follows DESIGN.md §5.3's write order: commit the SQLite
/// row first, then write the sidecar atomically. The sidecar's new mtime
/// is recorded on the row so the next reconciliation knows it's already
/// been applied and doesn't re-read it.
extension Catalog {
    public func setRating(_ rating: Int, forImageID id: Int64) throws {
        try updateRow(id) { $0.rating = min(max(rating, 0), 5) }
    }

    public func setFlag(_ flag: ImageFlag, forImageID id: Int64) throws {
        try updateRow(id) { $0.flag = flag.rawValue }
    }

    public func setLabel(_ label: String?, forImageID id: Int64) throws {
        try updateRow(id) { $0.label = label?.isEmpty == true ? nil : label }
    }

    /// Sets the manual rotation, normalized to 0...3 quarter turns.
    public func setUserRotation(_ quarterTurns: Int, forImageID id: Int64) throws {
        try updateRow(id) { $0.userRotation = ((quarterTurns % 4) + 4) % 4 }
    }

    /// Adds quarter turns to the stored rotation, read inside the write, so
    /// rotations sent one after another all count even when the caller's
    /// copy of the record is behind.
    public func rotate(by quarterTurns: Int, forImageID id: Int64) throws {
        try updateRow(id) { $0.userRotation = ((($0.userRotation + quarterTurns) % 4) + 4) % 4 }
    }

    public func setKeywords(_ keywords: [String], forImageID id: Int64) throws {
        let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try dbQueue.write { db in
            try Self.replaceKeywords(cleaned, forImageID: id, in: db)
        }
        try writeSidecar(forImageID: id)
    }

    /// Stores the edit stack for an image and writes the sidecar. `nil`
    /// removes it (the image is back to defaults). The catalog doesn't
    /// interpret the JSON — that's PixelEngine's business — it only keeps
    /// it and its versions.
    public func setEditStack(_ json: String?, schemaVersion: Int = 1,
                             processVersion: String = "1.0",
                             forImageID id: Int64) throws {
        try dbQueue.write { db in
            if let json {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO edits
                      (image_id, schema_version, process_version, params_json, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [id, schemaVersion, processVersion, json,
                                     ImageRecord.milliseconds(Date())])
            } else {
                try db.execute(sql: "DELETE FROM edits WHERE image_id = ?", arguments: [id])
            }
        }
        try writeSidecar(forImageID: id)
    }

    // MARK: Snapshots and history

    /// Snapshots as stored: name and the stack JSON, in name order.
    public func snapshots(forImageID id: Int64) throws -> [(name: String, stackJSON: String)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT name, params_json FROM snapshots WHERE image_id = ? ORDER BY name",
                             arguments: [id]).map { ($0["name"] as String, $0["params_json"] as String) }
        }
    }

    /// Replaces the image's snapshots and writes the sidecar.
    public func setSnapshots(_ snapshots: [(name: String, stackJSON: String)], forImageID id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM snapshots WHERE image_id = ?", arguments: [id])
            for s in snapshots {
                try db.execute(sql: "INSERT INTO snapshots (image_id, name, params_json) VALUES (?, ?, ?)",
                               arguments: [id, s.name, s.stackJSON])
            }
        }
        try writeSidecar(forImageID: id)
    }

    /// History steps in order; `params_json` holds each step's stack.
    public func history(forImageID id: Int64) throws -> [(stackJSON: String, createdAt: Int64)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT params_json, created_at FROM history WHERE image_id = ? ORDER BY step",
                             arguments: [id]).map { ($0["params_json"] as String, $0["created_at"] as Int64? ?? 0) }
        }
    }

    /// Replaces the image's history (capped by the caller) and writes the
    /// sidecar. Steps are numbered from 0 in order.
    public func setHistory(_ steps: [(stackJSON: String, createdAt: Int64)], forImageID id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM history WHERE image_id = ?", arguments: [id])
            for (i, s) in steps.enumerated() {
                try db.execute(sql: "INSERT INTO history (image_id, step, params_json, created_at) VALUES (?, ?, ?, ?)",
                               arguments: [id, i, s.stackJSON, s.createdAt])
            }
        }
        try writeSidecar(forImageID: id)
    }

    /// Sidecar encodings: JSON arrays whose "stack" members are the
    /// stored JSON objects themselves, not strings, so the sidecar stays
    /// readable by a person.
    static func snapshotsJSON(_ snapshots: [(name: String, stackJSON: String)]) -> String {
        let items: [[String: Any]] = snapshots.compactMap { s in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(s.stackJSON.utf8)) else { return nil }
            return ["name": s.name, "stack": obj]
        }
        guard !items.isEmpty, let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func historyJSON(_ steps: [(stackJSON: String, createdAt: Int64)]) -> String {
        let items: [[String: Any]] = steps.compactMap { s in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(s.stackJSON.utf8)) else { return nil }
            return ["t": s.createdAt, "stack": obj]
        }
        guard !items.isEmpty, let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseSnapshots(_ json: String) -> [(name: String, stackJSON: String)] {
        guard !json.isEmpty, let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["name"] as? String, let stack = item["stack"],
                  let data = try? JSONSerialization.data(withJSONObject: stack, options: [.sortedKeys]) else { return nil }
            return (name, String(decoding: data, as: UTF8.self))
        }
    }

    static func parseHistory(_ json: String) -> [(stackJSON: String, createdAt: Int64)] {
        guard !json.isEmpty, let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let stack = item["stack"],
                  let data = try? JSONSerialization.data(withJSONObject: stack, options: [.sortedKeys]) else { return nil }
            let t = (item["t"] as? NSNumber)?.int64Value ?? 0
            return (String(decoding: data, as: UTF8.self), t)
        }
    }

    // MARK: Merge recipes

    /// The latent:Merge recipe of a Photo Merge result, or nil for any other
    /// image (docs/PhotoMerge.md §5).
    public func mergeRecipe(forImageID id: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT merge_json FROM images WHERE id = ?", arguments: [id])
        }
    }

    /// Stores the recipe on an image already in the catalog and writes the
    /// sidecar; nil (or empty) removes it. Like the edit stack, the catalog
    /// keeps the JSON without reading it. Surrounding whitespace is dropped,
    /// as reading the sidecar drops it, so the row and a database rebuilt
    /// from the sidecar hold the same text.
    public func setMergeRecipe(_ json: String?, forImageID id: Int64) throws {
        let trimmed = json?.trimmingCharacters(in: .whitespacesAndNewlines)
        try updateRow(id) { $0.mergeJSON = trimmed?.isEmpty == false ? trimmed : nil }
    }

    /// Writes the sidecar of a merge result that isn't in the catalog yet.
    ///
    /// A merge commits in this order (docs/PhotoMerge.md §5): this sidecar,
    /// then the DNG, then a refresh. The refresh finds the new file and
    /// reads this sidecar onto its new row, like any sidecar waiting beside
    /// a new file, so the pass that catalogues the DNG also gives it its
    /// recipe. The DNG's hash isn't known yet, so the sidecar's SourceHash
    /// is empty until the first write from the row fills it in.
    ///
    /// Never overwrites: a name held by a file, a sidecar or a row (the same
    /// test Move and Copy use, `ImageTransfer.place`) throws `.taken`, since
    /// that sidecar's ratings and edits would be given to the merge.
    public func writeMergeSidecar(_ json: String, forRelPath relPath: String) throws {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MergeRecipeError.empty }
        let name = (relPath as NSString).lastPathComponent
        let sidecar = sidecarURL(forRelPath: relPath)
        // The same test the merge job plans its name with (MergeNaming).
        if try mergeResultNameIsTaken(relPath) {
            throw FileOperations.NameProblem.taken(name)
        }
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try ImageTransfer.writeSidecarExclusively(.init(sourceHash: "", mergeJSON: trimmed), to: sidecar)
    }

    /// Removes a sidecar made by `writeMergeSidecar` when the DNG never
    /// arrived (its name was taken at the last moment, or the merge was
    /// cancelled). Only while neither the file nor a row exists: once
    /// either does, the sidecar belongs to a catalogued photo.
    ///
    /// `fileTookTheName`: the merge's own write found another file under
    /// the name (`SafeFileWriter.DestinationExists`). That file isn't the
    /// merge result, so the sidecar still goes, as long as no row has been
    /// made for it; left, it would give the other file the merge's recipe.
    public func discardMergeSidecar(forRelPath relPath: String, fileTookTheName: Bool = false) throws {
        guard fileTookTheName || !FileOperations.itemExists(fileURL(forRelPath: relPath)),
              try image(forRelPath: relPath) == nil else { return }
        let sidecar = sidecarURL(forRelPath: relPath)
        if FileOperations.itemExists(sidecar) { try FileManager.default.removeItem(at: sidecar) }
    }

    /// The stored edit stack JSON, if the image has one.
    public func editStack(forImageID id: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT params_json FROM edits WHERE image_id = ?",
                                arguments: [id])
        }
    }

    /// IDs of every image with a stored edit, for badges in the grid.
    public func editedImageIDs() throws -> Set<Int64> {
        Set(try dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT image_id FROM edits")
        })
    }

    private func updateRow(_ id: Int64, _ mutate: (inout ImageRecord) -> Void) throws {
        try dbQueue.write { db in
            guard var row = try ImageRecord.fetchOne(db, key: id) else { return }
            mutate(&row)
            try row.update(db)
        }
        try writeSidecar(forImageID: id)
    }

    /// Everything the sidecar should say about an image, gathered from the
    /// row, its keywords and its edit stack.
    public func sidecarFields(forImageID id: Int64) throws -> XMPSidecar.Fields? {
        try dbQueue.read { db in
            guard let row = try ImageRecord.fetchOne(db, key: id) else { return nil }
            let keywords = try String.fetchAll(db, sql: """
                SELECT k.name FROM keywords k
                JOIN image_keywords ik ON ik.keyword_id = k.id
                WHERE ik.image_id = ? ORDER BY k.name
                """, arguments: [id])
            let edit = try Row.fetchOne(db, sql: """
                SELECT schema_version, process_version, params_json FROM edits WHERE image_id = ?
                """, arguments: [id])
            let snapshots = try Row.fetchAll(db, sql: "SELECT name, params_json FROM snapshots WHERE image_id = ? ORDER BY name",
                                             arguments: [id]).map { ($0["name"] as String, $0["params_json"] as String) }
            let history = try Row.fetchAll(db, sql: "SELECT params_json, created_at FROM history WHERE image_id = ? ORDER BY step",
                                           arguments: [id]).map { ($0["params_json"] as String, $0["created_at"] as Int64? ?? 0) }
            return XMPSidecar.Fields(
                rating: row.rating, label: row.label, flag: row.flag,
                rotation: row.userRotation, keywords: keywords,
                preservedFileName: row.preservedName, sourceHash: row.hashString,
                schemaVersion: edit?["schema_version"] ?? 1,
                processVersion: edit?["process_version"] ?? "1.0",
                editStackJSON: edit?["params_json"] ?? "",
                snapshotsJSON: Self.snapshotsJSON(snapshots),
                historyJSON: Self.historyJSON(history),
                mergeJSON: row.mergeJSON ?? "")
        }
    }

    /// Writes the sidecar for an image and records its mtime on the row.
    public func writeSidecar(forImageID id: Int64) throws {
        guard let fields = try sidecarFields(forImageID: id),
              let row = try dbQueue.read({ db in try ImageRecord.fetchOne(db, key: id) })
        else { return }
        let url = sidecarURL(forRelPath: row.relPath)
        try XMPSidecar.write(fields, to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs[.modificationDate] as? Date).map(ImageRecord.milliseconds)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE images SET sidecar_mtime = ? WHERE id = ?",
                           arguments: [mtime, id])
        }
    }
}

public enum MergeRecipeError: Error, CustomStringConvertible {
    case empty
    case noOpenCatalog

    public var description: String {
        switch self {
        case .empty: "The merge recipe is empty."
        case .noOpenCatalog: "No folder is open to save the merge recipe in."
        }
    }
}
