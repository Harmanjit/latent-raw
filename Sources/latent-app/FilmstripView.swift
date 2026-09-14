import SwiftUI
import AppKit
import Catalog

/// The strip of thumbnails along the bottom of Loupe and Develop: the
/// folder's visible images, with the grid's filter and sort, the current
/// image highlighted and kept in view. Click one to open it.
///
/// An NSCollectionView, like the grid, so a folder of twenty thousand
/// images costs the same as fifty: only cells in view exist and they are
/// recycled. Thumbnails come from the Library's cache, so a folder already
/// browsed shows its strip at once. A cell's load is cancelled when it
/// scrolls away, and every load goes when the strip does (hidden, or
/// another mode), since SwiftUI then takes the view down.
struct FilmstripView: NSViewRepresentable {
    static let height: CGFloat = 86

    @ObservedObject var library: Library
    let onSelect: (ImageRecord) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = FilmstripItem.size
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let collection = FilmstripCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.setAccessibilityLabel("Filmstrip")
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        collection.addGestureRecognizer(click)
        context.coordinator.collectionView = collection

        let scroll = HorizontalScrollView()
        scroll.onResize = { [weak coordinator = context.coordinator] in coordinator?.scrollToCurrentIfPending() }
        scroll.documentView = collection
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.sync(with: library)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelAll()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let library: Library
        var onSelect: ((ImageRecord) -> Void)?
        weak var collectionView: NSCollectionView?

        private var images: [ImageRecord] = []
        private var currentID: Int64?
        private var thumbnailVersion = -1
        /// The current image still has to be scrolled into view: set when
        /// the list or the current image changes, cleared once a scroll
        /// could happen (the strip has a size).
        private var scrollPending = true
        /// The first scroll lands straight away; later ones glide.
        private var hasScrolled = false

        init(library: Library) {
            self.library = library
        }

        /// Called on every SwiftUI update. Reloads only when the list or the
        /// thumbnails changed; a new current image moves the ring and
        /// scrolls it into view.
        func sync(with library: Library) {
            guard let collectionView else { return }
            if library.visibleImages != images {
                images = library.visibleImages
                collectionView.reloadData()
                scrollPending = true
                hasScrolled = false
            } else if library.thumbnailVersion != thumbnailVersion {
                for case let item as FilmstripItem in collectionView.visibleItems() {
                    item.reloadThumbnail()
                }
            }
            thumbnailVersion = library.thumbnailVersion

            if library.selectedImageID != currentID {
                currentID = library.selectedImageID
                for case let item as FilmstripItem in collectionView.visibleItems() {
                    item.isCurrent = item.record?.id != nil && item.record?.id == currentID
                }
                scrollPending = true
            }
            scrollToCurrentIfPending()
        }

        /// Nearest edge, so stepping to an image already in view doesn't
        /// move the strip at all. Glides unless Reduce Motion is on.
        func scrollToCurrentIfPending() {
            guard scrollPending, let collectionView, let scrollView = collectionView.enclosingScrollView,
                  scrollView.bounds.width > 0 else { return }
            scrollPending = false
            guard let index = images.firstIndex(where: { $0.id == currentID }) else { return }
            collectionView.layoutSubtreeIfNeeded()
            let path = IndexPath(item: index, section: 0)
            if hasScrolled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.allowsImplicitAnimation = true
                    collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
                }
            } else {
                collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
            }
            hasScrolled = true
        }

        func cancelAll() {
            for case let item as FilmstripItem in collectionView?.visibleItems() ?? [] { item.cancelThumbnail() }
        }

        @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard let collectionView,
                  let path = collectionView.indexPathForItem(at: recognizer.location(in: collectionView)),
                  images.indices.contains(path.item) else { return }
            onSelect?(images[path.item])
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            images.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath)
            guard let cell = item as? FilmstripItem, images.indices.contains(indexPath.item) else { return item }
            let record = images[indexPath.item]
            cell.show(record, library: library)
            cell.isCurrent = record.id != nil && record.id == currentID
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            (item as? FilmstripItem)?.cancelThumbnail()
        }
    }
}

/// Never takes the keyboard: the arrow keys must keep stepping through
/// images after a click on the strip.
private final class FilmstripCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

/// A mouse wheel scrolls the strip sideways. Trackpads already scroll in
/// both directions, so only line-based wheel events are turned.
private final class HorizontalScrollView: NSScrollView {
    /// Tells the strip it has a size, for the scroll it couldn't make before.
    var onResize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0 { onResize?() }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              let cgEvent = event.cgEvent?.copy() else { return super.scrollWheel(with: event) }
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(event.scrollingDeltaY))
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        super.scrollWheel(with: NSEvent(cgEvent: cgEvent) ?? event)
    }
}

/// One thumbnail: the picture, a ring when it's the current image, and its
/// name for VoiceOver and the tooltip.
private final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmstripItem")
    static let size = NSSize(width: 96, height: FilmstripView.height - 12)

    private let imageLayer = CALayer()
    private let ringLayer = CALayer()
    private(set) var record: ImageRecord?
    private weak var library: Library?
    private var load: Task<Void, Never>?

    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            ringLayer.isHidden = !isCurrent
            view.setAccessibilitySelected(isCurrent)
        }
    }

    override func loadView() {
        let view = CellView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        view.onLayout = { [weak self] in self?.layoutLayers() }
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        ringLayer.borderWidth = 2
        ringLayer.cornerRadius = 5
        ringLayer.borderColor = NSColor.controlAccentColor.cgColor
        ringLayer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        ringLayer.isHidden = true
        view.layer?.addSublayer(ringLayer)
        view.layer?.addSublayer(imageLayer)
        self.view = view
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.frame = view.bounds
        imageLayer.frame = view.bounds.insetBy(dx: 4, dy: 4)
        let scale = view.window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = scale
        ringLayer.contentsScale = scale
        CATransaction.commit()
    }

    func show(_ record: ImageRecord, library: Library) {
        let sameImage = record.id == self.record?.id && record.userRotation == self.record?.userRotation
        self.record = record
        self.library = library
        var label = record.fileName
        if record.rating > 0 { label += ", \(record.rating) star\(record.rating == 1 ? "" : "s")" }
        if record.flag > 0 { label += ", picked" } else if record.flag < 0 { label += ", rejected" }
        view.toolTip = record.fileName
        view.setAccessibilityLabel(label)
        if !sameImage {
            cancelThumbnail()
            setImage(nil)
        }
        if imageLayer.contents == nil { reloadThumbnail() }
    }

    /// A cached thumbnail is drawn at once, so scrolling back never shows a
    /// blank frame; otherwise it loads, unless the cell scrolls away first.
    func reloadThumbnail() {
        guard let record, let library else { return }
        if let cached = library.cachedThumbnail(for: record) {
            cancelThumbnail()
            setImage(cached)
            return
        }
        guard load == nil else { return }
        load = Task { [weak self] in
            // Cells flicked past are cancelled before their turn comes up.
            guard !Task.isCancelled else { return }
            let image = await library.loadThumbnail(for: record)
            guard let self, !Task.isCancelled, self.record?.id == record.id else { return }
            self.load = nil
            if let image { self.setImage(image) }
        }
    }

    func cancelThumbnail() {
        load?.cancel()
        load = nil
    }

    /// The user's quarter turns are applied here, as the grid does.
    private func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image.map { Thumbnailer.rotated($0, quarterTurns: record?.userRotation ?? 0) }
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        record = nil
        isCurrent = false
        setImage(nil)
    }

    /// Reports size and scale changes so the layers follow the cell.
    private final class CellView: NSView {
        var onLayout: (() -> Void)?
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            onLayout?()
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            onLayout?()
        }
    }
}
