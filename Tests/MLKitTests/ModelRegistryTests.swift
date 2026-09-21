import XCTest
import CoreML
@testable import MLKit

/// The registry's listing over temp folders: what is bundled, installed
/// and catalogued, which wins when two say the same id, the defaults for
/// new masks and the compute rank rule (docs/Retouch.md §2 A).
final class ModelRegistryTests: XCTestCase {
    var root: URL!
    var bundled: URL!
    var external: URL!
    var catalogue: URL!
    var defaults: UserDefaults!
    var suite: String!

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("latent-registry-\(UUID().uuidString)")
        bundled = root.appendingPathComponent("bundled")
        external = root.appendingPathComponent("external")
        catalogue = bundled.appendingPathComponent("ModelCatalog.json")
        try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        suite = "latent-registry-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// A manifest's JSON: installable (with hashes) unless `row`.
    static func json(id: String, kind: String, version: Int = 1, packages: [String] = ["A.mlpackage"],
                     row: Bool = false, computeUnits: String? = nil) -> String {
        let hash = row ? "null" : "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
        let list = packages.map { "{\"name\": \"\($0)\", \"sha256\": \(hash)}" }.joined(separator: ", ")
        let units = computeUnits.map { ", \"computeUnits\": \"\($0)\"" } ?? ""
        return """
        {"id": "\(id)", "displayName": "\(id.capitalized)", "purpose": "Testing", "version": \(version), "kind": "\(kind)",
         "licence": {"name": "MIT", "url": "https://example.org/L", "commercialUse": true},
         "sourceURL": "https://example.org/\(id)", "sizeMB": 1, "inputSize": 64, "packages": [\(list)]\(units)}
        """
    }

    func addBundled(_ id: String, kind: String, version: Int = 1, computeUnits: String? = nil) throws {
        try Self.json(id: id, kind: kind, version: version, computeUnits: computeUnits)
            .write(to: bundled.appendingPathComponent("\(id).model.json"), atomically: true, encoding: .utf8)
    }

    /// external/<folder>/<id>.model.json; the folder is the id unless said otherwise.
    func addExternal(_ id: String, kind: String, version: Int = 1, folder: String? = nil,
                     computeUnits: String? = nil) throws {
        let dir = external.appendingPathComponent(folder ?? id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.json(id: id, kind: kind, version: version, computeUnits: computeUnits)
            .write(to: dir.appendingPathComponent("\(id).model.json"), atomically: true, encoding: .utf8)
    }

    func writeCatalogue(_ rows: [(id: String, kind: String)]) throws {
        let json = "[" + rows.map { Self.json(id: $0.id, kind: $0.kind, row: true) }.joined(separator: ",") + "]"
        try json.write(to: catalogue, atomically: true, encoding: .utf8)
    }

    func registry(bundled: Bool = true, catalogue: Bool = true) -> ModelRegistry {
        ModelRegistry(bundled: bundled ? self.bundled : nil, external: external,
                      catalogue: catalogue ? self.catalogue : nil, defaults: defaults)
    }

    /// Nothing bundled, nothing installed, no catalogue (the state of a
    /// checkout before the manifests land): only Apple Vision lists, and
    /// it is the subject default; there is no prompted default.
    func testEmptyRegistryHasOnlyBuiltInVision() {
        let r = ModelRegistry(bundled: nil, external: root.appendingPathComponent("nowhere"), catalogue: nil,
                              defaults: defaults)
        let all = r.entries()
        XCTAssertEqual(all.map(\.id), [ModelRegistry.builtInSubjectID])
        XCTAssertEqual(all[0].status, .builtIn)
        XCTAssertNil(all[0].location)
        XCTAssertTrue(all[0].isInstalled)
        XCTAssertEqual(all[0].manifest.kind, .subjectSegmentation)
        XCTAssertEqual(all[0].modelVersion, "vision.foregroundInstance@1")
        XCTAssertEqual(r.defaultSubject().id, ModelRegistry.builtInSubjectID)
        XCTAssertNil(r.defaultPrompted())
        XCTAssertEqual(r.entries(kind: .promptedSegmentation), [])
        XCTAssertNil(r.entry(id: "birefnet-lite"))
    }

    /// The listing walks the same folders the app's registry does, so
    /// the shared instance answers even without bundled manifests.
    func testSharedRegistryLists() {
        XCTAssertEqual(ModelRegistry.shared.entries().first?.id, ModelRegistry.builtInSubjectID)
        XCTAssertEqual(ModelRegistry.shared.defaultSubject().manifest.kind, .subjectSegmentation)
    }

    func testOrderStatusAndLocation() throws {
        try addBundled("b-subject", kind: "subjectSegmentation")
        try addBundled("a-prompted", kind: "promptedSegmentation")
        try addExternal("z-installed", kind: "subjectSegmentation")
        try addExternal("m-installed", kind: "semanticSegmentation")
        try writeCatalogue([(id: "y-row", kind: "promptedSegmentation"), (id: "c-row", kind: "subjectSegmentation")])
        let r = registry()
        let all = r.entries()
        XCTAssertEqual(all.map(\.id), [ModelRegistry.builtInSubjectID, "a-prompted", "b-subject",
                                       "m-installed", "z-installed", "c-row", "y-row"],
                       "built-in, bundled, installed, catalogue; by id within each group")
        XCTAssertEqual(all.map(\.status), [.builtIn, .bundled, .bundled, .installed, .installed, .notInstalled, .notInstalled])
        XCTAssertEqual(r.entry(id: "b-subject")?.location?.path, bundled.path)
        // The temporary folder is reached through a symlink (/var → /private/var).
        XCTAssertEqual(r.entry(id: "z-installed")?.location?.resolvingSymlinksInPath().path,
                       external.appendingPathComponent("z-installed").resolvingSymlinksInPath().path)
        XCTAssertNil(r.entry(id: "c-row")?.location)
        XCTAssertEqual(r.entry(id: "c-row")?.isInstalled, false)
        XCTAssertEqual(r.entries(kind: .subjectSegmentation).map(\.id),
                       [ModelRegistry.builtInSubjectID, "b-subject", "z-installed", "c-row"])
        XCTAssertEqual(r.entries(kind: .denoise), [])
    }

    /// A bundled id shadows an external one, an external id shadows a
    /// catalogue one, and nothing shadows the built-in row.
    func testShadowing() throws {
        try addBundled("shared", kind: "subjectSegmentation", version: 1)
        try addExternal("shared", kind: "subjectSegmentation", version: 2)
        try addExternal("imported", kind: "promptedSegmentation", version: 3)
        try addExternal(ModelRegistry.builtInSubjectID, kind: "subjectSegmentation", version: 9)
        try writeCatalogue([(id: "imported", kind: "promptedSegmentation"), (id: "shared", kind: "subjectSegmentation"),
                            (id: "only-row", kind: "promptedSegmentation")])
        let r = registry()
        XCTAssertEqual(r.entries().map(\.id), [ModelRegistry.builtInSubjectID, "shared", "imported", "only-row"])
        XCTAssertEqual(r.entry(id: "shared")?.status, .bundled)
        XCTAssertEqual(r.entry(id: "shared")?.manifest.version, 1, "the bundled manifest, not the stray copy's")
        XCTAssertEqual(r.entry(id: "imported")?.status, .installed)
        XCTAssertEqual(r.entry(id: "imported")?.manifest.version, 3)
        XCTAssertEqual(r.entry(id: ModelRegistry.builtInSubjectID)?.status, .builtIn)
        XCTAssertEqual(r.entry(id: "only-row")?.status, .notInstalled)
    }

    /// A folder whose manifest names another id, a manifest that doesn't
    /// parse, a stray file among the folders and an unreadable catalogue
    /// are each skipped without hiding the rest.
    func testBadEntriesAreSkipped() throws {
        try addBundled("good", kind: "subjectSegmentation")
        try "{not json".write(to: bundled.appendingPathComponent("broken.model.json"), atomically: true, encoding: .utf8)
        try Self.json(id: "Bad ID", kind: "subjectSegmentation")
            .write(to: bundled.appendingPathComponent("bad-id.model.json"), atomically: true, encoding: .utf8)
        try addExternal("renamed", kind: "subjectSegmentation", folder: "other-name")
        try addExternal("fine", kind: "subjectSegmentation")
        try "stray".write(to: external.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: external.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try "[{".write(to: catalogue, atomically: true, encoding: .utf8)
        let r = registry()
        XCTAssertEqual(r.entries().map(\.id), [ModelRegistry.builtInSubjectID, "good", "fine"])
    }

    /// A stored version resolves by id alone: another installed version
    /// runs (and the mask row says so); a missing id or a nil reference
    /// resolves to nothing.
    func testInstalledResolvesByIDOnly() throws {
        try addBundled("bundled-one", kind: "promptedSegmentation", version: 2)
        try writeCatalogue([(id: "row", kind: "promptedSegmentation")])
        let r = registry()
        XCTAssertEqual(r.installed(ModelRef(stored: "bundled-one@1"))?.id, "bundled-one")
        XCTAssertEqual(r.installed(ModelRef(stored: "bundled-one@1"))?.manifest.version, 2)
        XCTAssertEqual(r.installed(ModelRef(stored: "vision.foregroundInstance.1"))?.status, .builtIn)
        XCTAssertNil(r.installed(ModelRef(stored: "row@1")), "a catalogue row is not installed")
        XCTAssertNil(r.installed(ModelRef(stored: "nowhere@1")))
        XCTAssertNil(r.installed(ModelRef(stored: "garbage")))
        XCTAssertNil(r.installed(nil))
    }

    /// The listing is read once; `refresh()` sees what an import added.
    func testRefreshSeesNewFolders() throws {
        let r = registry()
        XCTAssertEqual(r.entries().count, 1)
        try addExternal("later", kind: "subjectSegmentation")
        XCTAssertEqual(r.entries().count, 1, "cached until refresh")
        r.refresh()
        XCTAssertEqual(r.entry(id: "later")?.status, .installed)
        try FileManager.default.removeItem(at: external.appendingPathComponent("later"))
        r.refresh()
        XCTAssertNil(r.entry(id: "later"))
    }

    /// The preferred id when it is installed and of the right kind, else
    /// the bundled model of the kind, else Vision (subject) or nothing
    /// (prompted). Only new masks ask; existing ones keep their model.
    func testDefaultsForNewMasks() throws {
        try addBundled("birefnet-lite", kind: "subjectSegmentation")
        try addBundled("sam2.1-small", kind: "promptedSegmentation")
        try addExternal("u2net", kind: "subjectSegmentation")
        try addExternal("sam2.1-large", kind: "promptedSegmentation")
        try writeCatalogue([(id: "modnet", kind: "subjectSegmentation")])
        let r = registry()

        // Unset: the bundled models by their well-known ids.
        XCTAssertEqual(r.defaultSubject().id, "birefnet-lite")
        XCTAssertEqual(r.defaultPrompted()?.id, "sam2.1-small")

        defaults.set("u2net", forKey: ModelRegistry.subjectPreferenceKey)
        defaults.set("sam2.1-large", forKey: ModelRegistry.promptedPreferenceKey)
        XCTAssertEqual(r.defaultSubject().id, "u2net")
        XCTAssertEqual(r.defaultPrompted()?.id, "sam2.1-large")

        // Vision can be chosen on purpose.
        defaults.set(ModelRegistry.builtInSubjectID, forKey: ModelRegistry.subjectPreferenceKey)
        XCTAssertEqual(r.defaultSubject().status, .builtIn)

        // Not installed (a catalogue row), gone, or of the other kind: the bundled one.
        defaults.set("modnet", forKey: ModelRegistry.subjectPreferenceKey)
        XCTAssertEqual(r.defaultSubject().id, "birefnet-lite")
        defaults.set("removed-model", forKey: ModelRegistry.promptedPreferenceKey)
        XCTAssertEqual(r.defaultPrompted()?.id, "sam2.1-small")
        defaults.set("sam2.1-small", forKey: ModelRegistry.subjectPreferenceKey)
        XCTAssertEqual(r.defaultSubject().id, "birefnet-lite")
    }

    func testDefaultsFallBackWithoutBundledModels() throws {
        try addExternal("u2net", kind: "subjectSegmentation")
        let r = registry(bundled: false, catalogue: false)
        XCTAssertEqual(r.defaultSubject().id, ModelRegistry.builtInSubjectID, "unset preference, nothing bundled")
        XCTAssertNil(r.defaultPrompted())
        defaults.set("u2net", forKey: ModelRegistry.subjectPreferenceKey)
        XCTAssertEqual(r.defaultSubject().id, "u2net")
        defaults.set("gone", forKey: ModelRegistry.subjectPreferenceKey)
        XCTAssertEqual(r.defaultSubject().id, ModelRegistry.builtInSubjectID)
    }

    /// Lowest rank of {preference, manifest override or .all, bundled ?
    /// .all : .cpuAndGPU}; on a tie between the two rank-1 choices the
    /// manifest's wins.
    func testEffectiveComputeUnits() throws {
        try addBundled("plain", kind: "subjectSegmentation")
        try addBundled("gpu", kind: "subjectSegmentation", computeUnits: "cpuAndGPU")
        try addBundled("cpu", kind: "subjectSegmentation", computeUnits: "cpuOnly")
        try addBundled("ane", kind: "subjectSegmentation", computeUnits: "cpuAndNeuralEngine")
        try addExternal("imported", kind: "subjectSegmentation")
        try addExternal("imported-all", kind: "subjectSegmentation", computeUnits: "all")
        try addExternal("imported-cpu", kind: "subjectSegmentation", computeUnits: "cpuOnly")
        let r = registry()
        func units(_ id: String, _ preference: MLComputeUnits) -> MLComputeUnits {
            r.effectiveComputeUnits(for: r.entry(id: id)!, preference: preference)
        }
        let table: [(id: String, preference: MLComputeUnits, expected: MLComputeUnits)] = [
            // Bundled, no override: the preference decides.
            ("plain", .all, .all), ("plain", .cpuAndGPU, .cpuAndGPU), ("plain", .cpuOnly, .cpuOnly),
            ("plain", .cpuAndNeuralEngine, .cpuAndNeuralEngine),
            // Bundled with an override: never above it.
            ("gpu", .all, .cpuAndGPU), ("gpu", .cpuAndNeuralEngine, .cpuAndGPU), ("gpu", .cpuOnly, .cpuOnly),
            ("cpu", .all, .cpuOnly), ("ane", .all, .cpuAndNeuralEngine), ("ane", .cpuAndGPU, .cpuAndNeuralEngine),
            // Imported: capped at cpuAndGPU whatever anyone says.
            ("imported", .all, .cpuAndGPU), ("imported", .cpuAndNeuralEngine, .cpuAndGPU),
            ("imported", .cpuOnly, .cpuOnly), ("imported-all", .all, .cpuAndGPU), ("imported-cpu", .all, .cpuOnly),
            (ModelRegistry.builtInSubjectID, .all, .cpuAndGPU),
        ]
        for row in table {
            XCTAssertEqual(units(row.id, row.preference), row.expected, "\(row.id) with \(row.preference.rawValue)")
        }
    }

    /// Loading answers nil, without throwing, for everything that cannot
    /// load: a manifest whose package is not there, a model asked for as
    /// the wrong kind, a catalogue row, built-in Vision (nothing to load)
    /// and an unknown id; releasing what isn't there is safe.
    func testLoadingAnswersNilForWhatCannotLoad() async throws {
        try addBundled("birefnet-lite", kind: "subjectSegmentation")
        try writeCatalogue([("u2net", "subjectSegmentation")])
        let r = registry()
        let noPackage = await r.subject(id: "birefnet-lite")
        XCTAssertNil(noPackage, "the fake manifest names a package that is not there")
        let wrongKind = await r.prompted(id: "birefnet-lite")
        XCTAssertNil(wrongKind)
        let row = await r.subject(id: "u2net")
        XCTAssertNil(row)
        let vision = await r.subject(id: ModelRegistry.builtInSubjectID)
        XCTAssertNil(vision)
        let unknown = await r.semantic(id: "segformer-b2-ade20k-512")
        XCTAssertNil(unknown)
        r.release(id: "birefnet-lite")
        r.releaseAll()
        XCTAssertNil(r.loaded(id: "birefnet-lite"))
    }

    /// The bundled BiRefNet loads once through the shared registry (two
    /// asks at once share one load), is kept until released, and loads
    /// afresh after.
    func testBundledSubjectModelLoadsOnceAndReleases() async throws {
        let r = ModelRegistry.shared
        try XCTSkipUnless(r.entry(id: "birefnet-lite")?.status == .bundled, "BiRefNet-lite not bundled")
        async let first = r.subject(id: "birefnet-lite")
        async let second = r.subject(id: "birefnet-lite")
        let (a, b) = await (first, second)
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b, "one load, shared")
        XCTAssertNotNil(r.loaded(id: "birefnet-lite"))
        XCTAssertEqual(a?.entry.status, .bundled)
        r.release(id: "birefnet-lite")
        XCTAssertNil(r.loaded(id: "birefnet-lite"))
        let c = await r.subject(id: "birefnet-lite")
        XCTAssertNotNil(c)
        XCTAssertFalse(a === c, "a fresh load after release")
        r.releaseAll()
        XCTAssertNil(r.loaded(id: "birefnet-lite"))
    }

    /// Remove deletes the model's folder and forgets it; an id that could
    /// name anything else is refused before anything is touched.
    func testRemoveDeletesTheFolder() throws {
        try addExternal("doomed", kind: "subjectSegmentation")
        let r = registry()
        XCTAssertEqual(r.entry(id: "doomed")?.status, .installed)
        try ModelImporter.remove(id: "doomed", from: r)
        XCTAssertNil(r.entry(id: "doomed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("doomed").path))
        XCTAssertNoThrow(try ModelImporter.remove(id: "never-there", from: r))
        XCTAssertThrowsError(try ModelImporter.remove(id: "../escape", from: r)) { error in
            XCTAssertEqual(error as? ModelImportError, .badID("../escape"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    /// The manifest-aware loader keys the compile cache by content hash
    /// and refuses a catalogue row, which has none.
    func testStoreRefusesAPackageWithoutChecksum() async throws {
        let manifest = try JSONDecoder().decode(ModelManifest.self,
                                                from: Data(Self.json(id: "row", kind: "subjectSegmentation", row: true).utf8))
        do {
            _ = try await CoreMLStore.load(manifest.packages[0], of: manifest, at: external, computeUnits: .cpuOnly)
            XCTFail("loaded a package that has no checksum")
        } catch let error as CoreMLStore.StoreError {
            XCTAssertEqual(String(describing: error).contains("checksum"), true)
        }
        let installable = try JSONDecoder().decode(ModelManifest.self,
                                                   from: Data(Self.json(id: "gone", kind: "subjectSegmentation").utf8))
        do {
            _ = try await CoreMLStore.load(installable.packages[0], of: installable, at: external, computeUnits: .cpuOnly)
            XCTFail("loaded a package that is not there")
        } catch let error as CoreMLStore.StoreError {
            XCTAssertEqual(String(describing: error).contains("not bundled"), true)
        }
    }

    /// Both places a model's JSON may sit, in order.
    func testJSONBesideAModel() throws {
        try "[\"a\"]".write(to: external.appendingPathComponent("labels.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CoreMLStore.json("labels.json", in: external, as: [String].self), ["a"])
        XCTAssertNil(CoreMLStore.json("labels.json", in: bundled, as: [String].self),
                     "not in the given folder and not bundled either")
        XCTAssertNil(CoreMLStore.json("labels.json", in: nil, as: [String].self))
        XCTAssertEqual(CoreMLStore.catalogueURL?.lastPathComponent, "ModelCatalog.json")
    }
}
