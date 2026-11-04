import XCTest
import CoreGraphics
@testable import MLKit
@testable import PixelEngine

/// Reflection removal's model side (ReflectionRemover.swift,
/// ReflectionRemovalMaker.swift): the kind in the manifest, registry and
/// importer, the gain arithmetic, and nothing at all without a model.
final class ReflectionRemoverTests: XCTestCase {
    func testKindDecodesAndTheImporterWantsOnePackage() throws {
        let manifest = try JSONDecoder().decode(ModelManifest.self,
                                                from: Data(ModelRegistryTests.json(id: "dereflect", kind: "reflectionRemoval").utf8))
        XCTAssertEqual(manifest.kind, .reflectionRemoval)
        XCTAssertNoThrow(try ModelImporter.checkKindFields(of: manifest))
        var two = manifest
        two.packages.append(.init(name: "B.mlpackage", sha256: "0"))
        XCTAssertThrowsError(try ModelImporter.checkKindFields(of: two))
    }

    func testNoModelMeansNoMap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("latent-dereflect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled"), external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let catalogue = bundled.appendingPathComponent("ModelCatalog.json")
        try "[]".write(to: catalogue, atomically: true, encoding: .utf8)
        let none = ModelRegistry(bundled: bundled, external: external, catalogue: catalogue)
        XCTAssertFalse(ReflectionRemovalMaker.isAvailable(registry: none))
        XCTAssertNil(ReflectionRemovalMaker.defaultSource(registry: none))
        let image = try XCTUnwrap(Self.image(width: 16, height: 16) { _, _ in (0.5, 0.5, 0.5) })
        let made = try await ReflectionRemovalMaker.make(from: image, stored: "dereflect@1", registry: none)
        XCTAssertNil(made, "no stand-in: without a model nothing is made")

        let installed = external.appendingPathComponent("dereflect")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try ModelRegistryTests.json(id: "dereflect", kind: "reflectionRemoval")
            .write(to: installed.appendingPathComponent("dereflect.model.json"), atomically: true, encoding: .utf8)
        let one = ModelRegistry(bundled: bundled, external: external, catalogue: catalogue)
        XCTAssertEqual(ReflectionRemovalMaker.defaultSource(registry: one), "dereflect@1")
        XCTAssertEqual(ReflectionRemovalMaker.displayName(of: "dereflect@1", registry: one), "Dereflect")
        XCTAssertEqual(ReflectionRemovalMaker.model(for: "gone@1", registry: one)?.substituted, "gone")
        XCTAssertNil(ReflectionRemovalMaker.model(for: "dereflect@1", registry: one)?.substituted)
    }

    func testGainsAreLinearRatios() {
        let o = ReflectionRemover.Planar(width: 3, height: 3, r: .init(repeating: 0.8, count: 9),
                                         g: .init(repeating: 0.5, count: 9), b: .init(repeating: 0.02, count: 9))
        let t = ReflectionRemover.Planar(width: 3, height: 3, r: .init(repeating: 0.6, count: 9),
                                         g: .init(repeating: 0.5, count: 9), b: .init(repeating: 0.01, count: 9))
        let g = ReflectionRemover.gains(original: o, removed: t)
        let map = ReflectionMap(width: g.width, height: g.height, gains: g.rgba, source: "t@1")
        let centre = map.gain(x: 1, y: 1)
        let f = ReflectionRemover.ratioFloor
        let expected = (ReflectionRemover.linear(0.6) + f) / (ReflectionRemover.linear(0.8) + f)
        XCTAssertEqual(centre.x, expected, accuracy: 0.01)
        XCTAssertEqual(centre.y, 1, accuracy: 0.01, "unchanged stays at 1")
        XCTAssertGreaterThan(centre.z, 0.9, "near black, the floor keeps the gain near 1")
    }

    func testArrayOutputScalesAndRotatesBack() throws {
        // 0…255 values are recognised.
        let values: [Float] = [255, 0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0]   // 3 planes of 2 x 2
        let planar = ReflectionRemover.planar(values, width: 2, height: 2)
        XCTAssertEqual(planar.r, [1, 0, 0, 0])
        XCTAssertEqual(planar.g, [0, 1, 0, 0])
        // A 4 x 2 upright map turned back for a 90° camera is 2 x 4.
        let rgba = [UInt8](repeating: 128, count: 4 * 2 * 4)
        let map = ReflectionRemover.sensorMap((4, 2, rgba), rotation: .cw90, source: "t@1")
        XCTAssertEqual(map.width, 2)
        XCTAssertEqual(map.height, 4)
        XCTAssertTrue(map.isValid)
    }

    static func image(width: Int, height: Int, _ pixel: (Int, Int) -> (Double, Double, Double)) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = pixel(x, y), i = (y * width + x) * 4
                bytes[i] = UInt8(c.0 * 255); bytes[i + 1] = UInt8(c.1 * 255); bytes[i + 2] = UInt8(c.2 * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
