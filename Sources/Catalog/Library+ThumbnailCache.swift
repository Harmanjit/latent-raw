import Foundation

/// Library › Rebuild Thumbnails and Settings › Performance's thumbnail
/// cache: what the open catalog's thumbnails take on disk, and remaking or
/// discarding them.
extension Library {
    /// Makes these images' thumbnails again, at the current quality, from
    /// their current edits (Lightroom's Render Previews). The old picture
    /// shows until the new one replaces it.
    public func rebuildThumbnails(for records: [ImageRecord]) {
        guard let catalog, !records.isEmpty else { return }
        let relPaths = records.map(\.relPath)
        perform("Rebuilding thumbnails") { [weak self] in
            try await catalog.discardThumbnailKeys(forRelPaths: relPaths)
            guard let self, catalog === self.catalog else { return }
            self.startThumbnailGeneration()
        }
    }

    /// What the open catalog's thumbnail folder holds; nil with no folder open.
    public func thumbnailCacheUsage() async throws -> ThumbnailCacheUsage? {
        guard let catalog else { return nil }
        return try await catalog.thumbnailCacheUsage()
    }

    /// Removes thumbnail files no image uses. Returns the bytes freed.
    @discardableResult
    public func purgeOrphanThumbnails() async throws -> Int64 {
        guard let catalog else { return 0 }
        return try await catalog.purgeOrphanThumbnails().orphanBytes
    }

    /// Throws every thumbnail of the open catalog away and makes them all
    /// again, at the current settings. Cells show their placeholder until
    /// each new thumbnail arrives.
    public func discardAllThumbnails() async throws {
        guard let catalog else { return }
        cancelThumbnailGeneration()
        try await catalog.discardAllThumbnails()
        guard catalog === self.catalog else { return }
        thumbnailLoader.invalidate(ids: Set(images.compactMap(\.id)))
        startThumbnailGeneration()
    }
}
