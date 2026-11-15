import Foundation

// Mask presets (wave 4): a mask (its shape, components, ranges and every
// slider) saved under a name and added to any photo later. They are files
// in their own folder beside the edit presets
// (~/Library/Application Support/latent/mask-presets), one JSON file per
// preset, so they can be backed up or shared like those.

/// A mask saved under a name.
///
/// `mask` is the local adjustment as it was saved; its ids are only
/// placeholders, since `instantiate` gives the added mask and each of its
/// components fresh ones (a photo may already hold a mask with the old
/// id, and model-mask pixels are keyed by it).
public struct MaskPreset: Codable, Equatable, Sendable, Identifiable {
    /// Written in every file so a future layout can tell old ones apart.
    public static let currentFormat = 1

    public var format: Int
    public var name: String
    public var mask: LocalAdjustment

    public var id: String { name.lowercased() }

    public init(name: String, mask: LocalAdjustment) {
        self.format = Self.currentFormat
        self.name = name
        self.mask = mask
    }

    /// Why a component is left out of a preset, for the save sheet.
    public enum SkipReason: Equatable, Sendable {
        /// A linked component points at another mask of this photo by its
        /// id; on another photo there is nothing for it to point at.
        case linkedMask
    }

    /// A component the preset leaves out: its name in the list and why.
    public struct Skipped: Equatable, Sendable {
        public var name: String
        public var reason: SkipReason
        public var explanation: String {
            switch reason {
            case .linkedMask: return "\(name): it uses another mask of this photo, which other photos don't have"
            }
        }
    }

    /// Whether a component can travel to another photo as it is, or why
    /// not.
    ///
    /// Every shape is stored resolution-independently: gradients, radials
    /// and brush strokes (points and radius) are in normalised sensor
    /// coordinates, and a model mask (Subject, a class, Click to Select)
    /// stores only its kind or its normalised clicks and is generated
    /// again from the new photo's own pixels. Those are kept as they are.
    /// Luminance, colour and channel ranges are measured on whatever
    /// photo they are applied to, so they travel too. Only a linked mask
    /// cannot: it names another mask of the source photo by id.
    public static func skipReason(for component: MaskComponent) -> SkipReason? {
        switch component.source {
        case .mask: return .linkedMask
        case .shape, .luminance, .colour, .channel: return nil
        }
    }

    /// A preset of `local`, with the components that can't travel left
    /// out and listed. The saved mask is shown (not hidden), whatever
    /// `local` was.
    public static func capture(_ local: LocalAdjustment, name: String) -> (preset: MaskPreset, skipped: [Skipped]) {
        var mask = local
        var skipped: [Skipped] = []
        mask.components = local.components.filter { component in
            guard let reason = skipReason(for: component) else { return true }
            skipped.append(Skipped(name: component.displayName, reason: reason))
            return false
        }
        mask.hidden = false
        mask.name = name
        return (MaskPreset(name: name, mask: mask), skipped)
    }

    /// The components `capture` would leave out of `local`, for the save
    /// sheet to list before saving.
    public static func skippedComponents(of local: LocalAdjustment) -> [Skipped] {
        capture(local, name: local.name).skipped
    }

    /// The mask to add to a photo: the saved one with a fresh id for the
    /// mask and for each component, named after the preset (or `name`).
    public func instantiate(name newName: String? = nil) -> LocalAdjustment {
        var local = mask.duplicated(name: newName ?? name)
        local.components = Array(local.components.prefix(MaskComponent.maximumPerMask))
        local.hidden = false
        return local
    }
}

/// A mask preset store operation that can't go ahead.
public enum MaskPresetStoreError: LocalizedError, Equatable {
    case emptyName
    case nameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "A mask preset needs a name."
        case .nameTaken(let name): return "There is already a mask preset called “\(name)”."
        }
    }
}

/// Mask preset files in one folder. The app uses `standard`; tests give
/// it a temporary folder.
public struct MaskPresetStore: Sendable {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    /// ~/Library/Application Support/latent/mask-presets, beside the edit
    /// presets' own folder (`PresetStore.directory`).
    public static var standard: MaskPresetStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return MaskPresetStore(directory: base.appendingPathComponent("latent/mask-presets", isDirectory: true))
    }

    /// Every preset in the folder, by name; unreadable files are skipped.
    public func load() -> [MaskPreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> MaskPreset? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(MaskPreset.self, from: data)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Writes the preset under its name, replacing any file of that name.
    public func save(_ preset: MaskPreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: fileURL(for: preset.name), options: .atomic)
    }

    public func delete(named name: String) throws {
        try FileManager.default.removeItem(at: fileURL(for: name))
    }

    /// Saves a new preset of `local` named `name` (trimmed), refusing a
    /// name another preset has. Returns the preset and what it left out.
    public func saveNew(_ local: LocalAdjustment, name: String) throws -> (preset: MaskPreset, skipped: [MaskPreset.Skipped]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MaskPresetStoreError.emptyName }
        guard isAvailable(trimmed) else { throw MaskPresetStoreError.nameTaken(trimmed) }
        let made = MaskPreset.capture(local, name: trimmed)
        try save(made.preset)
        return made
    }

    /// Renames a preset: written under the new name first, then the old
    /// file removed, so a failure never loses it.
    public func rename(_ preset: MaskPreset, to newName: String) throws -> MaskPreset {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MaskPresetStoreError.emptyName }
        if trimmed == preset.name { return preset }
        let caseOnly = trimmed.lowercased() == preset.name.lowercased()
        guard caseOnly || isAvailable(trimmed) else { throw MaskPresetStoreError.nameTaken(trimmed) }
        var renamed = preset
        renamed.name = trimmed
        renamed.mask.name = trimmed
        let oldURL = fileURL(for: preset.name), newURL = fileURL(for: trimmed)
        try save(renamed)
        // On a case-insensitive disk a case-only rename replaced the one file.
        if oldURL.lastPathComponent.lowercased() != newURL.lastPathComponent.lowercased() {
            try? FileManager.default.removeItem(at: oldURL)
        } else if oldURL.lastPathComponent != newURL.lastPathComponent {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            if names.contains(oldURL.lastPathComponent), names.contains(newURL.lastPathComponent) {
                try? FileManager.default.removeItem(at: oldURL)
            }
        }
        return renamed
    }

    /// Whether no preset already uses `name` or its file (compared without
    /// case, as the disk does).
    public func isAvailable(_ name: String) -> Bool {
        let file = fileURL(for: name).lastPathComponent.lowercased()
        return !load().contains {
            $0.name.lowercased() == name.lowercased() || fileURL(for: $0.name).lastPathComponent.lowercased() == file
        }
    }

    func fileURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent(safe + ".json")
    }
}
