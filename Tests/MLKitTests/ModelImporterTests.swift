import XCTest
import os
@testable import MLKit

/// Add Model… against a temp registry (docs/Retouch.md §5, §11): a real
/// import of the bundled NAFNet package copied to a temp folder with a
/// manifest written here, every refusal leaving nothing behind, and the
/// zip path.
final class ModelImporterTests: XCTestCase {
    static let id = "nafnet-import-test"
    static let packageName = "NAFNet_SIDD_width32.mlpackage"

    var root: URL!
    var external: URL!
    var suite: String!
    var defaults: UserDefaults!
    var registry: ModelRegistry!

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("latent-import-test-\(UUID().uuidString)")
        external = root.appendingPathComponent("external")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        suite = "latent-importer-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        // The real bundle and catalogue, so "already bundled" can be tested; only the external folder is ours.
        registry = ModelRegistry(bundled: CoreMLStore.modelsDirectory, external: external,
                                 catalogue: CoreMLStore.catalogueURL, defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        let cache = CoreMLStore.cacheDirectory
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [] where entry.hasPrefix(Self.id + "-") {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent(entry))
        }
    }

    // MARK: - Fixtures

    /// A folder holding a copy of the bundled NAFNet package and a
    /// manifest written here, its hash computed by `PackageHash` (nil
    /// `sha256` computes it; "null" writes a catalogue row).
    func makeFolder(id: String = ModelImporterTests.id, kind: String = "denoise", sha256: String? = nil,
                    inputNames: [String] = ["image"], outputNames: [String] = ["denoised"],
                    labelsFile: String? = nil, copyPackage: Bool = true,
                    corruptModel: Bool = false) throws -> URL {
        let bundled = try XCTUnwrap(CoreMLStore.modelsDirectory).appendingPathComponent(Self.packageName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundled.path), "NAFNet not bundled")
        let folder = root.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent(Self.packageName)
        if copyPackage {
            try FileManager.default.copyItem(at: bundled, to: package)
            if corruptModel {
                try Data(repeating: 0x42, count: 4096).write(to: package.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"))
            }
        }
        let hash: String
        if let sha256 {
            hash = sha256 == "null" ? "null" : "\"\(sha256)\""
        } else if copyPackage {
            hash = "\"\(try PackageHash.sha256(ofPackageAt: package))\""
        } else {
            hash = "\"\(String(repeating: "0", count: 64))\""
        }
        let labels = labelsFile.map { ", \"labelsFile\": \"\($0)\"" } ?? ""
        let json = """
        {"id": "\(id)", "displayName": "NAFNet Import Test", "purpose": "Testing", "version": 1, "kind": "\(kind)",
         "licence": {"name": "MIT", "url": "https://example.org/L", "commercialUse": true},
         "sourceURL": "https://example.org/\(id)", "sizeMB": 59, "inputSize": 256,
         "packages": [{"name": "\(Self.packageName)", "sha256": \(hash),
                       "inputNames": \(inputNames), "outputNames": \(outputNames)}]\(labels)}
        """
        try json.write(to: folder.appendingPathComponent("\(id).model.json"), atomically: true, encoding: .utf8)
        return folder
    }

    func zip(_ folder: URL, keepParent: Bool) throws -> URL {
        let zip = root.appendingPathComponent("\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return zip
    }

    func externalContents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: external.path)) ?? []).sorted()
    }

    /// Temp folders `stageArchive` has not cleaned up.
    func stagingFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("latent-import-") && !$0.hasPrefix("latent-import-test-") }
    }

    /// The import must throw `expected` and leave the external folder as
    /// it was (empty unless said otherwise).
    func assertRefused(_ url: URL, _ check: (ModelImportError) -> Bool, leaving: [String] = [],
                       into registry: ModelRegistry? = nil,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let staging = stagingFolders()
        do {
            _ = try await ModelImporter.importModel(from: url, into: registry ?? self.registry)
            XCTFail("the model was added", file: file, line: line)
        } catch let error as ModelImportError {
            XCTAssertTrue(check(error), "\(error)", file: file, line: line)
            XCTAssertTrue(error.description.hasSuffix("."), "a plain sentence: \(error.description)", file: file, line: line)
            XCTAssertFalse(error.description.contains("Error Domain"), "no NSError dump: \(error.description)", file: file, line: line)
            XCTAssertFalse(error.description.contains(root.path), "no path: \(error.description)", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
        XCTAssertEqual(externalContents(), leaving, "nothing left behind", file: file, line: line)
        XCTAssertEqual(stagingFolders(), staging, "no staging left behind", file: file, line: line)
    }

    // MARK: - The real import

    func testRealImportOfTheBundledNAFNet() async throws {
        let folder = try makeFolder()
        let progress = OSAllocatedUnfairLock<[ModelImporter.Progress]>(initialState: [])
        let t0 = Date()
        let manifest = try await ModelImporter.importModel(from: folder, into: registry) { p in
            progress.withLock { $0.append(p) }
        }
        print(String(format: "IMPORT NAFNet in %.1f s", Date().timeIntervalSince(t0)))
        XCTAssertEqual(manifest.id, Self.id)
        XCTAssertEqual(manifest.kind, .denoise)

        let installed = external.appendingPathComponent(Self.id)
        XCTAssertEqual(externalContents(), [Self.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted(),
                       [Self.packageName, "\(Self.id).model.json"].sorted())
        XCTAssertEqual(try PackageHash.sha256(ofPackageAt: installed.appendingPathComponent(Self.packageName)),
                       manifest.packages[0].sha256)
        let entry = try XCTUnwrap(registry.entry(id: Self.id))
        XCTAssertEqual(entry.status, .installed)
        XCTAssertEqual(entry.location?.resolvingSymlinksInPath().path, installed.resolvingSymlinksInPath().path)
        XCTAssertEqual(registry.installed(ModelRef(stored: "\(Self.id)@1"))?.id, Self.id)

        // The compile check leaves the compiled copy behind for the first real use.
        let key = "\(Self.id)-\(Self.packageName)-\(manifest.packages[0].sha256!.prefix(16)).mlmodelc"
        XCTAssertTrue(FileManager.default.fileExists(atPath: CoreMLStore.cacheDirectory.appendingPathComponent(key).path))

        let stages = progress.withLock { $0 }
        XCTAssertEqual(stages.last?.fraction, 1)
        XCTAssertEqual(stages.map(\.fraction), stages.map(\.fraction).sorted(), "progress never goes backwards")
        XCTAssertTrue(stages.contains { $0.stage == "Checking \(Self.packageName)…" }, "\(stages.map(\.stage))")
        XCTAssertEqual(stages.last?.stage, "Added NAFNet Import Test")

        // The .mlpackage itself can be chosen; its folder holds the manifest. This replaces the first import.
        let again = try await ModelImporter.importModel(from: folder.appendingPathComponent(Self.packageName), into: registry)
        XCTAssertEqual(again.id, Self.id)
        XCTAssertEqual(externalContents(), [Self.id], "replaced, not duplicated, no staging copy left")
        XCTAssertEqual(registry.entry(id: Self.id)?.status, .installed)

        try ModelImporter.remove(id: Self.id, from: registry)
        XCTAssertNil(registry.entry(id: Self.id))
        XCTAssertEqual(externalContents(), [])
    }

    /// A zip of the folder (with or without the folder itself as the
    /// archive's root) imports like the folder; the archive is copied and
    /// unpacked in the container's temporary directory and cleaned up.
    func testZipImport() async throws {
        let folder = try makeFolder()
        let staging = stagingFolders()
        let withParent = try zip(folder, keepParent: true)
        let manifest = try await ModelImporter.importModel(from: withParent, into: registry)
        XCTAssertEqual(manifest.id, Self.id)
        XCTAssertEqual(externalContents(), [Self.id])
        XCTAssertEqual(stagingFolders(), staging)

        let flat = try zip(folder, keepParent: false)
        let again = try await ModelImporter.importModel(from: flat, into: registry)
        XCTAssertEqual(again.id, Self.id)
        XCTAssertEqual(externalContents(), [Self.id])
        XCTAssertEqual(stagingFolders(), staging)
        try ModelImporter.remove(id: Self.id, from: registry)
    }

    // MARK: - Refusals

    func testEveryRefusalLeavesNothingBehind() async throws {
        let fm = FileManager.default

        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        await assertRefused(empty) { $0 == .noManifest }

        await assertRefused(root.appendingPathComponent("nowhere")) { $0 == .notFound("nowhere") }

        let text = root.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        await assertRefused(text) { $0 == .noManifest }

        let two = try makeFolder()
        try fm.copyItem(at: two.appendingPathComponent("\(Self.id).model.json"), to: two.appendingPathComponent("other.model.json"))
        await assertRefused(two) { $0 == .severalManifests }

        await assertRefused(try makeFolder(id: "Bad_ID")) { $0 == .badID("Bad_ID") }
        await assertRefused(try makeFolder(kind: "magic")) { $0 == .unknownKind("magic") }
        // The built-in id has capitals, so the id pattern refuses it before
        // anything else does; a bundled id is refused as built in.
        await assertRefused(try makeFolder(id: ModelRegistry.builtInSubjectID, kind: "subjectSegmentation")) {
            $0 == .badID(ModelRegistry.builtInSubjectID)
        }
        let bundledFolder = root.appendingPathComponent("bundled")
        try fm.createDirectory(at: bundledFolder, withIntermediateDirectories: true)
        try ModelRegistryTests.json(id: "fake-bundled", kind: "subjectSegmentation")
            .write(to: bundledFolder.appendingPathComponent("fake-bundled.model.json"), atomically: true, encoding: .utf8)
        let withBundled = ModelRegistry(bundled: bundledFolder, external: external, catalogue: nil, defaults: defaults)
        await assertRefused(try makeFolder(id: "fake-bundled", kind: "subjectSegmentation"),
                            { $0 == .alreadyBuiltIn("fake-bundled") }, into: withBundled)
        if registry.entry(id: "birefnet-lite")?.status == .bundled {
            await assertRefused(try makeFolder(id: "birefnet-lite", kind: "subjectSegmentation")) { $0 == .alreadyBuiltIn("birefnet-lite") }
        }
        await assertRefused(try makeFolder(sha256: "null")) { $0 == .notInstallable }
        await assertRefused(try makeFolder(copyPackage: false)) { $0 == .missingPackage(Self.packageName) }

        let stray = try makeFolder()
        try "notes".write(to: stray.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        await assertRefused(stray) { $0 == .strayFile("README.txt") }

        let strayInside = try makeFolder()
        try Data([1]).write(to: strayInside.appendingPathComponent("\(Self.packageName)/Data/com.apple.CoreML/weights/extra.bin"))
        await assertRefused(strayInside) { $0 == .strayFile("\(Self.packageName)/Data/com.apple.CoreML/weights/extra.bin") }

        let incomplete = try makeFolder()
        try fm.removeItem(at: incomplete.appendingPathComponent("\(Self.packageName)/Manifest.json"))
        await assertRefused(incomplete) { $0 == .incompletePackage(Self.packageName, "Manifest.json") }

        await assertRefused(try makeFolder(sha256: String(repeating: "0", count: 64))) { $0 == .checksumMismatch(Self.packageName) }

        await assertRefused(try makeFolder(kind: "semanticSegmentation")) { $0 == .semanticWithoutLabels }
        await assertRefused(try makeFolder(kind: "semanticSegmentation", labelsFile: "labels.json")) { $0 == .semanticWithoutLabels }
        let badLabels = try makeFolder(kind: "semanticSegmentation", labelsFile: "labels.json")
        try "not a list".write(to: badLabels.appendingPathComponent("labels.json"), atomically: true, encoding: .utf8)
        await assertRefused(badLabels) { $0 == .semanticWithoutLabels }
        // A labels name matching a bundled file must not pass on the
        // bundled copy: the check reads this folder alone. And a missing
        // labels file is missing for any kind, before the copy step
        // stumbles on it.
        await assertRefused(try makeFolder(kind: "semanticSegmentation",
                                           labelsFile: "SegFormer_segformer_b2_finetuned_ade_512_512.labels.json")) {
            $0 == .semanticWithoutLabels
        }
        await assertRefused(try makeFolder(labelsFile: "labels.json")) { $0 == .missingLabels("labels.json") }

        // Past the folder checks: the compile check and feature names.
        await assertRefused(try makeFolder(inputNames: ["picture"])) { $0 == .featureMismatch(Self.packageName) }
        await assertRefused(try makeFolder(outputNames: ["denoised", "extra"])) { $0 == .featureMismatch(Self.packageName) }
        await assertRefused(try makeFolder(corruptModel: true)) {
            if case .compileFailed(let name, _) = $0 { return name == Self.packageName }
            return false
        }
    }

    /// A package or labels name with a path in it would be appended to
    /// the staging copy's path, so `../<id>` would land the copy straight
    /// in external/<id>/ before the compile check and stay there when the
    /// check fails. Refused whole, from a folder and from a zip.
    func testNamesWithPathsAreRefused() async throws {
        let fm = FileManager.default
        // What `../<id>` would copy: a folder beside the source named as
        // the model, holding a manifest, with the package's model corrupt
        // so the compile check fails after the copy.
        let planted = root.appendingPathComponent(Self.id)
        try fm.createDirectory(at: planted, withIntermediateDirectories: true)
        let climbing = try makeFolder(kind: "subjectSegmentation", labelsFile: "../\(Self.id)", corruptModel: true)
        try fm.copyItem(at: climbing.appendingPathComponent("\(Self.id).model.json"),
                        to: planted.appendingPathComponent("\(Self.id).model.json"))
        await assertRefused(climbing) { $0 == .badFileName("../\(Self.id)") }
        await assertRefused(try zip(climbing, keepParent: true)) { $0 == .badFileName("../\(Self.id)") }

        let packageNamed = try makeFolder()
        let manifestFile = packageNamed.appendingPathComponent("\(Self.id).model.json")
        let json = try String(contentsOf: manifestFile, encoding: .utf8)
            .replacingOccurrences(of: "\"name\": \"\(Self.packageName)\"", with: "\"name\": \"../x\"")
        try json.write(to: manifestFile, atomically: true, encoding: .utf8)
        await assertRefused(packageNamed) { $0 == .badFileName("../x") }
        for bad in ["", ".", "..", "a/b", "a\\b", "with space", "ümlaut"] {
            XCTAssertFalse(ModelManifest.isPlainFileName(bad), bad)
        }
        for good in ["A.mlpackage", "labels.json", "x-y_z.1", ".hidden"] {
            XCTAssertTrue(ModelManifest.isPlainFileName(good), good)
        }
    }

    /// A link inside a package reads as its target, so the hash would pin
    /// bytes the copy does not carry; refused before anything is copied.
    func testLinkedFileInAPackageIsRefused() async throws {
        let fm = FileManager.default
        let folder = try makeFolder()
        let weights = folder.appendingPathComponent("\(Self.packageName)/Data/com.apple.CoreML/weights/weight.bin")
        let elsewhere = root.appendingPathComponent("weight.bin")
        try fm.moveItem(at: weights, to: elsewhere)
        try fm.createSymbolicLink(at: weights, withDestinationURL: elsewhere)
        await assertRefused(folder) { $0 == .linkedFile(Self.packageName, "Data/com.apple.CoreML/weights/weight.bin") }
    }

    /// A folder that exists but cannot be listed (the sandbox grants the
    /// chosen item, not its parent) is refused with a sentence, never the
    /// file system's dump with the path in it.
    func testUnlistableFolderIsASentence() async throws {
        let fm = FileManager.default
        let folder = try makeFolder()
        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        await assertRefused(folder) {
            if case .unreadableFolder(let name, let why) = $0 { return name == folder.lastPathComponent && !why.isEmpty }
            return false
        }
    }

    /// An .mlpackage chosen on its own: the sandbox opens the package and
    /// nothing beside it, so its manifest (and labels) travel inside it
    /// and are moved beside it on the way in. The folder around it is
    /// made unlistable here, as the sandbox leaves it.
    func testPackageAloneWithItsManifestInside() async throws {
        let fm = FileManager.default
        let folder = try makeFolder(labelsFile: "labels.json")
        let package = folder.appendingPathComponent(Self.packageName)
        try fm.moveItem(at: folder.appendingPathComponent("\(Self.id).model.json"),
                        to: package.appendingPathComponent("\(Self.id).model.json"))
        try "[\"a\"]".write(to: package.appendingPathComponent("labels.json"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertNil(try? fm.contentsOfDirectory(atPath: folder.path), "the folder around the package is out of reach")

        let manifest = try await ModelImporter.importModel(from: package, into: registry)
        XCTAssertEqual(manifest.id, Self.id)
        let installed = external.appendingPathComponent(Self.id)
        XCTAssertEqual(externalContents(), [Self.id])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: installed.path).sorted(),
                       [Self.packageName, "labels.json", "\(Self.id).model.json"].sorted(), "sidecars beside the package")
        XCTAssertEqual(try PackageHash.sha256(ofPackageAt: installed.appendingPathComponent(Self.packageName)),
                       manifest.packages[0].sha256, "nothing left inside the package")
        XCTAssertEqual(registry.entry(id: Self.id)?.status, .installed)
        try ModelImporter.remove(id: Self.id, from: registry)
    }

    /// The package-alone refusals say where a manifest was looked for.
    func testPackageAloneRefusals() async throws {
        let fm = FileManager.default
        let folder = try makeFolder()
        let package = folder.appendingPathComponent(Self.packageName)
        try fm.removeItem(at: folder.appendingPathComponent("\(Self.id).model.json"))
        await assertRefused(package) { $0 == .packageWithoutManifest(Self.packageName, besideUnreadable: false) }
        XCTAssertTrue(ModelImportError.packageWithoutManifest("P.mlpackage", besideUnreadable: false).description
            .contains("beside P.mlpackage or inside it"))

        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        await assertRefused(package) { $0 == .packageWithoutManifest(Self.packageName, besideUnreadable: true) }
        let sentence = ModelImportError.packageWithoutManifest("P.mlpackage", besideUnreadable: true).description
        XCTAssertTrue(sentence.contains("inside P.mlpackage") && sentence.contains("could not be read"), sentence)

        // A manifest inside naming another package besides this one.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let two = try makeFolder()
        let twoManifest = two.appendingPathComponent("\(Self.id).model.json")
        let json = try String(contentsOf: twoManifest, encoding: .utf8)
            .replacingOccurrences(of: "\"packages\": [", with: "\"packages\": [{\"name\": \"Other.mlpackage\", \"sha256\": \"00\"}, ")
        try json.write(to: two.appendingPathComponent("\(Self.packageName)/\(Self.id).model.json"), atomically: true, encoding: .utf8)
        try fm.removeItem(at: twoManifest)
        await assertRefused(two.appendingPathComponent(Self.packageName)) { $0 == .manifestNamesOtherPackages(Self.packageName) }
    }

    /// A crash during the compile check leaves the hidden staging copy
    /// under external/ (and an archive's staging folder in the temporary
    /// directory); the sweep takes those old enough to be abandoned and
    /// leaves a fresh one, which may be another import under way.
    func testAbandonedCopiesAreSwept() throws {
        let fm = FileManager.default
        let old = Date(timeIntervalSinceNow: -2 * ModelImporter.abandonedAge)
        let stale = external.appendingPathComponent(".importing-\(Self.id)-\(UUID().uuidString)")
        let fresh = external.appendingPathComponent(".importing-\(Self.id)-\(UUID().uuidString)")
        let staleStaging = fm.temporaryDirectory.appendingPathComponent("latent-import-\(UUID().uuidString)")
        let freshStaging = fm.temporaryDirectory.appendingPathComponent("latent-import-\(UUID().uuidString)")
        let named = fm.temporaryDirectory.appendingPathComponent("latent-import-test-\(UUID().uuidString)")
        for url in [stale, fresh, staleStaging, freshStaging, named] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        addTeardownBlock { for url in [staleStaging, freshStaging, named] { try? FileManager.default.removeItem(at: url) } }
        for url in [stale, staleStaging, named] { try fm.setAttributes([.creationDate: old], ofItemAtPath: url.path) }

        ModelImporter.sweepAbandonedCopies(in: registry)
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "an old copy goes")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a fresh copy may be an import under way")
        XCTAssertFalse(fm.fileExists(atPath: staleStaging.path), "an old staging folder goes")
        XCTAssertTrue(fm.fileExists(atPath: freshStaging.path))
        XCTAssertTrue(fm.fileExists(atPath: named.path), "only latent-import-<uuid> is the importer's")
        // Once per process for a registry: a second call leaves a copy
        // that has aged since (an import still running).
        try fm.setAttributes([.creationDate: old], ofItemAtPath: fresh.path)
        ModelImporter.sweepAbandonedCopies(in: registry)
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
    }

    /// File-system errors reach the Settings row as one sentence naming
    /// the file, never the domain, code and full path.
    func testReasonIsASentenceWithoutAPath() {
        let missing = root.appendingPathComponent("nowhere.mlpackage")
        do {
            try FileManager.default.copyItem(at: missing, to: root.appendingPathComponent("copy"))
            XCTFail("copied nothing")
        } catch {
            let why = ModelImporter.reason(error)
            XCTAssertTrue(why.contains("nowhere.mlpackage"), why)
            XCTAssertFalse(why.contains(root.path), why)
            XCTAssertFalse(why.contains("Error Domain"), why)
        }
        XCTAssertEqual(ModelImporter.reason(PackageHashError.missingFile("x")), "missingFile(\"x\")",
                       "an error of our own with no sentence is described as it is")
    }

    /// A refused re-import keeps the model that was there.
    func testFailedReimportKeepsThePreviousInstall() async throws {
        _ = try await ModelImporter.importModel(from: try makeFolder(), into: registry)
        XCTAssertEqual(externalContents(), [Self.id])
        await assertRefused(try makeFolder(inputNames: ["picture"]), { $0 == .featureMismatch(Self.packageName) }, leaving: [Self.id])
        XCTAssertEqual(registry.entry(id: Self.id)?.status, .installed)
        try ModelImporter.remove(id: Self.id, from: registry)
    }

    /// The checks alone, on a folder that passes; hidden files are ignored.
    func testValidateAcceptsAGoodFolder() throws {
        let folder = try makeFolder()
        try Data([0]).write(to: folder.appendingPathComponent(".DS_Store"))
        let manifest = try ModelImporter.validate(folder: folder, registry: registry)
        XCTAssertEqual(manifest.id, Self.id)
        XCTAssertEqual(manifest.packages.count, 1)
    }

    /// Feature names: the SAM decoder's singular/plural embeddings are the
    /// same names; an empty manifest list compares nothing.
    func testFeatureNameComparison() {
        XCTAssertTrue(ModelImporter.featuresMatch(["image"], ["image"]))
        XCTAssertTrue(ModelImporter.featuresMatch(["sparse_embeddings", "dense_embeddings", "image_embedding"],
                                                  ["sparse_embedding", "dense_embedding", "image_embedding"]))
        XCTAssertTrue(ModelImporter.featuresMatch([], ["anything"]))
        XCTAssertFalse(ModelImporter.featuresMatch(["image"], ["picture"]))
        XCTAssertFalse(ModelImporter.featuresMatch(["image"], ["image", "mask"]))
    }

    /// The model folder inside an unpacked archive: the root when the
    /// manifest is there, else the one folder, never __MACOSX.
    func testModelFolderInsideAnArchive() throws {
        let unpacked = root.appendingPathComponent("unpacked")
        let inner = unpacked.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unpacked.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        XCTAssertEqual(ModelImporter.modelFolder(inStaged: unpacked).lastPathComponent, "model")
        try "{}".write(to: unpacked.appendingPathComponent("x.model.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ModelImporter.modelFolder(inStaged: unpacked), unpacked)
    }
}
