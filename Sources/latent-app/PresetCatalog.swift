import SwiftUI
import AppKit
import PixelEngine

/// The presets every menu lists, and the ones starred as favourites, so
/// the menu bar, the Presets panel, the Library panel and the grid's menu
/// all show the same list and follow a change at once.
///
/// `EditorModel.presets` stays the editor's own copy; `reloadPresets()`
/// updates both, and the shortcut table's preset commands with them.
@MainActor
final class PresetCatalog: ObservableObject {
    static let shared = PresetCatalog()

    @Published private(set) var presets: [Preset]
    @Published private(set) var favourites: Set<String>

    static let favouritesKey = "latent.presetFavourites"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, presets: [Preset]? = nil) {
        self.defaults = defaults
        self.presets = presets ?? PresetStore.load()
        favourites = Set(defaults.stringArray(forKey: Self.favouritesKey) ?? [])
        PresetShortcuts.setNames(self.presets.filter { !$0.isBuiltIn }.map(\.name))
    }

    /// The store was changed: lists, menus and the shortcut table follow.
    func update(_ presets: [Preset]) {
        self.presets = presets
        // A favourite whose preset is gone is forgotten.
        let names = Set(presets.map(\.name))
        if !favourites.isSubset(of: names) { setFavourites(favourites.intersection(names)) }
        PresetShortcuts.setNames(presets.filter { !$0.isBuiltIn }.map(\.name))
        KeyboardSettings.shared.presetsDidChange()
    }

    func isFavourite(_ preset: Preset) -> Bool { favourites.contains(preset.name) }

    func toggleFavourite(_ preset: Preset) {
        var next = favourites
        if next.contains(preset.name) { next.remove(preset.name) } else { next.insert(preset.name) }
        setFavourites(next)
    }

    /// A preset renamed: its star goes with it.
    func renamed(from old: String, to new: String) {
        guard favourites.contains(old) else { return }
        var next = favourites
        next.remove(old)
        next.insert(new)
        setFavourites(next)
    }

    private func setFavourites(_ names: Set<String>) {
        favourites = names
        if names.isEmpty {
            defaults.removeObject(forKey: Self.favouritesKey)
        } else {
            defaults.set(names.sorted(), forKey: Self.favouritesKey)
        }
    }

    /// The favourites, in the order the list has them.
    var favouritePresets: [Preset] { presets.filter { favourites.contains($0.name) } }
}

// MARK: - Folders as a tree

/// A preset list as menus show it: "Film|Portra" inside a Film submenu.
struct PresetMenuNode: Identifiable {
    enum Kind {
        case preset(Preset)
        case folder(String, [PresetMenuNode])
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .preset(let preset): "p:" + preset.name
        case .folder(let name, let children): "f:" + name + ":" + (children.first?.id ?? "")
        }
    }
}

enum PresetMenuTree {
    /// `presets` grouped into folders by their names, keeping their order:
    /// a folder sits where its first preset would.
    static func nodes(_ presets: [Preset]) -> [PresetMenuNode] {
        nodes(presets.map { (Preset.pathComponents(of: $0.name), $0) })
    }

    private static func nodes(_ entries: [([String], Preset)]) -> [PresetMenuNode] {
        var order: [String] = []          // "" + name for presets, folder names otherwise
        var folders: [String: [([String], Preset)]] = [:]
        var leaves: [String: Preset] = [:]
        for (path, preset) in entries {
            if path.count <= 1 {
                let key = "\u{0}" + preset.name
                if leaves[key] == nil { order.append(key) }
                leaves[key] = preset
            } else {
                let folder = path[0]
                if folders[folder] == nil { order.append(folder) }
                folders[folder, default: []].append((Array(path.dropFirst()), preset))
            }
        }
        return order.compactMap { key in
            if let preset = leaves[key] { return PresetMenuNode(kind: .preset(preset)) }
            guard let children = folders[key] else { return nil }
            return PresetMenuNode(kind: .folder(key, nodes(children)))
        }
    }

    /// A favourite's title: its name with folders shown as "Film › Portra".
    static func favouriteTitle(_ preset: Preset) -> String {
        Preset.pathComponents(of: preset.name).joined(separator: " › ")
    }
}

// MARK: - SwiftUI menus

/// How a preset is put on photos from a menu (PresetApplyMode.swift).
typealias PresetMenuAction = (Preset, PresetApplyMode) -> Void

/// The items of an Apply Preset menu: Favourites first, then the built-in
/// presets, then the user's, folders as submenus. Holding Option turns each
/// item into its Overwrite form. `virtualCopies` adds the Apply as New
/// Virtual Copy submenu.
struct PresetMenuItems: View {
    let presets: [Preset]
    let favourites: [Preset]
    var virtualCopies = false
    let action: PresetMenuAction

    var body: some View {
        if !favourites.isEmpty {
            Section("Favourites") {
                ForEach(favourites) { preset in
                    PresetMenuButton(preset: preset, title: PresetMenuTree.favouriteTitle(preset), action: action)
                }
            }
            Divider()
        }
        let builtIns = presets.filter(\.isBuiltIn), user = presets.filter { !$0.isBuiltIn }
        PresetNodeItems(nodes: PresetMenuTree.nodes(builtIns), action: action)
        if !user.isEmpty {
            Divider()
            PresetNodeItems(nodes: PresetMenuTree.nodes(user), action: action)
        }
        if virtualCopies, !presets.isEmpty {
            Divider()
            Menu("Apply as New Virtual Copy") {
                PresetNodeItems(nodes: PresetMenuTree.nodes(presets), plainOnly: true) { preset, _ in
                    action(preset, .virtualCopy)
                }
            }
        }
    }
}

/// Presets and folders, recursively.
struct PresetNodeItems: View {
    let nodes: [PresetMenuNode]
    var plainOnly = false
    /// Shows each preset as a checkable item, ticked when this says so.
    var isChecked: ((Preset) -> Bool)?
    let action: PresetMenuAction

    var body: some View {
        ForEach(nodes) { node in
            switch node.kind {
            case .preset(let preset):
                if let isChecked {
                    Toggle(preset.leafName, isOn: Binding(get: { isChecked(preset) },
                                                          set: { _ in action(preset, .append) }))
                } else if plainOnly {
                    Button(preset.leafName) { action(preset, .append) }
                } else {
                    PresetMenuButton(preset: preset, title: preset.leafName, action: action)
                }
            case .folder(let name, let children):
                Menu(name) {
                    AnyView(PresetNodeItems(nodes: children, plainOnly: plainOnly, isChecked: isChecked, action: action))
                }
            }
        }
    }
}

/// One preset: Apply, or with Option held, Apply (Overwrite).
struct PresetMenuButton: View {
    let preset: Preset
    let title: String
    let action: PresetMenuAction

    var body: some View {
        Button(title) { action(preset, .append) }
            .modifierKeyAlternate(.option) {
                Button("\(title) (Overwrite)") { action(preset, .overwrite) }
            }
    }
}

// MARK: - AppKit menus

/// The grid's Apply Preset submenu, the same tree as the SwiftUI menus.
@MainActor
enum PresetNSMenu {
    static func items(presets: [Preset], favourites: [Preset], enabled: Bool,
                      virtualCopies: Bool, action: @escaping PresetMenuAction) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if !favourites.isEmpty {
            let header = NSMenuItem(title: "Favourites", action: nil, keyEquivalent: "")
            header.isEnabled = false
            items.append(header)
            for preset in favourites {
                items += pair(preset, title: PresetMenuTree.favouriteTitle(preset), enabled: enabled, action: action)
            }
            items.append(.separator())
        }
        let builtIns = presets.filter(\.isBuiltIn), user = presets.filter { !$0.isBuiltIn }
        items += nodeItems(PresetMenuTree.nodes(builtIns), enabled: enabled, plainOnly: false, action: action)
        if !user.isEmpty {
            items.append(.separator())
            items += nodeItems(PresetMenuTree.nodes(user), enabled: enabled, plainOnly: false, action: action)
        }
        if virtualCopies, !presets.isEmpty {
            items.append(.separator())
            items.append(submenu("Apply as New Virtual Copy", enabled: enabled,
                                 nodeItems(PresetMenuTree.nodes(presets), enabled: enabled, plainOnly: true) { preset, _ in
                                     action(preset, .virtualCopy)
                                 }))
        }
        return items
    }

    private static func nodeItems(_ nodes: [PresetMenuNode], enabled: Bool, plainOnly: Bool,
                                  action: @escaping PresetMenuAction) -> [NSMenuItem] {
        nodes.flatMap { node -> [NSMenuItem] in
            switch node.kind {
            case .preset(let preset):
                if plainOnly {
                    return [ClosureMenuItem(preset.leafName, enabled: enabled) { action(preset, .append) }]
                }
                return pair(preset, title: preset.leafName, enabled: enabled, action: action)
            case .folder(let name, let children):
                return [submenu(name, enabled: enabled,
                                nodeItems(children, enabled: enabled, plainOnly: plainOnly, action: action))]
            }
        }
    }

    /// The item and its Option alternate, Overwrite.
    private static func pair(_ preset: Preset, title: String, enabled: Bool,
                             action: @escaping PresetMenuAction) -> [NSMenuItem] {
        let plain = ClosureMenuItem(title, enabled: enabled) { action(preset, .append) }
        plain.keyEquivalentModifierMask = []
        let overwrite = ClosureMenuItem("\(title) (Overwrite)", enabled: enabled) { action(preset, .overwrite) }
        overwrite.isAlternate = true
        overwrite.keyEquivalentModifierMask = .option
        return [plain, overwrite]
    }

    private static func submenu(_ title: String, enabled: Bool, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        item.submenu = menu
        item.isEnabled = enabled
        return item
    }
}
