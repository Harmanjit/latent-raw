import AppKit
import Catalog
import PixelEngine

/// What the grid's right-click menu does. ContentView owns the modes, the
/// settings clipboard, presets and the export sheet, so it supplies these;
/// the grid only decides what applies to the selection.
struct GridActions {
    var openLoupe: () -> Void = {}
    var openDevelop: () -> Void = {}
    var openCompare: () -> Void = {}
    var openSurvey: () -> Void = {}
    var rate: (Int) -> Void = { _ in }
    var flag: (ImageFlag) -> Void = { _ in }
    var rotate: (Int) -> Void = { _ in }
    var copySettings: () -> Void = {}
    var pasteSettings: () -> Void = {}
    var canPasteSettings: () -> Bool = { false }
    var presets: () -> [Preset] = { [] }
    var applyPreset: (Preset) -> Void = { _ in }
    var export: () -> Void = {}
    var canExport: () -> Bool = { true }
    var rename: () -> Void = {}
    /// Whether files can be renamed, moved or copied now.
    var canChangeFiles: () -> Bool = { false }
    /// Moves or copies the selection into a folder; nil asks which.
    var transfer: (TransferMode, URL?) -> Void = { _, _ in }
    var recentDestinations: () -> [URL] = { [] }
    /// Sets the selection's colour label; nil removes it.
    var label: (String?) -> Void = { _ in }
    var renameWithTemplate: () -> Void = {}
    /// Runs a menu command as the menu bar does, and says whether it can
    /// run now (virtual copies and Duplicate, whose rules live in
    /// CommandState).
    var command: (KeyCommand) -> Void = { _ in }
    var canRun: (KeyCommand) -> Bool = { _ in false }
}

/// The grid's context menus, built fresh each time they open so every
/// item is enabled and checked for the selection as it is now.
@MainActor
enum GridContextMenu {
    /// For a click on an image (already selected by then, as in Finder).
    static func itemMenu(library: Library, actions: GridActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Counted, never walked: ⌘A on a big folder must open the menu at once.
        let count = library.selectedImageIDs.count
        let hasLead = library.selectedImage != nil

        menu.addItem(ClosureMenuItem("Open in Loupe", enabled: hasLead, actions.openLoupe))
        menu.addItem(ClosureMenuItem("Open in Develop", enabled: hasLead, actions.openDevelop))
        menu.addItem(ClosureMenuItem("Compare Selected", enabled: count == 2, actions.openCompare))
        menu.addItem(ClosureMenuItem("Survey Selected", enabled: SurveyPanes.canSurvey(selectionCount: count),
                                     actions.openSurvey))
        menu.addItem(.separator())

        let targets = library.selectedImages
        menu.addItem(submenu("Rating", ratingItems(targets: targets, actions: actions)))
        menu.addItem(submenu("Flag", flagItems(targets: targets, actions: actions)))
        menu.addItem(submenu("Label", labelItems(targets: targets, actions: actions)))
        menu.addItem(ClosureMenuItem("Rotate Left", enabled: hasLead) { actions.rotate(-1) })
        menu.addItem(ClosureMenuItem("Rotate Right", enabled: hasLead) { actions.rotate(1) })
        for (title, horizontal) in [("Flip Horizontal", true), ("Flip Vertical", false)] {
            let command = KeyCommand.libraryView(.flip(horizontal: horizontal))
            menu.addItem(ClosureMenuItem(title, enabled: actions.canRun(command)) { actions.command(command) })
        }
        menu.addItem(.separator())
        for (title, command) in [("Create Virtual Copy", KeyCommand.createVirtualCopy),
                                 ("Set Copy as Master", .setCopyAsMaster), ("Remove Virtual Copy", .removeVirtualCopy)] {
            menu.addItem(ClosureMenuItem(title, enabled: actions.canRun(command)) { actions.command(command) })
        }
        StackCommands.addItems(to: menu, actions: actions)
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Copy Settings", enabled: hasLead, actions.copySettings))
        menu.addItem(ClosureMenuItem("Paste Settings", enabled: count > 0 && actions.canPasteSettings(),
                                     actions.pasteSettings))
        let presets = actions.presets()
        let presetItem = submenu("Apply Preset", presets.map { preset in
            ClosureMenuItem(preset.name, enabled: count > 0) { actions.applyPreset(preset) }
        })
        presetItem.isEnabled = !presets.isEmpty && count > 0
        menu.addItem(presetItem)
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(count > 1 ? "Export \(count) Images…" : "Export…",
                                     enabled: count > 0 && actions.canExport(), actions.export))
        menu.addItem(ClosureMenuItem("Reveal in Finder", enabled: !library.revealInFinderURLs.isEmpty) {
            revealInFinder(library)
        })
        menu.addItem(.separator())
        let canChange = hasLead && actions.canChangeFiles()
        menu.addItem(ClosureMenuItem(Shortcuts.menuTitle(count > 1 ? "Rename \(count) Images…" : "Rename…", for: .rename),
                                     enabled: canChange && library.selectedImage?.isVirtualCopy != true,
                                     actions.rename))
        menu.addItem(ClosureMenuItem("Rename with Template…", enabled: canChange, actions.renameWithTemplate))
        menu.addItem(destinationMenu("Move to Folder", mode: .move, enabled: canChange, actions: actions))
        menu.addItem(destinationMenu("Copy to Folder", mode: .copy, enabled: canChange, actions: actions))
        menu.addItem(ClosureMenuItem("Duplicate", enabled: canChange && actions.canRun(.duplicatePhoto)) {
            actions.command(.duplicatePhoto)
        })
        CollectionCommands.addItems(to: menu, library: library)
        return menu
    }

    /// The last folders images went to, then Choose Folder….
    private static func destinationMenu(_ title: String, mode: TransferMode, enabled: Bool,
                                        actions: GridActions) -> NSMenuItem {
        var items: [NSMenuItem] = actions.recentDestinations().map { folder in
            let item = ClosureMenuItem(RecentDestinations.shared.name(of: folder), enabled: enabled) {
                actions.transfer(mode, folder)
            }
            item.toolTip = folder.path
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.setAccessibilityLabel("\(mode == .move ? "Move" : "Copy") to \(item.title)")
            return item
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(ClosureMenuItem("Choose Folder…", enabled: enabled) { actions.transfer(mode, nil) })
        let item = submenu(title, items)
        item.isEnabled = enabled
        return item
    }

    /// For a click between images: what applies to the folder itself.
    static func backgroundMenu(library: Library) -> NSMenu? {
        guard library.folderURL != nil else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Select All", enabled: !library.visibleImages.isEmpty) {
            library.selectAllVisible()
        })
        menu.addItem(ClosureMenuItem("Reveal Folder in Finder", enabled: true) {
            if let folder = library.folderURL { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        })
        return menu
    }

    /// Shows the selected originals in Finder, or the folder when nothing
    /// is selected.
    static func revealInFinder(_ library: Library) {
        let urls = library.revealInFinderURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Clear Rating and 1 to 5 stars, the one every target shares checked.
    private static func ratingItems(targets: [ImageRecord], actions: GridActions) -> [NSMenuItem] {
        let shared = Set(targets.map(\.rating)).count == 1 ? targets.first?.rating : nil
        return (0...5).map { stars in
            let title = stars == 0 ? "No Rating" : String(repeating: "★", count: stars)
            let item = ClosureMenuItem(title, enabled: !targets.isEmpty) { actions.rate(stars) }
            item.state = shared == stars ? .on : .off
            item.setAccessibilityLabel(stars == 0 ? "No rating" : stars == 1 ? "1 star" : "\(stars) stars")
            return item
        }
    }

    private static func flagItems(targets: [ImageRecord], actions: GridActions) -> [NSMenuItem] {
        let shared = Set(targets.map(\.flag)).count == 1 ? targets.first?.flag : nil
        let choices: [(String, ImageFlag)] = [("Pick", .picked), ("Reject", .rejected), ("Unflag", .none)]
        return choices.map { title, flag in
            let item = ClosureMenuItem(title, enabled: !targets.isEmpty) { actions.flag(flag) }
            item.state = shared == flag.rawValue ? .on : .off
            return item
        }
    }

    /// The five labels and No Label, the one every target shares checked.
    /// Unlike the keys, choosing a label here always sets it.
    private static func labelItems(targets: [ImageRecord], actions: GridActions) -> [NSMenuItem] {
        let labels = Set(targets.map { $0.label ?? "" })
        let shared = labels.count == 1 ? labels.first : nil
        var items: [NSMenuItem] = ColorLabel.allCases.map { label in
            let item = ClosureMenuItem(Shortcuts.menuTitle(label.title, for: .label(label)), enabled: !targets.isEmpty) {
                actions.label(label.xmpValue)
            }
            item.state = shared.flatMap { ColorLabel(xmpLabel: $0) } == label ? .on : .off
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [label.nsColor]))
            item.setAccessibilityLabel("\(label.title) label")
            return item
        }
        items.append(.separator())
        let none = ClosureMenuItem("No Label", enabled: !targets.isEmpty) { actions.label(nil) }
        none.state = shared == "" ? .on : .off
        items.append(none)
        return items
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        items.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }
}

/// A menu item that runs a closure; it is its own target, and the menu
/// keeps it alive.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
