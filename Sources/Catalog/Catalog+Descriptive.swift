import Foundation
import GRDB

/// Colour labels and the descriptive fields (title, caption, creator,
/// copyright), each change reporting what it replaced so the Library can
/// undo it. As with every metadata change (DESIGN.md §5.3) the row is
/// committed first and the sidecar written after it, and the old value is
/// read in the same turn on the catalog's actor as the new one is written
/// (see `exchangeRating`).
extension Catalog {
    /// Sets the label (nil or empty clears it) and returns the image's row
    /// as it was, or nil if there is no such image.
    @discardableResult
    public func exchangeLabel(_ label: String?, forImageID id: Int64) throws -> ImageRecord? {
        let cleaned = DescriptiveField.normalized(label)
        return try exchangeRow(id) { $0.label = cleaned }
    }

    /// Sets one descriptive field and returns the row as it was, or nil if
    /// there is no such image.
    @discardableResult
    public func exchangeDescriptive(_ field: DescriptiveField, _ value: String?,
                                    forImageID id: Int64) throws -> ImageRecord? {
        try exchangeRow(id) { field.set(value, on: &$0) }
    }

    /// Changes the row and writes the sidecar. A change that leaves the row
    /// as it was writes nothing: an unchanged sidecar keeps its date, and
    /// reconcile has nothing to read again.
    private func exchangeRow(_ id: Int64, _ mutate: (inout ImageRecord) -> Void) throws -> ImageRecord? {
        let outcome: (row: ImageRecord, changed: Bool)? = try dbQueue.write { db in
            guard let row = try ImageRecord.fetchOne(db, key: id) else { return nil }
            var changed = row
            mutate(&changed)
            guard changed != row else { return (row, false) }
            try changed.update(db)
            return (row, true)
        }
        guard let outcome else { return nil }
        if outcome.changed { try writeSidecar(forImageID: id) }
        let previous = outcome.row
        return previous
    }
}
