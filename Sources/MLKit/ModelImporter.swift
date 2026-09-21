import Foundation

public enum ModelImportError: Error, Equatable, CustomStringConvertible {
    case noManifest, severalManifests, badManifest(String), badID(String), unknownKind(String)
    case alreadyBuiltIn(String), notInstallable, missingPackage(String), strayFile(String)
    case checksumMismatch(String), featureMismatch(String), semanticWithoutLabels, unsafeArchive
    case unzipFailed(String), compileFailed(String, String)
    /// Wave 0 only: the step named is not built yet (docs/Retouch.md §14).
    case notYetImplemented(String)

    /// Plain sentences, each ending with what happened: the model was not
    /// added.
    public var description: String {
        switch self {
        case .noManifest:
            return "The folder has no .model.json manifest, so the model was not added."
        case .severalManifests:
            return "The folder holds more than one .model.json manifest, so the model was not added."
        case .badManifest(let why):
            return "The manifest could not be read (\(why)), so the model was not added."
        case .badID(let id):
            return "The model id '\(id)' is not lower-case letters, digits, dots and dashes, so the model was not added."
        case .unknownKind(let kind):
            return "This build does not know the model kind '\(kind)', so the model was not added."
        case .alreadyBuiltIn(let id):
            return "'\(id)' is built into Latent already, so the model was not added."
        case .notInstallable:
            return "The manifest carries no checksums (it is a catalogue row, not a converted model), so the model was not added."
        case .missingPackage(let name):
            return "The package \(name) named in the manifest is not in the folder, so the model was not added."
        case .strayFile(let name):
            return "The folder holds a file the manifest does not name (\(name)), so the model was not added."
        case .checksumMismatch(let name):
            return "The weights in \(name) don't match the checksum in the manifest, so the model was not added."
        case .featureMismatch(let name):
            return "The inputs and outputs of \(name) are not the ones the manifest names, so the model was not added."
        case .semanticWithoutLabels:
            return "A class model needs its labels file beside the package, so the model was not added."
        case .unsafeArchive:
            return "The archive holds paths that reach outside its folder, so it was refused."
        case .unzipFailed(let why):
            return "The archive could not be unpacked (\(why)), so the model was not added."
        case .compileFailed(let name, let why):
            return "Core ML could not compile \(name) (\(why)), so the model was not added."
        case .notYetImplemented(let step):
            return "\(step) is not built yet, so the model was not added."
        }
    }
}

/// Add Model… (a folder, an .mlpackage or a .zip) and Remove. The zip
/// helpers move here from OptionalModels.swift in Wave 1; until then the
/// two that already exist are called through it, and the rest throw
/// `.notYetImplemented` rather than pretending (docs/Retouch.md §5).
public enum ModelImporter {
    public struct Progress: Sendable {
        public var stage: String
        public var fraction: Double
        public init(stage: String, fraction: Double) {
            self.stage = stage
            self.fraction = fraction
        }
    }

    /// A folder, an .mlpackage (its folder must hold the manifest) or a
    /// .zip. Stages, validates, copies to external/<id>/, compile-checks
    /// one package at a time with .cpuAndGPU off the main actor and
    /// compares feature names (SAM decoder aliases allowed); deletes the
    /// copy and throws on any failure.
    public static func importModel(from url: URL, into registry: ModelRegistry = .shared,
                                   progress: (@Sendable (Progress) -> Void)? = nil) async throws -> ModelManifest {
        throw ModelImportError.notYetImplemented("Adding a model")
    }

    /// Deletes external/<id>/ and releases the loaded model. An id off the
    /// pattern names no folder Add Model… made, so nothing is touched.
    public static func remove(id: String, from registry: ModelRegistry = .shared) throws {
        guard ModelManifest.isValidID(id) else { throw ModelImportError.badID(id) }
        let folder = registry.externalDirectory.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        registry.release(id: id)
        registry.refresh()
    }

    /// Entry names an archive may contain: relative, no parent references,
    /// no absolute paths (ZipSafetyTests). Moves from ModelDownloader in
    /// Wave 1; the rule lives there until then.
    static func entriesAreSafe(_ entries: [String]) -> Bool {
        ModelDownloader.entriesAreSafe(entries)
    }

    static func listEntries(_ zip: URL) throws -> [String] {
        try ModelDownloader.listEntries(zip)
    }

    /// Copies `zip` into the container's temporary directory, then
    /// zipinfo + ditto into a fresh staging folder there.
    static func stageArchive(_ zip: URL) throws -> URL {
        throw ModelImportError.notYetImplemented("Unpacking a model archive")
    }

    /// The checks without copying, for tests: exactly one *.model.json, id
    /// pattern, kind, not bundled/built-in, every package present with no
    /// stray files, hashes, labels for a semantic kind.
    static func validate(folder: URL, registry: ModelRegistry) throws -> ModelManifest {
        throw ModelImportError.notYetImplemented("Checking a model folder")
    }
}
