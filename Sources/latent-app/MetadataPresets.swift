import Foundation
import Catalog

/// A named set of descriptive fields (creator, copyright, city…) to put on
/// photos in one go, like Lightroom's metadata presets. Applying one sets
/// only the fields it names, as one undo step
/// (`Library.setDescriptive(_:forImageIDs:in:action:)`).
struct MetadataPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Field raw values to text, so a preset saved by a later build with a
    /// field this one doesn't know still loads.
    var values: [String: String]

    init(name: String, values: [DescriptiveField: String]) {
        self.name = name
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    /// The fields this build knows.
    var fields: [DescriptiveField: String] {
        var out: [DescriptiveField: String] = [:]
        for (key, value) in values {
            if let field = DescriptiveField(rawValue: key) { out[field] = value }
        }
        return out
    }

    /// The non-empty fields every one of `records` shares: what Save
    /// Current as Preset keeps. A field they differ in is left out.
    static func values(sharedBy records: [ImageRecord]) -> [DescriptiveField: String] {
        var out: [DescriptiveField: String] = [:]
        guard !records.isEmpty else { return out }
        for field in DescriptiveField.allCases {
            if case .same(let value?) = field.shared(by: records) { out[field] = value }
        }
        return out
    }
}

/// Metadata presets, kept in the app's preferences.
enum MetadataPresetStore {
    static let defaultsKey = "latent.metadataPresets"

    static func load(from defaults: UserDefaults = .standard) -> [MetadataPreset] {
        guard let data = defaults.data(forKey: defaultsKey),
              let presets = try? JSONDecoder().decode([MetadataPreset].self, from: data) else { return [] }
        return presets
    }

    static func save(_ presets: [MetadataPreset], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
