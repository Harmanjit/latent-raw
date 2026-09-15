import AppKit
import Catalog

/// Dragging thumbnails: out of the grid as the original files, to Finder
/// or any app that takes files, and within the grid to rearrange the
/// Custom sort.
///
/// One drag source serves both. Each dragged item writes its file URL, so
/// a drop elsewhere gets the raw itself (Finder copies it; the original
/// never leaves its catalog by a drag). Dropped back on the grid under the
/// Custom sort, the same drag moves the images to the gap it shows.
/// Under any other sort the grid refuses the drop: its order is the key's.
@MainActor
enum GridDragAndDrop {
    static func configure(_ collection: NSCollectionView) {
        // Only this grid's own drags are accepted; the type is what they carry.
        collection.registerForDraggedTypes([.fileURL])
        // Other apps may copy; inside Latent a drop may move (a rearrangement,
        // or a file drop on a folder, which decides for itself).
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
    }

    /// Where a drop at the gap before `index` goes: before that image, or
    /// at the end for the gap after the last.
    static func target<Paths: RandomAccessCollection<String>>(before index: Int, in paths: Paths) -> String?
        where Paths.Index == Int {
        paths.indices.contains(index) ? paths[index] : nil
    }
}

extension ThumbnailGridView.Coordinator {
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool {
        library.folderURL != nil && !indexPaths.isEmpty
    }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        let images = shownImages
        guard images.indices.contains(indexPath.item), let url = library.fileURL(for: images[indexPath.item]) else {
            return nil
        }
        return url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        let images = shownImages
        draggedPaths = indexPaths.sorted().map(\.item).filter(images.indices.contains).map { images[$0].relPath }
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        draggedPaths = []
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>)
        -> NSDragOperation {
        guard (draggingInfo.draggingSource as AnyObject?) === collectionView, !draggedPaths.isEmpty,
              library.canReorder else { return [] }
        // Always between images: dropping onto one means "here".
        if proposedDropOperation.pointee == .on { proposedDropOperation.pointee = .before }
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard (draggingInfo.draggingSource as AnyObject?) === collectionView, !draggedPaths.isEmpty,
              library.canReorder else { return false }
        let target = GridDragAndDrop.target(before: indexPath.item, in: shownImages.lazy.map(\.relPath))
        library.moveInCustomOrder(draggedPaths, before: target)
        return true
    }
}
