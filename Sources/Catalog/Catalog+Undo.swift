import Foundation
import GRDB

/// An image's stored edit as the catalog keeps it: the JSON and the
/// versions it was written under. Undo puts back all three, so an edit
/// written by an earlier process version is restored as that version.
public struct StoredEdit: Equatable, Sendable {
    public var json: String
    public var schemaVersion: Int
    public var processVersion: String

    public init(json: String, schemaVersion: Int, processVersion: String) {
        self.json = json
        self.schemaVersion = schemaVersion
        self.processVersion = processVersion
    }
}

/// Changes that report what they replaced, for Library undo.
///
/// Each reads the old value and writes the new one in the same turn on the
/// catalog's actor, so two changes sent one after another (3 then 4 pressed
/// quickly) each see what the other left: the second's undo goes back to
/// 3, not to the 0 both would have read beforehand.
extension Catalog {
    /// Sets the rating (row, then sidecar) and returns the previous one,
    /// or nil if there is no such image.
    public func exchangeRating(_ rating: Int, forImageID id: Int64) throws -> Int? {
        let previous = try dbQueue.read { db in try ImageRecord.fetchOne(db, key: id) }?.rating
        try setRating(rating, forImageID: id)
        return previous
    }

    /// Sets the flag and returns the previous flag's raw value.
    public func exchangeFlag(_ flag: ImageFlag, forImageID id: Int64) throws -> Int? {
        let previous = try dbQueue.read { db in try ImageRecord.fetchOne(db, key: id) }?.flag
        try setFlag(flag, forImageID: id)
        return previous
    }

    /// Replaces the keywords and returns the previous ones.
    public func exchangeKeywords(_ keywords: [String], forImageID id: Int64) throws -> [String] {
        let previous = try self.keywords(forImageID: id)
        try setKeywords(keywords, forImageID: id)
        return previous
    }

    /// The stored edit with its versions, or nil if the image is unedited.
    public func storedEdit(forImageID id: Int64) throws -> StoredEdit? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT params_json, schema_version, process_version FROM edits WHERE image_id = ?
                """, arguments: [id])
        }.map { row in
            StoredEdit(json: row["params_json"], schemaVersion: row["schema_version"] ?? 1,
                       processVersion: row["process_version"] ?? "1.0")
        }
    }

    /// Stores `edit` (nil: back to defaults) and writes the sidecar.
    public func setStoredEdit(_ edit: StoredEdit?, forImageID id: Int64) throws {
        if let edit {
            try setEditStack(edit.json, schemaVersion: edit.schemaVersion,
                             processVersion: edit.processVersion, forImageID: id)
        } else {
            try setEditStack(nil, forImageID: id)
        }
    }
}
