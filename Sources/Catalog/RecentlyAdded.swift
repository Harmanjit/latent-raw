import Foundation
import GRDB

/// The photos the most recent scan of a catalog found new: Lightroom's
/// "Previous Import", for a catalog that has no import step. Files copied
/// in from Finder, brought in by a watched-folder import, or there the
/// first time a folder was opened all arrive through reconcile, so that
/// is where they are counted.
///
/// Only a scan that added something replaces the list, so a later scan
/// that found nothing new (a refresh, reopening the folder) leaves the
/// last batch to look at. Kept in the catalog's settings table rather
/// than a table of its own: it is one small value, rebuilt by the next
/// scan that adds anything, and losing it with a rebuilt database loses
/// nothing the user made.
public struct RecentlyAdded: Codable, Equatable, Sendable {
    /// Row ids, which stay with a photo through renames and moves inside
    /// the catalog, unlike paths.
    public var ids: [Int64]
    /// When the scan that added them ran.
    public var date: Date

    public init(ids: [Int64], date: Date) {
        self.ids = ids
        self.date = date
    }
}

extension Catalog {
    static let recentlyAddedKey = "folders.recently_added"

    /// Records `ids` as the latest batch, inside the reconcile's own
    /// transaction so the list and the rows it names land together.
    static func recordRecentlyAdded(_ ids: [Int64], at date: Date, in db: Database) throws {
        let data = try JSONEncoder().encode(RecentlyAdded(ids: ids, date: date))
        try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                       arguments: [recentlyAddedKey, String(decoding: data, as: UTF8.self)])
    }

    /// The latest batch of new photos, without the ids of any that have
    /// left the catalog since. Nil when no scan has added anything yet
    /// (or the stored value can't be read, which only hides the view).
    public func recentlyAdded() throws -> RecentlyAdded? {
        guard let text = try setting(Self.recentlyAddedKey),
              var batch = try? JSONDecoder().decode(RecentlyAdded.self, from: Data(text.utf8)) else { return nil }
        let present = try dbQueue.read { db in Set(try Int64.fetchAll(db, sql: "SELECT id FROM images")) }
        batch.ids = batch.ids.filter(present.contains)
        return batch.ids.isEmpty ? nil : batch
    }
}
