import SwiftUI
import AppKit
import Catalog

/// The library grid: an NSCollectionView of thumbnails.
///
/// AppKit rather than a SwiftUI LazyVGrid because the Phase 2 exit
/// criterion is smooth scrolling through 20,000 images, and only a
/// collection view recycles a fixed pool of cells at that scale
/// (DESIGN.md §3). Cells show a thumbnail from the Library's memory cache
/// and, on a miss, ask its loader for one, cancelling when they scroll away
/// so a fling decodes only where it lands.
struct ThumbnailGridView: NSViewRepresentable {
    @ObservedObject var library: Library
    @ObservedObject private var prefs = AppPreferences.shared
    /// Double-click, or Return: open this image in the editor.
    let onOpen: (ImageRecord) -> Void
    /// What the right-click menu does.
    var actions = GridActions()

    func makeCoordinator() -> Coordinator { Coordinator(library: library, onOpen: onOpen) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = coordinator.layout.itemSize
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let collection = GridCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsEmptySelection = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [AppPreferences.shared.surroundNSColor]
        collection.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collection.dataSource = coordinator
        collection.delegate = coordinator
        collection.prefetchDataSource = coordinator
        collection.onOpen = { [weak coordinator] indexPath in coordinator?.open(at: indexPath) }
        collection.onSelectAll = { [weak coordinator] in coordinator?.selectAll() }
        collection.menuProvider = { [weak coordinator] indexPath in coordinator?.menu(at: indexPath) }
        collection.onScreenChange = { [weak coordinator] in coordinator?.screenChanged() }
        collection.setAccessibilityLabel("Thumbnails")
        coordinator.collectionView = collection

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.sync(with: library, side: prefs.thumbnailSize)
        if let collection = scrollView.documentView as? NSCollectionView {
            let colour = prefs.surroundNSColor
            if collection.backgroundColors.first != colour { collection.backgroundColors = [colour] }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
                             NSCollectionViewPrefetching {
        let library: Library
        let onOpen: (ImageRecord) -> Void
        var actions = GridActions()
        weak var collectionView: GridCollectionView?

        private(set) var layout = ThumbnailGridLayout(side: AppPreferences.shared.thumbnailSize)
        private var images: [ImageRecord] = []
        private var listVersion = -1
        private var thumbnailVersion = -1
        private var selectedID: Int64?
        private var selectedIDs: Set<Int64> = []
        /// Set while the library's selection is pushed into the view, so the
        /// view doesn't report it straight back.
        private var isApplyingSelection = false
        /// Thumbnails requested just ahead of the visible rows, by image,
        /// with the item each was asked for.
        private var prefetches: [Int64: (request: ThumbnailRequest, item: Int)] = [:]
        private var backingScale: CGFloat = 2

        init(library: Library, onOpen: @escaping (ImageRecord) -> Void) {
            self.library = library
            self.onOpen = onOpen
        }

        /// Called on every SwiftUI update, so it does only what changed: the
        /// whole grid reloads only when images come, go or reorder; a rating
        /// or flag redraws just the cells showing those images; new thumbnails
        /// fill the cells still waiting; a selection change moves the highlight.
        func sync(with library: Library, side: Double) {
            guard let collectionView else { return }
            let newLayout = ThumbnailGridLayout(side: side)
            if newLayout != layout { setLayout(newLayout) }

            var reloaded = false
            if library.visibleListVersion != listVersion || library.visibleImages.count != images.count {
                listVersion = library.visibleListVersion
                images = library.visibleImages
                cancelPrefetches()
                // Cells start clean and take their picture from the cache
                // again, so none can keep one that belongs to another image
                // (or another catalog) that happens to share its id.
                forEachVisibleCell { $0.forgetImage() }
                collectionView.reloadData()
                reloaded = true
            } else {
                images = library.visibleImages
                refreshVisibleCells()
            }
            if library.thumbnailVersion != thumbnailVersion {
                thumbnailVersion = library.thumbnailVersion
                if !reloaded { forEachVisibleCell { $0.refreshThumbnail() } }
            }

            if reloaded || library.selectedImageID != selectedID || library.selectedImageIDs != selectedIDs {
                applyLibrarySelection()
            }
        }

        // MARK: Cells

        private func forEachVisibleCell(_ body: (ThumbnailItem) -> Void) {
            guard let collectionView else { return }
            for case let cell as ThumbnailItem in collectionView.visibleItems() { body(cell) }
        }

        /// Visible cells whose record or edited badge changed pick up the new
        /// state; the rest aren't touched. Cells off screen get theirs when
        /// they're configured again.
        private func refreshVisibleCells() {
            guard let collectionView else { return }
            let edited = library.editedImageIDs
            for indexPath in collectionView.indexPathsForVisibleItems() where images.indices.contains(indexPath.item) {
                guard let cell = collectionView.item(at: indexPath) as? ThumbnailItem else { continue }
                let record = images[indexPath.item]
                cell.update(record: record, isEdited: record.id.map(edited.contains) ?? false)
            }
        }

        private func setLayout(_ newLayout: ThumbnailGridLayout) {
            let leadWasVisible = leadFrame().map { collectionView?.visibleRect.intersects($0) ?? false } ?? false
            layout = newLayout
            (collectionView?.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize = newLayout.itemSize
            cancelPrefetches()
            let pixelSize = newLayout.pixelSize(backingScale: backingScale)
            forEachVisibleCell { $0.apply(layout: newLayout, pixelSize: pixelSize) }
            if leadWasVisible { scrollLeadIntoView() }
        }

        /// The window moved to another screen, or the screens changed:
        /// thumbnails are drawn for the screen's colour space and scale.
        func screenChanged() {
            guard let window = collectionView?.window else { return }
            let space = window.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let spaceChanged = library.thumbnailLoader.displayColorSpace != space
            library.thumbnailLoader.displayColorSpace = space
            let scale = window.backingScaleFactor
            if scale != backingScale {
                backingScale = scale
                let pixelSize = layout.pixelSize(backingScale: scale)
                forEachVisibleCell { $0.apply(layout: layout, pixelSize: pixelSize) }
            }
            if spaceChanged { forEachVisibleCell { $0.refreshThumbnail() } }
        }

        // MARK: Data source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            images.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
            guard let cell = item as? ThumbnailItem, images.indices.contains(indexPath.item) else { return item }
            let record = images[indexPath.item]
            cell.configure(record: record, isEdited: record.id.map(library.editedImageIDs.contains) ?? false,
                           library: library, layout: layout, pixelSize: layout.pixelSize(backingScale: backingScale))
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            guard let cell = item as? ThumbnailItem else { return }
            cell.loadIfNeeded()
            // The cell's own request has joined the prefetch's job, so the
            // prefetch lets go. Otherwise it would keep the decode alive after
            // the cell scrolled away and cancelled.
            if let id = cell.record?.id { prefetches.removeValue(forKey: id)?.request.cancel() }
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            (item as? ThumbnailItem)?.cancelLoading()
        }

        // MARK: Prefetching

        /// Starts thumbnails for rows about to scroll into view, so they arrive
        /// with the cells rather than after them.
        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            dropDistantPrefetches()
            let pixelSize = layout.pixelSize(backingScale: backingScale)
            for indexPath in indexPaths where images.indices.contains(indexPath.item) {
                let record = images[indexPath.item]
                guard let id = record.id, prefetches[id] == nil,
                      library.displayThumbnail(for: record, pixelSize: pixelSize) == nil else { continue }
                let request = library.requestDisplayThumbnail(for: record, pixelSize: pixelSize) { [weak self] _ in
                    self?.prefetches[id] = nil
                }
                if let request { prefetches[id] = (request, indexPath.item) }
            }
        }

        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for indexPath in indexPaths where images.indices.contains(indexPath.item) {
                guard let id = images[indexPath.item].id else { continue }
                prefetches.removeValue(forKey: id)?.request.cancel()
            }
        }

        /// Cancels prefetches for rows the grid has scrolled well past without
        /// showing (a fling), which the collection view never cancels itself.
        private func dropDistantPrefetches() {
            guard !prefetches.isEmpty, let collectionView else { return }
            let visible = collectionView.indexPathsForVisibleItems().map(\.item)
            guard let first = visible.min(), let last = visible.max() else { return }
            let span = last - first + 1
            for (id, prefetch) in prefetches
            where prefetch.item < first - span || prefetch.item > last + span {
                prefetch.request.cancel()
                prefetches[id] = nil
            }
        }

        private func cancelPrefetches() {
            prefetches.values.forEach { $0.request.cancel() }
            prefetches.removeAll()
        }

        // MARK: Selection

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            reportSelection(added: indexPaths)
        }

        /// A click on another item deselects the old one and then selects the
        /// new one, as two calls. Reporting the empty moment in between would
        /// blank the metadata panel, so a deselection is reported a turn
        /// later, by when the selection (if any) has already arrived.
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            guard !isApplyingSelection else { return }
            DispatchQueue.main.async { [weak self] in self?.reportSelection(added: []) }
        }

        /// Tells the library what the view now selects. The lead is the item
        /// just clicked or arrowed to; when a shift-click adds several at
        /// once, it's the end that moved (`GridSelection.lead`).
        private func reportSelection(added: Set<IndexPath>) {
            guard !isApplyingSelection, let collectionView else { return }
            let selectedItems = Set(collectionView.selectionIndexPaths.map(\.item).filter(images.indices.contains))
            let previous = selectedID.flatMap { id in images.firstIndex { $0.id == id } }
            let leadItem = GridSelection.lead(previous: previous, added: added.map(\.item), selected: selectedItems)
            let ids = Set(selectedItems.compactMap { images[$0].id })
            library.setSelection(ids, primary: leadItem.flatMap { images[$0].id })
            // The view already shows this and has scrolled as it needs to.
            selectedIDs = library.selectedImageIDs
            selectedID = library.selectedImageID
        }

        /// Pushes the library's selection into the view, and scrolls to a lead
        /// the library moved (arrow keys, opening an image). A reload that
        /// keeps the lead leaves the scroll position alone.
        private func applyLibrarySelection() {
            guard let collectionView else { return }
            let leadMoved = library.selectedImageID != selectedID
            selectedID = library.selectedImageID
            selectedIDs = library.selectedImageIDs
            var paths = Set<IndexPath>()
            if selectedID != nil || !selectedIDs.isEmpty {
                for (index, image) in images.enumerated() {
                    guard let id = image.id, id == selectedID || selectedIDs.contains(id) else { continue }
                    paths.insert(IndexPath(item: index, section: 0))
                }
            }
            if paths != collectionView.selectionIndexPaths {
                isApplyingSelection = true
                collectionView.selectionIndexPaths = paths
                isApplyingSelection = false
            }
            if leadMoved { scrollLeadIntoView() }
        }

        private func leadFrame() -> CGRect? {
            guard let lead = selectedID, let index = images.firstIndex(where: { $0.id == lead }) else { return nil }
            return collectionView?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        }

        private func scrollLeadIntoView() {
            guard let collectionView, selectedID != nil else { return }
            // Layout first: after a reload the item has no frame to scroll to yet.
            collectionView.layoutSubtreeIfNeeded()
            guard let frame = leadFrame() else { return }
            collectionView.scrollToVisible(frame.insetBy(dx: 0, dy: -8))
        }

        /// ⌘A selects everything and keeps the lead where it is. The view's
        /// own select-all would report every item as newly added, and the
        /// lead would jump to whichever end is farthest away.
        func selectAll() {
            library.selectAllVisible()
            applyLibrarySelection()
        }

        // MARK: Opening and the menu

        func open(at indexPath: IndexPath) {
            guard images.indices.contains(indexPath.item) else { return }
            onOpen(images[indexPath.item])
        }

        /// A right-click on an unselected image selects it first, as in Finder,
        /// so the menu always acts on what's highlighted.
        func menu(at indexPath: IndexPath?) -> NSMenu? {
            guard let collectionView else { return nil }
            guard let indexPath, images.indices.contains(indexPath.item) else {
                return GridContextMenu.backgroundMenu(library: library)
            }
            if !collectionView.selectionIndexPaths.contains(indexPath) {
                isApplyingSelection = true
                collectionView.selectionIndexPaths = [indexPath]
                isApplyingSelection = false
                reportSelection(added: [indexPath])
            }
            return GridContextMenu.itemMenu(library: library, actions: actions)
        }
    }
}

/// The collection view with the grid's clicks: double-click opens, ⌘A keeps
/// the lead, right-click shows the menu, and it follows its screen.
final class GridCollectionView: NSCollectionView {
    var onOpen: ((IndexPath) -> Void)?
    var onSelectAll: (() -> Void)?
    var menuProvider: ((IndexPath?) -> NSMenu?)?
    var onScreenChange: (() -> Void)?
    private var screenObservers: [NSObjectProtocol] = []

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) { onOpen?(indexPath) }
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(indexPathForItem(at: point))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in screenObservers { NotificationCenter.default.removeObserver(observer) }
        screenObservers = []
        guard let window else { return }
        let names: [(NSNotification.Name, NSWindow?)] = [
            (NSWindow.didChangeScreenNotification, window),
            (NSWindow.didChangeBackingPropertiesNotification, window),
            (NSApplication.didChangeScreenParametersNotification, nil),
        ]
        for (name, object) in names {
            screenObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onScreenChange?() }
            })
        }
        onScreenChange?()
    }
}

/// One grid cell: thumbnail, file name, and a badge row (edited, flag,
/// stars).
///
/// A cell asks for its thumbnail when configured and cancels the request
/// when it scrolls away or is reused, so fast scrolling decodes only where
/// the user stops.
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    private typealias Want = (turns: Int, tier: Int)

    private(set) var record: ImageRecord?
    private(set) var isEdited = false
    private weak var library: Library?
    private var cellView: ThumbnailCellView { view as! ThumbnailCellView }
    private var request: ThumbnailRequest?
    /// Rotation and tier of the request in flight.
    private var requested: Want?
    /// Rotation and tier of what's showing; tier 0 for a stand-in of
    /// another size, shown while the right one loads.
    private var shown: Want?
    private var pixelSize = 0
    /// Bumped on every new image, so a completion meant for this cell's
    /// previous image is ignored even if it was already on its way.
    private var generation = 0

    override func loadView() {
        view = ThumbnailCellView(frame: NSRect(origin: .zero, size: ThumbnailGridLayout(side: 160).itemSize))
    }

    func configure(record: ImageRecord, isEdited: Bool, library: Library, layout: ThumbnailGridLayout, pixelSize: Int) {
        let sameImage = self.record?.id == record.id && self.record?.relPath == record.relPath
        self.library = library
        cellView.layoutInfo = layout
        self.pixelSize = pixelSize
        if !sameImage {
            cancelLoading()
            generation += 1
            // Any size already in memory beats a blank while the right one loads.
            let standIn = library.displayThumbnail(for: record, pixelSize: 1)
            cellView.setImage(standIn)
            shown = standIn == nil ? nil : (Self.turns(record), 0)
        }
        self.record = nil   // so update() applies everything
        update(record: record, isEdited: isEdited)
    }

    /// Shows a changed record: marks redraw only if they differ, and a new
    /// rotation asks for the turned thumbnail.
    func update(record: ImageRecord, isEdited: Bool) {
        guard record != self.record || isEdited != self.isEdited else { return }
        self.record = record
        self.isEdited = isEdited
        cellView.setMarks(name: record.fileName, rating: record.rating, flag: record.flag, isEdited: isEdited)
        loadIfNeeded()
    }

    func apply(layout: ThumbnailGridLayout, pixelSize: Int) {
        cellView.layoutInfo = layout
        self.pixelSize = pixelSize
        loadIfNeeded()
    }

    /// Requests whatever is missing: nothing showing, the wrong rotation, or
    /// a smaller tier than the cell now wants. Called again when the cell
    /// comes back on screen after `cancelLoading`.
    func loadIfNeeded() {
        guard let record, let library else { return }
        let wanted = want(record)
        if let shown, Self.satisfies(shown, wanted) { return }
        if let requested, Self.satisfies(requested, wanted) { return }
        if let image = library.displayThumbnail(for: record, pixelSize: pixelSize) {
            cancelLoading()
            cellView.setImage(image)
            shown = wanted
            return
        }
        startRequest(for: record, wanted: wanted)
    }

    /// New thumbnails landed or old ones were replaced. A cell whose picture
    /// is still what the cache holds does nothing; otherwise it asks again
    /// (joining any decode already under way), keeping the old picture up
    /// until the new one arrives.
    func refreshThumbnail() {
        guard let record, let library else { return }
        let wanted = want(record)
        if let image = library.displayThumbnail(for: record, pixelSize: pixelSize) {
            if !cellView.isShowing(image) {
                cancelLoading()
                cellView.setImage(image)
            }
            shown = wanted
            return
        }
        startRequest(for: record, wanted: wanted)
    }

    private func startRequest(for record: ImageRecord, wanted: Want) {
        guard let library else { return }
        cancelLoading()
        let generation = self.generation
        request = library.requestDisplayThumbnail(for: record, pixelSize: pixelSize) { [weak self] image in
            guard let self, self.generation == generation else { return }
            self.request = nil
            self.requested = nil
            guard let image else { return }
            self.cellView.setImage(image)
            self.shown = wanted
            // The cell grew, or the image turned, while this was loading.
            self.loadIfNeeded()
        }
        if request != nil { requested = wanted }
    }

    func cancelLoading() {
        request?.cancel()
        request = nil
        requested = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        forgetImage()
    }

    func forgetImage() {
        cancelLoading()
        generation += 1
        record = nil
        shown = nil
        cellView.setImage(nil)
    }

    private func want(_ record: ImageRecord) -> Want {
        (Self.turns(record), ThumbnailLoader.tier(forPixelSize: pixelSize))
    }

    private static func turns(_ record: ImageRecord) -> Int { ((record.userRotation % 4) + 4) % 4 }

    private static func satisfies(_ have: Want, _ wanted: Want) -> Bool {
        have.turns == wanted.turns && have.tier >= wanted.tier
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        cellView.selectionStyle = highlightState == .forSelection ? .highlighted
            : isSelected && highlightState != .forDeselection ? .selected : .none
    }
}

/// The view of one grid cell: the thumbnail drawn by a plain CALayer (the
/// CGImage goes straight to the layer, no NSImage in between), the name and
/// the badge row, laid out from `ThumbnailGridLayout`.
final class ThumbnailCellView: NSView {
    enum SelectionStyle { case none, highlighted, selected }

    private let placeholderLayer = CALayer()
    private let imageLayer = CALayer()
    private let nameField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")
    private var imagePixels: CGSize?
    /// The cached image the layer's copy was made from.
    private weak var sourceImage: CGImage?
    private var rating = 0
    private var flag = 0
    private var isEdited = false

    var layoutInfo = ThumbnailGridLayout(side: 160) {
        didSet { if layoutInfo != oldValue { needsLayout = true } }
    }
    var selectionStyle = SelectionStyle.none {
        didSet { if selectionStyle != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 4

        placeholderLayer.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        placeholderLayer.cornerRadius = 3
        imageLayer.contentsGravity = .resizeAspect
        // Thumbnails are decoded at 256 or 512 px and usually drawn smaller:
        // trilinear filtering keeps the downscale smooth instead of shimmery.
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        // Frames change as cells are reused and resized; they must not animate.
        let still: [String: any CAAction] = ["contents": NSNull(), "bounds": NSNull(),
                                             "position": NSNull(), "hidden": NSNull()]
        imageLayer.actions = still
        placeholderLayer.actions = still
        layer?.addSublayer(placeholderLayer)
        layer?.addSublayer(imageLayer)

        nameField.font = .systemFont(ofSize: 10)
        nameField.textColor = .secondaryLabelColor
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.alignment = .center
        badgeField.font = .systemFont(ofSize: 9)
        badgeField.textColor = .tertiaryLabelColor
        badgeField.alignment = .center
        for field in [nameField, badgeField] {
            field.maximumNumberOfLines = 1
            addSubview(field)
        }

        // VoiceOver reads the cell as one image (name, flag, stars, edited)
        // rather than scraps of it.
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        nameField.setAccessibilityElement(false)
        badgeField.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func accessibilityLabel() -> String? {
        Self.accessibilityText(name: nameField.stringValue, rating: rating, flag: flag, isEdited: isEdited)
    }

    override func isAccessibilitySelected() -> Bool { selectionStyle == .selected }

    /// "DSC_0107.NEF, picked, 3 stars, edited". Unrated and unflagged say
    /// nothing, as the cell shows nothing.
    static func accessibilityText(name: String, rating: Int, flag: Int, isEdited: Bool) -> String {
        var parts = [name]
        if flag > 0 { parts.append("picked") }
        if flag < 0 { parts.append("rejected") }
        if rating > 0 { parts.append(rating == 1 ? "1 star" : "\(min(rating, 5)) stars") }
        if isEdited { parts.append("edited") }
        return parts.joined(separator: ", ")
    }

    /// Name, stars, flag and edited badge. Text is set only when it
    /// changed, so refreshing every visible cell costs nearly nothing.
    func setMarks(name: String, rating: Int, flag: Int, isEdited: Bool) {
        if nameField.stringValue != name {
            nameField.stringValue = name
            toolTip = name
        }
        guard rating != self.rating || flag != self.flag || isEdited != self.isEdited else { return }
        self.rating = rating
        self.flag = flag
        self.isEdited = isEdited
        var badges: [String] = []
        if isEdited { badges.append("✎") }
        if flag > 0 { badges.append("✓") }
        if flag < 0 { badges.append("✗") }
        if rating > 0 { badges.append(String(repeating: "★", count: min(rating, 5))) }
        badgeField.stringValue = badges.joined(separator: "  ")
        badgeField.textColor = flag < 0 ? .systemRed : flag > 0 ? .systemGreen : .tertiaryLabelColor
    }

    /// Core Animation copies a CGImage's pixels for the render server and
    /// keeps that copy as long as the CGImage object lives. The cache keeps
    /// its images, so every thumbnail scrolled past would hold a second copy
    /// (minivu measured 194 MB beside the cache's own 191 MB). A new CGImage
    /// sharing the cached pixels (`copy()` copies no bytes) ties Core
    /// Animation's copy to this cell instead, and it goes when the cell
    /// moves on (43 MB).
    func setImage(_ image: CGImage?) {
        sourceImage = image
        imageLayer.contents = image?.copy()
        imagePixels = image.map { CGSize(width: $0.width, height: $0.height) }
        needsLayout = true
    }

    func isShowing(_ image: CGImage) -> Bool { sourceImage === image }

    override func layout() {
        super.layout()
        let info = layoutInfo
        placeholderLayer.frame = info.thumbnailArea
        imageLayer.frame = imagePixels.map(info.imageFrame(for:)) ?? info.thumbnailArea
        nameField.frame = info.nameFrame
        badgeField.frame = info.badgeFrame
    }

    /// Colours resolve here, against the view's appearance.
    override func updateLayer() {
        let fill: NSColor = switch selectionStyle {
        case .none: .clear
        case .highlighted: NSColor.controlAccentColor.withAlphaComponent(0.2)
        case .selected: NSColor.controlAccentColor.withAlphaComponent(0.35)
        }
        layer?.backgroundColor = fill.cgColor
        // A tinted fill alone is faint with Increase Contrast; add an outline.
        let outlined = selectionStyle == .selected && NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.borderWidth = outlined ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}
