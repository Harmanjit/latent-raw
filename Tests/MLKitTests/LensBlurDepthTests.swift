import XCTest
import CoreGraphics
import RawCore
@testable import MLKit
@testable import PixelEngine

/// Lens Blur's depth (LensBlurDepth.swift, DepthEstimator.swift): the
/// depth kind in the manifest, registry and importer, the two-plane
/// fallback when no depth model is installed, and an export that carries
/// the blur.
final class LensBlurDepthTests: XCTestCase {
    // MARK: - The depth kind

    func testDepthManifestsDecodeAndList() throws {
        let json = ModelRegistryTests.json(id: "depthy", kind: "depth")
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.kind, .depth)

        // The catalogue offers Depth Anything V2 Small, not installed.
        let row = try XCTUnwrap(ModelRegistry.shared.entry(id: "depth-anything-v2-small"))
        XCTAssertEqual(row.manifest.kind, .depth)
        XCTAssertEqual(row.manifest.licence.name, "Apache-2.0")
        XCTAssertTrue(row.manifest.licence.commercialUse)
        XCTAssertEqual(row.manifest.converter?.script, "scripts/convert_depth_anything.py")
        XCTAssertFalse(row.manifest.isInstallable, "a catalogue row has no hashes")
    }

    func testDefaultDepthIsTheInstalledOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("latent-depth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled"), external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let installed = external.appendingPathComponent("depthy")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let catalogue = bundled.appendingPathComponent("ModelCatalog.json")
        try "[\(ModelRegistryTests.json(id: "row-depth", kind: "depth", row: true))]"
            .write(to: catalogue, atomically: true, encoding: .utf8)

        let none = ModelRegistry(bundled: bundled, external: external, catalogue: catalogue)
        XCTAssertNil(none.defaultDepth(), "a catalogue row is not installed")
        XCTAssertEqual(LensBlurDepth.defaultSource(registry: none), LensBlur.subjectDepthVersion)

        try ModelRegistryTests.json(id: "depthy", kind: "depth")
            .write(to: installed.appendingPathComponent("depthy.model.json"), atomically: true, encoding: .utf8)
        let one = ModelRegistry(bundled: bundled, external: external, catalogue: catalogue)
        XCTAssertEqual(one.defaultDepth()?.id, "depthy")
        XCTAssertEqual(LensBlurDepth.defaultSource(registry: one), "depthy@1")
        XCTAssertEqual(LensBlurDepth.displayName(of: "depthy@1", registry: one), "Depthy")
        XCTAssertEqual(LensBlurDepth.displayName(of: LensBlur.subjectDepthVersion, registry: one), "Subject (two planes)")
        XCTAssertEqual(LensBlurDepth.displayName(of: "gone@2", registry: one), "gone")
    }

    func testImporterTakesADepthModelOfOnePackage() throws {
        func manifest(packages: Int) -> ModelManifest {
            ModelManifest(id: "depthy", displayName: "Depthy", purpose: "Testing", version: 1, kind: .depth,
                          licence: .init(name: "MIT", url: URL(string: "https://example.org/L")!, commercialUse: true),
                          sourceURL: URL(string: "https://example.org/d")!, sizeMB: 1, inputSize: 518,
                          packages: (0..<packages).map { .init(name: "P\($0).mlpackage", sha256: "0") })
        }
        XCTAssertNoThrow(try ModelImporter.checkKindFields(of: manifest(packages: 1)))
        XCTAssertThrowsError(try ModelImporter.checkKindFields(of: manifest(packages: 2)))
    }

    // MARK: - The model's output

    /// The 1st and 99th percentiles stretch to 0 and 255, so one stray
    /// value at either end doesn't flatten the rest; larger stays nearer.
    func testNormalisationIsRobustToOutliers() {
        var values = (0..<1000).map { Float($0) / 999 }   // 0…1, far to near
        values[500] = 1000                                 // one glint read as very near
        values[10] = .nan
        let map = DepthEstimator.normalised(values, width: 1000, height: 1)
        XCTAssertEqual(map.data[999], 255)
        XCTAssertEqual(map.data[0], 0)
        XCTAssertEqual(map.data[10], 0, "NaN reads as far")
        XCTAssertEqual(Int(map.data[600]), 152, accuracy: 4, "the middle of the scene keeps its place")
        XCTAssertEqual(DepthEstimator.normalised([2, 2, 2, 2], width: 2, height: 2).data, [0, 0, 0, 0])
    }

    // MARK: - The fallback

    /// Without a depth model the depth is two planes from the subject
    /// mask; a missing model the edit names is reported as such.
    func testFallbackIsTwoPlanesFromTheSubject() async throws {
        let image = try PortraitAsset.image(longEdge: 1024)
        let registry = ModelRegistry.shared
        try XCTSkipIf(registry.defaultDepth() != nil, "a depth model is installed on this Mac")
        let planes = try await LensBlurDepth.make(from: image, stored: nil, registry: registry)
        XCTAssertEqual(planes.depth.source, LensBlur.subjectDepthVersion)
        XCTAssertNil(planes.substitutedModel)
        let face = SIMD2<Float>(Float(PortraitAsset.faceBox.midX), Float(PortraitAsset.faceBox.midY))
        XCTAssertGreaterThan(planes.depth.depth(atNormalized: face), 0.7, "the subject is near")
        XCTAssertLessThan(planes.depth.depth(atNormalized: SIMD2(0.02, 0.02)), 0.3, "the corner is far")

        let missing = try await LensBlurDepth.make(from: image, stored: "depth-anything-v2-small@1", registry: registry)
        XCTAssertEqual(missing.substitutedModel, "Depth Anything V2 Small")
        XCTAssertEqual(missing.depth.source, LensBlur.subjectDepthVersion)
    }

    // MARK: - Export

    /// An export with Lens Blur makes its own depth map and blurs: the
    /// render differs from the same edit at amount 0, and the edit with
    /// the blur reads back unchanged from its stored JSON.
    func testExportCarriesTheBlur() async throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        func json(amount: Float) throws -> String {
            var p = EditParameters()
            p.lensBlur = LensBlur(amount: amount, bokeh: .circle, boost: 40, focusFar: 0.5, focusNear: 1,
                                  depthModel: LensBlur.subjectDepthVersion)
            return try EditStack(parameters: p).encodeJSON()
        }
        let blurredJSON = try json(amount: 100)
        XCTAssertEqual(try EditStack.decode(json: blurredJSON).parameters().lensBlur.amount, 100)
        func rendered(_ json: String) async throws -> CGImage {
            let request = ExportWorker.ImageRequest(sourceURL: URL(fileURLWithPath: path), editStackJSON: json,
                                                    userRotation: 0, colorSpace: .sRGB, maxLongEdge: 800,
                                                    bitsPerComponent: 8, runsAIDenoise: false)
            return try await ExportWorker.renderImage(request, gpu: gpu).cgImage
        }
        let plain = try await rendered(try json(amount: 0))
        let blurred = try await rendered(blurredJSON)
        XCTAssertEqual(plain.width, blurred.width)
        let a = try XCTUnwrap(plain.dataProvider?.data as Data?), b = try XCTUnwrap(blurred.dataProvider?.data as Data?)
        XCTAssertNotEqual(a, b, "the background blurs")
    }
}
