import Foundation

/// Colour labels and the descriptive fields, set from the keys, the menus
/// and the Library panel, with undo like ratings and flags.
extension Library {
    /// Sets the label of every image a rating would change (the visible
    /// selection, or the primary only, `batchTargets`). Nil clears it.
    public func setLabel(_ label: String?, onlyPrimary: Bool = false, targets: [ImageRecord]? = nil) async throws {
        let written = catalog, after = DescriptiveField.normalized(label) ?? "", before = UndoLedger<String>()
        defer {
            let changed = before.recorded.filter { $0.value != after }
            fileFreshUndo("Label", count: changed.count, in: written,
                          undo: .label(changed), redo: .label(changed.mapValues { _ in after }))
        }
        try await change(targets ?? batchTargets(onlyPrimary: onlyPrimary)) { catalog, id, _ in
            if let previous = try await catalog.exchangeLabel(after, forImageID: id) {
                before.record(id, previous.label ?? "")
            }
        }
    }

    /// A label key or menu item: the label on every target, or off them
    /// all when the primary already has it, as Lightroom's keys toggle.
    /// Nil clears.
    public func chooseLabel(_ label: ColorLabel?, onlyPrimary: Bool = false) async throws {
        let next = ColorLabel.label(afterChoosing: label, current: selectedImage?.label)
        try await setLabel(next, onlyPrimary: onlyPrimary)
    }

    /// Sets one descriptive field on the images `ids` of `target`, the
    /// catalog they were chosen in. The panel names the images when the
    /// typing starts, so a field committed as the selection moves on still
    /// lands on the photos it was typed for; nothing is written if another
    /// folder has opened since. Only that field changes: typing a caption
    /// for twelve photos leaves each one's title alone.
    public func setDescriptive(_ field: DescriptiveField, to value: String?,
                               forImageIDs ids: [Int64], in target: Catalog?) async throws {
        guard let target, target === catalog else { return }
        let wanted = Set(ids)
        let records = images.filter { $0.id.map(wanted.contains) ?? false }
        let after = DescriptiveField.normalized(value, multiline: field == .caption) ?? ""
        let before = UndoLedger<String>()
        defer {
            let changed = before.recorded.filter { $0.value != after }
            fileFreshUndo(field.title, count: changed.count, in: target,
                          undo: .descriptive(field, changed), redo: .descriptive(field, changed.mapValues { _ in after }))
        }
        try await change(records) { catalog, id, _ in
            if let previous = try await catalog.exchangeDescriptive(field, after, forImageID: id) {
                before.record(id, field.value(of: previous) ?? "")
            }
        }
    }
}
