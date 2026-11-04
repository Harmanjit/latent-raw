import Foundation
import GRDB

/// Reading and writing the open catalog's stacks (ImageStack). Every stack
/// action is worked out on the whole list (StackEditing) and written back
/// in one transaction: a folder holds at most a few thousand stacked
/// photos, and one write path keeps the tables consistent.
extension Catalog {
    /// Every stack with at least two photos still in the catalog, in id
    /// order, each top first.
    public func allStacks() throws -> [ImageStack] {
        try dbQueue.read { db in try Self.stacks(in: db) }
    }

    static func stacks(in db: Database) throws -> [ImageStack] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.id AS stack_id, s.collapsed AS collapsed, m.image_id AS image_id
            FROM stacks s JOIN stack_members m ON m.stack_id = s.id
            ORDER BY s.id, m.position, m.image_id
            """)
        var result: [ImageStack] = []
        for row in rows {
            let stackID: Int64 = row["stack_id"]
            let imageID: Int64 = row["image_id"]
            if let last = result.last, last.id == stackID {
                result[result.count - 1].memberIDs.append(imageID)
            } else {
                result.append(ImageStack(id: stackID, memberIDs: [imageID], isCollapsed: row["collapsed"] ?? true))
            }
        }
        return result.filter { $0.memberIDs.count >= 2 }
    }

    /// Replaces every stack with `stacks`. Photos no longer in the catalog
    /// are dropped, a photo listed twice keeps its first place, and a stack
    /// left with fewer than two photos is not written.
    public func replaceStacks(_ stacks: [ImageStack]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM stack_members")
            try db.execute(sql: "DELETE FROM stacks")
            let existing = Set(try Int64.fetchAll(db, sql: "SELECT id FROM images"))
            var placed = Set<Int64>()
            for stack in stacks {
                var members: [Int64] = []
                for id in stack.memberIDs where existing.contains(id) && !placed.contains(id) {
                    placed.insert(id)
                    members.append(id)
                }
                guard members.count >= 2 else {
                    for id in members { placed.remove(id) }
                    continue
                }
                try db.execute(sql: "INSERT INTO stacks (id, collapsed) VALUES (?, ?)",
                               arguments: [stack.id, stack.isCollapsed])
                for (position, id) in members.enumerated() {
                    try db.execute(sql: "INSERT INTO stack_members (image_id, stack_id, position) VALUES (?, ?, ?)",
                                   arguments: [id, stack.id, position])
                }
            }
        }
    }
}
