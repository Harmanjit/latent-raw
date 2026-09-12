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

    public func setKeywords(_ keywords: [String], forImageID id: Int64) throws {
        let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try dbQueue.write { db in
            try Self.replaceKeywords(cleaned, forImageID: id, in: db)
        }
        try writeSidecar(forImageID: id)
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
            return XMPSidecar.Fields(
                rating: row.rating, label: row.label, flag: row.flag,
                rotation: row.userRotation, keywords: keywords,
                preservedFileName: row.preservedName, sourceHash: row.hashString,
                schemaVersion: edit?["schema_version"] ?? 1,
                processVersion: edit?["process_version"] ?? "1.0",
                editStackJSON: edit?["params_json"] ?? "")
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
