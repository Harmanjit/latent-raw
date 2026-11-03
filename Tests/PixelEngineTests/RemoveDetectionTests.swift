import XCTest
import simd
@testable import PixelEngine

/// Detect Objects' geometry: the crop given to the model, the prompts, and
/// turning its mask into the outline a Remove patch stores.
final class RemoveDetectionTests: XCTestCase {
    let sensor = CGSize(width: 6000, height: 4000)

    /// A 256 x 256 mask over the crop with discs lit at `discs` (cells).
    func mask(_ discs: [(x: Int, y: Int, r: Int)], side: Int = 256) -> MaskBitmap {
        var data = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side {
            for d in discs where (x - d.x) * (x - d.x) + (y - d.y) * (y - d.y) <= d.r * d.r { data[y * side + x] = 230 }
        } }
        return MaskBitmap(width: side, height: side, data: data)
    }

    func testCropIsASquareAroundTheBrushOnTheImage() throws {
        let aspect: Float = 1.5
        let path: [SIMD2<Float>] = [[0.40, 0.50], [0.45, 0.52]]
        let crop = try XCTUnwrap(RemoveDetection.cropRect(path: path, radius: 0.01, aspect: aspect))
        // Square in pixels: width x aspect equals height.
        XCTAssertEqual(Float(crop.width) * aspect, Float(crop.height), accuracy: 1e-4)
        XCTAssertTrue(crop.contains(CGPoint(x: 0.40, y: 0.50)) && crop.contains(CGPoint(x: 0.45, y: 0.52)))
        XCTAssertLessThan(crop.width, 0.3)
        // At a corner it slides onto the image.
        let corner = try XCTUnwrap(RemoveDetection.cropRect(path: [[0.01, 0.99]], radius: 0.01, aspect: aspect))
        XCTAssertGreaterThanOrEqual(corner.minX, 0)
        XCTAssertLessThanOrEqual(corner.maxY, 1 + 1e-6)
        XCTAssertNil(RemoveDetection.cropRect(path: [], radius: 0.01, aspect: aspect))
    }

    func testPromptsSpreadAlongTheStroke() {
        let points = RemoveDetection.promptPoints(along: [[0, 0], [1, 0], [1, 1]], count: 5)
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.first, [0, 0])
        XCTAssertEqual(points.last, [1, 1])
        XCTAssertEqual(points[2].x, 1, accuracy: 1e-5)
        XCTAssertEqual(points[2].y, 0, accuracy: 1e-5)
        XCTAssertEqual(RemoveDetection.promptPoints(along: [[0.3, 0.3]]), [[0.3, 0.3]])
    }

    /// The object joined to the brush is kept and grown a little; another
    /// object the model lit up in the crop is not.
    func testOutlineKeepsTheBrushedObjectOnly() throws {
        let crop = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.15)
        let m = mask([(x: 100, y: 120, r: 30), (x: 220, y: 30, r: 15)])
        let seed = SIMD2<Float>(0.4 + 100.0 / 256 * 0.1, 0.4 + 120.0 / 256 * 0.15)
        let target = seed
        let outline = try XCTUnwrap(RemoveDetection.objectMask(
            from: m, crop: crop, seeds: [seed], toOutput: { $0 }, toRaw: { $0 }, target: target, sensorSize: sensor))
        let box = outline.bounds(target: target, sensorSize: sensor)
        // The disc is 60 cells across; a cell is 600/256 px wide and 600/256 px tall.
        let cellPx = 600.0 / 256
        XCTAssertGreaterThan(box.width, 60 * cellPx)
        XCTAssertLessThan(box.width, 90 * cellPx)
        // The far blob, at cell (220, 30), lies outside the box.
        let far = CGPoint(x: (0.4 + 220.0 / 256 * 0.1) * 6000, y: (0.4 + 30.0 / 256 * 0.15) * 4000)
        XCTAssertFalse(box.contains(far))
        // The centre is in, the box corner (outside the disc) is out.
        func covers(_ sensorPoint: CGPoint) -> Bool {
            let x = Int((sensorPoint.x - box.minX) / box.width * CGFloat(outline.width))
            let y = Int((sensorPoint.y - box.minY) / box.height * CGFloat(outline.height))
            return outline.contains(x: x, y: y)
        }
        XCTAssertTrue(covers(CGPoint(x: box.midX, y: box.midY)))
        XCTAssertFalse(covers(CGPoint(x: box.minX + 1, y: box.minY + 1)))
        XCTAssertLessThanOrEqual(max(outline.width, outline.height), RemoveDetection.storedSide)
        XCTAssertNotNil(outline.sanitized)
    }

    /// Nothing at the brush, or most of the crop taken: no outline.
    func testNoOutlineWhenTheModelMissesOrTakesTheBackground() {
        let crop = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.15)
        let seed = SIMD2<Float>(0.41, 0.41)
        XCTAssertNil(RemoveDetection.objectMask(from: mask([(x: 200, y: 200, r: 20)]), crop: crop, seeds: [seed],
                                                toOutput: { $0 }, toRaw: { $0 }, target: seed, sensorSize: sensor))
        XCTAssertNil(RemoveDetection.objectMask(from: mask([(x: 128, y: 128, r: 200)]), crop: crop, seeds: [seed],
                                                toOutput: { $0 }, toRaw: { $0 }, target: seed, sensorSize: sensor))
    }

    /// With a lens map, the outline is stored on the raw grid: a raw point
    /// whose output position is in the object is in the outline.
    func testOutlineGoesThroughTheLensMap() throws {
        let crop = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.15)
        let m = mask([(x: 128, y: 128, r: 40)])
        let shift = SIMD2<Float>(0.01, -0.005)
        let toRaw: (SIMD2<Float>) -> SIMD2<Float> = { $0 + shift }
        let toOutput: (SIMD2<Float>) -> SIMD2<Float> = { $0 - shift }
        let centreOut = SIMD2<Float>(0.45, 0.475)
        let target = toRaw(centreOut)
        let outline = try XCTUnwrap(RemoveDetection.objectMask(
            from: m, crop: crop, seeds: [centreOut], toOutput: toOutput, toRaw: toRaw, target: target, sensorSize: sensor))
        let box = outline.bounds(target: target, sensorSize: sensor)
        XCTAssertEqual(box.midX / 6000, CGFloat(target.x), accuracy: 0.002)
        XCTAssertEqual(box.midY / 4000, CGFloat(target.y), accuracy: 0.002)
    }
}
