import Foundation

// MARK: - Names and folders

extension Preset {
    /// What separates folders in a preset's name: "Film|Portra 400" sits in
    /// a Film folder, as darktable's styles do. A name without it is at the
    /// top level, exactly as before folders existed.
    public static let folderSeparator: Character = "|"

    /// The name split into its folders and its own name, each trimmed;
    /// empty parts are dropped, so "Film||Portra" reads as "Film|Portra".
    public static func pathComponents(of name: String) -> [String] {
        let parts = name.split(separator: folderSeparator, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [name] : parts
    }

    /// The folders the preset sits in, outermost first; empty at the top.
    public var folders: [String] { Array(Self.pathComponents(of: name).dropLast()) }

    /// The name shown in a menu, without its folders.
    public var leafName: String { Self.pathComponents(of: name).last ?? name }

    /// The name tidied for saving: folders and name trimmed, empty parts
    /// dropped. Nil when nothing is left.
    public static func normalisedName(_ name: String) -> String? {
        let parts = name.split(separator: folderSeparator, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: String(folderSeparator))
    }

    /// `name`, or "name 2", "name 3"… so it clashes with none of `taken`
    /// (compared without case, since the files on disk are).
    public static func uniqueName(_ name: String, avoiding taken: [String]) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(name.lowercased()) else { return name }
        var n = 2
        while lowered.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }
}

// MARK: - Managing the store

/// A preset store operation that can't go ahead.
public enum PresetStoreError: LocalizedError, Equatable {
    case emptyName
    case nameTaken(String)
    case builtIn(String)
    case notAPresetFile

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A preset needs a name."
        case .nameTaken(let name): "There is already a preset called “\(name)”."
        case .builtIn(let name): "“\(name)” is built in and can’t be changed. Duplicate it to make your own."
        case .notAPresetFile: "The file isn’t a Latent preset."
        }
    }
}

extension PresetStore {
    /// The extension Export… writes; Import… also takes plain .json.
    public static let fileExtension = "latentpreset"

    /// Whether `name` is free for a new user preset: no built-in or user
    /// preset has it, and no other name maps to its file.
    public static func isAvailable(_ name: String, among presets: [Preset], ignoring old: String? = nil) -> Bool {
        let file = fileURL(for: name).lastPathComponent.lowercased()
        return !presets.contains { other in
            guard other.name != old else { return false }
            return other.name.lowercased() == name.lowercased()
                || (!other.isBuiltIn && fileURL(for: other.name).lastPathComponent.lowercased() == file)
        }
    }

    /// Renames a user preset: written under the new name first, then the
    /// old file removed, so a failure never loses it.
    public static func rename(_ preset: Preset, to newName: String, among presets: [Preset]) throws -> Preset {
        guard !preset.isBuiltIn else { throw PresetStoreError.builtIn(preset.name) }
        guard let name = Preset.normalisedName(newName) else { throw PresetStoreError.emptyName }
        if name == preset.name { return preset }
        guard name.lowercased() == preset.name.lowercased() || isAvailable(name, among: presets, ignoring: preset.name) else {
            throw PresetStoreError.nameTaken(name)
        }
        var renamed = preset
        renamed.name = name
        let oldURL = fileURL(for: preset.name), newURL = fileURL(for: name)
        try save(renamed)
        guard oldURL.lastPathComponent != newURL.lastPathComponent else { return renamed }
        if oldURL.lastPathComponent.lowercased() == newURL.lastPathComponent.lowercased() {
            // Only the case changed. On a case-insensitive disk the save
            // replaced the one file; remove the old only if both still exist.
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            guard names.contains(oldURL.lastPathComponent), names.contains(newURL.lastPathComponent) else { return renamed }
        }
        try? FileManager.default.removeItem(at: oldURL)
        return renamed
    }

    /// A user copy of any preset, built-ins included, named "<name> copy".
    public static func duplicate(_ preset: Preset, among presets: [Preset]) throws -> Preset {
        var copy = preset
        copy.isBuiltIn = false
        copy.name = uniqueFreeName("\(preset.name) copy", among: presets)
        try save(copy)
        return copy
    }

    /// `name`, numbered until it is free.
    static func uniqueFreeName(_ name: String, among presets: [Preset]) -> String {
        if isAvailable(name, among: presets) { return name }
        var n = 2
        while !isAvailable("\(name) \(n)", among: presets) { n += 1 }
        return "\(name) \(n)"
    }

    /// The preset with `groups` narrowed to those ticked (never widened:
    /// the stack holds nothing for a group the preset didn't save).
    public static func restrict(_ preset: Preset, to groups: Set<EditGroup>) throws -> Preset {
        guard !preset.isBuiltIn else { throw PresetStoreError.builtIn(preset.name) }
        var changed = Preset(name: preset.name, groups: preset.groups.intersection(groups), stack: preset.stack)
        changed.details = preset.details
        try save(changed)
        return changed
    }

    // MARK: Files

    /// What Export… writes: one preset as itself, several as an array.
    public static func exportData(_ presets: [Preset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let mine = presets.map { preset -> Preset in var p = preset; p.isBuiltIn = false; return p }
        return mine.count == 1 ? try encoder.encode(mine[0]) : try encoder.encode(mine)
    }

    /// The presets in an exported file: one preset, or an array of them.
    /// None is built in, whatever the file says.
    public static func decodeFile(_ data: Data) throws -> [Preset] {
        let decoder = JSONDecoder()
        let found: [Preset]
        if let one = try? decoder.decode(Preset.self, from: data) {
            found = [one]
        } else if let many = try? decoder.decode([Preset].self, from: data), !many.isEmpty {
            found = many
        } else {
            throw PresetStoreError.notAPresetFile
        }
        return found.map { var p = $0; p.isBuiltIn = false; return p }
    }

    /// Saves the presets in `data` alongside `existing`, renaming any whose
    /// name is taken ("Portra 2"). Returns the names they were saved as.
    @discardableResult
    public static func importFile(_ data: Data, existing: [Preset]) throws -> [String] {
        var all = existing
        var saved: [String] = []
        for var preset in try decodeFile(data) {
            guard let name = Preset.normalisedName(preset.name) else { continue }
            preset.name = uniqueFreeName(name, among: all)
            try save(preset)
            all.append(preset)
            saved.append(preset.name)
        }
        return saved
    }

    // MARK: Lookup

    private static let cache = PresetLookupCache()

    /// The preset called `name`, built-in or user, read through a cache
    /// that is refreshed whenever the folder changes, so a batch export
    /// asking once per photo doesn't read every file each time.
    public static func preset(named name: String) -> Preset? {
        cache.presets().first { $0.name == name }
    }
}

/// `PresetStore.load()`, kept until the presets folder's modification date
/// changes (every save, rename and delete moves a file in or out of it).
private final class PresetLookupCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: Date?
    private var loaded: [Preset]?

    func presets() -> [Preset] {
        let dir = PresetStore.directory
        let now = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return lock.withLock {
            if let loaded, stamp == now, now != nil { return loaded }
            let fresh = PresetStore.load()
            loaded = fresh
            stamp = now
            return fresh
        }
    }
}

// MARK: - A preset applied on output

/// A develop preset applied only to an output (an export or a print), as
/// darktable's "style" on export: the photo's own edit is never changed.
///
/// Append applies the preset over the photo's edit, as Apply Preset does;
/// Replace starts from no edit at all, so only the preset's look is used.
/// Amount is the Presets panel's Amount (`PresetAmount`).
public struct PresetStyle: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case append, replace

        public var title: String {
            switch self {
            case .append: "Append"
            case .replace: "Replace"
            }
        }
    }

    public var presetName: String
    public var mode: Mode = .append
    public var amount: Float = PresetAmount.full

    public init(presetName: String, mode: Mode = .append, amount: Float = PresetAmount.full) {
        self.presetName = presetName
        self.mode = mode
        self.amount = amount
    }

    private enum CodingKeys: String, CodingKey { case presetName, mode, amount }

    /// Lenient: an unknown mode or a bad amount falls back to the default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presetName = try c.decode(String.self, forKey: .presetName)
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .append
        let raw = (try? c.decodeIfPresent(Float.self, forKey: .amount)) ?? PresetAmount.full
        amount = raw.isFinite ? min(max(raw, PresetAmount.range.lowerBound), PresetAmount.range.upperBound)
                              : PresetAmount.full
    }

    /// `json` (a photo's stored edit, nil for none) with `preset` applied,
    /// as a fresh document; the stored edit itself is untouched. Throws
    /// when `json` can't be read, so the caller can keep it as it was.
    public func applied(to json: String?, preset: Preset) throws -> String? {
        let base: EditStack
        switch mode {
        case .append: base = try json.map { try EditStack.decode(json: $0) } ?? EditStack()
        case .replace: base = EditStack()
        }
        let result = base.applying(preset.stack, groups: preset.groups, amount: amount)
        return result == EditStack() ? nil : try result.encodeJSON()
    }

    /// `json` with the named preset applied, or `json` unchanged when the
    /// preset no longer exists or the edit can't be read (the render then
    /// reports the unreadable edit as it always has).
    public func applied(to json: String?, lookup: (String) -> Preset? = PresetStore.preset(named:)) -> String? {
        guard let preset = lookup(presetName), let styled = try? applied(to: json, preset: preset) else { return json }
        return styled
    }
}
