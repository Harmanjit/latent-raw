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
    case badFileName(String), missingLabels(String), linkedFile(String, String), unreadableFolder(String, String)
    case packageWithoutManifest(String, besideUnreadable: Bool), manifestNamesOtherPackages(String)
    case archiveTooLarge(Int64), archiveTooManyEntries(Int)

    /// Plain sentences, each ending with what happened: the model was not
    /// added. Never a path: the file's name says which file, and the log
    /// keeps the rest.
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
        case .badFileName(let name):
            return "The manifest names \(name), which is not a plain file name, so the model was not added."
        case .missingLabels(let name):
            return "The labels file \(name) named in the manifest is not there, so the model was not added."
        case .linkedFile(let name, let file):
            return "The package \(name) holds a link (\(file)) instead of a file, so the model was not added."
        case .unreadableFolder(let name, let why):
            return "The folder \(name) could not be read (\(why)), so the model was not added."
        case .packageWithoutManifest(let name, let besideUnreadable):
            if besideUnreadable {
                return "No .model.json manifest was found inside \(name), and the folder around it could not be read "
                    + "(only what was chosen is open to Latent), so the model was not added. "
                    + "Choose the folder that holds the package and its manifest, or put the manifest inside the package."
            }
            return "No .model.json manifest was found beside \(name) or inside it, so the model was not added."
        case .manifestNamesOtherPackages(let name):
            return "The manifest inside \(name) names more packages than \(name) alone, so the model was not added. "
                + "Choose the folder that holds them all."
        case .archiveTooLarge(let limit):
            let size = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "The archive unpacks to more than \(size), far more than a model needs, so it was refused."
        case .archiveTooManyEntries(let count):
            return "The archive holds \(count) entries, far more than a model needs, so it was refused."
        }
    }
}

/// Add Model… (a folder, an .mlpackage or a .zip) and Remove
/// (docs/Retouch.md §5).
///
/// Everything an import reads comes from a folder the user chose, so it
/// is checked before it is trusted: the manifest's id names a folder and
/// a cache entry, the package and labels names must be plain file names
/// (they become path components), the package contents must hash to what
/// the manifest says with no link among them, an archive's entries must
/// stay inside it and unpack to a bounded size, and each package must
/// compile and answer to the feature names the manifest lists. The copy
/// is made into a hidden sibling of `external/<id>/` and only swapped in
/// once every check has passed, so a failed import leaves nothing behind
/// and a previous import of the same id keeps working; a copy a crash
/// abandoned is swept before the next import. The sandbox, not the hash,
/// is the security boundary (§2 A).
public enum ModelImporter {
    public struct Progress: Sendable {
        public var stage: String
        public var fraction: Double
        public init(stage: String, fraction: Double) {
            self.stage = stage
            self.fraction = fraction
        }
    }

    /// Where an import's files are once found: the manifest, the folder
    /// the manifest's package names resolve in, and the folder holding
    /// the labels file. For a package chosen on its own the sandbox
    /// grants only the package, so its manifest and labels travel
    /// inside it and are moved beside it on the way in.
    struct Source {
        var manifestFile: URL
        var packagesFolder: URL
        var sidecarFolder: URL
        var sidecarsInsidePackage: Bool
    }

    /// A folder, an .mlpackage or a .zip. Stages, validates, copies to
    /// external/<id>/, compile-checks one package at a time with
    /// .cpuAndGPU off the main actor and compares feature names (SAM
    /// decoder aliases allowed); deletes the copy and throws on any
    /// failure. An .mlpackage is looked up first through its folder (the
    /// manifest beside it) and, when that folder cannot be read or holds
    /// no manifest, through a manifest inside the package itself.
    public static func importModel(from url: URL, into registry: ModelRegistry = .shared,
                                   progress: (@Sendable (Progress) -> Void)? = nil) async throws -> ModelManifest {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ModelImportError.notFound(url.lastPathComponent)
        }
        var staged: URL?
        defer { if let staged { discardStaging(staged) } }
        let folder: URL?
        var besideUnreadable = false
        if !isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "zip" else { throw ModelImportError.noManifest }
            progress?(Progress(stage: "Unpacking \(url.lastPathComponent)…", fraction: 0.05))
            let unpacked = try stageArchive(url)
            staged = unpacked
            folder = modelFolder(inStaged: unpacked)
        } else if url.pathExtension.lowercased() == "mlpackage" {
            let parent = url.deletingLastPathComponent()
            let beside = try? manifestFiles(in: parent)
            besideUnreadable = beside == nil
            folder = (beside?.isEmpty == false) ? parent : nil
        } else {
            folder = url
        }

        progress?(Progress(stage: "Checking the manifest…", fraction: 0.15))
        let manifest: ModelManifest
        let source: Source
        if let folder {
            manifest = try validate(folder: folder, registry: registry)
            source = Source(manifestFile: try manifestFiles(in: folder)[0], packagesFolder: folder,
                            sidecarFolder: folder, sidecarsInsidePackage: false)
        } else {
            (manifest, source) = try validate(package: url, besideUnreadable: besideUnreadable, registry: registry)
        }
        let name = manifest.displayName

        // The copy: only what the manifest names, so nothing stray comes
        // along, into a hidden sibling the registry's listing skips.
        progress?(Progress(stage: "Copying \(name)…", fraction: 0.25))
        sweepAbandonedCopies(in: registry)
        let destination = registry.externalDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        let copy = registry.externalDirectory.appendingPathComponent(".importing-\(manifest.id)-\(UUID().uuidString)",
                                                                     isDirectory: true)
        func discardCopy() { try? fm.removeItem(at: copy) }
        do {
            try fm.createDirectory(at: copy, withIntermediateDirectories: true)
            try fm.copyItem(at: source.manifestFile, to: copy.appendingPathComponent("\(manifest.id).model.json"))
            for package in manifest.packages {
                let copied = copy.appendingPathComponent(package.name)
                try fm.copyItem(at: source.packagesFolder.appendingPathComponent(package.name), to: copied)
                if source.sidecarsInsidePackage {
                    // The installed layout is always manifest and labels
                    // beside the package, whichever way they came in.
                    try fm.removeItem(at: copied.appendingPathComponent(source.manifestFile.lastPathComponent))
                    if let labels = manifest.labelsFile { try fm.removeItem(at: copied.appendingPathComponent(labels)) }
                }
            }
            if let labels = manifest.labelsFile {
                try fm.copyItem(at: source.sidecarFolder.appendingPathComponent(labels), to: copy.appendingPathComponent(labels))
            }
        } catch {
            discardCopy()
            throw ModelImportError.copyFailed(reason(error))
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
                throw ModelImportError.compileFailed(package.name, reason(error))
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
            throw ModelImportError.copyFailed(reason(error))
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

    // MARK: - Leftovers

    /// How old a staging copy must be before a sweep takes it for
    /// abandoned: an import under way in another process (the tests run
    /// several) is never this old.
    public static let abandonedAge: TimeInterval = 3600

    /// Registries swept this process, by external folder; once is enough,
    /// and a second sweep during a live import would take its copy.
    private static let swept = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Removes what a crash or a force quit during an import left behind:
    /// `.importing-*` copies under the registry's external folder, which
    /// the listing skips as hidden, and `latent-import-<uuid>` staging
    /// folders in the temporary directory. Both are the hidden, growing
    /// kind of leftover nothing else ever shows. Only entries older than
    /// `abandonedAge` go, and only once per process for a registry.
    public static func sweepAbandonedCopies(in registry: ModelRegistry = .shared, olderThan age: TimeInterval = abandonedAge) {
        let key = registry.externalDirectory.standardizedFileURL.path
        let first = swept.withLock { $0.insert(key).inserted }
        guard first else { return }
        removeAbandoned(in: registry.externalDirectory, olderThan: age) { $0.hasPrefix(".importing-") }
        removeAbandoned(in: FileManager.default.temporaryDirectory, olderThan: age) { name in
            name.hasPrefix("latent-import-") && UUID(uuidString: String(name.dropFirst("latent-import-".count))) != nil
        }
    }

    private static func removeAbandoned(in directory: URL, olderThan age: TimeInterval, matching: (String) -> Bool) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        for entry in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])) ?? [] {
            guard matching(entry.lastPathComponent),
                  let values = try? entry.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                  let created = values.creationDate, Date().timeIntervalSince(created) > age else { continue }
            importLogger.notice("removing abandoned import copy \(entry.lastPathComponent, privacy: .public)")
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Checks

    /// A file-system error as one sentence naming the file, never its
    /// path: what the Settings row shows. The full error, paths and all,
    /// goes to the log. An error Foundation has no sentence for (one of
    /// this project's own enums) is described as it is; those name no
    /// path either.
    static func reason(_ error: Error) -> String {
        importLogger.error("import failed: \(String(describing: error), privacy: .private)")
        let nsError = error as NSError
        if nsError.localizedDescription.contains("(\(nsError.domain) error \(nsError.code).)") {
            return String(describing: error)
        }
        return nsError.localizedDescription
    }

    /// The checks without copying, for tests: exactly one *.model.json, id
    /// pattern, kind, not bundled/built-in, plain package and labels
    /// names, every package present with no stray files, hashes, the
    /// labels file present (and a list of strings for a semantic kind).
    /// Hidden files are neither counted as stray nor copied.
    static func validate(folder: URL, registry: ModelRegistry) throws -> ModelManifest {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ModelImportError.notFound(folder.lastPathComponent)
        }
        let manifests = try readableManifestFiles(in: folder)
        guard let manifestFile = manifests.first else { throw ModelImportError.noManifest }
        guard manifests.count == 1 else { throw ModelImportError.severalManifests }
        let manifest = try readManifest(manifestFile, registry: registry)

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
        let contents: [String]
        do {
            contents = try fm.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
        } catch {
            throw ModelImportError.unreadableFolder(folder.lastPathComponent, reason(error))
        }
        if let stray = contents.first(where: { !expected.contains($0) }) { throw ModelImportError.strayFile(stray) }

        for package in manifest.packages {
            try checkHash(of: package, at: folder.appendingPathComponent(package.name), ignoringRootFiles: [])
        }
        try checkLabels(of: manifest, in: folder)
        return manifest
    }

    /// The checks for a package chosen on its own, whose manifest sits at
    /// its root: exactly one *.model.json there, the same manifest checks
    /// as a folder, the manifest naming this package and no other (the
    /// sandbox grants nothing beside it), the hash with the manifest and
    /// labels at the root left out, and the labels file at the root too.
    static func validate(package url: URL, besideUnreadable: Bool, registry: ModelRegistry) throws -> (ModelManifest, Source) {
        let name = url.lastPathComponent
        let manifests = try readableManifestFiles(in: url)
        guard let manifestFile = manifests.first else {
            throw ModelImportError.packageWithoutManifest(name, besideUnreadable: besideUnreadable)
        }
        guard manifests.count == 1 else { throw ModelImportError.severalManifests }
        let manifest = try readManifest(manifestFile, registry: registry)
        guard manifest.packages.count == 1, manifest.packages[0].name == name else {
            throw ModelImportError.manifestNamesOtherPackages(name)
        }
        var sidecars: Set<String> = [manifestFile.lastPathComponent]
        if let labels = manifest.labelsFile { sidecars.insert(labels) }
        try checkHash(of: manifest.packages[0], at: url, ignoringRootFiles: sidecars)
        try checkLabels(of: manifest, in: url)
        let source = Source(manifestFile: manifestFile, packagesFolder: url.deletingLastPathComponent(),
                            sidecarFolder: url, sidecarsInsidePackage: true)
        return (manifest, source)
    }

    /// The manifest itself: decoded with its errors as sentences, of a
    /// kind this build knows, not bundled or built in, installable, and
    /// naming only plain file names (they become path components under
    /// the copy, so `..` in one would write outside it).
    static func readManifest(_ manifestFile: URL, registry: ModelRegistry) throws -> ModelManifest {
        // The kind before the decoder sees it: `ModelManifest` reports an
        // unknown one as a missing key, which would send the user looking
        // for the wrong thing.
        let data: Data
        do { data = try Data(contentsOf: manifestFile) } catch { throw ModelImportError.badManifest(reason(error)) }
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
        for package in manifest.packages where !ModelManifest.isPlainFileName(package.name) {
            throw ModelImportError.badFileName(package.name)
        }
        if let labels = manifest.labelsFile, !ModelManifest.isPlainFileName(labels) {
            throw ModelImportError.badFileName(labels)
        }
        return manifest
    }

    /// The package's content hash against the manifest's, with the hash
    /// errors as import sentences.
    static func checkHash(of package: ModelManifest.Package, at url: URL, ignoringRootFiles sidecars: Set<String>) throws {
        let digest: String
        do {
            digest = try PackageHash.sha256(ofPackageAt: url, ignoringRootFiles: sidecars)
        } catch PackageHashError.unexpectedFile(let file) {
            throw ModelImportError.strayFile("\(package.name)/\(file)")
        } catch PackageHashError.missingFile(let file) {
            throw ModelImportError.incompletePackage(package.name, file)
        } catch PackageHashError.symbolicLink(let file) {
            throw ModelImportError.linkedFile(package.name, file)
        }
        guard digest == package.sha256 else { throw ModelImportError.checksumMismatch(package.name) }
    }

    /// A named labels file must be a regular file in `folder`, whatever
    /// the kind (it is copied); a semantic kind must name one that reads
    /// as a list of strings, from this folder alone, never the bundled
    /// copy `CoreMLStore.json` would fall back to.
    static func checkLabels(of manifest: ModelManifest, in folder: URL) throws {
        if let labels = manifest.labelsFile {
            var labelsIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(labels).path, isDirectory: &labelsIsDirectory),
                  !labelsIsDirectory.boolValue else {
                throw manifest.kind == .semanticSegmentation ? ModelImportError.semanticWithoutLabels
                    : ModelImportError.missingLabels(labels)
            }
        }
        if manifest.kind == .semanticSegmentation {
            guard let labels = manifest.labelsFile,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(labels)),
                  (try? JSONDecoder().decode([String].self, from: data)) != nil else {
                throw ModelImportError.semanticWithoutLabels
            }
        }
    }

    /// The `*.model.json` files of a folder, sorted.
    static func manifestFiles(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".model.json") && !$0.hasPrefix(".") }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// `manifestFiles` with a listing failure as an import sentence.
    static func readableManifestFiles(in folder: URL) throws -> [URL] {
        do { return try manifestFiles(in: folder) } catch {
            throw ModelImportError.unreadableFolder(folder.lastPathComponent, reason(error))
        }
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

    /// What an archive may unpack to. A model is a manifest, a labels file
    /// and a few packages of three files each; the largest catalogue model
    /// is under half a gigabyte. The bound is enforced while ditto runs,
    /// because the sizes an archive declares are its own claim: a small
    /// archive of zeros unpacks to a thousand times its size.
    static let maximumUnpackedBytes: Int64 = 8 << 30
    static let maximumArchiveEntries = 10_000

    /// Copies `zip` into the container's temporary directory (the
    /// open-panel grant belongs to this process, not to a spawned tool),
    /// then zipinfo + ditto into a fresh staging folder there. The caller
    /// hands the folder to `discardStaging` when done.
    static func stageArchive(_ zip: URL, unpackedLimit: Int64 = maximumUnpackedBytes) throws -> URL {
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
            throw fail(.unzipFailed(reason(error)))
        }
        let entries: [String]
        do { entries = try listEntries(copy) } catch let error as ModelImportError { throw fail(error) }
        guard entries.count <= maximumArchiveEntries else { throw fail(.archiveTooManyEntries(entries.count)) }
        guard entriesAreSafe(entries) else { throw fail(.unsafeArchive) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", copy.path, unpacked.path]
        // ditto's complaints go to a file, not a pipe: a pipe nobody reads
        // fills after 64 KB and ditto then blocks on it for ever, with the
        // import waiting on ditto.
        let errorLog = root.appendingPathComponent("ditto.log")
        fm.createFile(atPath: errorLog.path, contents: nil)
        let errorHandle = FileHandle(forWritingAtPath: errorLog.path)
        process.standardError = errorHandle
        do { try process.run() } catch { throw fail(.unzipFailed(reason(error))) }
        var tooLarge = false
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.25)
            if allocatedSize(of: unpacked) > unpackedLimit {
                tooLarge = true
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        try? errorHandle?.close()
        // Checked once more after the fact: a fast disk can finish a small
        // bomb between two looks.
        if tooLarge || allocatedSize(of: unpacked) > unpackedLimit { throw fail(.archiveTooLarge(unpackedLimit)) }
        guard process.terminationStatus == 0 else {
            let log = (try? String(contentsOf: errorLog, encoding: .utf8)) ?? ""
            // One line for the Settings row, with the staging path ditto
            // echoes taken out; the whole log for the log.
            let first = log.split(whereSeparator: \.isNewline).first.map {
                String($0).replacingOccurrences(of: unpacked.path + "/", with: "").trimmingCharacters(in: .whitespaces)
            }
            importLogger.error("ditto failed: \(log, privacy: .private)")
            throw fail(.unzipFailed(first.flatMap { $0.isEmpty ? nil : $0 } ?? "ditto exited with status \(process.terminationStatus)"))
        }
        try? fm.removeItem(at: copy)
        try? fm.removeItem(at: errorLog)
        return unpacked
    }

    /// Bytes of every regular file under `folder`, as a running total
    /// while an archive unpacks.
    static func allocatedSize(of folder: URL) -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: []) {
            for case let file as URL in walk {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
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
