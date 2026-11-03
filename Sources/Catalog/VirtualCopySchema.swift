import GRDB

/// The schema behind virtual copies (VirtualCopy), added by migration
/// `vcopies_v1_virtual_copies`. Every row before it is a master or an
/// ordinary photo, so `master_id` starts NULL everywhere.
enum VirtualCopySchema {
    /// Columns that describe the file rather than what the user did to it.
    /// A copy shows its master's file, so these follow the master's row.
    static let fileColumns = [
        "size", "mtime", "xxhash", "capture_time", "camera", "lens", "lens_id",
        "iso", "shutter", "aperture", "focal", "width", "height", "orientation", "finder_tags",
    ]

    static func migrate(_ db: Database) throws {
        // The copy's master. Deleting the master's row (its file has gone,
        // or moved to another catalog) deletes its copies with it.
        try db.alter(table: "images") { t in
            t.add(column: "master_id", .integer).references("images", onDelete: .cascade)
        }
        try db.create(index: "idx_images_master_id", on: "images", columns: ["master_id"])

        // A master's rename or move, and a change of its file, carry to its
        // copies here, so no code that renames or reconciles a row has to
        // know about copies. Recursive triggers are off, and the copies'
        // own update never matches the WHEN (they have a master), so this
        // runs once per change of a master. A changed file also makes the
        // copies' thumbnails stale.
        let changed = (["rel_path"] + fileColumns).map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
        let follow = fileColumns.map { "\($0) = NEW.\($0)" }.joined(separator: ", ")
        try db.execute(sql: """
            CREATE TRIGGER vcopies_follow_master AFTER UPDATE ON images
            WHEN NEW.master_id IS NULL AND (\(changed))
            BEGIN
              UPDATE images SET
                rel_path = NEW.rel_path || substr(rel_path, length(OLD.rel_path) + 1),
                \(follow),
                thumb_key = CASE WHEN OLD.xxhash IS NOT NEW.xxhash THEN NULL ELSE thumb_key END
              WHERE master_id = NEW.id;
            END
            """)

        // image_keywords has no foreign key, so copies deleted by the
        // cascade above would leave their keyword links behind. Rows are
        // deleted with their links everywhere else already; this does it
        // for the cascade, and is harmless for those.
        try db.execute(sql: """
            CREATE TRIGGER vcopies_forget_keywords AFTER DELETE ON images
            BEGIN
              DELETE FROM image_keywords WHERE image_id = OLD.id;
            END
            """)
    }
}
