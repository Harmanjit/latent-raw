import SwiftUI
import AppKit
import Catalog

/// The collapsible left sidebar: favourite folders, each expanding into its
/// folder tree. Clicking a folder opens it as the catalog, exactly as Open
/// Folder does.
///
/// The tree is only ever read with `readdir`; no catalog is touched until a
/// folder is opened. Under the sandbox the app may read inside a favourite
/// (its bookmark carries the permission) but nowhere else, which is why
/// folders outside every favourite still need Open Folder, and the footer
/// says so.
struct FolderSidebar: View {
    @ObservedObject var favourites: FavouriteFolders
    /// The folder to highlight: the one being opened, else the open catalog.
    let currentFolder: URL?
    /// Returns whether opening started; false when the folder was refused
    /// at once (the message is already shown).
    let onOpen: (URL) -> Bool
    /// Shows the open panel to choose a folder to add.
    let onChooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderOutline(folders: favourites.folders, currentFolder: currentFolder,
                          onOpen: open, onAdd: { urls in urls.forEach { favourites.add($0) } },
                          onRemove: { favourites.remove($0) }, onChooseFolder: onChooseFolder)
            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    /// A favourite whose disk wasn't there is resolved again first; if it
    /// still isn't, opening reports why.
    private func open(_ url: URL) -> Bool {
        if let favourite = favourites.folders.first(where: { FolderAccess.samePath($0.url, url) }),
           !favourite.isAvailable {
            return onOpen(favourites.retry(url) ?? url)
        }
        return onOpen(url)
    }

    private var isInsideAFavourite: Bool {
        guard let currentFolder else { return true }
        return FolderAccess.bestRoot(for: currentFolder, among: favourites.folders.map(\.url)) != nil
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if favourites.folders.isEmpty {
                Text("Add the folders you keep photos in. Latent can open any folder inside them from here; for anywhere else, use Open Folder….")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isInsideAFavourite, let currentFolder {
                Text("“\(currentFolder.lastPathComponent)” isn’t in a favourite, so its neighbours can’t be shown here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add “\(currentFolder.lastPathComponent)”") { favourites.add(currentFolder) }
                    .controlSize(.small)
                    .accessibilityLabel("Add \(currentFolder.lastPathComponent) to Favourites")
            }
            Button(action: onChooseFolder) {
                Label("Add Folder…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Add a folder to Favourites. Folders inside it open from the sidebar; drag folders here from Finder too.")
            .accessibilityLabel("Add Folder to Favourites")
        }
    }
}

/// Hosts the AppKit outline: a source list recycles its rows and lists
/// each level only when it's expanded, which a SwiftUI List over a whole
/// photo library can't promise.
private struct FolderOutline: NSViewControllerRepresentable {
    let folders: [FavouriteFolder]
    let currentFolder: URL?
    let onOpen: (URL) -> Bool
    let onAdd: ([URL]) -> Void
    let onRemove: (URL) -> Void
    let onChooseFolder: () -> Void

    func makeNSViewController(context: Context) -> FolderOutlineController {
        let controller = FolderOutlineController()
        update(controller)
        return controller
    }

    func updateNSViewController(_ controller: FolderOutlineController, context: Context) {
        update(controller)
    }

    private func update(_ controller: FolderOutlineController) {
        controller.onOpen = onOpen
        controller.onAdd = onAdd
        controller.onRemove = onRemove
        controller.onChooseFolder = onChooseFolder
        controller.setFavourites(folders)
        controller.reveal(currentFolder)
    }
}

/// One row. A class, because NSOutlineView identifies rows by identity.
private final class FolderNode {
    enum Kind { case header, favourite, folder }

    let kind: Kind
    let title: String
    let url: URL?
    var isAvailable: Bool
    var hasCatalog: Bool
    /// nil until listed.
    var children: [FolderNode]?
    /// Whether to draw a disclosure triangle, from a check that stops at the
    /// first subfolder. False until that check is back.
    var mayHaveChildren: Bool
    var isListing = false
    /// The user or a reveal asked to expand this row before it was listed.
    var wantsExpansion = false
    /// Gone from the tree (its favourite was removed) while a listing for it
    /// may still be out; a listing that lands on it is dropped.
    private(set) var isDetached = false

    init(kind: Kind, title: String, url: URL?, isAvailable: Bool = true, hasCatalog: Bool = false,
         children: [FolderNode]? = nil, mayHaveChildren: Bool = false) {
        self.kind = kind
        self.title = title
        self.url = url
        self.isAvailable = isAvailable
        self.hasCatalog = hasCatalog
        self.children = children
        self.mayHaveChildren = mayHaveChildren
    }

    func detach() {
        isDetached = true
        children?.forEach { $0.detach() }
    }
}

/// A subfolder as a background listing found it.
private struct FoundFolder: Sendable {
    let url: URL
    let title: String
    let hasSubfolders: Bool
    let hasCatalog: Bool

    /// Reads the disk: call off the main thread.
    static func list(_ folder: URL) -> [FoundFolder] {
        FolderAccess.subfolders(of: folder).map { url in
            FoundFolder(url: url, title: FileManager.default.displayName(atPath: url.path),
                        hasSubfolders: FolderAccess.hasSubfolders(url), hasCatalog: FolderAccess.hasCatalog(url))
        }
    }
}

/// Clicks select rows but the outline never takes the keyboard, so the
/// arrow keys keep stepping through images (BareKeyMonitor) and arrowing
/// through the tree can't open one catalog after another.
private final class FolderOutlineView: NSOutlineView {
    override var acceptsFirstResponder: Bool { false }
}

private final class FolderOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpen: ((URL) -> Bool)?
    var onAdd: (([URL]) -> Void)?
    var onRemove: ((URL) -> Void)?
    var onChooseFolder: (() -> Void)?

    private let outlineView = FolderOutlineView()
    private let header = FolderNode(kind: .header, title: "Favourites", url: nil, children: [])
    private var currentFolder: URL?
    private var favouriteAvailability: [String: Bool] = [:]
    private var favouriteOrder: [String] = []
    /// Set while rows are selected or expanded in code, so that isn't taken
    /// for a click (which would open a catalog, or list a row twice).
    private var isChangingInCode = false
    /// Folders relisted because the folder being revealed wasn't among
    /// their children, so a folder that really is hidden isn't relisted
    /// over and over. Cleared for each new folder.
    private var relistedForReveal: Set<String> = []

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        outlineView.autosaveExpandedItems = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.backgroundColor = .clear
        outlineView.setAccessibilityLabel("Folders")

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView
        outlineView.reloadData()
        outlineView.expandItem(header)
    }

    // MARK: - Favourites

    /// Rebuilds the favourite rows only when the list or a favourite's
    /// availability changed. Rows kept keep their listed, expanded subtrees.
    func setFavourites(_ folders: [FavouriteFolder]) {
        let order = folders.map(\.id)
        let availability = Dictionary(folders.map { ($0.id, $0.isAvailable) }, uniquingKeysWith: { a, _ in a })
        guard order != favouriteOrder || availability != favouriteAvailability else { return }
        favouriteOrder = order
        favouriteAvailability = availability
        _ = view

        var existing: [String: FolderNode] = [:]
        for node in header.children ?? [] { if let url = node.url { existing[url.standardizedFileURL.path] = node } }
        var fresh: [FolderNode] = []
        let nodes = folders.map { folder -> FolderNode in
            if let node = existing.removeValue(forKey: folder.id), node.isAvailable == folder.isAvailable { return node }
            let node = FolderNode(kind: .favourite, title: FileManager.default.displayName(atPath: folder.url.path),
                                  url: folder.url, isAvailable: folder.isAvailable)
            if folder.isAvailable { fresh.append(node) }
            return node
        }
        existing.values.forEach { $0.detach() }
        header.children = nodes
        isChangingInCode = true
        outlineView.reloadItem(header, reloadChildren: true)
        outlineView.expandItem(header)
        isChangingInCode = false
        checkForSubfolders(fresh)
        reveal(currentFolder, force: true)
    }

    /// Finds out in the background which new favourites can expand.
    private func checkForSubfolders(_ nodes: [FolderNode]) {
        let urls = nodes.compactMap(\.url)
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            let answers = await Task.detached(priority: .utility) {
                urls.map { (FolderAccess.hasSubfolders($0), FolderAccess.hasCatalog($0)) }
            }.value
            guard let self else { return }
            for (node, answer) in zip(nodes, answers) where !node.isDetached && node.children == nil {
                node.mayHaveChildren = answer.0
                node.hasCatalog = answer.1
                self.reloadRow(node, children: false)
            }
        }
    }

    // MARK: - Children

    /// Lists a row's subfolders off the main thread: the first time it's
    /// expanded, and again (`refresh`) on every later expansion or reveal,
    /// since folders made or deleted in Finder meanwhile should appear and
    /// go. There is no live watching (DESIGN.md §5.3).
    private func listChildren(of node: FolderNode, refresh: Bool = false) {
        guard let url = node.url, node.isAvailable, !node.isDetached, !node.isListing,
              refresh || node.children == nil else { return }
        node.isListing = true
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { FoundFolder.list(url) }.value
            node.isListing = false
            guard let self, !node.isDetached else { return }
            self.apply(found, to: node)
        }
    }

    /// Shows a listing, keeping the row objects of folders still there so
    /// their own expanded subtrees and the selection survive.
    private func apply(_ found: [FoundFolder], to node: FolderNode) {
        let firstListing = node.children == nil
        let old = node.children ?? []
        var existing: [String: FolderNode] = [:]
        for child in old { if let url = child.url { existing[url.standardizedFileURL.path] = child } }
        var rowsChanged = false
        let children = found.map { folder -> FolderNode in
            if let child = existing.removeValue(forKey: folder.url.standardizedFileURL.path) {
                if child.children == nil, child.mayHaveChildren != folder.hasSubfolders {
                    child.mayHaveChildren = folder.hasSubfolders
                    rowsChanged = true
                }
                if child.hasCatalog != folder.hasCatalog {
                    child.hasCatalog = folder.hasCatalog
                    rowsChanged = true
                }
                return child
            }
            return FolderNode(kind: .folder, title: folder.title, url: folder.url, hasCatalog: folder.hasCatalog,
                              mayHaveChildren: folder.hasSubfolders)
        }
        existing.values.forEach { $0.detach() }
        let unchanged = node.children != nil && children.map(ObjectIdentifier.init) == old.map(ObjectIdentifier.init)
        node.children = children
        node.mayHaveChildren = !children.isEmpty
        if !unchanged || rowsChanged { reloadRow(node, children: true) }
        if node.wantsExpansion {
            node.wantsExpansion = false
            isChangingInCode = true
            outlineView.expandItem(node)
            isChangingInCode = false
        }
        // Only a reveal that may have been waiting for this listing looks
        // again: revealing after every relist would reopen rows the user
        // had collapsed.
        if firstListing || node.url.map({ relistedForReveal.contains($0.standardizedFileURL.path) }) == true {
            reveal(currentFolder, force: true)
        }
    }

    private func reloadRow(_ node: FolderNode, children: Bool) {
        isChangingInCode = true
        outlineView.reloadItem(node, reloadChildren: children)
        isChangingInCode = false
        // A reload can drop the selection; put the highlight back.
        select(self.node(for: currentFolder))
    }

    // MARK: - Reveal

    /// Selects the row for `folder` when it lies under a favourite, expanding
    /// (and listing) the rows above it; clears the selection otherwise.
    /// Listing is asynchronous, so this runs again as each level arrives.
    func reveal(_ folder: URL?, force: Bool = false) {
        let isNew = folder.map { new in currentFolder.map { !FolderAccess.samePath($0, new) } ?? true } ?? (currentFolder != nil)
        guard isNew || force else { return }
        currentFolder = folder
        if isNew { relistedForReveal = [] }
        guard isViewLoaded else { return }
        let favourites = (header.children ?? []).filter(\.isAvailable)
        guard let folder,
              let rootIndex = FolderAccess.bestRoot(for: folder, among: favourites.compactMap(\.url)),
              let chain = FolderAccess.chain(from: favourites[rootIndex].url!, to: folder) else {
            select(nil)
            return
        }
        var node = favourites[rootIndex]
        for url in chain.dropFirst() {
            guard let children = node.children else {
                node.wantsExpansion = true
                listChildren(of: node)
                select(nil)
                return
            }
            let name = url.lastPathComponent
            guard let child = children.first(where: { $0.url?.lastPathComponent == name }) else {
                // Made since the parent was listed: list it again, once.
                if let parent = node.url, relistedForReveal.insert(parent.standardizedFileURL.path).inserted {
                    listChildren(of: node, refresh: true)
                }
                select(nil)
                return
            }
            isChangingInCode = true
            outlineView.expandItem(node)
            isChangingInCode = false
            node = child
        }
        select(node)
    }

    private func node(for folder: URL?) -> FolderNode? {
        guard let folder else { return nil }
        let favourites = (header.children ?? []).filter(\.isAvailable)
        guard let rootIndex = FolderAccess.bestRoot(for: folder, among: favourites.compactMap(\.url)),
              let chain = FolderAccess.chain(from: favourites[rootIndex].url!, to: folder) else { return nil }
        var node = favourites[rootIndex]
        for url in chain.dropFirst() {
            guard let child = node.children?.first(where: { $0.url?.lastPathComponent == url.lastPathComponent }) else {
                return nil
            }
            node = child
        }
        return node
    }

    private func select(_ node: FolderNode?) {
        let row = node.map { outlineView.row(forItem: $0) } ?? -1
        guard row != outlineView.selectedRow else { return }
        isChangingInCode = true
        if row >= 0 {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
        isChangingInCode = false
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FolderNode else { return 1 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FolderNode else { return header }
        return node.children?[index] ?? header
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        if node.kind == .header { return true }
        guard node.isAvailable else { return false }
        return node.children.map { !$0.isEmpty } ?? node.mayHaveChildren
    }

    // MARK: - Drop: folders from Finder become favourites

    private func droppedFolders(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
    }

    /// The whole list is the target, never a row: a dropped folder is
    /// added to Favourites, not moved into the folder under the pointer.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard !droppedFolders(info).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let folders = droppedFolders(info)
        guard !folders.isEmpty else { return false }
        onAdd?(folders)
        return true
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? FolderNode)?.kind == .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FolderNode)?.kind != .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        if node.kind == .header { return true }
        if node.children == nil {
            node.wantsExpansion = true
            listChildren(of: node)
            return false
        }
        if !isChangingInCode { listChildren(of: node, refresh: true) }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let isHeader = node.kind == .header
        let id = NSUserInterfaceItemIdentifier(isHeader ? "HeaderCell" : "FolderCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id, image: !isHeader)
        cell.textField?.stringValue = node.title
        guard !isHeader else { return cell }
        let symbol = !node.isAvailable ? "externaldrive.badge.xmark" : node.hasCatalog ? "folder.fill" : "folder"
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.textField?.textColor = node.isAvailable ? .labelColor : .tertiaryLabelColor
        var label = node.title
        if !node.isAvailable {
            label += ", not connected"
            cell.toolTip = "Not connected: \(node.url?.path ?? ""). Connect its disk or share, then click it."
        } else {
            if node.hasCatalog { label += ", has a catalog" }
            cell.toolTip = node.url?.path
        }
        cell.setAccessibilityLabel(label)
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, image: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        if image {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            imageView.contentTintColor = .controlAccentColor
            cell.addSubview(imageView)
            cell.imageView = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            ])
        } else {
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            text.textColor = .tertiaryLabelColor
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// A click opens the folder: on the click itself, not on a selection
    /// change, so dragging across rows doesn't open each one and a click on
    /// a disclosure triangle only expands. The highlight follows the folder
    /// being opened (ContentView passes it as current) and goes back if the
    /// folder is refused.
    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FolderNode, let url = node.url else { return }
        if let event = NSApp.currentEvent,
           outlineView.frameOfOutlineCell(atRow: row).contains(outlineView.convert(event.locationInWindow, from: nil)) {
            return
        }
        if let currentFolder, FolderAccess.samePath(currentFolder, url) { return }
        guard onOpen?(url) == false else { return }
        select(self.node(for: currentFolder))
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FolderNode, let url = node.url else {
            menu.addItem(item("Add Folder…", #selector(chooseFolderClicked(_:)), nil))
            return
        }
        menu.addItem(item("Open", #selector(openClicked(_:)), url))
        if node.isAvailable {
            menu.addItem(item("Show in Finder", #selector(revealClicked(_:)), url))
        }
        menu.addItem(.separator())
        if node.kind == .favourite {
            menu.addItem(item("Remove from Favourites", #selector(removeClicked(_:)), url))
        } else {
            menu.addItem(item("Add to Favourites", #selector(addClicked(_:)), url))
        }
    }

    private func item(_ title: String, _ action: Selector, _ url: URL?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = url
        return item
    }

    @objc private func openClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = onOpen?(url)
    }

    @objc private func revealClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onRemove?(url)
    }

    @objc private func addClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onAdd?([url])
    }

    @objc private func chooseFolderClicked(_ sender: NSMenuItem) {
        onChooseFolder?()
    }
}
