import SwiftUI
import AppKit
import Catalog

/// What the menu bar needs to know to title and enable its items, and what
/// `ContentView.perform(_:)` checks before running a command, so a greyed
/// item and an ignored key always agree.
///
/// ContentView builds it from its models. Equal states leave the menu bar
/// alone, so a slider drag doesn't rebuild the menus.
struct CommandState: Equatable {
    var mode: AppMode = .library
    var hasVisibleImages = false
    /// A primary selection in the grid.
    var hasSelection = false
    var selectionCount = 0
    /// The primary selection's flag. With several selected, Pick and
    /// Reject still go by the primary, the image the panel shows.
    var primaryFlag: ImageFlag = .none
    var hasImage = false
    var editorReady = false
    var exportingOpenImage = false
    var exportQueueRunning = false
    /// What Undo and Redo would change, nil when there is nothing to.
    var undoLabel: String?
    var redoLabel: String?
    /// A text field in the window has the keyboard.
    var isEditingText = false
    var showingBefore = false
    var cropToolActive = false
    var healToolActive = false
    var hasSelectedHeal = false
    /// The mask brush or the spot tool is armed, so [ and ] have a size to change.
    var toolSizeAdjustable = false
    var canAddMask = false
    var hasSelectedMask = false
    var showMaskOverlay = false
    var filterActive = false
    var hasCompareSelect = false

    func isEnabled(_ command: KeyCommand) -> Bool {
        switch command {
        case .step: hasVisibleImages
        case .openSelection, .loupe, .compare, .rate, .pick, .reject, .unflag, .rotate: hasSelection
        case .library, .openFolder, .disarmTools: true
        case .develop: hasImage || hasSelection
        case .toggleLoupe: (mode == .library && hasSelection) || mode == .loupe
        case .zoomIn, .zoomOut: mode == .library || (mode.showsImage && hasImage)
        case .toggleZoom, .zoomToFit, .zoomToActualSize: mode.showsImage && hasImage
        case .revealInFinder: hasSelection || hasVisibleImages
        case .beforeAfter: mode.showsImage && hasImage
        case .crop, .heal, .autoAdjust: mode == .develop && hasImage
        case .deleteHeal: mode == .develop && healToolActive && hasSelectedHeal
        case .toolSize: mode == .develop && toolSizeAdjustable
        case .addMask: mode == .develop && canAddMask
        case .toggleMaskOverlay: mode == .develop && hasSelectedMask
        case .makeSelect: mode == .compare && hasSelection
        case .swapCompare: mode == .compare && hasSelection && hasCompareSelect
        case .openFile: editorReady
        case .export: selectionCount > 0 && !exportQueueRunning
        case .exportOpenImage: hasImage && !exportingOpenImage
        // Edits are undone where they are made. Typing is undone by the
        // Edit menu itself (see LatentCommands).
        case .undo: mode == .develop && undoLabel != nil
        case .redo: mode == .develop && redoLabel != nil
        case .copySettings: hasImage || hasSelection
        case .pasteSettings: hasImage || selectionCount > 0
        case .clearFilter: filterActive
        }
    }

    /// Keys that carry on to the rest of the app when their command can't
    /// run: Delete, Shift-X and the brackets mean something elsewhere. The
    /// other single keys are swallowed, so a key with nothing to do
    /// doesn't beep.
    static func passesThroughWhenUnavailable(_ command: KeyCommand) -> Bool {
        switch command {
        case .deleteHeal, .makeSelect, .toolSize: true
        default: false
        }
    }

    // MARK: Titles that say what choosing the item will do

    var undoTitle: String {
        isEditingText ? "Undo" : undoLabel.map { "Undo \($0)" } ?? "Undo"
    }

    var redoTitle: String {
        isEditingText ? "Redo" : redoLabel.map { "Redo \($0)" } ?? "Redo"
    }

    var exportTitle: String {
        selectionCount > 1 ? "Export \(selectionCount) Images…" : "Export…"
    }

    var beforeAfterTitle: String { showingBefore ? "Show After" : "Show Before" }

    /// ⌘= and ⌘- size the thumbnails in the grid and zoom elsewhere.
    var zoomInTitle: String { mode == .library ? "Larger Thumbnails" : "Zoom In" }
    var zoomOutTitle: String { mode == .library ? "Smaller Thumbnails" : "Zoom Out" }

    /// Pick, or Unpick when the image is already picked (the U key).
    var pickItem: (title: String, command: KeyCommand) {
        primaryFlag == .picked ? ("Unpick", .unflag) : ("Pick", .pick)
    }

    var rejectItem: (title: String, command: KeyCommand) {
        primaryFlag == .rejected ? ("Unreject", .unflag) : ("Reject", .reject)
    }

    static func ratingTitle(_ stars: Int) -> String {
        switch stars {
        case ...0: "Clear Rating"
        case 1: "1 Star"
        default: "\(min(stars, 5)) Stars"
        }
    }
}

/// The commands ContentView offers the menu bar: its state and its
/// `perform(_:)`. Compared by state only; the closure is the same view's.
struct CommandContext: Equatable {
    var state: CommandState
    var perform: @MainActor (KeyCommand) -> Void

    static func == (lhs: CommandContext, rhs: CommandContext) -> Bool {
        lhs.state == rhs.state
    }
}

struct CommandContextKey: FocusedValueKey {
    typealias Value = CommandContext
}

extension FocusedValues {
    var commandContext: CommandContext? {
        get { self[CommandContextKey.self] }
        set { self[CommandContextKey.self] = newValue }
    }
}

/// The menu bar. Every command goes through ContentView's `perform(_:)`,
/// the same path as the keys, and takes its key from `Shortcuts.all`.
/// Without the main window in front (Settings, say) there is nothing to
/// act on and the items are disabled.
struct LatentCommands: Commands {
    @FocusedValue(\.commandContext) private var context

    private var state: CommandState { context?.state ?? CommandState() }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item("Open Folder…", .openFolder)
            item("Open File…", .openFile)
            Divider()
            item(state.exportTitle, .export)
            item("Export Open Image…", .exportOpenImage)
            item("Reveal in Finder", .revealInFinder)
        }

        CommandGroup(replacing: .undoRedo) {
            textAwareItem(state.undoTitle, .undo, textAction: "undo:")
            textAwareItem(state.redoTitle, .redo, textAction: "redo:")
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            item("Copy Settings", .copySettings)
            item("Paste Settings", .pasteSettings)
        }

        CommandGroup(before: .toolbar) {
            modeToggle(.library)
            modeToggle(.loupe)
            modeToggle(.compare)
            modeToggle(.develop)
            Divider()
            item("Grid ↔ Loupe", .toggleLoupe)
            item("Previous Image", .step(-1))
            item("Next Image", .step(1))
            item("Open in Develop", .openSelection)
            Divider()
            item(state.zoomInTitle, .zoomIn)
            item(state.zoomOutTitle, .zoomOut)
            item("Zoom to Fit", .zoomToFit)
            item("Actual Size", .zoomToActualSize)
            item("Fit ↔ 100%", .toggleZoom)
            Divider()
            item(state.beforeAfterTitle, .beforeAfter)
            // TODO(display): Show/Hide Clipping belongs here once the
            // clipping overlay has a command; title it from its state as
            // Before/After is.
            item("Make Select", .makeSelect)
            item("Swap Select and Candidate", .swapCompare)
            Divider()
            item("Clear Filters", .clearFilter)
            Divider()
        }

        CommandMenu("Photo") {
            ForEach(0...5, id: \.self) { stars in
                item(CommandState.ratingTitle(stars), .rate(stars))
            }
            Divider()
            item(state.pickItem.title, state.pickItem.command)
            item(state.rejectItem.title, state.rejectItem.command)
            Divider()
            item("Rotate Left", .rotate(-1))
            item("Rotate Right", .rotate(1))
        }

        CommandMenu("Develop") {
            item("Auto Adjust", .autoAdjust)
            Divider()
            toolToggle("Crop & Straighten", .crop, isOn: state.cropToolActive)
            toolToggle("Spot Removal", .heal, isOn: state.healToolActive)
            Menu("Masks") {
                item("New Linear Gradient", .addMask(.linear))
                item("New Radial Gradient", .addMask(.radial))
                item("New Brush", .addMask(.brush))
                Divider()
                toolToggle("Show Mask Overlay", .toggleMaskOverlay, isOn: state.showMaskOverlay)
            }
            Divider()
            item("Smaller Brush", .toolSize(-1))
            item("Larger Brush", .toolSize(1))
            item("Delete Spot", .deleteHeal)
            item("Leave Tool", .disarmTools)
        }
    }

    private func isEnabled(_ command: KeyCommand) -> Bool {
        context?.state.isEnabled(command) ?? false
    }

    private func item(_ title: String, _ command: KeyCommand) -> some View {
        Button(Shortcuts.menuTitle(title, for: command)) { context?.perform(command) }
            .menuKeyEquivalent(for: command)
            .disabled(!isEnabled(command))
    }

    /// A checkmarked item. Choosing it runs the command, which toggles.
    private func toolToggle(_ title: String, _ command: KeyCommand, isOn: Bool) -> some View {
        Toggle(Shortcuts.menuTitle(title, for: command),
               isOn: Binding(get: { isOn }, set: { _ in context?.perform(command) }))
            .menuKeyEquivalent(for: command)
            .disabled(!isEnabled(command))
    }

    private func modeToggle(_ mode: AppMode) -> some View {
        let command: KeyCommand = switch mode {
        case .library: .library
        case .loupe: .loupe
        case .compare: .compare
        case .develop: .develop
        }
        return toolToggle(mode.title, command, isOn: context?.state.mode == mode)
    }

    /// Undo and Redo replace the system's, which text fields rely on. While
    /// a field has the keyboard they send the standard action down the
    /// responder chain, as the system items would; otherwise they undo edits.
    private func textAwareItem(_ title: String, _ command: KeyCommand, textAction: String) -> some View {
        Button(title) {
            if KeyFocus(NSApp.keyWindow?.firstResponder) == .text {
                NSApp.sendAction(Selector(textAction), to: nil, from: nil)
            } else {
                context?.perform(command)
            }
        }
        .menuKeyEquivalent(for: command)
        .disabled(!(state.isEditingText || isEnabled(command)))
    }
}
