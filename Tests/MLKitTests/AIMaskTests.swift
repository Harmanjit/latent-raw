import XCTest
import CoreGraphics
@testable import MLKit
@testable import PixelEngine
@testable import RawCore

final class AIMaskTests: XCTestCase {
    static func assetPath(_ name: String) -> String { TestAssets.path(name) }

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

    /// Fraction of mask pixels above half within a normalized region.
    func coverage(_ m: MaskBitmap, x: ClosedRange<Double> = 0...1, y: ClosedRange<Double>) -> Double {
        let y0 = Int(y.lowerBound * Double(m.height)), y1 = max(y0 + 1, Int(y.upperBound * Double(m.height)))
        let x0 = Int(x.lowerBound * Double(m.width)), x1 = max(x0 + 1, Int(x.upperBound * Double(m.width)))
        var on = 0, n = 0
        for yy in y0..<min(y1, m.height) { for xx in x0..<min(x1, m.width) { n += 1; if m.data[yy * m.width + xx] > 127 { on += 1 } } }
        return Double(on) / Double(max(n, 1))
    }

    func testSegFormerLabelsAndSkyOnTheSunset() async throws {
        try XCTSkipUnless(SegmentationModel.isAvailable, "SegFormer package not bundled")
        let model = try await SegmentationModel.load()
        XCTAssertEqual(model.labels.count, 150)
        XCTAssertEqual(model.labels[2], "sky")
        XCTAssertEqual(model.inputSize, 512)

        let image = try smallImage("HSB_6548.NEF")
        let t0 = Date()
        let map = try model.classify(image)
        let t1 = Date()
        let map2 = try model.classify(image)
        let t2 = Date()
        let sky = map.mask(classIndices: model.indices(forLabels: ["sky"]))
        let top = coverage(sky, y: 0...0.25), bottom = coverage(sky, y: 0.8...1)
        print(String(format: "SEGFORMER cold %.0f ms, warm %.0f ms; sky top %.0f%% bottom %.0f%%",
                     t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, top * 100, bottom * 100))
        _ = map2
        XCTAssertGreaterThan(top, 0.9, "the upper frame is all sky")
        XCTAssertLessThan(bottom, 0.05, "the rocks are not sky")

        // The orange cloud band the heuristic missed sits around 40-45% down.
        let band = coverage(sky, x: 0.2...0.7, y: 0.40...0.46)
        print(String(format: "SEGFORMER sunset cloud band coverage %.0f%%", band * 100))
        XCTAssertGreaterThan(band, 0.8, "warm clouds are still sky")

        // The generator routes 'sky' through the same model.
        let r = try await AIMaskGenerator.generate(.sky, from: image)
        XCTAssertGreaterThan(coverage(r.mask, y: 0...0.25), 0.9)
    }

    func testSegFormerFindsRockAndVegetationInTheSquirrelScene() async throws {
        try XCTSkipUnless(SegmentationModel.isAvailable)
        let model = try await SegmentationModel.load()
        let map = try model.classify(try smallImage("HSB_2639.NEF"))
        let veg = map.mask(classIndices: model.indices(forLabels: SegmentClass.vegetation.labels))
        let sky = map.mask(classIndices: model.indices(forLabels: ["sky"]))
        print(String(format: "SEGFORMER squirrel scene: vegetation %.0f%%, sky %.0f%%", veg.coverage * 100, sky.coverage * 100))
        XCTAssertGreaterThan(veg.coverage, 0.1, "grass and shrubs")
        XCTAssertLessThan(sky.coverage, 0.02, "no sky in this frame")
    }

    func testSAM2ClickSelectsTheSquirrel() async throws {
        try XCTSkipUnless(SAM2Models.isAvailable, "SAM2 packages not bundled")
        let models = try await SAM2Models.load()
        let image = try smallImage("HSB_2639.NEF")
        let session = try SAM2Session(models: models, image: image)

        // The squirrel sits at roughly (0.48, 0.55) of the frame.
        let click = PromptPoint(x: 0.48, y: 0.55, foreground: true)
        let p1 = try session.predict(points: [click])
        let p2 = try session.predict(points: [click])
        print(String(format: "SAM2 encode %.0f ms, decode %.0f ms then %.0f ms, score %.2f, coverage %.1f%%, mask %dx%d",
                     session.encodeSeconds * 1000, p1.seconds * 1000, p2.seconds * 1000,
                     p1.score, p1.mask.coverage * 100, p1.mask.width, p1.mask.height))
        XCTAssertEqual(p1.mask.width, 256)
        // The clicked point is inside the mask; the far corners are not.
        let m = p1.mask
        XCTAssertGreaterThan(m.data[Int(0.55 * 255) * 256 + Int(0.48 * 255)], 127)
        XCTAssertLessThan(coverage(m, x: 0...0.15, y: 0...0.15), 0.05)
        XCTAssertLessThan(coverage(m, x: 0.85...1, y: 0.85...1), 0.05)
        XCTAssertTrue((0.003...0.3).contains(p1.mask.coverage), "a squirrel, not the whole frame: \(p1.mask.coverage)")

        // A background click on the log above should not add the log.
        let exclude = PromptPoint(x: 0.5, y: 0.15, foreground: false)
        let p3 = try session.predict(points: [click, exclude])
        XCTAssertLessThan(coverage(p3.mask, x: 0.3...0.7, y: 0.05...0.2), 0.05)
    }

    func testVisionSubjectStillWorks() throws {
        let image = try smallImage("HSB_2639.NEF")
        let mask = try AIMaskGenerator.subjectMask(image)
        XCTAssertGreaterThan(mask.coverage, 0.002)
        XCTAssertLessThan(mask.coverage, 0.6)
    }

    func testAIMaskDrivesALocalAdjustment() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        let local = LocalAdjustment(name: "ai", shape: .prompted(points: [], modelVersion: "test"), exposureEV: 2)
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
