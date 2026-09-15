import GRDB

/// The per-folder catalog schema (DESIGN.md §5.4). One `DatabaseQueue` per
/// `_latent/catalog.sqlite`, one `Catalog` actor per open folder.
///
/// Journal mode is NOT set here — that's volume-dependent (WAL on local/
/// external drives, rollback journal on network shares, DESIGN.md §5.3) and
/// is decided by `Catalog.open(at:)` based on the volume the folder lives on,
/// not hardcoded into the migration.
enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "images") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rel_path", .text).notNull().unique()
                t.column("preserved_name", .text)
                t.column("size", .integer).notNull()
                t.column("mtime", .integer).notNull()
                t.column("xxhash", .blob).notNull()
                t.column("capture_time", .integer)
                t.column("camera", .text)
                t.column("lens", .text)
                t.column("lens_id", .text)
                t.column("iso", .integer)
                t.column("shutter", .double)
                t.column("aperture", .double)
                t.column("focal", .double)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("orientation", .integer)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("label", .text)
                t.column("flag", .integer).notNull().defaults(to: 0)
                t.column("sidecar_mtime", .integer)
                t.column("thumb_key", .blob)
            }
            try db.create(index: "idx_images_capture_time", on: "images", columns: ["capture_time"])
            try db.create(index: "idx_images_xxhash", on: "images", columns: ["xxhash"])

            try db.create(table: "edits") { t in
                t.column("image_id", .integer).notNull().primaryKey()
                    .references("images", onDelete: .cascade)
                t.column("schema_version", .integer).notNull()
                t.column("process_version", .text).notNull()
                t.column("params_json", .text).notNull()
                t.column("updated_at", .integer).notNull()
            }

            try db.create(table: "history") { t in
                t.column("image_id", .integer).notNull()
                    .references("images", onDelete: .cascade)
                t.column("step", .integer).notNull()
                t.column("params_json", .text)
                t.column("created_at", .integer)
                t.primaryKey(["image_id", "step"])
            }

            try db.create(table: "snapshots") { t in
                t.column("image_id", .integer).notNull()
                    .references("images", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("params_json", .text).notNull()
                t.primaryKey(["image_id", "name"])
            }

            try db.create(table: "keywords") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("parent_id", .integer).references("keywords")
            }

            try db.create(table: "image_keywords") { t in
                t.column("image_id", .integer).notNull()
                t.column("keyword_id", .integer).notNull()
                t.primaryKey(["image_id", "keyword_id"])
            }

            try db.create(table: "subfolders") { t in
                t.column("rel_path", .text).notNull().primaryKey()
                t.column("mode", .text).notNull()
                    .check { ["included", "independent", "ask"].contains($0) }
            }

            try db.create(table: "lens_overrides") { t in
                t.column("camera", .text).notNull()
                t.column("lens_id", .text).notNull()
                t.column("lensfun_model", .text).notNull()
                t.primaryKey(["camera", "lens_id"])
            }

            try db.create(table: "settings") { t in
                t.column("key", .text).notNull().primaryKey()
                t.column("value", .text)
            }
        }

        migrator.registerMigration("v2_user_rotation") { db in
            // Quarter turns clockwise the user added on top of the camera's
            // orientation. Kept separate from `orientation` (what the camera
            // recorded) so re-reading EXIF never clobbers a manual fix.
            try db.alter(table: "images") { t in
                t.add(column: "user_rotation", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v3_finder_tags") { db in
            // The file's Finder tags as reconcile last read them (see
            // FinderTag). A cache of the file's own attribute, refreshed on
            // every reconcile, so a rebuilt database loses nothing.
            try db.alter(table: "images") { t in
                t.add(column: "finder_tags", .text)
            }
        }

        return migrator
    }
}
