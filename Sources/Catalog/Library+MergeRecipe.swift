import Foundation

/// The latent:Merge recipe of Photo Merge results (docs/PhotoMerge.md §5),
/// for the app's merge job.
///
/// Writes are counted as the Library's pending work, like a rating made
/// through `perform`, so quitting waits for a recipe on its way to disk.
/// Unlike `perform` they also hand their error back: the merge job has to
/// know the sidecar is written before it writes the DNG.
extension Library {
    /// The recipe of `record`, read from its catalog rather than from the
    /// grid's copy of the row, or nil when it isn't a merge result.
    public func mergeRecipe(for record: ImageRecord, in target: Catalog? = nil) async throws -> String? {
        guard let id = record.id, let catalog = target ?? catalog else { return nil }
        return try await catalog.mergeRecipe(forImageID: id)
    }

    /// Step 2 of a merge's commit: the sidecar for the result about to be
    /// written at `relPath` (relative to the catalog's folder), before the
    /// DNG exists. Throws `FileOperations.NameProblem.taken` when anything
    /// already holds that name. `target` is the catalog captured when the
    /// merge started, as for `saveEditStack`: another folder may be open by
    /// the time it finishes.
    public func writeMergeRecipe(_ json: String, forNewImageAt relPath: String,
                                 in target: Catalog? = nil) async throws {
        // Throws rather than returning quietly: a merge job that went on to
        // write its DNG would leave a result with no recipe.
        guard let catalog = target ?? catalog else { throw MergeRecipeError.noOpenCatalog }
        try await countedAsPendingWork("Saving the merge recipe") {
            try await catalog.writeMergeSidecar(json, forRelPath: relPath)
        }
    }

    /// Takes back `writeMergeRecipe` when the DNG could not be placed (step
    /// 3's name clash, a cancel), so the next name planned isn't blocked by
    /// a sidecar with no photo. Leaves it if a file or row has appeared.
    public func discardMergeRecipe(forNewImageAt relPath: String, in target: Catalog? = nil) async throws {
        guard let catalog = target ?? catalog else { return }
        try await countedAsPendingWork("Removing an unused merge recipe") {
            try await catalog.discardMergeSidecar(forRelPath: relPath)
        }
    }

    /// Sets (nil: removes) the recipe of an image already in the catalog,
    /// row and sidecar. Not undoable: it records how the file was made, it
    /// isn't an edit.
    public func setMergeRecipe(_ json: String?, forImageID id: Int64, in target: Catalog? = nil) async throws {
        guard let catalog = target ?? catalog else { return }
        try await countedAsPendingWork("Saving the merge recipe") {
            try await catalog.setMergeRecipe(json, forImageID: id)
        }
        // The grid's copy of the row is now behind. `change` with nothing
        // left to change re-reads it; checked and started in one step on the
        // main actor, so it can't re-read another folder's image.
        guard catalog === self.catalog, let record = images.first(where: { $0.id == id }) else { return }
        try await change([record]) { _, _, _ in }
    }

    /// Starts `work` and counts it as pending work until it ends, then
    /// throws its error, if any, to the caller. The error isn't also put in
    /// the status bar: the caller decides what the user sees.
    private func countedAsPendingWork(_ what: String,
                                      _ work: @escaping @Sendable () async throws -> Void) async throws {
        let task = Task { try await work() }
        perform(what) { _ = await task.result }
        try await task.value
    }
}
