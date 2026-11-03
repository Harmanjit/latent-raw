import Foundation
import GRDB

/// One remembered lens profile: for photos from `camera` with lens
/// `lensID`, use the Lensfun lens `lensfunModel` instead of the automatic
/// match. The keys are LensKit's `LensProfileOverrides.Key`, as text.
public struct LensOverrideRow: Equatable, Sendable {
    public var camera: String
    public var lensID: String
    public var lensfunModel: String

    public init(camera: String, lensID: String, lensfunModel: String) {
        self.camera = camera
        self.lensID = lensID
        self.lensfunModel = lensfunModel
    }
}

/// The `lens_overrides` table, there since the first schema and filled
/// from the Lens Corrections panel's "Use for All Photos From This Lens".
extension Catalog {
    public func lensOverrides() throws -> [LensOverrideRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT camera, lens_id, lensfun_model FROM lens_overrides ORDER BY camera, lens_id")
                .map { LensOverrideRow(camera: $0["camera"], lensID: $0["lens_id"], lensfunModel: $0["lensfun_model"]) }
        }
    }

    /// Sets the profile for a camera and lens (nil removes the choice) and
    /// returns the one it replaced, for undo. Read and written in one
    /// transaction, so two quick changes each see what the other left.
    @discardableResult
    public func exchangeLensOverride(_ lensfunModel: String?, camera: String, lensID: String) throws -> String? {
        try dbQueue.write { db in
            let previous = try String.fetchOne(db, sql: """
                SELECT lensfun_model FROM lens_overrides WHERE camera = ? AND lens_id = ?
                """, arguments: [camera, lensID])
            if let lensfunModel {
                try db.execute(sql: """
                    INSERT INTO lens_overrides (camera, lens_id, lensfun_model) VALUES (?, ?, ?)
                    ON CONFLICT(camera, lens_id) DO UPDATE SET lensfun_model = excluded.lensfun_model
                    """, arguments: [camera, lensID, lensfunModel])
            } else {
                try db.execute(sql: "DELETE FROM lens_overrides WHERE camera = ? AND lens_id = ?",
                               arguments: [camera, lensID])
            }
            return previous
        }
    }
}
