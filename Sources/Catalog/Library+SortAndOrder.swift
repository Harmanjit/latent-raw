import Foundation

/// Choosing a sort key, and rearranging the Custom sort by dragging.
extension Library {
    /// Shows the grid sorted by `key`, in the direction that key was last
    /// left in (or its natural one), remembering the current key's.
    public func chooseSortKey(_ key: LibrarySortKey) {
        var memory = sortMemory
        let next = memory.switching(from: sort, to: key)
        sortMemory = memory
        sort = next
    }

    /// Puts back a sort saved by `sortDidChange` (see
    /// `LibrarySortMemory.stored`), without reporting it as a change.
    public func restoreSort(_ stored: [String: Any]?) {
        let report = sortDidChange
        sortDidChange = nil
        defer { sortDidChange = report }
        let restored = LibrarySortMemory.restore(stored)
        sortMemory = restored.memory
        sort = restored.sort
    }

    /// Whether dragging thumbnails rearranges them: only under the Custom
    /// sort, with a folder open.
    public var canReorder: Bool { sort.key == .custom && catalog != nil }

    /// Moves the images at `moving` (catalog-relative paths) to just before
    /// `target` as the grid shows it, or to the end for nil, and saves the
    /// arrangement. Undoable. Images the filter hides keep their places
    /// relative to the rest (`CustomOrder.afterMove`).
    ///
    /// The grid shows the new order at once; the file is written in the
    /// background through `perform`, and if that fails the previous order
    /// comes back and the status bar says why.
    public func moveInCustomOrder(_ moving: [String], before target: String?) {
        guard canReorder, let catalog, !moving.isEmpty else { return }
        let current = CustomOrder.arranged(images, positions: CustomOrder.positions(customOrder), ascending: true)
            .map(\.relPath)
        let next = CustomOrder.afterMove(all: images, order: customOrder, ascending: sort.ascending,
                                         moving: moving, before: target)
        guard next != current else { return }
        replaceCustomOrder(with: next, previous: customOrder, in: catalog)
    }

    /// Shows and saves `order`, registering the way back to `previous`.
    /// The inverse is registered here, synchronously, so that during an
    /// undo it lands on the redo stack as UndoManager expects.
    func replaceCustomOrder(with order: [String], previous: [String], in catalog: Catalog) {
        guard catalog === self.catalog else { return }
        customOrder = order
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { library in
                MainActor.assumeIsolated {
                    library.replaceCustomOrder(with: previous, previous: order, in: catalog)
                }
            }
            undoManager.setActionName("Rearrange")
        }
        perform("Saving the custom order") { [weak self] in
            // Two drops in quick succession each write the latest order, so
            // whichever write lands last, the file ends up as shown.
            let latest = self.flatMap { $0.catalog === catalog ? $0.customOrder : nil } ?? order
            do {
                try await catalog.setCustomOrder(latest)
            } catch {
                if let self, catalog === self.catalog, self.customOrder == order { self.customOrder = previous }
                throw error
            }
        }
    }
}
