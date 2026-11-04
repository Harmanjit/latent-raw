import SwiftUI
import Catalog
import PixelEngine

// MARK: - Customised keys

/// What the user did to one command's keys in Settings › Keyboard: gave it
/// other keys, or took its keys away. A command with no override has its
/// keys from `Shortcuts.all`, which stays the one table of defaults.
enum ShortcutOverride: Equatable {
    case unbound
    case keys(BareKeyPress.Key, ShortcutModifiers)
}

/// A command Settings › Keyboard lists: every command `Shortcuts.all` gives
/// a key, and the menu commands that have none until the user gives them
/// one.
struct ShortcutCommandInfo {
    /// Stable, for the saved keymap and keymap files.
    let id: String
    let command: KeyCommand
    let title: String
    let group: String
    /// For a command without a default key: where its keys would apply.
    var scope: ShortcutScope = .everywhere
    /// No menu item carries the command, so only a single key (which
    /// BareKeyMonitor dispatches) can reach it.
    var singleKeyOnly = false
}

/// Why a recorded key combination can't be given to a command.
enum ShortcutProblem: Equatable {
    /// The system or a standard menu item keeps it (⌘Q, ⌘C…).
    case system(String)
    /// Another command has it; it can be reassigned.
    case taken(by: ShortcutCommandInfo)
    /// The command has no menu item, so only a single key can reach it.
    case needsSingleKey

    static func == (a: ShortcutProblem, b: ShortcutProblem) -> Bool {
        switch (a, b) {
        case let (.system(x), .system(y)): x == y
        case let (.taken(x), .taken(y)): x.id == y.id
        case (.needsSingleKey, .needsSingleKey): true
        default: false
        }
    }
}

/// The keys in effect: `Shortcuts.all` with the user's overrides applied,
/// kept in UserDefaults. `Shortcuts.shortcut(for:)` and
/// `Shortcuts.command(for:)` read it, so the menu bar, single-key handling
/// and every key hint follow a change straight away.
///
/// Read from anywhere (the lookups aren't actor-bound), written from
/// Settings on the main actor; a lock keeps the two apart.
final class Keymap: @unchecked Sendable {
    static let shared = Keymap(defaults: .standard)
    static let defaultsKey = "keyboardShortcuts"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var storedOverrides: [String: ShortcutOverride]
    private var cachedEffective: [Shortcut]?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        storedOverrides = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? KeymapFile.decode($0).overrides } ?? [:]
    }

    var overrides: [String: ShortcutOverride] {
        lock.withLock { storedOverrides }
    }

    var effective: [Shortcut] {
        lock.withLock {
            if let cachedEffective { return cachedEffective }
            let table = Self.effective(overrides: storedOverrides)
            cachedEffective = table
            return table
        }
    }

    /// Replaces every override, dropping any that only restate a default,
    /// and saves them.
    func setOverrides(_ overrides: [String: ShortcutOverride]) {
        let kept = Self.normalised(overrides)
        lock.withLock {
            storedOverrides = kept
            cachedEffective = nil
        }
        if kept.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? KeymapFile(overrides: kept).encoded() {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Pure parts

    /// Every command the Keyboard tab lists, `Shortcuts.all`'s first and in
    /// its order. A command added to the table without an entry below
    /// still gets a row (titled by its case), so it can be rebound.
    static let commands: [ShortcutCommandInfo] = {
        var known = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [ShortcutCommandInfo] = []
        for shortcut in Shortcuts.all {
            if let info = catalog.first(where: { $0.command == shortcut.command }) {
                guard known.removeValue(forKey: info.id) != nil else { continue }
                result.append(info)
            } else {
                let name = String(describing: shortcut.command)
                result.append(ShortcutCommandInfo(id: name, command: shortcut.command, title: name, group: "Other"))
            }
        }
        // The rest, the commands without a default key, in catalog order.
        result += catalog.filter { known[$0.id] != nil }
        return result
    }()

    static func info(for command: KeyCommand) -> ShortcutCommandInfo? {
        commands.first { $0.command == command }
    }

    static func info(id: String) -> ShortcutCommandInfo? {
        commands.first { $0.id == id }
    }

    /// The keys each listed command has with `overrides` applied. Commands
    /// keep their default scope; a key given to a command with no default
    /// takes the command's own.
    static func effective(overrides: [String: ShortcutOverride]) -> [Shortcut] {
        commands.compactMap { info in
            let fallback = Shortcuts.defaultShortcut(for: info.command)
            switch overrides[info.id] {
            case nil: return fallback
            case .some(.unbound): return nil
            case let .some(.keys(key, modifiers)):
                return Shortcut(info.command, key, modifiers, in: fallback?.scope ?? info.scope)
            }
        }
    }

    /// Overrides that change something: a known command, given keys other
    /// than its default, or a default taken away.
    static func normalised(_ overrides: [String: ShortcutOverride]) -> [String: ShortcutOverride] {
        overrides.filter { id, override in
            guard let info = info(id: id) else { return false }
            let fallback = Shortcuts.defaultShortcut(for: info.command)
            switch override {
            case .unbound: return fallback != nil
            case let .keys(key, modifiers): return fallback.map { $0.key != key || $0.modifiers != modifiers } ?? true
            }
        }
    }

    /// What stops `key` with `modifiers` going to `info`, if anything.
    /// Keys clash whatever their scopes: a single key is looked up by keys
    /// alone, so two commands on one key would leave one unreachable.
    static func problem(giving key: BareKeyPress.Key, _ modifiers: ShortcutModifiers,
                        to info: ShortcutCommandInfo, in table: [Shortcut]) -> ShortcutProblem? {
        if info.singleKeyOnly && !modifiers.isSubset(of: .shift) { return .needsSingleKey }
        if let system = Shortcuts.system.first(where: { $0.key == key && $0.modifiers == modifiers }) {
            return .system(system.title)
        }
        if let holder = table.first(where: { $0.key == key && $0.modifiers == modifiers && $0.command != info.command
                                              && $0.scope.overlaps(info.scope) }),
           let holderInfo = Self.info(for: holder.command) {
            return .taken(by: holderInfo)
        }
        return nil
    }

    /// Commands sharing keys in `table`, which only a keymap file or a
    /// default added since the keys were chosen can bring about.
    static func clashes(in table: [Shortcut]) -> [(Shortcut, Shortcut)] {
        var result: [(Shortcut, Shortcut)] = []
        for (i, a) in table.enumerated() {
            for b in table[(i + 1)...] where a.key == b.key && a.modifiers == b.modifiers && a.scope.overlaps(b.scope) {
                result.append((a, b))
            }
        }
        return result
    }

    /// The keys a recorded key-down gives, or nil for a key the table can't
    /// hold (Tab, F1, a dead key…). Read as BareKeyPress reads a press, so
    /// a recorded key matches the same key pressed later.
    static func recordedKeys(charactersIgnoringModifiers characters: String, shift: Bool, command: Bool,
                             option: Bool, control: Bool) -> (BareKeyPress.Key, ShortcutModifiers)? {
        guard let press = BareKeyPress(charactersIgnoringModifiers: characters, shift: shift,
                                       command: false, option: false, control: false) else { return nil }
        if case .character(let c) = press.key {
            guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1,
                  c == " " || (!CharacterSet.controlCharacters.contains(scalar)
                               && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                               && !(0xE000...0xF8FF).contains(scalar.value)) else { return nil }
        }
        var modifiers: ShortcutModifiers = []
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        if command { modifiers.insert(.command) }
        return (press.key, modifiers)
    }
}

// MARK: - Keymap files

/// The saved keymap, in UserDefaults and in the files Export Keymap… writes:
///
///     { "format": "latent-keymap", "version": 1,
///       "shortcuts": { "export": { "key": "e", "modifiers": ["shift", "command"] },
///                      "pick": { "key": null } } }
///
/// Only overrides are kept, so a file says what differs from the defaults.
/// A null key takes the command's keys away. Keys are a single character,
/// or space, left, right, up, down, return, delete, escape or f2.
struct KeymapFile: Codable {
    static let format = "latent-keymap"

    var overrides: [String: ShortcutOverride]

    init(overrides: [String: ShortcutOverride]) {
        self.overrides = overrides
    }

    enum DecodeError: LocalizedError {
        case notAKeymap
        var errorDescription: String? { "The file isn't a Latent keymap." }
    }

    private enum CodingKeys: String, CodingKey { case format, version, shortcuts }

    private struct Entry: Codable {
        var key: String?
        var modifiers: [String]?

        private enum CodingKeys: String, CodingKey { case key, modifiers }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)   // null, not left out, for none
            if let modifiers, !modifiers.isEmpty { try c.encode(modifiers, forKey: .modifiers) }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? c.decode(String.self, forKey: .format)) == Self.format else { throw DecodeError.notAKeymap }
        let entries = (try? c.decode([String: Entry].self, forKey: .shortcuts)) ?? [:]
        var overrides: [String: ShortcutOverride] = [:]
        // An entry this version can't read is skipped, not the whole file.
        for (id, entry) in entries {
            guard let token = entry.key else { overrides[id] = ShortcutOverride.unbound; continue }
            guard let key = Self.key(token) else { continue }
            let names = entry.modifiers ?? []
            let modifiers = names.compactMap(Self.modifier)
            guard modifiers.count == names.count else { continue }
            overrides[id] = .keys(key, ShortcutModifiers(modifiers))
        }
        self.overrides = overrides
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.format, forKey: .format)
        try c.encode(1, forKey: .version)
        var entries: [String: Entry] = [:]
        for (id, override) in overrides {
            switch override {
            case .unbound: entries[id] = Entry(key: nil, modifiers: nil)
            case let .keys(key, modifiers): entries[id] = Entry(key: Self.token(key), modifiers: Self.names(modifiers))
            }
        }
        try c.encode(entries, forKey: .shortcuts)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> KeymapFile {
        try JSONDecoder().decode(KeymapFile.self, from: data)
    }

    private static let namedKeys: [(String, BareKeyPress.Key)] = [
        ("space", .character(" ")), ("left", .leftArrow), ("right", .rightArrow), ("up", .upArrow),
        ("down", .downArrow), ("return", .returnKey), ("delete", .delete), ("escape", .escape), ("f2", .f2),
    ]

    private static let modifierNames: [(String, ShortcutModifiers)] = [
        ("control", .control), ("option", .option), ("shift", .shift), ("command", .command),
    ]

    static func token(_ key: BareKeyPress.Key) -> String {
        if let name = namedKeys.first(where: { $0.1 == key })?.0 { return name }
        if case .character(let c) = key { return String(c) }
        return "?"
    }

    static func key(_ token: String) -> BareKeyPress.Key? {
        if let named = namedKeys.first(where: { $0.0 == token })?.1 { return named }
        guard token.count == 1, let c = token.first, c.unicodeScalars.count == 1 else { return nil }
        return .character(Character(String(c).lowercased()))
    }

    private static func names(_ modifiers: ShortcutModifiers) -> [String] {
        modifierNames.filter { modifiers.contains($0.1) }.map(\.0)
    }

    private static func modifier(_ name: String) -> ShortcutModifiers? {
        modifierNames.first { $0.0 == name }?.1
    }
}

private extension ShortcutModifiers {
    init(_ parts: [ShortcutModifiers]) {
        self = parts.reduce(into: []) { $0.formUnion($1) }
    }
}

// MARK: - The commands, titled

extension Keymap {
    /// Titles and groups for the Keyboard tab, and the ids saved keymaps
    /// use. Groups follow the Keyboard Shortcuts page's sections.
    fileprivate static let catalog: [ShortcutCommandInfo] = {
        let views = "Views and navigation", rating = "Rating and metadata", editing = "Editing"
        let develop = "Develop tools", export = "Export", files = "Files", merge = "Photo Merge"
        func c(_ id: String, _ command: KeyCommand, _ title: String, _ group: String,
               in scope: ShortcutScope = .everywhere, singleKeyOnly: Bool = false) -> ShortcutCommandInfo {
            ShortcutCommandInfo(id: id, command: command, title: title, group: group, scope: scope,
                                singleKeyOnly: singleKeyOnly)
        }
        var list: [ShortcutCommandInfo] = [
            c("library", .library, "Library", views),
            c("loupe", .loupe, "Loupe", views),
            c("compare", .compare, "Compare", views),
            c("survey", .survey, "Survey", views),
            c("develop", .develop, "Develop", views),
            c("toggleLoupe", .toggleLoupe, "Grid ↔ Loupe", views),
            c("previousImage", .step(-1), "Previous Image", views),
            c("nextImage", .step(1), "Next Image", views),
            c("panUp", .panImage(.up), "Pan Up", views, singleKeyOnly: true),
            c("panDown", .panImage(.down), "Pan Down", views, singleKeyOnly: true),
            c("openSelection", .openSelection, "Open in Develop", views),
            c("toggleZoom", .toggleZoom, "Fit ↔ 100%", views),
            c("fullScreenImage", .fullScreenImage, "Full-Screen Image", views),
            c("zoomToFit", .zoomToFit, "Zoom to Fit", views),
            c("zoomToActualSize", .zoomToActualSize, "Actual Size", views),
            c("zoomIn", .zoomIn, "Zoom In", views),
            c("zoomOut", .zoomOut, "Zoom Out", views),
            c("makeSelect", .makeSelect, "Make Select", views),
            c("removeFromSurvey", .removeFromSurvey, "Remove from Survey", views),
            c("openFolder", .openFolder, "Open Folder…", views),
            c("slideshow", .slideshow, "Slideshow", views),
            c("back", .back, "Back", views),
            c("forward", .forward, "Forward", views),
        ]
        list += (0...5).map { c("rate\($0)", .rate($0), CommandState.ratingTitle($0), rating) }
        list += [
            c("pick", .pick, "Pick", rating),
            c("reject", .reject, "Reject", rating),
            c("unflag", .unflag, "Unflag", rating),
        ]
        list += [ColorLabel.red, .yellow, .green, .blue].map {
            c("label\($0.rawValue)", .label($0), "\($0.title) Label", rating)
        }
        list += [
            c("rotateLeft", .rotate(-1), "Rotate Left", rating),
            c("rotateRight", .rotate(1), "Rotate Right", rating),
            c("clearFilter", .clearFilter, "Clear Filters", rating),
            c("addToTargetCollection", .addToTargetCollection, "Add to Target Collection", rating),
            c("newCollection", .newCollection, "New Collection…", rating),
            c("undo", .undo, "Undo", editing),
            c("redo", .redo, "Redo", editing),
            c("beforeAfter", .beforeAfter, "Before / After", editing),
            c("autoAdjust", .autoAdjust, "Auto Adjust", editing),
            c("crop", .crop, "Crop & Straighten", editing),
            c("cycleCropGuide", .geometry(.cycleCropGuide), "Cycle Crop Guide Overlay", editing),
            c("rotateCropGuide", .geometry(.rotateCropGuide), "Rotate Crop Guide Overlay", editing),
            c("heal", .heal, "Spot Removal", editing),
            c("redEye", .redEye, "Red-Eye Removal", editing),
            c("toggleBlackAndWhite", .toggleBlackAndWhite, "Black & White", editing),
            c("whiteBalanceSelector", .whiteBalanceSelector, "White Balance Selector", editing),
            c("toggleClipping", .toggleClipping, "Show Clipping", editing),
            c("smallerBrush", .toolSize(-1), "Smaller Brush", editing),
            c("largerBrush", .toolSize(1), "Larger Brush", editing),
            c("deleteHeal", .deleteHeal, "Delete Spot", editing),
            c("disarmTools", .disarmTools, "Leave Tool", editing),
            c("copySettings", .copySettings, "Copy Settings", editing),
            c("pasteSettings", .pasteSettings, "Paste Settings", editing),
            c("export", .export, "Export…", export),
            c("exportWithPrevious", .exportWithPrevious, "Export with Previous", export),
            c("revealInFinder", .revealInFinder, "Reveal in Finder", export),
            c("print", .print, "Print…", export),
            c("editExternally", .editExternally, "Edit in External Editor…", export),
            c("rename", .rename, "Rename…", files),
            c("refreshFolder", .refreshFolder, "Refresh Folder", files),
            c("createVirtualCopy", .createVirtualCopy, "Create Virtual Copy", files),
            c("photoMergeHDR", .photoMergeHDR, "HDR…", merge),
            c("photoMergeHDRWithoutDialog", .photoMergeHDRWithoutDialog, "HDR Merge Without Dialog", merge),
            c("photoMergePanorama", .photoMergePanorama, "Panorama…", merge),
            c("photoMergeHDRPanorama", .photoMergeHDRPanorama, "HDR Panorama…", merge),
            // Menu items without a default key, which the user may give one.
            c("swapCompare", .swapCompare, "Swap Select and Candidate", views, in: .compare),
            c("secondaryDisplay", .secondaryDisplay, "Show Loupe on Second Display", views),
            c("labelPurple", .label(.purple), "Purple Label", rating),
            c("labelNone", .label(nil), "No Label", rating),
            c("resetOrientation", .geometry(.resetOrientation), "Reset to Camera Orientation", rating),
            c("newSmartCollection", .newSmartCollection, "New Smart Collection…", rating),
            c("newCollectionSet", .newCollectionSet, "New Collection Set…", rating),
            c("saveFilterAsSmartCollection", .saveFilterAsSmartCollection, "Save Filter as Smart Collection…", rating),
            c("removeFromCollection", .removeFromCollection, "Remove from Collection", rating),
            c("autoStraighten", .geometry(.autoStraighten), "Auto Straighten", develop, in: .develop),
            c("flipHorizontal", .geometry(.flipHorizontal), "Flip Horizontal", develop, in: .develop),
            c("flipVertical", .geometry(.flipVertical), "Flip Vertical", develop, in: .develop),
            c("uprightOff", .geometry(.upright(nil)), "Upright Off", develop, in: .develop),
        ]
        list += UprightCorrection.Mode.allCases.map {
            c("upright.\($0.rawValue)", .geometry(.upright($0)), "Upright \($0.title)", develop, in: .develop)
        }
        list += [
            c("dust", .dust, "Sensor Dust", develop, in: .develop),
            c("touchUp", .touchUp, "Touch-up", develop, in: .develop),
            c("maskLinear", .addMask(.linear), "New Linear Gradient", develop, in: .develop),
            c("maskRadial", .addMask(.radial), "New Radial Gradient", develop, in: .develop),
            c("maskBrush", .addMask(.brush), "New Brush", develop, in: .develop),
            c("maskSubject", .addMask(.subject), "New Subject Mask", develop, in: .develop),
            c("maskPrompt", .addMask(.prompt), "New Click to Select", develop, in: .develop),
            c("toggleMaskOverlay", .toggleMaskOverlay, "Show Mask Overlay", develop, in: .develop),
            c("openFile", .openFile, "Open File…", files),
            c("exportOpenImage", .exportOpenImage, "Export Open Image…", export),
            c("contactSheet", .contactSheet, "Contact Sheet…", export),
            c("renameWithTemplate", .renameWithTemplate, "Rename with Template…", files),
            c("moveToFolder", .moveToFolder, "Move to Folder…", files),
            c("copyToFolder", .copyToFolder, "Copy to Folder…", files),
            c("duplicatePhoto", .duplicatePhoto, "Duplicate", files),
            c("setCopyAsMaster", .setCopyAsMaster, "Set Copy as Master", files),
            c("removeVirtualCopy", .removeVirtualCopy, "Remove Virtual Copy", files),
            c("removeDust", .removeDust, "Remove Dust…", develop),
            c("matchTotalExposures", .matchTotalExposures, "Match Total Exposures", develop),
            c("pasteFromPrevious", .pasteFromPrevious, "Paste Settings From Previous", editing),
            c("toggleSoftProof", .toggleSoftProof, "Soft Proofing", develop, in: .develop),
            c("selectNone", .select(.none), "Select None", views),
            c("selectPicked", .select(.flag(.picked)), "Select Flagged Photos", views),
            c("deselectUnflagged", .select(.deselectUnflagged), "Deselect Unflagged Photos", views),
            c("groupIntoStack", .stack(.group), "Group into Stack", files),
            c("unstack", .stack(.unstack), "Unstack", files),
            c("toggleStack", .stack(.toggleExpanded), "Expand or Collapse Stack", files, in: .library),
            c("moveToTopOfStack", .stack(.moveToTop), "Move to Top of Stack", files, in: .library),
            c("loupeOverlay", .view(.toggleOverlay), "Show Loupe Overlay", views),
            c("cycleBeforeAfter", .view(.cycleBeforeAfter), "Cycle Before/After Views", views, in: .develop),
            c("referenceView", .view(.referenceView), "Reference View", views, in: .develop),
            c("copyAfterToBefore", .view(.copyAfterToBefore), "Copy After's Settings to Before", develop, in: .develop),
            c("copyBeforeToAfter", .view(.copyBeforeToAfter), "Copy Before's Settings to After", develop, in: .develop),
            c("swapBeforeAfter", .view(.swapBeforeAfter), "Swap Before and After Settings", develop, in: .develop),
        ]
        return list
    }()

    /// The groups in the order the Keyboard tab shows them.
    static var groups: [String] {
        var seen: [String] = []
        for info in commands where !seen.contains(info.group) { seen.append(info.group) }
        return seen
    }
}

// MARK: - Settings' side

/// Settings › Keyboard's model, and what the menu bar watches so its key
/// equivalents and titles follow a change. Every change goes through here.
@MainActor
final class KeyboardSettings: ObservableObject {
    static let shared = KeyboardSettings(keymap: .shared)

    let keymap: Keymap

    init(keymap: Keymap) {
        self.keymap = keymap
    }

    var table: [Shortcut] { keymap.effective }

    func shortcut(for info: ShortcutCommandInfo) -> Shortcut? {
        table.first { $0.command == info.command }
    }

    func isCustomised(_ info: ShortcutCommandInfo) -> Bool {
        keymap.overrides[info.id] != nil
    }

    /// Another command on the same keys, which only an imported keymap or
    /// a later default can cause.
    func clash(for info: ShortcutCommandInfo) -> ShortcutCommandInfo? {
        guard let mine = shortcut(for: info) else { return nil }
        return table.first { $0.command != info.command && $0.key == mine.key && $0.modifiers == mine.modifiers
                             && $0.scope.overlaps(mine.scope) }
            .flatMap { Keymap.info(for: $0.command) }
    }

    func problem(giving key: BareKeyPress.Key, _ modifiers: ShortcutModifiers,
                 to info: ShortcutCommandInfo) -> ShortcutProblem? {
        Keymap.problem(giving: key, modifiers, to: info, in: table)
    }

    /// Gives `info` the keys, taking them from `holder` first when the
    /// user chose to reassign them.
    func assign(_ key: BareKeyPress.Key, _ modifiers: ShortcutModifiers, to info: ShortcutCommandInfo,
                takingFrom holder: ShortcutCommandInfo? = nil) {
        var overrides = keymap.overrides
        if let holder { overrides[holder.id] = ShortcutOverride.unbound }
        overrides[info.id] = .keys(key, modifiers)
        apply(overrides)
    }

    func removeKeys(from info: ShortcutCommandInfo) {
        var overrides = keymap.overrides
        overrides[info.id] = ShortcutOverride.unbound
        apply(overrides)
    }

    /// What resetting `info` would collide with: its default keys, now
    /// held by another command.
    func resetProblem(for info: ShortcutCommandInfo) -> ShortcutProblem? {
        guard let fallback = Shortcuts.defaultShortcut(for: info.command) else { return nil }
        return problem(giving: fallback.key, fallback.modifiers, to: info)
    }

    func reset(_ info: ShortcutCommandInfo, takingFrom holder: ShortcutCommandInfo? = nil) {
        var overrides = keymap.overrides
        overrides[info.id] = nil
        if let holder { overrides[holder.id] = ShortcutOverride.unbound }
        apply(overrides)
    }

    func resetAll() {
        apply([:])
    }

    var hasCustomisations: Bool { !keymap.overrides.isEmpty }

    func exportData() throws -> Data {
        try KeymapFile(overrides: keymap.overrides).encoded()
    }

    /// Replaces the keymap with a file's. Refused, leaving the keys as they
    /// were, when the file would put two commands on one key.
    func importData(_ data: Data) throws {
        let file = try KeymapFile.decode(data)
        let overrides = Keymap.normalised(file.overrides)
        let table = Keymap.effective(overrides: overrides)
        if let pair = Keymap.clashes(in: table).first {
            let (a, b) = pair
            throw ImportError.clash(Keymap.info(for: a.command)?.title ?? "\(a.command)",
                                    Keymap.info(for: b.command)?.title ?? "\(b.command)", a.glyphs)
        }
        if let used = table.first(where: { s in Shortcuts.system.contains { $0.key == s.key && $0.modifiers == s.modifiers } }) {
            throw ImportError.system(Keymap.info(for: used.command)?.title ?? "\(used.command)", used.glyphs)
        }
        apply(overrides)
    }

    enum ImportError: LocalizedError {
        case clash(String, String, String)
        case system(String, String)

        var errorDescription: String? {
            switch self {
            case let .clash(a, b, keys): "The keymap gives \(keys) to both \(a) and \(b)."
            case let .system(title, keys): "The keymap gives \(title) \(keys), which macOS keeps for itself."
            }
        }
    }

    private func apply(_ overrides: [String: ShortcutOverride]) {
        objectWillChange.send()
        keymap.setOverrides(overrides)
    }
}
