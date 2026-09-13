import XCTest
import Metal
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

    /// The GPU export pack: a 2x1 texture, red then green, turned 90° CW
    /// must come out 1 wide, 2 tall, red on top (the left edge becomes
    /// the top edge).
    func testExporterRotationSwapsDimensions() throws {
        let gpu = try GPUContext()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2, height: 1, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead]
        let tex = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        let px: [Float16] = [1, 0, 0, 1,  0, 1, 0, 1]
        px.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }

        let image = try Exporter(gpu: gpu).cgImage(from: tex, colorSpace: .sRGB, rotation: .cw90)
        XCTAssertEqual(image.width, 1); XCTAssertEqual(image.height, 2)
        var bytes = [UInt8](repeating: 0, count: 8)
        let ctx = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 2, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 2))
        // A bitmap context stores its first row at the top of the image.
        XCTAssertGreaterThan(bytes[0], 200, "top pixel red"); XCTAssertLessThan(bytes[1], 50)
        XCTAssertGreaterThan(bytes[5], 200, "bottom pixel green"); XCTAssertLessThan(bytes[4], 50)
    }
}
