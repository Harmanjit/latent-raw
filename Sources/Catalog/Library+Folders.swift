import Foundation

/// The Recently Added view and refreshing the open folder from the disk.
extension Library {
    /// Whether the grid shows only the latest batch of new photos.
    public var isShowingRecentlyAdded: Bool { filter.recentlyAddedIDs != nil }

    /// Shows only the photos the latest scan that found anything new added,
    /// with whatever else the filter bar asks for still applied, or every
    /// photo again. Clear Filters turns it off too. With nothing recently
    /// added there is nothing to show, and the view stays off.
    public func showRecentlyAdded(_ show: Bool) {
        filter.recentlyAddedIDs = show ? recentlyAdded.map { Set($0.ids) } : nil
    }

    /// Takes a newly read batch. While the view is on it follows the new
    /// batch (a scan that added more photos shows those), and goes off when
    /// there is none, as after opening a folder that has never added any:
    /// ids belong to a catalog, so another folder's list can't be kept.
    func followRecentlyAdded(_ batch: RecentlyAdded?) {
        if recentlyAdded != batch { recentlyAdded = batch }
        guard filter.recentlyAddedIDs != nil else { return }
        let ids = batch.map { Set($0.ids) }
        if filter.recentlyAddedIDs != ids { filter.recentlyAddedIDs = ids }
    }

    /// File › Refresh Folder, and the folder watcher: reconciles the open
    /// folder again through `perform`, so a failure reaches the status bar
    /// and quitting waits for it. Nothing happens without a folder.
    public func refreshFromDisk(_ what: String = "Refreshing the folder") {
        guard catalog != nil else { return }
        perform(what) { [weak self] in try await self?.refresh() }
    }
}
