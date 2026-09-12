import XCTest
import simd
@testable import PixelEngine

final class ImageRotationTests: XCTestCase {
    let sensor = CGSize(width: 600, height: 400)

    func testLibRawFlipMapping() {
        XCTAssertEqual(ImageRotation(libRawFlip: 0), .none)
        XCTAssertEqual(ImageRotation(libRawFlip: 3), .cw180)
        XCTAssertEqual(ImageRotation(libRawFlip: 5), .cw270)
        XCTAssertEqual(ImageRotation(libRawFlip: 6), .cw90)
        XCTAssertEqual(ImageRotation.cw270.rotated(by: 1), .none)
        XCTAssertEqual(ImageRotation.none.rotated(by: -1), .cw270)
    }

    func testSizesAndCornersForEveryRotation() {
        for rotation in ImageRotation.allCases {
            let size = rotation.imageSize(forSensorSize: sensor)
            XCTAssertEqual(size, rotation.swapsAxes ? CGSize(width: 400, height: 600) : sensor)

            // Every sensor corner must land on an image corner, and the
            // top-left of the sensor moves clockwise around the image.
            let tl = rotation.imagePoint(fromSensorPoint: .zero, sensorSize: sensor)
            let expected: CGPoint
            switch rotation {
            case .none:  expected = .zero
            case .cw90:  expected = CGPoint(x: 400, y: 0)     // top-right of a 400-wide image
            case .cw180: expected = CGPoint(x: 600, y: 400)
            case .cw270: expected = CGPoint(x: 0, y: 600)
            }
            XCTAssertEqual(tl, expected, "\(rotation)")
        }
    }

    func testPointRoundTrip() {
        let p = CGPoint(x: 123.5, y: 77.25)
        for rotation in ImageRotation.allCases {
            let image = rotation.imagePoint(fromSensorPoint: p, sensorSize: sensor)
            let back = rotation.sensorPoint(fromImagePoint: image, sensorSize: sensor)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        }
    }

    func testRectMappingKeepsArea() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 50)
        for rotation in ImageRotation.allCases {
            let s = rotation.sensorRect(fromImageRect: r, sensorSize: sensor)
            XCTAssertEqual(s.width * s.height, 5000, accuracy: 1e-9)
            let back = rotation.imageRect(fromSensorRect: s, sensorSize: sensor)
            XCTAssertEqual(back, r)
        }
    }

    /// At fit, with a 90° rotation, the screen's top-left should map to
    /// the sensor's *bottom*-left, i.e. uv (0, 1) of a full-sensor texture.
    func testScreenToTextureMapHonoursRotation() {
        let drawable = CGSize(width: 400, height: 600)
        let rotation = ImageRotation.cw90
        let imageSize = rotation.imageSize(forSensorSize: sensor)   // 400 x 600, exact fit
        let t = ViewportTransform.fit(imageSize: imageSize, drawableSize: drawable)
        let m = t.screenToTextureMap(coverage: CGRect(origin: .zero, size: sensor),
                                     rotation: rotation, sensorSize: sensor, drawableSize: drawable)
        func uv(_ x: Float, _ y: Float) -> SIMD2<Float> { simd_mul(m, SIMD3<Float>(x, y, 1)) }
        XCTAssertEqual(uv(0, 0).x, 0, accuracy: 1e-5)
        XCTAssertEqual(uv(0, 0).y, 1, accuracy: 1e-5)
        XCTAssertEqual(uv(400, 600).x, 1, accuracy: 1e-5)
        XCTAssertEqual(uv(400, 600).y, 0, accuracy: 1e-5)
    }

    func testExporterRotationSwapsDimensions() {
        // 2x1 image: pixels A then B. Turn it 90° clockwise and the left
        // edge becomes the top edge, so it's 1 wide, 2 tall with A on top.
        let a: [Float16] = [1, 0, 0, 1], b: [Float16] = [0, 1, 0, 1]
        let out = Exporter.rotate(a + b, width: 2, height: 1, rotation: .cw90)
        XCTAssertEqual(out.count, 8)
        XCTAssertEqual(Array(out[0..<4]), a, "A (left) becomes top")
        XCTAssertEqual(Array(out[4..<8]), b, "B (right) becomes bottom")
    }
}
