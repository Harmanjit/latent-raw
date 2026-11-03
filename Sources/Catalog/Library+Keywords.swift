import Foundation

extension Catalog {
    /// Changes an image's keywords with `transform`, reading and writing
    /// in one turn on the catalog's actor so two changes sent quickly both
    /// count. Returns the keywords before and after, or nil when nothing
    /// changed (and nothing was written).
    public func updateKeywords(forImageID id: Int64,
                               _ transform: @Sendable ([String]) -> [String]) throws -> (before: [String], after: [String])? {
        let before = try keywords(forImageID: id)
        var seen = Set<String>()
        let after = transform(before).compactMap(KeywordPath.normalized).filter { seen.insert($0).inserted }.sorted()
        guard Set(after) != Set(before) else { return nil }
        try setKeywords(after, forImageID: id)
        return (before, after)
    }
}

/// Keywording over the selection and keyword maintenance over the whole
/// catalog. Each is one undo step, through the same machinery as ratings
/// (`Library+Undo`), so undo gives every photo back its own keywords.
extension Library {
    /// The Keyword List: every keyword in the folder as a hierarchy, with
    /// how many photos carry it or a keyword inside it.
    public var keywordTree: [KeywordTree] { KeywordTree.build(from: keywordIndex) }

    /// Every photo's keywords (image id → paths), for working out which
    /// photos a smart collection's rules match.
    public var keywordsByImage: [Int64: Set<String>] { keywordIndex }

    /// The keywords of the photos keywording acts on (the visible
    /// selection, as for ratings), each with how many of them carry it, and
    /// how many photos that is.
    public func selectionKeywords(onlyPrimary: Bool = false) -> (photos: Int, counts: [String: Int]) {
        let targets = metadataTargetsForKeywords(onlyPrimary: onlyPrimary)
        var counts: [String: Int] = [:]
        for record in targets {
            for keyword in record.id.flatMap({ keywordIndex[$0] }) ?? [] { counts[keyword, default: 0] += 1 }
        }
        return (targets.count, counts)
    }

    /// Adds keywords (paths, see KeywordPath) to every photo keywording
    /// acts on, keeping each photo's own.
    public func addKeywords(_ keywords: [String], onlyPrimary: Bool = false) async throws {
        let paths = keywords.compactMap(KeywordPath.normalized)
        guard !paths.isEmpty else { return }
        try await changeKeywords(metadataTargetsForKeywords(onlyPrimary: onlyPrimary), action: "Add Keyword") {
            $0 + paths
        }
    }

    /// Takes keywords off every photo keywording acts on.
    public func removeKeywords(_ keywords: [String], onlyPrimary: Bool = false) async throws {
        let paths = Set(keywords.compactMap(KeywordPath.normalized))
        guard !paths.isEmpty else { return }
        try await changeKeywords(metadataTargetsForKeywords(onlyPrimary: onlyPrimary), action: "Remove Keyword") {
            $0.filter { !paths.contains($0) }
        }
    }

    /// Adds `keyword` to the selection, or takes it off when every photo
    /// already has it: the Keyword List's checkbox.
    public func toggleKeyword(_ keyword: String) async throws {
        let usage = selectionKeywords()
        if usage.photos > 0, usage.counts[keyword] == usage.photos {
            try await removeKeywords([keyword])
        } else {
            try await addKeywords([keyword])
        }
    }

    /// Renames a keyword, or moves it in the hierarchy, on every photo of
    /// the catalog: "Places|Paris" to "Places|France|Paris" moves Paris
    /// into France, and everything inside Paris goes with it.
    public func renameKeyword(_ old: String, to new: String) async throws {
        guard let old = KeywordPath.normalized(old), let new = KeywordPath.normalized(new), old != new else { return }
        try await changeKeywords(images(carrying: old), action: "Rename Keyword") { keywords in
            keywords.map { KeywordPath.replacing(old, with: new, in: $0) }
        }
    }

    /// Takes a keyword, and every keyword inside it, off every photo of the
    /// catalog.
    public func deleteKeyword(_ keyword: String) async throws {
        guard let keyword = KeywordPath.normalized(keyword) else { return }
        try await changeKeywords(images(carrying: keyword), action: "Delete Keyword") { keywords in
            keywords.filter { !KeywordPath.path($0, isWithin: keyword) }
        }
    }

    /// Photos with `keyword` or a keyword inside it.
    private func images(carrying keyword: String) -> [ImageRecord] {
        let index = keywordIndex
        return images.filter { record in
            record.id.flatMap { index[$0] }?.contains { KeywordPath.path($0, isWithin: keyword) } ?? false
        }
    }

    /// As for ratings: the visible selection in the grid, the image shown elsewhere.
    private func metadataTargetsForKeywords(onlyPrimary: Bool) -> [ImageRecord] {
        batchTargets(onlyPrimary: onlyPrimary)
    }

    /// Runs `transform` on each photo's keywords and files one undo step
    /// for the photos that changed.
    private func changeKeywords(_ records: [ImageRecord], action: String,
                                _ transform: @escaping @Sendable ([String]) -> [String]) async throws {
        let written = catalog
        let before = UndoLedger<[String]>(), after = UndoLedger<[String]>()
        defer {
            let changed = before.recorded
            fileFreshUndo(action, count: changed.count, in: written,
                          undo: .keywords(changed), redo: .keywords(after.recorded))
            // The index follows the rows written, while they are still the
            // open catalog's.
            if let written, written === catalog {
                var index = keywordIndex
                for (id, names) in after.recorded { index[id] = names.isEmpty ? nil : Set(names) }
                keywordIndex = index
            }
        }
        try await change(records) { catalog, id, _ in
            if let result = try await catalog.updateKeywords(forImageID: id, transform) {
                before.record(id, result.before)
                after.record(id, result.after)
            }
        }
    }
}
