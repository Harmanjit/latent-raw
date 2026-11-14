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
        let after = DescriptiveField.normalized(value, multiline: field.isMultiline) ?? ""
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

    // MARK: Several fields at once

    /// Sets every field in `values` on the images `ids` of `target` (a
    /// metadata preset applied, Library+Descriptive's batch setter), leaving
    /// fields not named alone. One undo step for all of it.
    public func setDescriptive(_ values: [DescriptiveField: String], forImageIDs ids: [Int64],
                               in target: Catalog?, action: String = "Apply Metadata Preset") async throws {
        guard let target, target === catalog, !values.isEmpty else { return }
        let cleaned = values
        try await changeMetadata(ids: ids, action: action) { snapshot in
            for (field, value) in cleaned {
                snapshot.descriptive[field] = DescriptiveField.normalized(value, multiline: field.isMultiline)
            }
        }
    }

    /// Folder › Import Ratings and Keywords from Other Apps' Sidecars…: every
    /// photo of `records` (the selection, or all photos) takes what
    /// darktable's or Lightroom's sidecar beside it says, for what it has
    /// empty only. One undo step. Returns how many photos changed.
    @discardableResult
    public func importForeignSidecars(for records: [ImageRecord]) async throws -> Int {
        let written = catalog
        let before = UndoLedger<MetadataSnapshot>(), after = UndoLedger<MetadataSnapshot>()
        defer { fileMetadataUndo("Import from Other Apps’ Sidecars", in: written,
                                 before: before.recorded, after: after.recorded) }
        try await change(records.filter { !$0.isVirtualCopy }) { catalog, id, _ in
            if let previous = try await catalog.fillFromForeignSidecar(forImageID: id),
               let now = try await catalog.metadataSnapshot(forImageID: id) {
                before.record(id, previous)
                after.record(id, now)
            }
        }
        await refreshKeywordIndex(for: Array(after.recorded.keys))
        return before.recorded.count
    }

    /// Add to This Catalog's "Copy rating, label and keywords from the
    /// original": each new export, at `url`, takes its source photo's
    /// rating, label, keywords and descriptive fields. Exports outside the
    /// open folder, or not catalogued, are skipped. Not an undo step of its
    /// own: it is part of adding the export.
    public func copyMetadata(toExports exports: [(url: URL, sourceID: Int64)]) async throws {
        guard let root = folderURL, let catalog else { return }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let byPath = Dictionary(images.map { ($0.relPath, $0) }, uniquingKeysWith: { first, _ in first })
        var pairs: [(target: ImageRecord, sourceID: Int64)] = []
        for export in exports {
            let path = export.url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix), let target = byPath[String(path.dropFirst(prefix.count))] else { continue }
            pairs.append((target, export.sourceID))
        }
        guard !pairs.isEmpty else { return }
        var sources: [Int64: MetadataSnapshot] = [:]
        for (_, sourceID) in pairs where sources[sourceID] == nil {
            sources[sourceID] = try await catalog.metadataSnapshot(forImageID: sourceID)
        }
        let wanted = Dictionary(pairs.compactMap { pair in pair.target.id.map { ($0, pair.sourceID) } },
                                uniquingKeysWith: { first, _ in first })
        let snapshots = sources
        try await change(pairs.map(\.target)) { catalog, id, _ in
            guard let sourceID = wanted[id], var next = snapshots[sourceID] else { return }
            // A reject flag is about the original, not the export.
            next.flag = 0
            try await catalog.exchangeMetadata(next, forImageID: id)
        }
        await refreshKeywordIndex(for: Array(wanted.keys))
    }

    /// Changes each image's metadata snapshot with `transform` and files
    /// one undo step for the ones that changed.
    private func changeMetadata(ids: [Int64], action: String,
                                _ transform: @escaping @Sendable (inout MetadataSnapshot) -> Void) async throws {
        let written = catalog, wanted = Set(ids)
        let records = images.filter { $0.id.map(wanted.contains) ?? false }
        let before = UndoLedger<MetadataSnapshot>(), after = UndoLedger<MetadataSnapshot>()
        defer { fileMetadataUndo(action, in: written, before: before.recorded, after: after.recorded) }
        try await change(records) { catalog, id, _ in
            guard let current = try await catalog.metadataSnapshot(forImageID: id) else { return }
            var next = current
            transform(&next)
            guard next != current else { return }
            if let previous = try await catalog.exchangeMetadata(next, forImageID: id) {
                before.record(id, previous)
                after.record(id, next)
            }
        }
    }

    /// Files the undo of a fresh change of whole snapshots.
    private func fileMetadataUndo(_ action: String, in catalog: Catalog?,
                                  before: [Int64: MetadataSnapshot], after: [Int64: MetadataSnapshot]) {
        guard let catalog, !before.isEmpty else { return }
        let name = Self.undoActionName(action, count: before.count)
        undoRegistration(name, in: catalog) { library, catalog in
            library.restoreMetadata(before, opposite: after, named: name, in: catalog)
        }(true)
    }

    /// Runs as an undo or redo, as `restore` does for the single-value
    /// changes: files the opposite at once, then puts the snapshots back,
    /// after any undo asked for before it.
    func restoreMetadata(_ values: [Int64: MetadataSnapshot], opposite: [Int64: MetadataSnapshot],
                         named name: String, in catalog: Catalog) {
        let verb = undoManager?.isRedoing == true ? "Redo" : "Undo"
        let done = undoRegistration(name, in: catalog) { library, catalog in
            library.restoreMetadata(opposite, opposite: values, named: name, in: catalog)
        }
        let previous = undoRestores
        let restoring = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, catalog === self.catalog else { return }
            let wanted = Set(values.keys)
            let records = self.images.filter { $0.id.map(wanted.contains) ?? false }
            try await self.change(records) { catalog, id, _ in
                if let snapshot = values[id] { try await catalog.exchangeMetadata(snapshot, forImageID: id) }
            }
            await self.refreshKeywordIndex(for: Array(wanted))
        }
        undoRestores = restoring
        perform("\(verb) \(name)") {
            try await restoring.value
            done(true)
        }
    }

    /// The keyword index follows rows whose keywords were written here.
    private func refreshKeywordIndex(for ids: [Int64]) async {
        guard let catalog else { return }
        var read: [Int64: [String]] = [:]
        for id in ids {
            if let names = try? await catalog.metadataSnapshot(forImageID: id)?.keywords { read[id] = names }
        }
        guard catalog === self.catalog, !read.isEmpty else { return }
        var index = keywordIndex
        for (id, names) in read { index[id] = names.isEmpty ? nil : Set(names) }
        keywordIndex = index
    }

    /// Each descriptive field's distinct values across the catalog's
    /// photos, most used first, at most `limit` each: the fields' menus of
    /// existing values. One pass over the photos for all of them.
    public func existingDescriptiveValues(limit: Int = 30) -> [DescriptiveField: [String]] {
        var counts: [DescriptiveField: [String: Int]] = [:]
        for record in images {
            for field in DescriptiveField.allCases {
                if let value = field.value(of: record) { counts[field, default: [:]][value, default: 0] += 1 }
            }
        }
        return counts.mapValues { values in
            values.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
        }
    }
}
