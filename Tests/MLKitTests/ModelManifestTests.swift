import XCTest
@testable import MLKit

/// The manifest format, the stored-version reference and the package
/// hash (docs/Retouch.md §2 A).
final class ModelManifestTests: XCTestCase {
    /// A subject model's manifest with every key, as the converters write it.
    static let full = """
    {
      "id": "fake-subject", "displayName": "Fake Subject", "purpose": "Testing", "version": 2,
      "kind": "subjectSegmentation",
      "licence": {"name": "MIT", "url": "https://example.org/LICENSE", "commercialUse": true},
      "sourceURL": "https://example.org/fake-subject", "sizeMB": 12, "inputSize": 512,
      "packages": [{"name": "Fake.mlpackage", "sha256": "abc", "inputNames": ["image"], "outputNames": ["mask"]}],
      "outputActivation": "sigmoid", "refine": "guided", "computeUnits": "cpuAndGPU",
      "converter": {"script": "scripts/convert_fake.py", "date": "2026-09-21"},
      "somethingNewer": true
    }
    """

    static func decode(_ json: String) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8))
    }

    /// The full manifest, with one top-level key replaced (or removed, with nil).
    static func variant(_ key: String, _ value: String?) -> String {
        var object = try! JSONSerialization.jsonObject(with: Data(full.utf8)) as! [String: Any]
        if let value {
            object[key] = (try! JSONSerialization.jsonObject(with: Data("[\(value)]".utf8)) as! [Any])[0]
        } else {
            object.removeValue(forKey: key)
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testFullManifestDecodesAndRoundTrips() throws {
        let m = try Self.decode(Self.full)
        XCTAssertEqual(m.id, "fake-subject")
        XCTAssertEqual(m.modelVersion, "fake-subject@2")
        XCTAssertEqual(m.kind, .subjectSegmentation)
        XCTAssertEqual(m.licence.url.host, "example.org")
        XCTAssertTrue(m.licence.commercialUse)
        XCTAssertEqual(m.packages.count, 1)
        XCTAssertEqual(m.packages[0].inputNames, ["image"])
        XCTAssertNil(m.packages[0].role)
        XCTAssertEqual(m.outputActivation, .sigmoid)
        XCTAssertEqual(m.refine, .guided)
        XCTAssertEqual(m.computeUnits, .cpuAndGPU)
        XCTAssertEqual(m.converter?.script, "scripts/convert_fake.py")
        XCTAssertNil(m.converter?.torch)
        XCTAssertTrue(m.isInstallable)

        // An unknown key ("somethingNewer") is ignored, and what was read
        // encodes to the same manifest again.
        let again = try JSONDecoder().decode(ModelManifest.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(again, m)
    }

    /// The optional keys may be missing; a catalogue row's packages carry
    /// no hash and say so through `isInstallable`.
    func testOptionalKeysAreLenient() throws {
        for key in ["outputActivation", "refine", "computeUnits", "converter"] {
            XCTAssertNoThrow(try Self.decode(Self.variant(key, nil)), key)
        }
        let row = """
        {"id": "row", "displayName": "Row", "purpose": "A catalogue row", "version": 1, "kind": "promptedSegmentation",
         "licence": {"name": "Apache-2.0", "url": "http://example.org/L", "commercialUse": false},
         "sourceURL": "https://example.org/row", "sizeMB": 80, "inputSize": 1024,
         "packages": [{"name": "A.mlpackage", "role": "imageEncoder", "sha256": null}, {"name": "B.mlpackage"}]}
        """
        let m = try Self.decode(row)
        XCTAssertNil(m.outputActivation)
        XCTAssertNil(m.refine)
        XCTAssertNil(m.computeUnits)
        XCTAssertNil(m.converter)
        XCTAssertNil(m.labelsFile)
        XCTAssertFalse(m.licence.commercialUse)
        XCTAssertEqual(m.packages.map(\.role), ["imageEncoder", nil])
        XCTAssertEqual(m.packages[1].inputNames, [])
        XCTAssertFalse(m.isInstallable)
    }

    func testMissingRequiredKeyIsNamed() {
        for key in ["id", "displayName", "purpose", "version", "kind", "licence", "sourceURL", "sizeMB", "inputSize", "packages"] {
            XCTAssertThrowsError(try Self.decode(Self.variant(key, nil)), key) { error in
                XCTAssertEqual(error as? ManifestError, .missingKey(key), key)
            }
        }
        // A key of the wrong type is as good as missing.
        XCTAssertThrowsError(try Self.decode(Self.variant("version", "\"two\""))) { error in
            XCTAssertEqual(error as? ManifestError, .missingKey("version"))
        }
        // Nested: a licence without its name, a package without its name.
        XCTAssertThrowsError(try Self.decode(Self.variant("licence", "{\"url\": \"https://x.org\", \"commercialUse\": true}"))) { error in
            XCTAssertEqual(error as? ManifestError, .missingKey("licence.name"))
        }
        XCTAssertThrowsError(try Self.decode(Self.variant("packages", "[{\"sha256\": \"abc\"}]"))) { error in
            XCTAssertEqual(error as? ManifestError, .missingKey("packages.name"))
        }
        XCTAssertFalse(ManifestError.missingKey("id").description.isEmpty)
    }

    /// An unknown kind is a decoding failure too: this build cannot run
    /// it, and listing it would offer something that does nothing.
    func testUnknownKindIsRefused() {
        XCTAssertThrowsError(try Self.decode(Self.variant("kind", "\"telepathy\"")))
    }

    func testIDPattern() throws {
        for good in ["a", "sam2.1-small", "birefnet-lite", "x9.y-z", String(repeating: "a", count: 64)] {
            XCTAssertTrue(ModelManifest.isValidID(good), good)
            XCTAssertEqual(try Self.decode(Self.variant("id", "\"\(good)\"")).id, good)
        }
        for bad in ["", "-lead", ".lead", "Upper", "with space", "slash/x", "under_score", "../up",
                    String(repeating: "a", count: 65), "ümlaut"] {
            XCTAssertFalse(ModelManifest.isValidID(bad), bad)
            XCTAssertThrowsError(try Self.decode(Self.variant("id", "\"\(bad)\"")), bad) { error in
                XCTAssertEqual(error as? ManifestError, .badID(bad), bad)
            }
        }
        XCTAssertFalse(ModelManifest.isValidID("trailing\n"), "the whole string must match, not a line of it")
    }

    /// Both links open in a browser, so only http(s) with a host will do.
    func testURLsMustBeWeb() throws {
        for bad in ["file:///etc/passwd", "ftp://example.org/x", "javascript:alert(1)", "example.org/no-scheme", "https://", ""] {
            XCTAssertThrowsError(try Self.decode(Self.variant("sourceURL", "\"\(bad)\"")), bad) { error in
                XCTAssertEqual(error as? ManifestError, .badURL(bad), bad)
            }
            let licence = "{\"name\": \"MIT\", \"url\": \"\(bad)\", \"commercialUse\": true}"
            XCTAssertThrowsError(try Self.decode(Self.variant("licence", licence)), bad) { error in
                XCTAssertEqual(error as? ManifestError, .badURL(bad), bad)
            }
        }
        XCTAssertEqual(try Self.decode(Self.variant("sourceURL", "\"HTTP://Example.org/x\"")).sourceURL.host?.lowercased(),
                       "example.org")
    }

    func testLoadFromFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("latent-manifest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fake-subject.model.json")
        try Self.full.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ModelManifest.load(from: file).id, "fake-subject")
        XCTAssertThrowsError(try ModelManifest.load(from: dir.appendingPathComponent("missing.model.json")))
    }

    // MARK: - ModelRef

    func testModelRefParsesStoredFormAndLegacyLiterals() {
        XCTAssertEqual(ModelRef(stored: "birefnet-lite@1"), ModelRef(id: "birefnet-lite", version: 1))
        XCTAssertEqual(ModelRef(stored: "sam2.1-large@12"), ModelRef(id: "sam2.1-large", version: 12))
        XCTAssertEqual(ModelRef(id: "x", version: 3).stored, "x@3")
        XCTAssertEqual(ModelRef(stored: ModelRef(id: "u2net", version: 2).stored), ModelRef(id: "u2net", version: 2))

        XCTAssertEqual(ModelRef(stored: "sam2.1-small.1"), ModelRef(id: "sam2.1-small", version: 1))
        XCTAssertEqual(ModelRef(stored: "vision.foregroundInstance.1"), ModelRef(id: "vision.foregroundInstance", version: 1))
        XCTAssertEqual(ModelRef(stored: "segformer-b2-ade20k-512.1"), ModelRef(id: "segformer-b2-ade20k-512", version: 1))
        XCTAssertEqual(ModelRef(stored: "latent.skyHeuristic.1"), ModelRef(id: "latent.skyHeuristic", version: 1))
        XCTAssertEqual(ModelRef.legacy.count, 4)
        // The legacy literals are the only dotted-version forms accepted.
        XCTAssertNil(ModelRef(stored: "sam2.1-small.2"))
    }

    func testModelRefRejectsGarbage() {
        for bad in ["", "test", "@1", "x@", "x@one", "x@-1", "x@1.5", "Upper@1", "a b@1", "x@1@2"] {
            XCTAssertNil(ModelRef(stored: bad), bad)
        }
    }

    // MARK: - PackageHash

    /// The bundled NAFNet package, copied to a temp folder so the test can
    /// add and remove files without touching the bundle.
    func temporaryNAFNet() throws -> (root: URL, package: URL) {
        let bundled = try XCTUnwrap(CoreMLStore.modelsDirectory).appendingPathComponent("NAFNet_SIDD_width32.mlpackage")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundled.path), "NAFNet package not bundled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("latent-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = root.appendingPathComponent("NAFNet_SIDD_width32.mlpackage")
        try FileManager.default.copyItem(at: bundled, to: copy)
        return (root, copy)
    }

    /// The Swift hash must equal the script's (scripts/latent_manifest.py,
    /// which wrote this digest into nafnet-sidd-w32.model.json), or the
    /// importer would refuse every package the script described.
    func testHashMatchesTheScriptOnTheBundledNAFNet() throws {
        let (root, package) = try temporaryNAFNet()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try PackageHash.sha256(ofPackageAt: package),
                       "93070946ed4c11b74513338db8f9c9d10370ebe4ab2382e7b3b7619384d64d1d")
        XCTAssertEqual(PackageHash.hashedFiles.count, 3)
    }

    /// The hash covers the three files, so a byte changed in any of them
    /// changes it, and a file it would not cover is refused rather than
    /// smuggled past it.
    func testHashRefusesStrayAndMissingFiles() throws {
        let (root, package) = try temporaryNAFNet()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let original = try PackageHash.sha256(ofPackageAt: package)

        let stray = package.appendingPathComponent("Data/com.apple.CoreML/weights/extra.bin")
        try Data([1, 2, 3]).write(to: stray)
        XCTAssertThrowsError(try PackageHash.sha256(ofPackageAt: package)) { error in
            XCTAssertEqual(error as? PackageHashError, .unexpectedFile("Data/com.apple.CoreML/weights/extra.bin"))
        }
        try fm.removeItem(at: stray)
        // Hidden files count too: the script walks them, so must this.
        let hidden = package.appendingPathComponent(".DS_Store")
        try Data([0]).write(to: hidden)
        XCTAssertThrowsError(try PackageHash.sha256(ofPackageAt: package)) { error in
            XCTAssertEqual(error as? PackageHashError, .unexpectedFile(".DS_Store"))
        }
        try fm.removeItem(at: hidden)
        // An empty folder is not a file and changes nothing.
        try fm.createDirectory(at: package.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        XCTAssertEqual(try PackageHash.sha256(ofPackageAt: package), original)

        let manifest = package.appendingPathComponent("Manifest.json")
        var bytes = try Data(contentsOf: manifest)
        bytes[0] ^= 0x01
        try bytes.write(to: manifest)
        XCTAssertNotEqual(try PackageHash.sha256(ofPackageAt: package), original)

        try fm.removeItem(at: manifest)
        XCTAssertThrowsError(try PackageHash.sha256(ofPackageAt: package)) { error in
            XCTAssertEqual(error as? PackageHashError, .missingFile("Manifest.json"))
        }
        XCTAssertThrowsError(try PackageHash.sha256(ofPackageAt: root.appendingPathComponent("nowhere.mlpackage")))
    }

    /// A link reads as its target, so the hash would pin bytes outside
    /// the package; a link to a file or to a folder is refused before
    /// anything is hashed, and one of the three named files is refused
    /// even when it is a link to the right bytes.
    func testHashRefusesSymbolicLinks() throws {
        let (root, package) = try temporaryNAFNet()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let elsewhere = root.appendingPathComponent("weight.bin")
        try fm.moveItem(at: weights, to: elsewhere)
        try fm.createSymbolicLink(at: weights, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try PackageHash.sha256(ofPackageAt: package)) { error in
            XCTAssertEqual(error as? PackageHashError, .symbolicLink("Data/com.apple.CoreML/weights/weight.bin"))
        }
        try fm.removeItem(at: weights)
        try fm.moveItem(at: elsewhere, to: weights)

        let linkedFolder = package.appendingPathComponent("Extra")
        try fm.createSymbolicLink(at: linkedFolder, withDestinationURL: package.appendingPathComponent("Data"))
        XCTAssertThrowsError(try PackageHash.sha256(ofPackageAt: package)) { error in
            XCTAssertEqual(error as? PackageHashError, .symbolicLink("Extra"))
        }
    }

    /// The manifest and labels of a package chosen on its own sit at its
    /// root; named to the hash they are passed over, and the value is
    /// the one the same package hashes to without them. Unnamed, or
    /// deeper than the root, they are strays as before.
    func testHashPassesOverNamedRootFiles() throws {
        let (root, package) = try temporaryNAFNet()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try PackageHash.sha256(ofPackageAt: package)
        try "{}".write(to: package.appendingPathComponent("x.model.json"), atomically: true, encoding: .utf8)
        try "[]".write(to: package.appendingPathComponent("labels.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PackageHash.sha256(ofPackageAt: package)) { error in
            XCTAssertEqual(error as? PackageHashError, .unexpectedFile("labels.json"))
        }
        XCTAssertEqual(try PackageHash.sha256(ofPackageAt: package, ignoringRootFiles: ["x.model.json", "labels.json"]), original)
        XCTAssertThrowsError(try PackageHash.sha256(ofPackageAt: package, ignoringRootFiles: ["x.model.json"]))
        try "{}".write(to: package.appendingPathComponent("Data/x.model.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PackageHash.sha256(ofPackageAt: package, ignoringRootFiles: ["x.model.json", "labels.json"])) { error in
            XCTAssertEqual(error as? PackageHashError, .unexpectedFile("Data/x.model.json"))
        }
    }

    /// Every bundled manifest names packages whose contents hash to what
    /// it says (the CI check of docs/Retouch.md §2 A). Vacuous until the
    /// manifests land beside the packages.
    func testBundledManifestsMatchTheirPackages() throws {
        let dir = try XCTUnwrap(CoreMLStore.modelsDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".model.json") }
        for name in names {
            let manifest = try ModelManifest.load(from: dir.appendingPathComponent(name))
            XCTAssertEqual(name, manifest.id + ".model.json", "a manifest is named after its id")
            XCTAssertTrue(manifest.isInstallable, "\(name): a bundled manifest carries every hash")
            for package in manifest.packages {
                XCTAssertEqual(try PackageHash.sha256(ofPackageAt: dir.appendingPathComponent(package.name)),
                               package.sha256, "\(name): \(package.name)")
            }
        }
    }

    func testComputeUnitsRankAndMapping() {
        XCTAssertEqual(ModelManifest.ComputeUnits.cpuOnly.rank, 0)
        XCTAssertEqual(ModelManifest.ComputeUnits.cpuAndGPU.rank, 1)
        XCTAssertEqual(ModelManifest.ComputeUnits.cpuAndNeuralEngine.rank, 1)
        XCTAssertEqual(ModelManifest.ComputeUnits.all.rank, 2)
        for units in [ModelManifest.ComputeUnits.cpuOnly, .cpuAndGPU, .cpuAndNeuralEngine, .all] {
            XCTAssertEqual(ModelManifest.ComputeUnits(units.mlComputeUnits), units)
        }
    }
}
