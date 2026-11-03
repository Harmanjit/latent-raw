import XCTest
import CoreML
@testable import MLKit

/// The manifest-aware compile cache (docs/Retouch.md §2 A): keyed by id,
/// package name and content hash, one compiled copy per package.
final class CoreMLStoreTests: XCTestCase {
    var root: URL!
    var id: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("latent-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        id = "store-test-" + UUID().uuidString.lowercased().prefix(8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        // The compiled copies this test made, in the real cache.
        let cache = CoreMLStore.cacheDirectory
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [] where entry.hasPrefix(id + "-") {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent(entry))
        }
    }

    /// A manifest for one copied package.
    func manifest(package name: String, sha256: String) -> ModelManifest {
        ModelManifest(
            id: id, displayName: "Store Test", purpose: "Testing", version: 1, kind: .promptedSegmentation,
            licence: ModelManifest.Licence(name: "MIT", url: URL(string: "https://example.org/L")!, commercialUse: true),
            sourceURL: URL(string: "https://example.org/store")!, sizeMB: 2, inputSize: 1024,
            packages: [ModelManifest.Package(name: name, role: "promptEncoder", sha256: sha256)])
    }

    /// The smallest bundled package (the 2 MB SAM prompt encoder) copied
    /// to a temp folder, so compiling is quick and the bundle untouched.
    func temporaryPromptEncoder() throws -> URL {
        let bundled = try XCTUnwrap(CoreMLStore.modelsDirectory).appendingPathComponent("SAM2_1SmallPromptEncoderFLOAT16.mlpackage")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundled.path), "SAM 2 packages not bundled")
        let copy = root.appendingPathComponent("Prompt.mlpackage")
        try FileManager.default.copyItem(at: bundled, to: copy)
        return copy
    }

    func cacheEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: CoreMLStore.cacheDirectory.path)) ?? [])
            .filter { $0.hasPrefix(id + "-") }.sorted()
    }

    /// The key holds the id, the package name and the first 16 hex digits
    /// of the hash; a replaced package (a different hash) recompiles under
    /// a new key and the stale one is pruned, while entries of another
    /// package of the same model are left alone.
    func testReplacedPackageRecompilesAndStaleEntriesArePruned() async throws {
        let package = try temporaryPromptEncoder()
        let hash1 = try PackageHash.sha256(ofPackageAt: package)
        let first = manifest(package: "Prompt.mlpackage", sha256: hash1)
        let t0 = Date()
        let model = try await CoreMLStore.load(first.packages[0], of: first, at: root, computeUnits: .cpuOnly)
        print(String(format: "STORE first compile+load %.0f ms", Date().timeIntervalSince(t0) * 1000))
        XCTAssertEqual(Set(model.modelDescription.inputDescriptionsByName.keys), ["points", "labels"])
        let key1 = "\(id!)-Prompt.mlpackage-\(hash1.prefix(16)).mlmodelc"
        XCTAssertEqual(cacheEntries(), [key1])

        // Another package of the same model: its entries are its own.
        let other = CoreMLStore.cacheDirectory.appendingPathComponent("\(id!)-Other.mlpackage-0123456789abcdef.mlmodelc")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        // Replace the package: a byte of its Manifest.json changes the
        // content hash without changing what Core ML compiles.
        let manifestFile = package.appendingPathComponent("Manifest.json")
        let text = try String(contentsOf: manifestFile, encoding: .utf8)
        XCTAssertTrue(text.contains("CoreML Model Specification"))
        try text.replacingOccurrences(of: "CoreML Model Specification", with: "CoreML Model Specification ")
            .write(to: manifestFile, atomically: true, encoding: .utf8)
        let hash2 = try PackageHash.sha256(ofPackageAt: package)
        XCTAssertNotEqual(hash1, hash2)
        let second = manifest(package: "Prompt.mlpackage", sha256: hash2)
        _ = try await CoreMLStore.load(second.packages[0], of: second, at: root, computeUnits: .cpuOnly)
        let key2 = "\(id!)-Prompt.mlpackage-\(hash2.prefix(16)).mlmodelc"
        XCTAssertEqual(cacheEntries(), [other.lastPathComponent, key2].sorted(), "the old copy is pruned, the other package's kept")

        // The same package again: a cache hit, nothing pruned.
        _ = try await CoreMLStore.load(second.packages[0], of: second, at: root, computeUnits: .cpuOnly)
        XCTAssertEqual(cacheEntries(), [other.lastPathComponent, key2].sorted())
    }

    /// The name-only lookup finds bundled packages, and in the flat
    /// legacy layout only the width-64 denoiser.
    func testFlatLegacyLookupIsForTheWidth64DenoiserOnly() {
        XCTAssertEqual(CoreMLStore.legacyFlatPackages, ["NAFNet_SIDD_width64"])
        XCTAssertNil(CoreMLStore.packageURL("NotAModel"))
        if let dir = CoreMLStore.modelsDirectory,
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("NAFNet_SIDD_width32.mlpackage").path) {
            XCTAssertEqual(CoreMLStore.packageURL("NAFNet_SIDD_width32")?.lastPathComponent, "NAFNet_SIDD_width32.mlpackage")
        }
    }

    // MARK: - The name-keyed cache

    /// Entries made under a temporary cache, so the installed app's are untouched.
    func withTemporaryCache(_ body: (URL) async throws -> Void) async throws {
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        CoreMLStore.overrideCacheDirectory(cache)
        defer { CoreMLStore.overrideCacheDirectory(nil) }
        try await body(cache)
    }

    func testNameKeyedEntryNames() {
        XCTAssertEqual(CoreMLStore.nameKeyedName(of: "NAFNet_SIDD_width32-58326976-1758000000.mlmodelc"), "NAFNet_SIDD_width32")
        XCTAssertEqual(CoreMLStore.nameKeyedName(of: "SegFormer_segformer_b2_finetuned_ade_512_512-1-2.mlmodelc"),
                       "SegFormer_segformer_b2_finetuned_ade_512_512")
        XCTAssertNil(CoreMLStore.nameKeyedName(of: "sam2.1-small-SAM2_1SmallPromptEncoderFLOAT16.mlpackage-0123456789012345.mlmodelc"))
        XCTAssertNil(CoreMLStore.nameKeyedName(of: "store-test-12345678-Prompt.mlpackage-0123456789abcdef.mlmodelc"))
        XCTAssertNil(CoreMLStore.nameKeyedName(of: "NAFNet_SIDD_width32-58326976-1758000000"))
        XCTAssertNil(CoreMLStore.nameKeyedName(of: "-1-2.mlmodelc"))
        XCTAssertNil(CoreMLStore.nameKeyedName(of: "x-1-a2.mlmodelc"))
    }

    /// Each build or reinstall gives the bundled denoiser a new mtime and
    /// so a new key. Loading prunes that name's older entries and the
    /// entries of names no longer loaded by name, and leaves the other
    /// denoiser variant and the manifest-keyed entries alone.
    func testNameKeyedLoadPrunesStaleEntries() async throws {
        let name = AIDenoiser.Variant.standard.packageName
        try XCTSkipUnless(CoreMLStore.isAvailable(name), "NAFNet package not bundled")
        try await withTemporaryCache { cache in
            let fm = FileManager.default
            let stale = ["\(name)-58326976-1700000000.mlmodelc", "\(name)-58326976-1700000001.mlmodelc",
                         "SAM2_1SmallImageEncoderFLOAT16-1-2.mlmodelc", "SegFormer_segformer_b2_finetuned_ade_512_512-3-4.mlmodelc"]
            let kept = ["NAFNet_SIDD_width64-5-6.mlmodelc",
                        "sam2.1-small-SAM2_1SmallPromptEncoderFLOAT16.mlpackage-0123456789abcdef.mlmodelc"]
            for entry in stale + kept {
                try fm.createDirectory(at: cache.appendingPathComponent(entry), withIntermediateDirectories: true)
            }
            _ = try await CoreMLStore.load(name, computeUnits: .cpuOnly)
            let after = try fm.contentsOfDirectory(atPath: cache.path).sorted()
            let fresh = after.filter { $0.hasPrefix(name + "-") }
            XCTAssertEqual(fresh.count, 1, "one compiled copy of \(name): \(after)")
            XCTAssertFalse(stale.contains(fresh.first ?? ""))
            XCTAssertEqual(Set(after), Set(kept + fresh))

            // A second load reuses that one copy.
            _ = try await CoreMLStore.load(name, computeUnits: .cpuOnly)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: cache.path).sorted(), after)
        }
    }

    /// The prune alone, with no compile: same-name siblings and retired
    /// names go, the key being kept and everything else stays.
    func testPruneNameKeyedWithoutLoading() async throws {
        try await withTemporaryCache { cache in
            let fm = FileManager.default
            let entries = ["NAFNet_SIDD_width32-1-1.mlmodelc", "NAFNet_SIDD_width32-1-2.mlmodelc",
                           "NAFNet_SIDD_width64-1-1.mlmodelc", "SAM2_1SmallMaskDecoderFLOAT16-1-1.mlmodelc",
                           "birefnet-lite-BiRefNet_lite.mlpackage-0123456789abcdef.mlmodelc", "notes.txt"]
            for entry in entries {
                try fm.createDirectory(at: cache.appendingPathComponent(entry), withIntermediateDirectories: true)
            }
            CoreMLStore.pruneNameKeyed(keeping: "NAFNet_SIDD_width32-1-2.mlmodelc", name: "NAFNet_SIDD_width32")
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: cache.path).sorted(),
                           ["NAFNet_SIDD_width32-1-2.mlmodelc", "NAFNet_SIDD_width64-1-1.mlmodelc",
                            "birefnet-lite-BiRefNet_lite.mlpackage-0123456789abcdef.mlmodelc", "notes.txt"])
        }
    }
}
