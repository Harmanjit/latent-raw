import SwiftUI

/// Modifier keys held with a shortcut's key.
struct ShortcutModifiers: OptionSet, Hashable {
    let rawValue: Int
    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)
}

/// Where a shortcut does anything. Two shortcuts may share keys only when
/// their scopes can never apply at once.
enum ShortcutScope: Equatable {
    case everywhere, develop, compare, survey

    func overlaps(_ other: ShortcutScope) -> Bool {
        self == .everywhere || other == .everywhere || self == other
    }
}

/// One key (with its modifiers) and the command it gives.
struct Shortcut {
    let command: KeyCommand
    let key: BareKeyPress.Key
    let modifiers: ShortcutModifiers
    let scope: ShortcutScope

    init(_ command: KeyCommand, _ key: BareKeyPress.Key, _ modifiers: ShortcutModifiers = [],
         in scope: ShortcutScope = .everywhere) {
        self.command = command
        self.key = key
        self.modifiers = modifiers
        self.scope = scope
    }

    init(_ command: KeyCommand, _ character: Character, _ modifiers: ShortcutModifiers = [],
         in scope: ShortcutScope = .everywhere) {
        self.init(command, .character(character), modifiers, in: scope)
    }

    /// No Command, Option or Control. BareKeyMonitor gives these, and a
    /// menu only mentions them in its title: as a real key equivalent the
    /// menu bar would take the key from text fields before they see it.
    var isBare: Bool { modifiers.isSubset(of: .shift) }

    /// "⇧⌘E", "Space", "←".
    var glyphs: String { Shortcuts.glyphs(key, modifiers) }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let c): KeyEquivalent(c)
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .returnKey: .return
        case .delete: .delete
        case .escape: .escape
        case .f2: KeyEquivalent(Character(Unicode.Scalar(0xF705)!))
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }
}

/// A key the system or SwiftUI already owns, listed so nothing in the
/// table can take it too.
struct SystemShortcut {
    let title: String
    let key: BareKeyPress.Key
    let modifiers: ShortcutModifiers
}

/// Every keyboard shortcut in the app, in one place: the single keys
/// BareKeyMonitor dispatches, the Command shortcuts the menu bar carries,
/// and the Keyboard Shortcuts page (docs/wiki/Keyboard-Shortcuts.md), which
/// is generated from this and checked by LatentAppTests so it can't drift.
enum Shortcuts {
    static let all: [Shortcut] = [
        // Views and navigation
        Shortcut(.library, "g"),
        Shortcut(.loupe, "e"),
        Shortcut(.compare, "c"),
        Shortcut(.survey, "n"),
        Shortcut(.develop, "d"),
        Shortcut(.toggleLoupe, " "),
        Shortcut(.step(-1), .leftArrow),
        Shortcut(.step(1), .rightArrow),
        Shortcut(.panImage(.up), .upArrow),
        Shortcut(.panImage(.down), .downArrow),
        Shortcut(.openSelection, .returnKey),
        Shortcut(.toggleZoom, "z"),
        Shortcut(.fullScreenImage, "f"),
        Shortcut(.zoomToFit, "0", .command),
        Shortcut(.zoomToActualSize, "1", .command),
        Shortcut(.zoomIn, "=", .command),
        Shortcut(.zoomOut, "-", .command),
        Shortcut(.makeSelect, "x", .shift, in: .compare),
        Shortcut(.removeFromSurvey, "/", in: .survey),
        Shortcut(.openFolder, "o", [.shift, .command]),
        Shortcut(.slideshow, .returnKey, .command),
        Shortcut(.back, .leftArrow, [.option, .command]),
        Shortcut(.forward, .rightArrow, [.option, .command]),
        // Rating and metadata
        Shortcut(.rate(0), "0"),
        Shortcut(.rate(1), "1"),
        Shortcut(.rate(2), "2"),
        Shortcut(.rate(3), "3"),
        Shortcut(.rate(4), "4"),
        Shortcut(.rate(5), "5"),
        Shortcut(.pick, "p"),
        Shortcut(.reject, "x"),
        Shortcut(.unflag, "u"),
        // Lightroom's label keys. Purple has none there either.
        Shortcut(.label(.red), "6"),
        Shortcut(.label(.yellow), "7"),
        Shortcut(.label(.green), "8"),
        Shortcut(.label(.blue), "9"),
        Shortcut(.rotate(-1), "[", .command),
        Shortcut(.rotate(1), "]", .command),
        Shortcut(.clearFilter, "l", [.shift, .command]),
        // Lightroom's selection keys: Select None, Select Flagged (picked)
        // and Deselect Unflagged.
        Shortcut(.select(.none), "d", .command),
        Shortcut(.select(.flag(.picked)), "a", [.option, .command]),
        Shortcut(.select(.deselectUnflagged), "d", [.option, .shift, .command]),
        // Lightroom's keys: B adds to the target (Quick) collection, ⌘N
        // makes a collection.
        Shortcut(.addToTargetCollection, "b"),
        Shortcut(.newCollection, "n", .command),
        // Editing
        Shortcut(.undo, "z", .command),
        Shortcut(.redo, "z", [.shift, .command]),
        Shortcut(.beforeAfter, "\\"),
        // Lightroom's keys: ⇧Y for the Before/After views (Y is red-eye
        // here), ⇧R for Reference view, ⌥⌘O for the loupe overlay, and
        // ⌥⇧⌘ with an arrow to copy or swap Before and After settings.
        Shortcut(.view(.cycleBeforeAfter), "y", .shift, in: .develop),
        Shortcut(.view(.referenceView), "r", .shift, in: .develop),
        Shortcut(.view(.toggleOverlay), "o", [.option, .command]),
        Shortcut(.view(.copyAfterToBefore), .leftArrow, [.option, .shift, .command]),
        Shortcut(.view(.copyBeforeToAfter), .rightArrow, [.option, .shift, .command]),
        Shortcut(.view(.swapBeforeAfter), .upArrow, [.option, .shift, .command]),
        Shortcut(.autoAdjust, "u", .command),
        Shortcut(.crop, "r"),
        Shortcut(.geometry(.cycleCropGuide), "o", in: .develop),
        Shortcut(.geometry(.rotateCropGuide), "o", .shift, in: .develop),
        Shortcut(.heal, "h"),
        Shortcut(.redEye, "y"),
        // Lightroom's key for the Black & White treatment.
        Shortcut(.toggleBlackAndWhite, "v", in: .develop),
        Shortcut(.whiteBalanceSelector, "w"),
        Shortcut(.toggleClipping, "j"),
        Shortcut(.toolSize(-1), "[", in: .develop),
        Shortcut(.toolSize(1), "]", in: .develop),
        Shortcut(.deleteHeal, .delete, in: .develop),
        Shortcut(.disarmTools, .escape),
        Shortcut(.copySettings, "c", [.shift, .command]),
        Shortcut(.pasteSettings, "v", [.shift, .command]),
        // Export
        Shortcut(.export, "e", [.shift, .command]),
        // Lightroom's key for Export with Previous.
        Shortcut(.exportWithPrevious, "e", [.option, .shift, .command]),
        Shortcut(.revealInFinder, "r", [.option, .command]),
        Shortcut(.print, "p", .command),
        Shortcut(.editExternally, "e", .command),
        // Files
        Shortcut(.rename, .f2),
        Shortcut(.refreshFolder, "r", .command),
        // Lightroom's key for Create Virtual Copy.
        Shortcut(.createVirtualCopy, "'", .command),
        // Lightroom's stacking keys.
        Shortcut(.stack(.group), "g", .command),
        Shortcut(.stack(.unstack), "g", [.shift, .command]),
        Shortcut(.stack(.toggleExpanded), "s"),
        Shortcut(.stack(.moveToTop), "s", .shift),
        // Photo Merge. Lightroom's key: ⌃H is otherwise only the text
        // system's delete-backward, which the command leaves to a field
        // being typed in (CommandState).
        Shortcut(.photoMergeHDR, "h", .control),
        // Lightroom's too: Shift with the dialog's key merges without it.
        Shortcut(.photoMergeHDRWithoutDialog, "h", [.shift, .control]),
        // Lightroom's ⌃M for Panorama. Like ⌃H it is otherwise only a text
        // system key (insert a new line), which the command leaves to a
        // field being typed in (CommandState).
        Shortcut(.photoMergePanorama, "m", .control),
        // Lightroom's ⌃⇧M for HDR Panorama, beside ⌃M as ⌃⇧H sits beside ⌃H.
        Shortcut(.photoMergeHDRPanorama, "m", [.shift, .control]),
    ]

    /// The menu bar's standard items that keep their keys.
    static let system: [SystemShortcut] = [
        SystemShortcut(title: "Settings", key: .character(","), modifiers: .command),
        SystemShortcut(title: "Hide Latent", key: .character("h"), modifiers: .command),
        SystemShortcut(title: "Hide Others", key: .character("h"), modifiers: [.option, .command]),
        SystemShortcut(title: "Quit", key: .character("q"), modifiers: .command),
        SystemShortcut(title: "Close", key: .character("w"), modifiers: .command),
        SystemShortcut(title: "Minimize", key: .character("m"), modifiers: .command),
        SystemShortcut(title: "Cut", key: .character("x"), modifiers: .command),
        SystemShortcut(title: "Copy", key: .character("c"), modifiers: .command),
        SystemShortcut(title: "Paste", key: .character("v"), modifiers: .command),
        SystemShortcut(title: "Select All", key: .character("a"), modifiers: .command),
        SystemShortcut(title: "Enter Full Screen", key: .character("f"), modifiers: [.control, .command]),
        SystemShortcut(title: "Latent Help", key: .character("?"), modifiers: .command),
    ]

    /// The command's keys in effect: its default from `all`, unless the
    /// user changed them in Settings › Keyboard (`Keymap`).
    static func shortcut(for command: KeyCommand) -> Shortcut? {
        Keymap.shared.effective.first { $0.command == command }
    }

    /// The command's keys as shipped, whatever the user changed.
    static func defaultShortcut(for command: KeyCommand) -> Shortcut? {
        all.first { $0.command == command }
    }

    /// The command a single key press gives, if any, with the user's keys.
    static func command(for press: BareKeyPress) -> KeyCommand? {
        command(for: press, in: Keymap.shared.effective)
    }

    static func command(for press: BareKeyPress, in table: [Shortcut]) -> KeyCommand? {
        let modifiers: ShortcutModifiers = press.shift ? .shift : []
        return table.first { $0.key == press.key && $0.modifiers == modifiers }?.command
    }

    /// Modifiers in the menu bar's order (⌃⌥⇧⌘), then the key.
    static func glyphs(_ key: BareKeyPress.Key, _ modifiers: ShortcutModifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(" "): text += "Space"
        case .character(let c): text += c.uppercased()
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .returnKey: text += "Return"
        case .delete: text += "⌫"
        case .escape: text += "Esc"
        case .f2: text += "F2"
        }
        return text
    }

    /// A menu item's title. A single key can't be the item's key
    /// equivalent (see `Shortcut.isBare`), so it goes in the title instead,
    /// where it is only a reminder; BareKeyMonitor still handles the key.
    static func menuTitle(_ title: String, for command: KeyCommand) -> String {
        guard let shortcut = shortcut(for: command), shortcut.isBare else { return title }
        return "\(title) (\(shortcut.glyphs))"
    }
}

extension View {
    /// Gives a menu item its command's key equivalent from the table, when
    /// the command has one with Command. Single keys stay out of menus.
    @ViewBuilder
    func menuKeyEquivalent(for command: KeyCommand) -> some View {
        if let shortcut = Shortcuts.shortcut(for: command), !shortcut.isBare {
            keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}

// MARK: - The Keyboard Shortcuts page

/// A row of the Keyboard Shortcuts page.
struct ShortcutPageRow {
    enum Keys {
        /// Keys looked up in `Shortcuts.all`, so the page can't disagree.
        case commands([KeyCommand])
        /// One of `Shortcuts.system`, by title.
        case system(String)
        /// Something done with the mouse or trackpad.
        case gesture(String)
    }

    let keys: Keys
    let action: String

    init(_ commands: [KeyCommand], _ action: String) {
        keys = .commands(commands)
        self.action = action
    }

    init(keys: Keys, _ action: String) {
        self.keys = keys
        self.action = action
    }
}

extension Shortcuts {
    static let page: [(title: String, rows: [ShortcutPageRow])] = [
        ("Views and navigation", [
            ShortcutPageRow([.library, .loupe, .compare, .develop], "Library, Loupe, Compare, Develop"),
            ShortcutPageRow([.toggleLoupe], "Grid ↔ Loupe"),
            ShortcutPageRow([.step(-1), .step(1)], "Previous / next image (loads it in Loupe, Compare and Develop)"),
            ShortcutPageRow([.openSelection], "Open the selection in Develop"),
            ShortcutPageRow([.panImage(.up), .panImage(.down)], "Pan a zoomed-in image in Loupe and Develop, and ← → too, when Settings › Library › Arrow keys pan a zoomed-in image is on (at fit ← → still step)"),
            ShortcutPageRow([.toggleZoom], "Toggle fit / 100%"),
            ShortcutPageRow([.fullScreenImage], "Full-screen image (from the grid, in Loupe): the pointer at the left, right or bottom edge brings in the library panel, Develop's adjustments or the filmstrip. F or Esc leaves"),
            ShortcutPageRow(keys: .gesture("Two-finger swipe left / right"), "Next / previous image, at fit in Loupe and Develop (one image per swipe)"),
            ShortcutPageRow(keys: .gesture("Pinch, or scroll with ⌥ or ⌘"), "Zoom about the pointer"),
            ShortcutPageRow(keys: .gesture("Double-click, or double-tap with two fingers"), "Toggle fit / 100% at the pointer"),
            ShortcutPageRow(keys: .gesture("Hold the mouse button on a fitted image"), "Magnifier: one image pixel per point under the pointer, until you let go (not while a Develop tool is on)"),
            ShortcutPageRow([.zoomToFit, .zoomToActualSize, .zoomIn, .zoomOut], "Fit, 100%, zoom in, zoom out (in the grid, ⌘= and ⌘- size the thumbnails)"),
            ShortcutPageRow([.makeSelect], "Compare: make the candidate the Select"),
            ShortcutPageRow([.survey], "Survey: the 2 to 4 selected images side by side (in Survey, ← and → move the focus)"),
            ShortcutPageRow([.removeFromSurvey], "Survey: take the focused image out and deselect it"),
            ShortcutPageRow([.openFolder], "Open folder"),
            ShortcutPageRow([.slideshow], "Slideshow of the selection, or of every image the filter shows (in the show: ← and → step, Space pauses, Esc ends)"),
            ShortcutPageRow([.back, .forward], "Back / forward through the folders opened, back to the images you had selected"),
            ShortcutPageRow(keys: .system("Settings"), "Settings"),
            ShortcutPageRow(keys: .system("Latent Help"), "Latent Help (these pages)"),
        ]),
        ("Rating and metadata", [
            ShortcutPageRow([.rate(0), .rate(1), .rate(2), .rate(3), .rate(4), .rate(5)], "Stars"),
            ShortcutPageRow([.pick, .reject, .unflag], "Pick, reject, unflag"),
            ShortcutPageRow([.label(.red), .label(.yellow), .label(.green), .label(.blue)],
                            "Red, yellow, green, blue label (the same key again takes it off)"),
            ShortcutPageRow(keys: .gesture("⇧ with a star, flag or label key"), "Set it and move on to the next photo (Lightroom's auto-advance once; ⇧X is still Make Select in Compare)"),
            ShortcutPageRow(keys: .gesture("Caps Lock on"), "Star, flag and label keys move on to the next photo, as Photo › Auto Advance does"),
            ShortcutPageRow([.select(.none), .select(.flag(.picked)), .select(.deselectUnflagged)], "In the grid: select none, select the picked photos, deselect the unflagged ones (Edit › Invert Selection and Select by Flag, Rating or Colour Label have no keys)"),
            ShortcutPageRow([.rotate(-1), .rotate(1)], "Rotate left, right"),
            ShortcutPageRow([.clearFilter], "Clear the filter bar"),
            ShortcutPageRow([.addToTargetCollection], "Add the selection to the target collection (the Quick Collection unless you chose another), or take it out when it is all there already"),
            ShortcutPageRow([.newCollection], "New collection (with the selected photos, if you like)"),
        ]),
        ("Editing", [
            ShortcutPageRow([.undo, .redo], "Undo, redo (in Develop, the image's edit history; elsewhere, what you did in the Library, moves and renames included)"),
            ShortcutPageRow([.beforeAfter], "Before / after"),
            ShortcutPageRow([.view(.cycleBeforeAfter)], "Develop: Before and After side by side, then split, then one above the other, then split across, then one image again"),
            ShortcutPageRow([.view(.copyAfterToBefore), .view(.copyBeforeToAfter), .view(.swapBeforeAfter)], "Develop: copy the After's settings to the Before, the Before's to the After (undoable), or swap them"),
            ShortcutPageRow([.view(.referenceView)], "Develop: Reference view, a reference photo beside the one you edit (drag one in from the filmstrip)"),
            ShortcutPageRow([.view(.toggleOverlay)], "Loupe and Develop: show or hide the loupe overlay (grid, guides, layout image; View › Loupe Overlay)"),
            ShortcutPageRow([.autoAdjust], "Auto adjust"),
            ShortcutPageRow([.crop], "Crop and straighten tool"),
            ShortcutPageRow([.geometry(.cycleCropGuide), .geometry(.rotateCropGuide)], "While cropping: the next crop guide overlay (thirds, grid, golden ratio, golden spiral, diagonal, triangle, none), and turn the spiral or triangle"),
            ShortcutPageRow(keys: .gesture("⌘-drag in the crop tool"), "Draw a line along something level or upright to straighten by it"),
            ShortcutPageRow([.heal], "Spot removal tool"),
            ShortcutPageRow([.redEye], "Red-eye tool"),
            ShortcutPageRow([.toggleBlackAndWhite], "Develop: switch the treatment between Color and Black & White"),
            ShortcutPageRow([.whiteBalanceSelector], "White Balance Selector: click something neutral in the photo"),
            ShortcutPageRow([.toggleClipping], "Show or hide clipping on the image: highlights red, crushed shadows blue"),
            ShortcutPageRow([.toolSize(-1), .toolSize(1)], "Smaller, larger brush or spot (while the mask brush, spot removal or red-eye is on)"),
            ShortcutPageRow([.deleteHeal], "Delete the selected spot patch or red-eye spot"),
            ShortcutPageRow([.disarmTools], "Leave any on-image tool; with none on, leave the full-screen image"),
            ShortcutPageRow([.copySettings, .pasteSettings], "Copy / paste settings (to the whole selection in the Library)"),
            ShortcutPageRow(keys: .gesture("Double-click a slider"), "Reset it"),
            ShortcutPageRow(keys: .gesture("Click a slider's value"), "Type a value: Return or Tab applies it, Esc cancels, ↑ and ↓ step it (with ⇧, ten steps)"),
            ShortcutPageRow(keys: .gesture("⌥-drag the sharpening Masking slider"), "Show the sharpening mask while dragging: white is sharpened"),
        ]),
        ("Export", [
            ShortcutPageRow([.export], "Export the selection"),
            ShortcutPageRow([.exportWithPrevious], "Export with Previous: the selection, with the last export's settings and folder, without the sheet"),
            ShortcutPageRow([.revealInFinder], "Reveal the selection in Finder"),
            ShortcutPageRow([.print], "Print the selection (in Library) or the image shown"),
            ShortcutPageRow([.editExternally], "Edit in External Editor: a 16-bit TIFF of the open or selected image, opened in the app chosen in Settings"),
        ]),
        ("Files", [
            ShortcutPageRow([.rename], "Rename the selected image (its sidecar and thumbnail follow); with several selected, rename them all from a filename template"),
            ShortcutPageRow([.refreshFolder], "Refresh the open folder: scan it again for photos added, removed or renamed outside Latent"),
            ShortcutPageRow([.createVirtualCopy], "Create a virtual copy of each selected image (in Loupe and Develop, of the image shown): another version of the photo with its own edit, rating and keywords, sharing the file"),
            ShortcutPageRow(keys: .gesture("Drag images onto a sidebar folder"), "Move them there with their edits (hold ⌥ to copy)"),
            ShortcutPageRow([.stack(.group), .stack(.unstack)], "Group the selected photos into a stack (the lead on top), unstack"),
            ShortcutPageRow([.stack(.toggleExpanded)], "Expand or collapse the selected stacks"),
            ShortcutPageRow([.stack(.moveToTop)], "Move the lead photo to the top of its stack"),
        ]),
        ("Photo Merge", [
            ShortcutPageRow([.photoMergeHDR], "HDR merge of the selected photos into one DNG beside them (see [Photo Merge](Photo-Merge)); not while typing in a text field, where ⌃H deletes backward"),
            ShortcutPageRow([.photoMergeHDRWithoutDialog], "HDR merge without the dialog, with the options it was last left with; problems show in the status bar"),
            ShortcutPageRow([.photoMergePanorama], "Stitch the selected photos into one panorama DNG beside them (see [Photo Merge](Photo-Merge)); not while typing in a text field"),
            ShortcutPageRow([.photoMergeHDRPanorama], "Merge a bracket at each position and stitch the results into one DNG (experimental; see [Photo Merge](Photo-Merge)); not while typing in a text field"),
        ]),
    ]

    /// docs/wiki/Keyboard-Shortcuts.md, from the table.
    static func pageMarkdown() -> String {
        var lines = [
            "# Keyboard Shortcuts",
            "",
            "<!-- Generated from Sources/latent-app/Shortcuts.swift. Edit the table there, then run",
            "     LATENT_WRITE_SHORTCUTS_PAGE=1 swift test --filter ShortcutsPageTests -->",
            "",
            "Single keys do nothing while you type in a text field, such as search, keywords or a slider's value; click the grid or the image to get them back. The menu bar lists these commands too, with a single key after the name, as in Pick (P).",
            "",
            "In the Library grid, stars, flags and rotation apply to every selected image. In Loupe, Compare and Develop they apply to the image shown, and in Survey to the focused pane.",
            "",
            "These are the default keys. Settings › Keyboard changes any of them, gives keys to menu commands that have none, and imports or exports the result as a keymap file; the menu bar and the single keys follow straight away. See [Customising the keys](#customising-the-keys) below.",
        ]
        for section in page {
            lines += ["", "## \(section.title)", "", "| Keys | Action |", "|---|---|"]
            for row in section.rows {
                lines.append("| \(pageKeys(row.keys)) | \(row.action) |")
            }
        }
        lines += ["", "## Customising the keys", ""] + customisingNotes
        return lines.joined(separator: "\n") + "\n"
    }

    private static let customisingNotes = [
        "Settings › Keyboard lists every command above, and the menu commands without a key, grouped as on this page and searchable by name or keys. Click a command's keys and press the new combination to change them.",
        "",
        "- Keys another command already has: Latent asks before moving them, and the other command is left without keys. Keys macOS or a standard menu item keeps (⌘Q, ⌘C, ⌘, and the like) can't be taken.",
        "- A single key, with or without ⇧, works anywhere but a text field, as the defaults do; a combination with ⌘, ⌥ or ⌃ goes on the command's menu item. Panning has no menu item, so it takes single keys only.",
        "- The ⌫ button beside a command takes its keys away; the arrow resets it to its default; Reset All puts every default back.",
        "- Export Keymap… saves your changes (only what differs from the defaults) as a JSON file, and Import Keymap… replaces yours with one, unless it would put two commands on the same keys.",
        "",
        "Changes are kept per user on this Mac and apply as soon as you make them.",
    ]

    private static func pageKeys(_ keys: ShortcutPageRow.Keys) -> String {
        switch keys {
        case .commands(let commands):
            // The page documents the defaults, not this Mac's keymap.
            let glyphs = commands.map { defaultShortcut(for: $0).map { markdownGlyphs($0.glyphs) } ?? "?" }
            return collapsingDigitRuns(glyphs).joined(separator: ", ")
        case .system(let title):
            return system.first { $0.title == title }.map { markdownGlyphs(glyphs($0.key, $0.modifiers)) } ?? "?"
        case .gesture(let text):
            return text
        }
    }

    /// A backslash would escape the table's next character, so it goes in
    /// a code span.
    private static func markdownGlyphs(_ glyphs: String) -> String {
        glyphs.contains("\\") ? "`\(glyphs)`" : glyphs
    }

    /// "0, 1, 2, 3" reads better as "0–3".
    static func collapsingDigitRuns(_ glyphs: [String]) -> [String] {
        var result: [String] = []
        var run: [Int] = []
        func flush() {
            if run.count >= 3 { result.append("\(run.first!)–\(run.last!)") } else { result += run.map(String.init) }
            run = []
        }
        for glyph in glyphs {
            if let digit = Int(glyph), glyph.count == 1, run.last.map({ $0 + 1 == digit }) ?? true {
                run.append(digit)
            } else {
                flush()
                if let digit = Int(glyph), glyph.count == 1 { run = [digit] } else { result.append(glyph) }
            }
        }
        flush()
        return result
    }
}
