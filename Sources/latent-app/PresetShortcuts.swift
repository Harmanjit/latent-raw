import SwiftUI
import PixelEngine

/// Presets as commands: each user preset is listed in Settings › Keyboard
/// as "Apply Preset: <name>", with no key until the user gives it one, and
/// Develop › Apply Preset carries its key in the menu bar. The id is the
/// preset's name, so a binding survives relaunches; a preset deleted since
/// keeps its keys, shown as missing, and the keys then do nothing.
///
/// The names are kept here, behind a lock, because the shortcut table is
/// read from any thread (`Keymap`).
enum PresetShortcuts {
    static let idPrefix = "applyPreset."
    static let group = "Presets"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [String] = []

    static func id(for name: String) -> String { idPrefix + name }

    static func isPresetID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    static func name(fromID id: String) -> String? {
        isPresetID(id) ? String(id.dropFirst(idPrefix.count)) : nil
    }

    /// The user presets now in the store (built-ins are left out: they
    /// can't be renamed or deleted, but they also aren't the user's).
    static func setNames(_ new: [String]) {
        lock.withLock { names = new }
        Keymap.shared.invalidate()
    }

    static var currentNames: [String] { lock.withLock { names } }

    /// One row per user preset, then one per binding whose preset is gone.
    static func infos(overrides: [String: ShortcutOverride]) -> [ShortcutCommandInfo] {
        let present = currentNames
        var rows = present.map { name in
            ShortcutCommandInfo(id: id(for: name), command: .applyPreset(name), title: "Apply Preset: \(name)",
                                group: group)
        }
        let known = Set(present)
        let missing = overrides.keys.compactMap(name(fromID:)).filter { !known.contains($0) }.sorted()
        rows += missing.map { name in
            ShortcutCommandInfo(id: id(for: name), command: .applyPreset(name),
                                title: "Apply Preset: \(name) (missing)", group: group)
        }
        return rows
    }

    /// Whether the command is a preset's binding whose preset is gone.
    static func isMissing(_ command: KeyCommand) -> Bool {
        guard case .applyPreset(let name) = command else { return false }
        return !currentNames.contains(name)
    }
}

extension KeyboardSettings {
    /// The presets changed: the table and the menu bar follow.
    func presetsDidChange() {
        objectWillChange.send()
        keymap.invalidate()
    }

    /// A preset was renamed: its keys go with it.
    func presetRenamed(from old: String, to new: String) {
        var overrides = keymap.overrides
        guard let keys = overrides.removeValue(forKey: PresetShortcuts.id(for: old)) else { return }
        overrides[PresetShortcuts.id(for: new)] = keys
        objectWillChange.send()
        keymap.setOverrides(overrides)
    }
}

/// Develop › Apply Preset in the menu bar: the presets as commands, so a
/// key given to one in Settings › Keyboard works from anywhere.
struct ApplyPresetMenu: View {
    @ObservedObject var catalog: PresetCatalog
    let item: (String, KeyCommand) -> AnyView

    var body: some View {
        Menu("Apply Preset") {
            if !catalog.favouritePresets.isEmpty {
                Section("Favourites") {
                    ForEach(catalog.favouritePresets) { preset in
                        item(PresetMenuTree.favouriteTitle(preset), .applyPreset(preset.name))
                    }
                }
                Divider()
            }
            nodes(PresetMenuTree.nodes(catalog.presets.filter(\.isBuiltIn)))
            let user = catalog.presets.filter { !$0.isBuiltIn }
            if !user.isEmpty {
                Divider()
                nodes(PresetMenuTree.nodes(user))
            }
        }
    }

    private func nodes(_ nodes: [PresetMenuNode]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            switch node.kind {
            case .preset(let preset): item(preset.leafName, .applyPreset(preset.name))
            case .folder(let name, let children): Menu(name) { self.nodes(children) }
            }
        })
    }
}
