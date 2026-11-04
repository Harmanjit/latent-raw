import Foundation

/// Verify Files and Find Duplicates on the open folder (FileIntegrity).
extension Library {
    /// The files a verify run reads: the selection, or every photo in the
    /// folder when nothing is selected, each file once.
    public func verificationTargets() -> [ImageRecord] {
        let chosen = selectedImages.isEmpty ? images : selectedImages
        return FileIntegrity.filesToVerify(chosen, in: images)
    }

    /// Stores what a verify run found in `catalog`, the one it read, and
    /// badges the damaged photos if that catalog is still the open one.
    public func recordVerification(_ checks: [FileIntegrity.Check], in catalog: Catalog) async throws {
        try await catalog.recordVerification(checks)
        let damaged = try await catalog.damagedImageIDs()
        guard catalog === self.catalog else { return }
        if damaged != damagedImageIDs { damagedImageIDs = damaged }
    }

    /// The open folder's duplicates: identical files, then the looser
    /// same-moment tier. Copies with an edit, then higher ratings, come
    /// first in each group, as the ones to keep.
    public func duplicateGroups() -> (exact: [DuplicateFinder.Group], near: [DuplicateFinder.Group]) {
        let edited = editedImageIDs
        return (DuplicateFinder.exactGroups(images, edited: edited), DuplicateFinder.nearGroups(images, edited: edited))
    }
}
