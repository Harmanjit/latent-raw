import XCTest
import CoreGraphics
@testable import MLKit
@testable import PixelEngine
@testable import RawCore

final class AIMaskTests: XCTestCase {
    static func assetPath(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets").appendingPathComponent(name).path
    }

    /// A ~1000px sRGB CGImage of a sample, the way the app feeds the models.
    func smallImage(_ name: String) throws -> CGImage {
        let path = Self.assetPath(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        let tex = try RenderPipeline(gpu: gpu).render(session, scale: .binned(quads: 3),
                                                       parameters: EditParameters(), output: .file(.sRGB))
        return try Exporter(gpu: gpu).cgImage(from: tex, colorSpace: .sRGB)
    }

    /// Fraction of mask pixels above half within a normalized band of rows.
    func coverage(_ m: MaskBitmap, rows: ClosedRange<Double>) -> Double {
        let y0 = Int(rows.lowerBound * Double(m.height)), y1 = max(y0 + 1, Int(rows.upperBound * Double(m.height)))
        var on = 0, n = 0
        for y in y0..<min(y1, m.height) { for x in 0..<m.width { n += 1; if m.data[y * m.width + x] > 127 { on += 1 } } }
        return Double(on) / Double(max(n, 1))
    }

    func testSubjectLiftFindsTheSquirrelAndNotTheWholeFrame() throws {
        let image = try smallImage("HSB_2639.NEF")
        let result = try AIMaskGenerator.generate(.subject, from: image)
        print(String(format: "subject mask: %.0fms, %dx%d, coverage %.1f%%",
                     result.seconds * 1000, result.mask.width, result.mask.height, result.mask.coverage * 100))
        XCTAssertGreaterThan(result.mask.width, 1, "a subject was found")
        XCTAssertGreaterThan(result.mask.coverage, 0.002)
        XCTAssertLessThan(result.mask.coverage, 0.6)
    }

    func testPersonMaskIsEmptyOnALandscape() throws {
        let image = try smallImage("HSB_6548.NEF")
        let result = try AIMaskGenerator.generate(.person, from: image)
        print(String(format: "person mask: %.0fms, coverage %.2f%%", result.seconds * 1000, result.mask.coverage * 100))
        XCTAssertLessThan(result.mask.coverage, 0.02, "no people in a mountain sunset")
    }

    func testSkyHeuristicSelectsTopNotBottom() throws {
        let image = try smallImage("HSB_6548.NEF")
        let result = try AIMaskGenerator.generate(.sky, from: image)
        let top = coverage(result.mask, rows: 0...0.2), bottom = coverage(result.mask, rows: 0.8...1)
        print(String(format: "sky mask: %.0fms, top %.0f%% bottom %.0f%%", result.seconds * 1000, top * 100, bottom * 100))
        XCTAssertGreaterThan(top, 0.7)
        XCTAssertLessThan(bottom, 0.1)
    }

    func testAIMaskDrivesALocalAdjustment() throws {
        let path = Self.assetPath("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        // A synthetic mask: top half on. Exposure +2 must brighten the top
        // by 4x and leave the bottom alone; without pixels, nothing changes.
        let local = LocalAdjustment(name: "ai", shape: .ai(kind: "sky", modelVersion: "test"), exposureEV: 2)
        var p = EditParameters(); p.locals = [local]

        func luma(at ny: Float) throws -> Double {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .sceneLinear)
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            let w = tex.width, h = tex.height
            let i = (Int(ny * Float(h)) * w + w / 2) * 4
            return 0.2627 * Double(px[i]) + 0.678 * Double(px[i + 1]) + 0.0593 * Double(px[i + 2])
        }
        var base = p; base.locals = []
        let saved = p; p = base
        let topBase = try luma(at: 0.1), bottomBase = try luma(at: 0.9)
        p = saved

        XCTAssertEqual(try luma(at: 0.1), topBase, accuracy: topBase * 0.01, "no pixels yet: no effect")

        var data = [UInt8](repeating: 0, count: 64 * 64)
        for y in 0..<32 { for x in 0..<64 { data[y * 64 + x] = 255 } }
        session.setAIMask(MaskBitmap(width: 64, height: 64, data: data), forLocal: local.id)
        XCTAssertEqual(try luma(at: 0.1), topBase * 4, accuracy: topBase * 0.2)
        XCTAssertEqual(try luma(at: 0.9), bottomBase, accuracy: bottomBase * 0.02)
    }
}
