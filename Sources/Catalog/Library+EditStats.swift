import Foundation
import GRDB

extension Catalog {
    /// Every stored edit's save time and history length, for the Edit time
    /// and Edit count sorts. One read of each table, not a query per image.
    public func editStats() throws -> [Int64: LibraryEditStat] {
        try dbQueue.read { db in
            let steps = Dictionary(
                try Row.fetchAll(db, sql: "SELECT image_id, COUNT(*) AS n FROM history GROUP BY image_id")
                    .map { ($0["image_id"] as Int64, $0["n"] as Int) },
                uniquingKeysWith: { first, _ in first })
            var stats: [Int64: LibraryEditStat] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT image_id, updated_at FROM edits") {
                let id: Int64 = row["image_id"]
                stats[id] = LibraryEditStat(updatedAt: row["updated_at"], steps: steps[id] ?? 0)
            }
            return stats
        }
    }
}

/// One stored edit as smart collections read it: what it holds and when
/// it was saved (milliseconds since 1970).
public struct EditDetailRow: Sendable, Equatable {
    public var id: Int64
    public var json: String
    public var updatedAt: Int64
}

extension Catalog {
    /// Every stored edit, for the "Edit changes" and "Edit date" smart
    /// collection fields (`LibraryCollections`, which works out the edit
    /// groups each one changes). One read of the table.
    public func editDetailRows() throws -> [EditDetailRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT image_id, params_json, updated_at FROM edits").map {
                EditDetailRow(id: $0["image_id"], json: $0["params_json"], updatedAt: $0["updated_at"])
            }
        }
    }
}

extension Library {
    /// Reads the edit statistics again and re-sorts, when the grid is
    /// sorted by Edit time or Edit count; the other sorts never look at
    /// them, so nothing is read for them. Called when such a key is chosen
    /// and whenever a stored edit changes.
    public func refreshEditStatsIfSorted() {
        guard sort.key.readsEditStats, let catalog else { return }
        editStatsGeneration += 1
        let generation = editStatsGeneration
        Task { @MainActor [weak self] in
            let stats = (try? await catalog.editStats()) ?? [:]
            // A later refresh, or another folder, overtook this one.
            guard let self, self.catalog === catalog, generation == self.editStatsGeneration else { return }
            if stats != self.editStats {
                self.editStats = stats
                self.recomputeVisible()
            }
        }
    }
}
