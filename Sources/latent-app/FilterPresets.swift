import SwiftUI
import AppKit
import Catalog

/// Named filter-bar settings, kept in the preferences as name → filter
/// (JSON in UserDefaults). Independent of Save Filter as Smart Collection:
/// a preset belongs to the app, not to a catalog, and holds every filter
/// bar criterion, the newer ones included.
@MainActor
final class FilterPresetStore: ObservableObject {
    static let shared = FilterPresetStore()
    static let defaultsKey = "latent.filterPresets"

    @Published private(set) var presets: [String: LibraryFilter] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presets = Self.decode(defaults.data(forKey: Self.defaultsKey))
    }

    /// The names in the order the menu lists them.
    var names: [String] {
        presets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Saves `filter` under `name`, replacing a preset of that name.
    func save(_ filter: LibraryFilter, as name: String) {
        guard let name = Self.cleaned(name) else { return }
        var filter = filter
        filter.recentlyAddedIDs = nil
        presets[name] = filter
        persist()
    }

    /// False when the new name is empty or already taken.
    @discardableResult
    func rename(_ old: String, to new: String) -> Bool {
        guard let new = Self.cleaned(new), let filter = presets[old] else { return false }
        if new == old { return true }
        guard presets[new] == nil else { return false }
        presets[old] = nil
        presets[new] = filter
        persist()
        return true
    }

    func remove(_ name: String) {
        guard presets.removeValue(forKey: name) != nil else { return }
        persist()
    }

    static func cleaned(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func decode(_ data: Data?) -> [String: LibraryFilter] {
        guard let data, let decoded = try? JSONDecoder().decode([String: LibraryFilter].self, from: data) else { return [:] }
        return decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(presets) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// The filter bar's Filter Presets menu, at its right end.
struct FilterPresetsMenu: View {
    @ObservedObject var library: Library
    @ObservedObject private var store = FilterPresetStore.shared

    var body: some View {
        Menu {
            Button("Save Current Filter…") { saveCurrent() }
                .disabled(!library.filter.isActive)
            if !store.names.isEmpty {
                Divider()
                ForEach(store.names, id: \.self) { name in
                    Button {
                        if let preset = store.presets[name] { library.filter = preset }
                    } label: {
                        if store.presets[name] == current { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
                Divider()
                Menu("Rename") {
                    ForEach(store.names, id: \.self) { name in
                        Button(name + "…") { rename(name) }
                    }
                }
                Menu("Remove") {
                    ForEach(store.names, id: \.self) { name in
                        Button(name) { store.remove(name) }
                    }
                }
            }
            Divider()
            // Off by default: the filter then carries over between folders
            // and collections, as it always has (Library+FilterMemory.swift).
            Toggle("Remember Filter per Source", isOn: $library.remembersFilterPerSource)
                .help("Each folder and collection keeps its own filter, which comes back when you return to it")
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter presets: save the filter bar's settings under a name and apply them again, or remember a filter per folder and collection")
        .accessibilityLabel("Filter presets")
    }

    /// The bar's filter as a preset would hold it.
    private var current: LibraryFilter {
        var filter = library.filter
        filter.recentlyAddedIDs = nil
        return filter
    }

    private func saveCurrent() {
        guard let name = Self.askName(title: "Save Filter Preset",
                                      message: "The filter bar's settings are saved under this name, for every catalog.",
                                      initial: "", button: "Save") else { return }
        if store.presets[name] != nil, !Self.confirmReplace(name) { return }
        store.save(library.filter, as: name)
    }

    private func rename(_ name: String) {
        guard let new = Self.askName(title: "Rename Filter Preset", message: "", initial: name, button: "Rename") else { return }
        if !store.rename(name, to: new) {
            let alert = NSAlert()
            alert.messageText = "A preset named “\(new)” already exists."
            alert.runModal()
        }
    }

    private static func askName(title: String, message: String, initial: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return FilterPresetStore.cleaned(field.stringValue)
    }

    private static func confirmReplace(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace the preset “\(name)”?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
