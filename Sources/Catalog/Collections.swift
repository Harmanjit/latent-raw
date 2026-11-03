import Foundation
import GRDB

/// A collection in the open catalog: photos gathered by hand (regular), by
/// rules (smart), or a set that holds other collections, as in
/// Lightroom's Collections panel. Collections belong to the folder's
/// catalog, like everything else in Latent (there is no master catalog),
/// and hold only photos of that catalog.
public struct CatalogCollection: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case regular, smart, set
    }

    public var id: Int64
    public var name: String
    public var kind: Kind
    /// The set this collection is inside, or nil at the top.
    public var parentID: Int64?
    /// The rules of a smart collection; nil for the others, and for a
    /// smart collection whose rules couldn't be read (it then shows nothing).
    public var rules: SmartCollectionRules?

    public init(id: Int64, name: String, kind: Kind, parentID: Int64? = nil, rules: SmartCollectionRules? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.rules = rules
    }
}

/// Every collection of a catalog and which photos are in the regular ones,
/// as one value: the Library shows it, undo puts a previous one back, and
/// the catalog saves it whole (`Catalog.saveCollections`).
public struct CollectionsState: Equatable, Sendable {
    public var collections: [CatalogCollection]
    /// Regular collection id → the image ids in it.
    public var members: [Int64: Set<Int64>]
    /// The collection B adds to (Lightroom's target collection), if any.
    public var targetID: Int64?

    public init(collections: [CatalogCollection] = [], members: [Int64: Set<Int64>] = [:], targetID: Int64? = nil) {
        self.collections = collections
        self.members = members
        self.targetID = targetID
    }

    public func collection(_ id: Int64?) -> CatalogCollection? {
        guard let id else { return nil }
        return collections.first { $0.id == id }
    }

    /// The collections directly inside `parent` (nil: the top level), sets
    /// first, then by name, as Lightroom lists them.
    public func children(of parent: Int64?) -> [CatalogCollection] {
        collections.filter { $0.parentID == parent }.sorted { a, b in
            if (a.kind == .set) != (b.kind == .set) { return a.kind == .set }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// `id` and every collection inside it, at any depth.
    public func subtree(_ id: Int64) -> [Int64] {
        var result = [id]
        var index = 0
        while index < result.count {
            let current = result[index]
            result += collections.filter { $0.parentID == current }.map(\.id)
            index += 1
        }
        return result
    }

    /// The sets a collection could be moved into: every set except itself
    /// and those inside it.
    public func possibleParents(for id: Int64?) -> [CatalogCollection] {
        let excluded = id.map { Set(subtree($0)) } ?? []
        return collections.filter { $0.kind == .set && !excluded.contains($0.id) }
            .sorted { path(of: $0.id).localizedStandardCompare(path(of: $1.id)) == .orderedAscending }
    }

    /// "Travel › 2026 › Lisbon", for menus that list collections flat.
    public func path(of id: Int64) -> String {
        var names: [String] = []
        var current = collection(id)
        var guardCount = 0
        while let c = current, guardCount < 64 {
            names.insert(c.name, at: 0)
            current = collection(c.parentID)
            guardCount += 1
        }
        return names.joined(separator: " › ")
    }

    /// Regular collections, by path, for "Add to Collection".
    public var regularCollections: [CatalogCollection] {
        collections.filter { $0.kind == .regular }
            .sorted { path(of: $0.id).localizedStandardCompare(path(of: $1.id)) == .orderedAscending }
    }

    /// An id no collection has, for a new one.
    public var nextID: Int64 { (collections.map(\.id).max() ?? 0) + 1 }

    /// What showing `id` restricts the grid to: its photos, its rules, or
    /// for a set everything in the collections inside it.
    public func scope(for id: Int64) -> CollectionScope? {
        guard collection(id) != nil else { return nil }
        var scope = CollectionScope(ids: [], rules: [])
        for member in subtree(id) {
            guard let c = collection(member) else { continue }
            switch c.kind {
            case .regular: scope.ids.formUnion(members[member] ?? [])
            case .smart: if let rules = c.rules { scope.rules.append(rules) }
            case .set: break
            }
        }
        return scope
    }

    /// The same state without photos that are no longer in the catalog.
    public func pruned(toImages ids: Set<Int64>) -> CollectionsState {
        var copy = self
        copy.members = members.mapValues { $0.intersection(ids) }.filter { !$0.value.isEmpty }
        return copy
    }
}

/// The photos a collection shows: listed ids, or any of its rules.
public struct CollectionScope: Equatable, Sendable {
    public var ids: Set<Int64>
    public var rules: [SmartCollectionRules]

    public func includes(_ record: ImageRecord, isEdited: Bool, keywords: Set<String>, now: Date = Date()) -> Bool {
        if let id = record.id, ids.contains(id) { return true }
        return rules.contains { $0.matches(record, isEdited: isEdited, keywords: keywords, now: now) }
    }

    public func dependsOnChange(from old: ImageRecord, to new: ImageRecord) -> Bool {
        rules.contains { $0.dependsOnChange(from: old, to: new) }
    }

    public var readsKeywords: Bool { rules.contains(where: \.readsKeywords) }
    public var readsEdits: Bool { rules.contains(where: \.readsEdits) }
}

// MARK: - Schema

/// The collections tables. Registered from `Schema.migrator()` after every
/// earlier migration, under a name of its own.
enum CollectionsSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("collections_v1_tables") { db in
            // parent_id cascades: deleting a set deletes what is inside it,
            // as in Lightroom. Undo puts the whole subtree back.
            try db.create(table: "collections") { t in
                t.column("id", .integer).primaryKey()
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                    .check { ["regular", "smart", "set"].contains($0) }
                t.column("parent_id", .integer).references("collections", onDelete: .cascade)
                t.column("rules_json", .text)
            }
            try db.create(table: "collection_images") { t in
                t.column("collection_id", .integer).notNull()
                    .references("collections", onDelete: .cascade)
                t.column("image_id", .integer).notNull()
                    .references("images", onDelete: .cascade)
                t.primaryKey(["collection_id", "image_id"])
            }
            try db.create(index: "idx_collection_images_image", on: "collection_images", columns: ["image_id"])
        }
    }
}

// MARK: - Catalog

/// The catalog's own copy of its collections, beside the database: the
/// database can be rebuilt from the sidecars (DESIGN.md §5.3), but
/// collections live in no sidecar. Photos are named by their paths, since
/// a rebuilt database numbers them afresh.
struct CollectionsBackup: Codable, Equatable {
    var version = 1
    var collections: [CatalogCollection]
    /// Collection id → catalog-relative paths.
    var members: [String: [String]]
    var targetID: Int64?
}

extension Catalog {
    static let collectionsTargetKey = "collections.target"
    public var collectionsBackupURL: URL { containerPath.appendingPathComponent("collections.json") }

    /// The catalog's collections. A database that has none while the
    /// backup beside it lists some (a damaged database set aside, or one
    /// deleted by hand) gets them back from the backup first.
    public func loadCollections() throws -> CollectionsState {
        let state = try readCollections()
        if state.collections.isEmpty, let restored = try restoreCollectionsFromBackup() {
            return restored
        }
        return state
    }

    func readCollections() throws -> CollectionsState {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name, kind, parent_id, rules_json FROM collections")
            let collections = rows.compactMap { row -> CatalogCollection? in
                guard let kind = CatalogCollection.Kind(rawValue: row["kind"]) else { return nil }
                let rulesJSON: String? = row["rules_json"]
                return CatalogCollection(id: row["id"], name: row["name"], kind: kind, parentID: row["parent_id"],
                                         rules: kind == .smart ? rulesJSON.flatMap(SmartCollectionRules.init(json:)) : nil)
            }
            var members: [Int64: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT collection_id, image_id FROM collection_images") {
                members[row["collection_id"], default: []].insert(row["image_id"])
            }
            let target = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?",
                                             arguments: [Self.collectionsTargetKey]).flatMap { Int64($0) }
            let ids = Set(collections.map(\.id))
            return CollectionsState(collections: collections, members: members,
                                    targetID: target.flatMap { ids.contains($0) ? $0 : nil })
        }
    }

    /// Replaces every collection with `state`, in one transaction, then
    /// writes the backup. Photos no longer in the catalog are left out.
    public func saveCollections(_ state: CollectionsState) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM collection_images")
            try db.execute(sql: "DELETE FROM collections")
            // Parents before children, for the foreign key.
            for collection in Self.parentsFirst(state.collections) {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, kind, parent_id, rules_json) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [collection.id, collection.name, collection.kind.rawValue,
                                     collection.parentID, collection.kind == .smart ? collection.rules?.json : nil])
            }
            for (collectionID, ids) in state.members where state.collection(collectionID)?.kind == .regular {
                for id in ids {
                    try db.execute(sql: """
                        INSERT INTO collection_images (collection_id, image_id)
                        SELECT ?, ? WHERE EXISTS (SELECT 1 FROM images WHERE id = ?)
                        """, arguments: [collectionID, id, id])
                }
            }
            if let target = state.targetID, state.collection(target) != nil {
                try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                               arguments: [Self.collectionsTargetKey, String(target)])
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [Self.collectionsTargetKey])
            }
        }
        try writeCollectionsBackup()
    }

    /// A parent's row before its children's; a collection whose parent is
    /// missing goes to the top level rather than being lost.
    static func parentsFirst(_ collections: [CatalogCollection]) -> [CatalogCollection] {
        let ids = Set(collections.map(\.id))
        var placed = Set<Int64>()
        var result: [CatalogCollection] = []
        var remaining = collections.map { c -> CatalogCollection in
            var c = c
            if let parent = c.parentID, !ids.contains(parent) || parent == c.id { c.parentID = nil }
            return c
        }
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.parentID.map(placed.contains) ?? true }
            if ready.isEmpty {
                // A loop of parents: break it at the top level.
                var first = remaining.removeFirst()
                first.parentID = nil
                result.append(first)
                placed.insert(first.id)
                continue
            }
            result += ready
            placed.formUnion(ready.map(\.id))
            remaining.removeAll { placed.contains($0.id) }
        }
        return result
    }

    func writeCollectionsBackup() throws {
        let state = try readCollections()
        let paths = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, rel_path FROM images").reduce(into: [Int64: String]()) {
                $0[$1["id"]] = $1["rel_path"]
            }
        }
        let backup = CollectionsBackup(
            collections: state.collections.sorted { $0.id < $1.id },
            members: state.members.reduce(into: [:]) { result, entry in
                result[String(entry.key)] = entry.value.compactMap { paths[$0] }.sorted()
            },
            targetID: state.targetID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(backup)
        let url = collectionsBackupURL
        if state.collections.isEmpty, !FileManager.default.fileExists(atPath: url.path) { return }
        try data.write(to: url, options: .atomic)
    }

    /// Puts the backup's collections into an empty database. Nil when there
    /// is no backup or it lists none.
    func restoreCollectionsFromBackup() throws -> CollectionsState? {
        let url = collectionsBackupURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let backup = try? JSONDecoder().decode(CollectionsBackup.self, from: data),
              !backup.collections.isEmpty else { return nil }
        let ids = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, rel_path FROM images").reduce(into: [String: Int64]()) {
                $0[$1["rel_path"]] = $1["id"]
            }
        }
        var members: [Int64: Set<Int64>] = [:]
        for (key, paths) in backup.members {
            guard let collectionID = Int64(key) else { continue }
            let found = Set(paths.compactMap { ids[$0] })
            if !found.isEmpty { members[collectionID] = found }
        }
        let state = CollectionsState(collections: backup.collections, members: members, targetID: backup.targetID)
        try saveCollections(state)
        return try readCollections()
    }
}
