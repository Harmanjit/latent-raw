import Foundation
import CoreML
import os

private let registryLogger = Logger(subsystem: "com.latent.app", category: "models")

/// One row of Settings › AI › Models: a manifest and where it stands.
public struct ModelEntry: Sendable, Identifiable, Equatable {
    public enum Status: String, Sendable { case builtIn, bundled, installed, notInstalled }
    public var manifest: ModelManifest
    public var status: Status
    /// Folder holding the packages; nil for builtIn and notInstalled.
    public var location: URL?

    public init(manifest: ModelManifest, status: Status, location: URL?) {
        self.manifest = manifest
        self.status = status
        self.location = location
    }

    public var id: String { manifest.id }
    public var isInstalled: Bool { status != .notInstalled }
    public var modelVersion: String { manifest.modelVersion }
}

/// One loaded model per id, whatever its kind. (AIDenoiser keeps its own
/// loading.)
public enum LoadedModel: Sendable {
    case subject(SubjectSegmenter)
    case prompted(SAM2Models)
    case semantic(SegmentationModel)
}

/// Every model the app knows: the manifests bundled beside the packages,
/// the rows of ModelCatalog.json (a source link, nothing installed), the
/// folders under `externalModelsDirectory/<id>/` that Add Model… made,
/// and one synthesised row for Apple Vision's subject lift, which needs
/// no file at all (docs/Retouch.md §2 A).
///
/// A bundled id shadows an external one and an external id shadows a
/// catalogue one, so importing a catalogue model replaces its row and a
/// stray copy of a bundled model changes nothing. The listing is read
/// once and kept until `refresh()`; loaded models are kept one per id and
/// let go of together under memory pressure. One `OSAllocatedUnfairLock`
/// guards both (static mutable state in an enum is a Swift 6 error, and
/// `SharedModel` holds one type only).
public final class ModelRegistry: @unchecked Sendable {
    public static let shared = ModelRegistry()
    public static let builtInSubjectID = "vision.foregroundInstance"
    public static let subjectPreferenceKey = "latent.subjectModel"
    public static let promptedPreferenceKey = "latent.promptedModel"
    /// What the preference keys mean when unset (or set to a model that
    /// is not installed): the bundled model of each kind.
    public static let defaultSubjectID = "birefnet-lite"
    public static let defaultPromptedID = "sam2.1-small"

    let bundledDirectory: URL?
    let externalDirectory: URL
    let catalogueURL: URL?
    let defaults: UserDefaults

    private struct State {
        var listing: [ModelEntry]?
        var loaded: [String: LoadedModel] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Test hook: explicit directories. `shared` uses CoreMLStore's.
    public init(bundled: URL? = CoreMLStore.modelsDirectory,
                external: URL = CoreMLStore.externalModelsDirectory,
                catalogue: URL? = CoreMLStore.catalogueURL,
                defaults: UserDefaults = .standard) {
        bundledDirectory = bundled
        externalDirectory = external
        catalogueURL = catalogue
        self.defaults = defaults
    }

    // MARK: - Listing

    /// Every entry, or those of one kind. Order: built-in, bundled,
    /// installed, catalogue; by id within a group, so the list is the
    /// same however the file system enumerates.
    public func entries(kind: ModelManifest.Kind? = nil) -> [ModelEntry] {
        let all = listing()
        guard let kind else { return all }
        return all.filter { $0.manifest.kind == kind }
    }

    public func entry(id: String) -> ModelEntry? {
        listing().first { $0.id == id }
    }

    /// The installed entry for a stored version, resolved by id only (a
    /// different installed version runs, and the mask row says so); nil
    /// when missing or when `ref` is nil.
    public func installed(_ ref: ModelRef?) -> ModelEntry? {
        guard let ref, let entry = entry(id: ref.id), entry.isInstalled else { return nil }
        return entry
    }

    /// Forgets the listing; the next question reads the folders again.
    /// Called after an import or a removal.
    public func refresh() {
        state.withLock { $0.listing = nil }
    }

    private func listing() -> [ModelEntry] {
        if let cached = state.withLock({ $0.listing }) { return cached }
        // Read outside the lock: this walks folders and parses JSON. Two
        // callers racing here read the same files and keep one answer.
        let fresh = Self.list(bundled: bundledDirectory, external: externalDirectory, catalogue: catalogueURL)
        return state.withLock { state in
            if let cached = state.listing { return cached }
            state.listing = fresh
            return fresh
        }
    }

    /// The listing rules, as a pure function of the three places.
    static func list(bundled: URL?, external: URL, catalogue: URL?) -> [ModelEntry] {
        var entries: [ModelEntry] = [builtInVision]
        var seen: Set<String> = [builtInVision.id]

        // Bundled: every *.model.json beside the packages.
        if let bundled {
            for manifest in manifests(in: bundled) where !seen.contains(manifest.id) {
                seen.insert(manifest.id)
                entries.append(ModelEntry(manifest: manifest, status: .bundled, location: bundled))
            }
        }

        // Installed: external/<id>/<id>.model.json. The folder is the id,
        // so a manifest that says otherwise is not something Add Model…
        // made and is left alone (Remove would delete the wrong folder).
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: external, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders {
            guard let manifest = manifests(in: folder).first else { continue }
            guard manifest.id == folder.lastPathComponent else {
                registryLogger.error("model folder \(folder.lastPathComponent, privacy: .public) holds manifest '\(manifest.id, privacy: .public)'; skipped")
                continue
            }
            guard !seen.contains(manifest.id) else { continue }
            seen.insert(manifest.id)
            entries.append(ModelEntry(manifest: manifest, status: .installed, location: folder))
        }

        // Catalogue rows: listed with a source link, nothing to load.
        if let catalogue, let data = try? Data(contentsOf: catalogue) {
            do {
                let rows = try JSONDecoder().decode([ModelManifest].self, from: data)
                for row in rows.sorted(by: { $0.id < $1.id }) where !seen.contains(row.id) {
                    seen.insert(row.id)
                    entries.append(ModelEntry(manifest: row, status: .notInstalled, location: nil))
                }
            } catch {
                registryLogger.error("ModelCatalog.json unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        return entries
    }

    /// The `*.model.json` files of a folder, parsed, by id; one that
    /// doesn't parse is logged and skipped rather than hiding the rest.
    private static func manifests(in folder: URL) -> [ModelManifest] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".model.json") }
            .sorted()
        var found: [ModelManifest] = []
        for name in names {
            do {
                found.append(try ModelManifest.load(from: folder.appendingPathComponent(name)))
            } catch {
                registryLogger.error("manifest \(name, privacy: .public) skipped: \(String(describing: error), privacy: .public)")
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    /// Apple Vision's subject lift as a row: always there, nothing to
    /// install, the fallback when no subject model is.
    static let builtInVision = ModelEntry(
        manifest: ModelManifest(
            id: builtInSubjectID, displayName: "Apple Vision", purpose: "Subject masks with the model built into macOS",
            version: 1, kind: .subjectSegmentation,
            licence: ModelManifest.Licence(name: "Part of macOS",
                                           url: URL(string: "https://developer.apple.com/documentation/vision")!,
                                           commercialUse: true),
            sourceURL: URL(string: "https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest")!,
            sizeMB: 0, inputSize: 0, packages: []),
        status: .builtIn, location: nil)

    // MARK: - Defaults for new masks

    /// The subject model a NEW mask uses: the preferred id if installed,
    /// else the bundled subject model, else built-in Vision. Existing
    /// masks keep the model they name.
    public func defaultSubject() -> ModelEntry {
        let preferred = defaults.string(forKey: Self.subjectPreferenceKey) ?? Self.defaultSubjectID
        if let entry = entry(id: preferred), entry.isInstalled, entry.manifest.kind == .subjectSegmentation {
            return entry
        }
        if let bundled = entries(kind: .subjectSegmentation).first(where: { $0.status == .bundled }) {
            return bundled
        }
        return entry(id: Self.builtInSubjectID) ?? Self.builtInVision
    }

    /// The click-to-select model a NEW mask uses: the preferred id if
    /// installed, else the bundled one; nil with neither.
    public func defaultPrompted() -> ModelEntry? {
        let preferred = defaults.string(forKey: Self.promptedPreferenceKey) ?? Self.defaultPromptedID
        if let entry = entry(id: preferred), entry.isInstalled, entry.manifest.kind == .promptedSegmentation {
            return entry
        }
        return entries(kind: .promptedSegmentation).first { $0.status == .bundled }
    }

    // MARK: - Compute policy

    /// Lowest rank of {preference, manifest.computeUnits ?? .all,
    /// entry.status == .bundled ? .all : .cpuAndGPU}: the user can only
    /// take processors away, a manifest can keep its model off the Neural
    /// Engine, and an imported model never reaches it (a package Core ML's
    /// ANE compiler chokes on hangs the app; docs/Retouch.md §13). On a
    /// tie between cpuAndGPU and cpuAndNeuralEngine the manifest's choice
    /// wins, then the preference's.
    public func effectiveComputeUnits(for entry: ModelEntry,
                                      preference: MLComputeUnits = CoreMLStore.defaultComputeUnits) -> MLComputeUnits {
        let cap: ModelManifest.ComputeUnits = entry.status == .bundled ? .all : .cpuAndGPU
        let candidates = [entry.manifest.computeUnits ?? .all, ModelManifest.ComputeUnits(preference), cap]
        var best = candidates[0]
        for candidate in candidates.dropFirst() where candidate.rank < best.rank { best = candidate }
        return best.mlComputeUnits
    }

    // MARK: - Loaded models

    /// The loaded subject model for `id`, loading it on the first ask;
    /// nil when it is not installed or fails to load. Wave 1 fills this
    /// in (docs/Retouch.md §14); until then nothing loads through the
    /// registry, and `installed` still answers what is on disk.
    public func subject(id: String) async -> SubjectSegmenter? {
        if case .subject(let model)? = loaded(id: id) { return model }
        return nil
    }

    public func prompted(id: String) async -> SAM2Models? {
        if case .prompted(let model)? = loaded(id: id) { return model }
        return nil
    }

    public func semantic(id: String) async -> SegmentationModel? {
        if case .semantic(let model)? = loaded(id: id) { return model }
        return nil
    }

    func loaded(id: String) -> LoadedModel? {
        state.withLock { $0.loaded[id] }
    }

    /// Drops the shared reference to one model; anyone still using it
    /// keeps it alive until they finish.
    public func release(id: String) {
        state.withLock { _ = $0.loaded.removeValue(forKey: id) }
    }

    /// Memory warning: every loaded model goes.
    public func releaseAll() {
        state.withLock { $0.loaded.removeAll() }
    }
}
