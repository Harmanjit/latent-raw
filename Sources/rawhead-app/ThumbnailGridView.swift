import SwiftUI
import AppKit
import Catalog

/// The library grid: an NSCollectionView of thumbnails.
///
/// AppKit rather than a SwiftUI LazyVGrid because the Phase 2 exit
/// criterion is smooth scrolling through 20,000 images, and only a
/// collection view recycles a fixed pool of cells at that scale
/// (DESIGN.md §3). Cells ask the Library for a cached thumbnail and,
/// on a miss, load it asynchronously and fill in when it arrives.
struct ThumbnailGridView: NSViewRepresentable {
    @ObservedObject var library: Library
    /// Double-click, or Return: open this image in the editor.
    let onOpen: (ImageRecord) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(library: library, onOpen: onOpen) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: ThumbnailItem.width, height: ThumbnailItem.height)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsEmptySelection = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [NSColor(white: 0.12, alpha: 1)]
        collection.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        context.coordinator.collectionView = collection

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync(with: library)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let library: Library
        let onOpen: (ImageRecord) -> Void
        weak var collectionView: NSCollectionView?

        private var images: [ImageRecord] = []
        private var thumbnailVersion = -1
        private var selectedID: Int64?

        init(library: Library, onOpen: @escaping (ImageRecord) -> Void) {
            self.library = library
            self.onOpen = onOpen
        }

        /// Called on every SwiftUI update. Reloads only when the list or
        /// the thumbnails actually changed; a selection change just moves
        /// the highlight.
        func sync(with library: Library) {
            guard let collectionView else { return }
            if library.images != images {
                images = library.images
                collectionView.reloadData()
            } else if library.thumbnailVersion != thumbnailVersion {
                collectionView.reloadItems(at: collectionView.indexPathsForVisibleItems())
            }
            thumbnailVersion = library.thumbnailVersion

            if library.selectedImageID != selectedID {
                selectedID = library.selectedImageID
                if let index = images.firstIndex(where: { $0.id == selectedID }) {
                    let path = IndexPath(item: index, section: 0)
                    collectionView.selectionIndexPaths = [path]
                    collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
                } else {
                    collectionView.selectionIndexPaths = []
                }
            }
        }

        // MARK: Data source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            images.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
            guard let cell = item as? ThumbnailItem else { return item }
            let record = images[indexPath.item]
            cell.configure(record: record, thumbnail: library.cachedThumbnail(for: record))
            cell.onDoubleClick = { [weak self] in self?.onOpen(record) }

            if cell.thumbnail == nil {
                let library = library
                Task { [weak cell] in
                    guard let image = await library.loadThumbnail(for: record) else { return }
                    // The cell may have been recycled for another image
                    // while the load was in flight.
                    if cell?.representedID == record.id { cell?.thumbnail = image }
                }
            }
            return cell
        }

        // MARK: Delegate

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let path = indexPaths.first else { return }
            selectedID = images[path.item].id
            library.selectedImageID = selectedID
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            if collectionView.selectionIndexPaths.isEmpty {
                selectedID = nil
                library.selectedImageID = nil
            }
        }
    }
}

/// One grid cell: thumbnail, filename, rating.
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")
    static let width: CGFloat = 176
    static let height: CGFloat = 176 + 34

    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let ratingLabel = NSTextField(labelWithString: "")

    private(set) var representedID: Int64?
    private var userRotation = 0
    var onDoubleClick: (() -> Void)?

    /// The cached, camera-oriented thumbnail; the user's extra turns are
    /// applied here at display time (512px, sub-millisecond) rather than
    /// baked into the file, so rotating never regenerates a thumbnail.
    var thumbnail: CGImage? {
        didSet {
            thumbnailView.image = thumbnail.map { image in
                let shown = Thumbnailer.rotated(image, quarterTurns: userRotation)
                return NSImage(cgImage: shown, size: NSSize(width: shown.width, height: shown.height))
            }
        }
    }

    override func loadView() {
        let root = DoubleClickView()
        root.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        root.wantsLayer = true
        root.layer?.cornerRadius = 4
        view = root

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageAlignment = .alignCenter
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        thumbnailView.layer?.cornerRadius = 3

        nameLabel.font = .systemFont(ofSize: 10)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .center
        ratingLabel.font = .systemFont(ofSize: 9)
        ratingLabel.textColor = .tertiaryLabelColor
        ratingLabel.alignment = .center

        for subview in [thumbnailView, nameLabel, ratingLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            thumbnailView.heightAnchor.constraint(equalToConstant: Self.width - 8),
            nameLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            ratingLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            ratingLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ratingLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func configure(record: ImageRecord, thumbnail: CGImage?) {
        representedID = record.id
        userRotation = record.userRotation
        nameLabel.stringValue = record.fileName
        var badges: [String] = []
        if record.flag > 0 { badges.append("✓") }
        if record.flag < 0 { badges.append("✗") }
        if record.rating > 0 { badges.append(String(repeating: "★", count: record.rating)) }
        ratingLabel.stringValue = badges.joined(separator: "  ")
        ratingLabel.textColor = record.flag < 0 ? .systemRed
            : record.flag > 0 ? .systemGreen : .tertiaryLabelColor
        self.thumbnail = thumbnail
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        userRotation = 0
        thumbnail = nil
        onDoubleClick = nil
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
                : NSColor.clear.cgColor
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            if highlightState == .forSelection {
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            } else if !isSelected {
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }
}

/// NSCollectionView has no double-click hook, so the cell's root view
/// watches for it. Single clicks still fall through to selection.
final class DoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}
