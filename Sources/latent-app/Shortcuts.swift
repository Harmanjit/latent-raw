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
        Shortcut(.openSelection, .returnKey),
        Shortcut(.toggleZoom, "z"),
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
        Shortcut(.rotate(-1), "[", .command),
        Shortcut(.rotate(1), "]", .command),
        Shortcut(.clearFilter, "l", [.shift, .command]),
        // Editing
        Shortcut(.undo, "z", .command),
        Shortcut(.redo, "z", [.shift, .command]),
        Shortcut(.beforeAfter, "\\"),
        Shortcut(.autoAdjust, "u", .command),
        Shortcut(.crop, "r"),
        Shortcut(.heal, "h"),
        Shortcut(.redEye, "y"),
        Shortcut(.toolSize(-1), "[", in: .develop),
        Shortcut(.toolSize(1), "]", in: .develop),
        Shortcut(.deleteHeal, .delete, in: .develop),
        Shortcut(.disarmTools, .escape),
        Shortcut(.copySettings, "c", [.shift, .command]),
        Shortcut(.pasteSettings, "v", [.shift, .command]),
        // Export
        Shortcut(.export, "e", [.shift, .command]),
        Shortcut(.revealInFinder, "r", [.option, .command]),
        Shortcut(.print, "p", .command),
        Shortcut(.editExternally, "e", .command),
        // Files
        Shortcut(.rename, .f2),
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

    static func shortcut(for command: KeyCommand) -> Shortcut? {
        all.first { $0.command == command }
    }

    /// The command a single key press gives, if any.
    static func command(for press: BareKeyPress) -> KeyCommand? {
        let modifiers: ShortcutModifiers = press.shift ? .shift : []
        return all.first { $0.key == press.key && $0.modifiers == modifiers }?.command
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
            ShortcutPageRow([.toggleZoom], "Toggle fit / 100%"),
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
            ShortcutPageRow([.rotate(-1), .rotate(1)], "Rotate left, right"),
            ShortcutPageRow([.clearFilter], "Clear the filter bar"),
        ]),
        ("Editing", [
            ShortcutPageRow([.undo, .redo], "Undo, redo"),
            ShortcutPageRow([.beforeAfter], "Before / after"),
            ShortcutPageRow([.autoAdjust], "Auto adjust"),
            ShortcutPageRow([.crop], "Crop and straighten tool"),
            ShortcutPageRow([.heal], "Spot removal tool"),
            ShortcutPageRow([.redEye], "Red-eye tool"),
            ShortcutPageRow([.toolSize(-1), .toolSize(1)], "Smaller, larger brush or spot (while the mask brush, spot removal or red-eye is on)"),
            ShortcutPageRow([.deleteHeal], "Delete the selected spot patch or red-eye spot"),
            ShortcutPageRow([.disarmTools], "Leave any on-image tool"),
            ShortcutPageRow([.copySettings, .pasteSettings], "Copy / paste settings (to the whole selection in the Library)"),
            ShortcutPageRow(keys: .gesture("Double-click a slider"), "Reset it"),
            ShortcutPageRow(keys: .gesture("Click a slider's value"), "Type a value: Return or Tab applies it, Esc cancels, ↑ and ↓ step it (with ⇧, ten steps)"),
        ]),
        ("Export", [
            ShortcutPageRow([.export], "Export the selection"),
            ShortcutPageRow([.revealInFinder], "Reveal the selection in Finder"),
            ShortcutPageRow([.print], "Print the selection (in Library) or the image shown"),
            ShortcutPageRow([.editExternally], "Edit in External Editor: a 16-bit TIFF of the open or selected image, opened in the app chosen in Settings"),
        ]),
        ("Files", [
            ShortcutPageRow([.rename], "Rename the selected image (its sidecar and thumbnail follow)"),
            ShortcutPageRow(keys: .gesture("Drag images onto a sidebar folder"), "Move them there with their edits (hold ⌥ to copy)"),
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
            "In the Library grid, stars, flags and rotation apply to every selected image. In Loupe, Compare and Develop they apply to the image shown.",
        ]
        for section in page {
            lines += ["", "## \(section.title)", "", "| Keys | Action |", "|---|---|"]
            for row in section.rows {
                lines.append("| \(pageKeys(row.keys)) | \(row.action) |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func pageKeys(_ keys: ShortcutPageRow.Keys) -> String {
        switch keys {
        case .commands(let commands):
            let glyphs = commands.map { shortcut(for: $0).map { markdownGlyphs($0.glyphs) } ?? "?" }
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
