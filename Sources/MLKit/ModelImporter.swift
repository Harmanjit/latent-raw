import Foundation
import CoreML
import os

private let importLogger = Logger(subsystem: "com.latent.app", category: "models")

public enum ModelImportError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case noManifest, severalManifests, badManifest(String), badID(String), unknownKind(String)
    case alreadyBuiltIn(String), notInstallable, missingPackage(String), incompletePackage(String, String)
    case strayFile(String), checksumMismatch(String), featureMismatch(String), semanticWithoutLabels
    case unsafeArchive, unzipFailed(String), copyFailed(String), compileFailed(String, String)

    /// Plain sentences, each ending with what happened: the model was not
    /// added.
    public var description: String {
        switch self {
        case .notFound(let name):
            return "There is nothing at \(name), so the model was not added."
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
        case .incompletePackage(let name, let file):
            return "The package \(name) is missing \(file), so the model was not added."
        case .strayFile(let name):
            return "The folder holds a file the manifest does not name (\(name)), so the model was not added."
        case .checksumMismatch(let name):
            return "The weights in \(name) don't match the checksum in the manifest, so the model was not added."
        case .featureMismatch(let name):
            return "The inputs and outputs of \(name) are not the ones the manifest names, so the model was not added."
        case .semanticWithoutLabels:
            return "A class model needs a readable labels file beside the package, so the model was not added."
        case .unsafeArchive:
            return "The archive holds paths that reach outside its folder, so it was refused."
        case .unzipFailed(let why):
            return "The archive could not be unpacked (\(why)), so the model was not added."
        case .copyFailed(let why):
            return "The model could not be copied into place (\(why)), so it was not added."
        case .compileFailed(let name, let why):
            return "Core ML could not compile \(name) (\(why)), so the model was not added."
        }
    }
}

/// Add Model… (a folder, an .mlpackage or a .zip) and Remove
/// (docs/Retouch.md §5).
///
/// Everything an import reads comes from a folder the user chose, so it
/// is checked before it is trusted: the manifest's id names a folder and
/// a cache entry, the package contents must hash to what the manifest
/// says, an archive's entries must stay inside it, and each package must
/// compile and answer to the feature names the manifest lists. The copy
/// is made into a hidden sibling of `external/<id>/` and only swapped in
/// once every check has passed, so a failed import leaves nothing behind
/// and a previous import of the same id keeps working. The sandbox, not
/// the hash, is the security boundary (§2 A).
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
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ModelImportError.notFound(url.lastPathComponent)
        }
        var staged: URL?
        defer { if let staged { discardStaging(staged) } }
        let folder: URL
        if !isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "zip" else { throw ModelImportError.noManifest }
            progress?(Progress(stage: "Unpacking \(url.lastPathComponent)…", fraction: 0.05))
            let unpacked = try stageArchive(url)
            staged = unpacked
            folder = modelFolder(inStaged: unpacked)
        } else if url.pathExtension.lowercased() == "mlpackage" {
            folder = url.deletingLastPathComponent()
        } else {
            folder = url
        }

        progress?(Progress(stage: "Checking the manifest…", fraction: 0.15))
        let manifest = try validate(folder: folder, registry: registry)
        let name = manifest.displayName

        // The copy: only what the manifest names, so nothing stray comes
        // along, into a hidden sibling the registry's listing skips.
        progress?(Progress(stage: "Copying \(name)…", fraction: 0.25))
        let destination = registry.externalDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        let copy = registry.externalDirectory.appendingPathComponent(".importing-\(manifest.id)-\(UUID().uuidString)",
                                                                     isDirectory: true)
        func discardCopy() { try? fm.removeItem(at: copy) }
        do {
            try fm.createDirectory(at: copy, withIntermediateDirectories: true)
            let manifestFile = try manifestFiles(in: folder)[0]
            try fm.copyItem(at: manifestFile, to: copy.appendingPathComponent("\(manifest.id).model.json"))
            for package in manifest.packages {
                try fm.copyItem(at: folder.appendingPathComponent(package.name), to: copy.appendingPathComponent(package.name))
            }
            if let labels = manifest.labelsFile {
                try fm.copyItem(at: folder.appendingPathComponent(labels), to: copy.appendingPathComponent(labels))
            }
        } catch {
            discardCopy()
            throw ModelImportError.copyFailed(String(describing: error))
        }

        // Compile check, one package at a time so a large model never
        // holds two compiles' memory; off the main actor because Core ML
        // compiles in-process. Never .all: the Neural Engine compiler
        // hangs on some graphs (CoreMLStore.defaultComputeUnits).
        for (index, package) in manifest.packages.enumerated() {
            let fraction = 0.3 + 0.65 * Double(index) / Double(max(manifest.packages.count, 1))
            progress?(Progress(stage: "Checking \(package.name)…", fraction: fraction))
            let names: (inputs: Set<String>, outputs: Set<String>)
            do {
                names = try await Task.detached(priority: .userInitiated) {
                    let model = try await CoreMLStore.load(package, of: manifest, at: copy, computeUnits: .cpuAndGPU)
                    return (Set(model.modelDescription.inputDescriptionsByName.keys),
                            Set(model.modelDescription.outputDescriptionsByName.keys))
                }.value
            } catch {
                discardCopy()
                throw ModelImportError.compileFailed(package.name, String(describing: error))
            }
            guard featuresMatch(package.inputNames, names.inputs), featuresMatch(package.outputNames, names.outputs) else {
                discardCopy()
                throw ModelImportError.featureMismatch(package.name)
            }
        }

        // Into place: a previous import of this id goes, and anything
        // loaded from it with it.
        progress?(Progress(stage: "Adding \(name)…", fraction: 0.97))
        do {
            registry.release(id: manifest.id)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: copy, to: destination)
        } catch {
            discardCopy()
            registry.refresh()
            throw ModelImportError.copyFailed(String(describing: error))
        }
        registry.refresh()
        importLogger.notice("added model \(manifest.id, privacy: .public) (\(manifest.sizeMB) MB)")
        progress?(Progress(stage: "Added \(name)", fraction: 1))
        return manifest
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

    // MARK: - Checks

    /// The checks without copying, for tests: exactly one *.model.json, id
    /// pattern, kind, not bundled/built-in, every package present with no
    /// stray files, hashes, labels for a semantic kind. Hidden files are
    /// neither counted as stray nor copied.
    static func validate(folder: URL, registry: ModelRegistry) throws -> ModelManifest {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ModelImportError.notFound(folder.lastPathComponent)
        }
        let manifests = try manifestFiles(in: folder)
        guard let manifestFile = manifests.first else { throw ModelImportError.noManifest }
        guard manifests.count == 1 else { throw ModelImportError.severalManifests }

        // The kind before the decoder sees it: `ModelManifest` reports an
        // unknown one as a missing key, which would send the user looking
        // for the wrong thing.
        let data: Data
        do { data = try Data(contentsOf: manifestFile) } catch { throw ModelImportError.badManifest(String(describing: error)) }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let kind = object["kind"] as? String, ModelManifest.Kind(rawValue: kind) == nil {
            throw ModelImportError.unknownKind(kind)
        }
        let manifest: ModelManifest
        do {
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch ManifestError.badID(let id) {
            throw ModelImportError.badID(id)
        } catch let error as ManifestError {
            throw ModelImportError.badManifest(error.description)
        } catch {
            throw ModelImportError.badManifest(String(describing: error))
        }

        if let existing = registry.entry(id: manifest.id), existing.status == .bundled || existing.status == .builtIn {
            throw ModelImportError.alreadyBuiltIn(manifest.id)
        }
        guard manifest.isInstallable, !manifest.packages.isEmpty else { throw ModelImportError.notInstallable }

        // Every package present, nothing else in the folder.
        var expected: Set<String> = [manifestFile.lastPathComponent]
        for package in manifest.packages {
            var packageIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.appendingPathComponent(package.name).path, isDirectory: &packageIsDirectory),
                  packageIsDirectory.boolValue else {
                throw ModelImportError.missingPackage(package.name)
            }
            expected.insert(package.name)
        }
        if let labels = manifest.labelsFile { expected.insert(labels) }
        let contents = try fm.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
        if let stray = contents.first(where: { !expected.contains($0) }) { throw ModelImportError.strayFile(stray) }

        for package in manifest.packages {
            let digest: String
            do {
                digest = try PackageHash.sha256(ofPackageAt: folder.appendingPathComponent(package.name))
            } catch PackageHashError.unexpectedFile(let file) {
                throw ModelImportError.strayFile("\(package.name)/\(file)")
            } catch PackageHashError.missingFile(let file) {
                throw ModelImportError.incompletePackage(package.name, file)
            }
            guard digest == package.sha256 else { throw ModelImportError.checksumMismatch(package.name) }
        }

        if manifest.kind == .semanticSegmentation {
            guard let labels = manifest.labelsFile,
                  CoreMLStore.json(labels, in: folder, as: [String].self) != nil else {
                throw ModelImportError.semanticWithoutLabels
            }
        }
        return manifest
    }

    /// The `*.model.json` files of a folder, sorted.
    static func manifestFiles(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".model.json") && !$0.hasPrefix(".") }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Apple's SAM 2 decoder names its embedding inputs in the singular
    /// while the prompt encoder's outputs are plural; a manifest may use
    /// either (`SAM2Session` accepts both).
    static let decoderAliases = ["sparse_embeddings": "sparse_embedding", "dense_embeddings": "dense_embedding"]

    /// Whether the manifest's names are the model's, aliases allowed. An
    /// empty manifest list (written without coremltools) compares nothing.
    static func featuresMatch(_ manifest: [String], _ model: Set<String>) -> Bool {
        guard !manifest.isEmpty else { return true }
        func canonical(_ names: some Sequence<String>) -> Set<String> { Set(names.map { decoderAliases[$0] ?? $0 }) }
        return canonical(manifest) == canonical(model)
    }

    // MARK: - Archives

    /// Entry names an archive may contain: relative, no parent references,
    /// no absolute paths. Checked before anything is written, so a zip
    /// that tries to climb out of its folder is refused whole.
    static func entriesAreSafe(_ entries: [String]) -> Bool {
        for e in entries {
            let name = e.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            if name.hasPrefix("/") || name.hasPrefix("\\") || name.contains("../") || name.hasPrefix("..")
                || name.contains("/../") || name.hasSuffix("/..") || name.contains("\u{0}") {
                return false
            }
        }
        return true
    }

    static func listEntries(_ zip: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", zip.path]
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModelImportError.unzipFailed("could not list the archive") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Copies `zip` into the container's temporary directory (the
    /// open-panel grant belongs to this process, not to a spawned tool),
    /// then zipinfo + ditto into a fresh staging folder there. The caller
    /// hands the folder to `discardStaging` when done.
    static func stageArchive(_ zip: URL) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-import-\(UUID().uuidString)", isDirectory: true)
        let copy = root.appendingPathComponent("archive.zip")
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        func fail(_ error: ModelImportError) -> ModelImportError {
            try? fm.removeItem(at: root)
            return error
        }
        do {
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try fm.copyItem(at: zip, to: copy)
        } catch {
            throw fail(.unzipFailed(String(describing: error)))
        }
        let entries: [String]
        do { entries = try listEntries(copy) } catch let error as ModelImportError { throw fail(error) }
        guard entriesAreSafe(entries) else { throw fail(.unsafeArchive) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", copy.path, unpacked.path]
        let err = Pipe(); process.standardError = err
        do { try process.run() } catch { throw fail(.unzipFailed(String(describing: error))) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw fail(.unzipFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        try? fm.removeItem(at: copy)
        return unpacked
    }

    /// Removes what `stageArchive` made.
    static func discardStaging(_ unpacked: URL) {
        try? FileManager.default.removeItem(at: unpacked.deletingLastPathComponent())
    }

    /// The folder to validate inside an unpacked archive: the archive's
    /// root when the manifest sits there, else its one folder (a zip made
    /// of the model's folder, as `ditto --keepParent` writes it).
    static func modelFolder(inStaged unpacked: URL) -> URL {
        if let manifests = try? manifestFiles(in: unpacked), !manifests.isEmpty { return unpacked }
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { $0.lastPathComponent != "__MACOSX" }
        return folders.count == 1 ? folders[0] : unpacked
    }
}
