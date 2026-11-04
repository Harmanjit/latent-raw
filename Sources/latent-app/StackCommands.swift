import AppKit
import SwiftUI
import Catalog

/// Photo › Stacking: the stack commands, under one `KeyCommand` case so the
/// tables they pass through (menus, shortcuts, enabling) each gain a line.
/// The work is the Library's (Library+Stacks.swift).
enum StackCommand: Equatable {
    case group, unstack, removeFromStack
    /// S: expand a collapsed stack, collapse an expanded one.
    case toggleExpanded
    case expandAll, collapseAll
    case moveToTop
    case autoStackByCaptureTime
}

/// What the stack commands need to know beyond the rest of CommandState.
struct StackCommandState: Equatable {
    /// Something selected is in a stack.
    var selectionInStack = false
    /// The lead is in a stack and not already on top of it.
    var primaryBelowTop = false
    /// The folder has any stacks.
    var hasStacks = false

    @MainActor
    init(library: Library, mode: AppMode) {
        guard mode == .library else { return }
        selectionInStack = library.anyStacked(library.selectedImages)
        primaryBelowTop = library.selectedImageID.flatMap { library.stackMemberships[$0] }.map { !$0.isTop } ?? false
        hasStacks = !library.stacks.isEmpty
    }

    init() {}
}

extension CommandState {
    /// Stacks are arranged in the grid, so every command is the Library's.
    func isEnabled(_ command: StackCommand) -> Bool {
        guard mode == .library, !fileOperationRunning else { return false }
        switch command {
        case .group: return selectionCount >= 2
        case .unstack, .removeFromStack, .toggleExpanded: return stacking.selectionInStack
        case .expandAll, .collapseAll: return stacking.hasStacks
        case .moveToTop: return stacking.primaryBelowTop
        case .autoStackByCaptureTime: return hasCatalog
        }
    }
}

/// Runs a stack command on the grid's selection.
@MainActor
struct StackCommands {
    let library: Library

    func perform(_ command: StackCommand) {
        let library = library
        let selected = library.selectedImages
        switch command {
        case .group:
            guard selected.count >= 2 else { return }
            library.perform("Group into Stack") {
                try await library.groupIntoStack(selected)
                Announcement.post("Stacked \(selected.count) photos")
            }
        case .unstack:
            library.perform("Unstack") {
                try await library.unstack(selected)
                Announcement.post("Unstacked")
            }
        case .removeFromStack:
            library.perform("Remove from Stack") { try await library.removeFromStack(selected) }
        case .toggleExpanded:
            library.perform("Expand or collapse the stack") { try await library.setStacksCollapsed(nil, of: selected) }
        case .expandAll:
            library.perform("Expand All Stacks") { try await library.setAllStacksCollapsed(false) }
        case .collapseAll:
            library.perform("Collapse All Stacks") { try await library.setAllStacksCollapsed(true) }
        case .moveToTop:
            guard let lead = library.selectedImage else { return }
            library.perform("Move to Top of Stack") { try await library.moveToTopOfStack(lead) }
        case .autoStackByCaptureTime:
            guard let gap = AutoStackDialog.run() else { return }
            library.perform("Auto-Stack by Capture Time") {
                let made = try await library.autoStackByCaptureTime(gap: gap)
                Announcement.post(made == 0 ? "No photos close enough in time to stack"
                                  : made == 1 ? "Made 1 stack" : "Made \(made) stacks")
            }
        }
    }

    /// The grid's right-click items.
    static func addItems(to menu: NSMenu, actions: GridActions) {
        let items: [(String, StackCommand)] = [
            ("Group into Stack", .group), ("Unstack", .unstack), ("Remove from Stack", .removeFromStack),
            ("Expand or Collapse Stack", .toggleExpanded), ("Move to Top of Stack", .moveToTop),
        ]
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (title, command) in items {
            let key = KeyCommand.stack(command)
            submenu.addItem(ClosureMenuItem(Shortcuts.menuTitle(title, for: key), enabled: actions.canRun(key)) {
                actions.command(key)
            })
        }
        let item = NSMenuItem(title: "Stacking", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = items.contains { actions.canRun(.stack($0.1)) }
        menu.addItem(item)
    }
}

/// Photo › Stacking.
struct StackingMenu: View {
    let item: (String, KeyCommand) -> AnyView

    var body: some View {
        Menu("Stacking") {
            item("Group into Stack", .stack(.group))
            item("Unstack", .stack(.unstack))
            item("Remove from Stack", .stack(.removeFromStack))
            Divider()
            item("Expand or Collapse Stack", .stack(.toggleExpanded))
            item("Expand All Stacks", .stack(.expandAll))
            item("Collapse All Stacks", .stack(.collapseAll))
            Divider()
            item("Move to Top of Stack", .stack(.moveToTop))
            Divider()
            item("Auto-Stack by Capture Time…", .stack(.autoStackByCaptureTime))
        }
    }
}

/// Asks for Auto-Stack's time gap, remembered between runs.
@MainActor
enum AutoStackDialog {
    static let gapKey = "latent.autoStackGapSeconds"
    static let defaultGap: TimeInterval = 60

    static var savedGap: TimeInterval {
        (UserDefaults.standard.object(forKey: gapKey) as? Double).map { max($0, 0) } ?? defaultGap
    }

    /// The gap in seconds, or nil when cancelled.
    static func run() -> TimeInterval? {
        let alert = NSAlert()
        alert.messageText = "Auto-Stack by Capture Time"
        alert.informativeText = "Photos taken within this many seconds of the one before go into one stack, "
            + "earliest on top. Photos already in a stack are left as they are."
        alert.addButton(withTitle: "Stack")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: Self.format(savedGap))
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        field.setAccessibilityLabel("Time between stacks, in seconds")
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximum = 86_400
        formatter.maximumFractionDigits = 1
        field.formatter = formatter
        let unit = NSTextField(labelWithString: "seconds between photos")
        let row = NSStackView(views: [field, unit])
        row.orientation = .horizontal
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = row
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let gap = max(0, min(field.doubleValue, 86_400))
        UserDefaults.standard.set(gap, forKey: gapKey)
        return gap
    }

    private static func format(_ gap: TimeInterval) -> String {
        gap == gap.rounded() ? String(Int(gap)) : String(gap)
    }
}

/// The stack mark on a thumbnail: the stack's size in a small dark chip at
/// the picture's top-left corner, "3" on a collapsed stack's photo and
/// "1/3" on each photo of an expanded one, as Lightroom numbers them.
final class StackBadgeView: NSView {
    static let height: CGFloat = 16
    static let inset: CGFloat = 3

    private let field = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        field.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        field.textColor = .white
        field.alignment = .center
        addSubview(field)
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        field.frame = bounds.insetBy(dx: 3, dy: 1.5)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The chip's text for a membership, nil for none.
    static func text(_ membership: StackMembership?) -> String? {
        guard let membership else { return nil }
        return membership.isCollapsed ? "▤ \(membership.count)" : "\(membership.position + 1)/\(membership.count)"
    }

    /// What VoiceOver adds to the cell: "stack of 3", "2 of 3 in stack".
    static func spokenText(_ membership: StackMembership?) -> String {
        guard let membership else { return "" }
        return membership.isCollapsed ? "stack of \(membership.count)"
            : "\(membership.position + 1) of \(membership.count) in stack"
    }

    /// Shows `membership`, or hides the chip for none.
    func show(_ membership: StackMembership?) {
        let text = Self.text(membership)
        isHidden = text == nil
        if field.stringValue != text ?? "" { field.stringValue = text ?? "" }
    }

    var preferredWidth: CGFloat {
        ceil(field.attributedStringValue.size().width) + 8
    }

    /// Its frame in a flipped cell: the top-left corner of the picture.
    func frame(inImageFrame image: CGRect) -> CGRect {
        CGRect(x: image.minX + Self.inset, y: image.minY + Self.inset, width: preferredWidth, height: Self.height)
    }
}
