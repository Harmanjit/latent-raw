import XCTest
import Metal
import simd
@testable import PixelEngine

final class CropTests: XCTestCase {
    let sensor = CGSize(width: 600, height: 400)

    func testIdentityFrameMatchesPlainRotation() {
        for rotation in ImageRotation.allCases {
            let frame = CropFrame(sensorSize: sensor, rotation: rotation)
            XCTAssertEqual(frame.canvasSize, rotation.imageSize(forSensorSize: sensor))
            for p in [CGPoint.zero, CGPoint(x: 600, y: 400), CGPoint(x: 123.5, y: 77.25)] {
                let viaRotation = rotation.imagePoint(fromSensorPoint: p, sensorSize: sensor)
                let viaFrame = frame.canvasPoint(fromSensorPoint: p)
                XCTAssertEqual(viaFrame.x, viaRotation.x, accuracy: 1e-9, "\(rotation)")
                XCTAssertEqual(viaFrame.y, viaRotation.y, accuracy: 1e-9, "\(rotation)")
                let back = frame.sensorPoint(fromCanvasPoint: viaFrame)
                XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
                XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
            }
        }
    }

    func testCentredHalfCrop() {
        let crop = CropParameters(centre: [0.5, 0.5], size: [0.5, 0.5])
        let frame = CropFrame(sensorSize: sensor, crop: crop)
        XCTAssertEqual(frame.canvasSize, CGSize(width: 300, height: 200))
        // Canvas origin is the crop's top-left corner on the sensor.
        let tl = frame.sensorPoint(fromCanvasPoint: .zero)
        XCTAssertEqual(tl.x, 150, accuracy: 1e-9); XCTAssertEqual(tl.y, 100, accuracy: 1e-9)
        let br = frame.sensorPoint(fromCanvasPoint: CGPoint(x: 300, y: 200))
        XCTAssertEqual(br.x, 450, accuracy: 1e-9); XCTAssertEqual(br.y, 300, accuracy: 1e-9)
        XCTAssertFalse(crop.isIdentity)
        XCTAssertTrue(CropParameters.none.isIdentity)
    }

    /// Positive angle shows the picture turned clockwise: what was above
    /// the centre on the sensor appears to the right of it on the canvas.
    func testPositiveAngleTurnsClockwise() {
        let crop = CropParameters(centre: [0.5, 0.5], size: [0.5, 0.5], angle: 90)
        let frame = CropFrame(sensorSize: CGSize(width: 400, height: 400), crop: crop)
        let right = frame.sensorPoint(fromCanvasPoint: CGPoint(x: 150, y: 100))   // 50 right of centre
        XCTAssertEqual(right.x, 200, accuracy: 1e-6)
        XCTAssertEqual(right.y, 150, accuracy: 1e-6, "50 above the sensor centre")
        // And the inverse agrees.
        let back = frame.canvasPoint(fromSensorPoint: right)
        XCTAssertEqual(back.x, 150, accuracy: 1e-6); XCTAssertEqual(back.y, 100, accuracy: 1e-6)
    }

    func testStraightenShrinksToFit() {
        var crop = CropParameters()
        crop.angle = 10
        XCTAssertFalse(crop.fitsInside(sensorSize: sensor), "a tilted full frame pokes out")
        let fitted = crop.constrained(sensorSize: sensor)
        XCTAssertTrue(fitted.fitsInside(sensorSize: sensor))
        XCTAssertLessThan(fitted.size.x, 1); XCTAssertLessThan(fitted.size.y, 1)
        // Aspect preserved by the shrink.
        XCTAssertEqual(fitted.ratio(sensorSize: sensor), crop.ratio(sensorSize: sensor), accuracy: 1e-5)
        // Every canvas corner lands inside the sensor.
        let frame = CropFrame(sensorSize: sensor, crop: fitted)
        let c = frame.canvasSize
        for p in [CGPoint.zero, CGPoint(x: c.width, y: 0), CGPoint(x: 0, y: c.height), CGPoint(x: c.width, y: c.height)] {
            let s = frame.sensorPoint(fromCanvasPoint: p)
            XCTAssertGreaterThanOrEqual(s.x, -0.5); XCTAssertLessThanOrEqual(s.x, 600.5)
            XCTAssertGreaterThanOrEqual(s.y, -0.5); XCTAssertLessThanOrEqual(s.y, 400.5)
        }
        // Zero degrees never shrinks.
        XCTAssertEqual(CropParameters().constrained(sensorSize: sensor), CropParameters())
    }

    func testAspectLock() {
        let square = CropParameters().withAspect(1, sensorSize: sensor)
        XCTAssertEqual(square.ratio(sensorSize: sensor), 1, accuracy: 1e-5)
        XCTAssertEqual(square.pixelSize(sensorSize: sensor).height, 400, accuracy: 1e-6, "keeps the short side")
        XCTAssertEqual(square.aspect, 1)
        let wide = CropParameters().withAspect(16.0 / 9, sensorSize: sensor)
        XCTAssertEqual(wide.pixelSize(sensorSize: sensor).width, 600, accuracy: 1e-6)
        XCTAssertEqual(wide.ratio(sensorSize: sensor), 16.0 / 9, accuracy: 1e-5)
    }

    /// The tool shows the crop as an axis-aligned rectangle on a canvas
    /// holding the whole tilted sensor; reading that rectangle back must
    /// give the same crop, with any rotation.
    func testToolCanvasRoundTrip() {
        for rotation in ImageRotation.allCases {
            let crop = CropParameters(centre: [0.4, 0.55], size: [0.3, 0.25], angle: 7)
            let frame = CropFrame(sensorSize: sensor, crop: crop, rotation: rotation)
            let rect = frame.toolCanvasRect
            let tool = frame.toolFrame
            XCTAssertTrue(CGRect(origin: .zero, size: tool.canvasSize).insetBy(dx: -0.01, dy: -0.01).contains(rect),
                          "\(rotation): crop rect must sit on the tool canvas")
            let back = frame.cropForToolCanvasRect(rect)
            XCTAssertEqual(back.centre.x, crop.centre.x, accuracy: 1e-5, "\(rotation)")
            XCTAssertEqual(back.centre.y, crop.centre.y, accuracy: 1e-5, "\(rotation)")
            XCTAssertEqual(back.size.x, crop.size.x, accuracy: 1e-5, "\(rotation)")
            XCTAssertEqual(back.size.y, crop.size.y, accuracy: 1e-5, "\(rotation)")
            XCTAssertEqual(back.angle, 7)
        }
    }

    func testSensorRectFromTiltedCanvasIsABoundingBox() {
        let crop = CropParameters(centre: [0.5, 0.5], size: [0.5, 0.5], angle: 45)
        let frame = CropFrame(sensorSize: CGSize(width: 400, height: 400), crop: crop)
        let r = frame.sensorRect(fromCanvasRect: CGRect(origin: .zero, size: frame.canvasSize))
        // A 200×200 square at 45° spans 200·√2 ≈ 282.8 on each axis.
        XCTAssertEqual(r.width, 282.84, accuracy: 0.01)
        XCTAssertEqual(r.height, 282.84, accuracy: 0.01)
        XCTAssertEqual(r.midX, 200, accuracy: 1e-6)
    }

    /// The export map reproduces the old rotation-only kernel's mapping.
    func testSamplingMapMatchesQuarterTurnConvention() {
        let frame = CropFrame(sensorSize: CGSize(width: 2, height: 1), rotation: .cw90)
        let m = frame.normalizedSamplingMap()
        func uv(_ x: Float, _ y: Float) -> SIMD2<Float> { m * SIMD3(x, y, 1) }
        // 90° CW: dest (0,0) samples source (0,1); dest (1,0) samples (0,0).
        XCTAssertEqual(uv(0, 0).x, 0, accuracy: 1e-6); XCTAssertEqual(uv(0, 0).y, 1, accuracy: 1e-6)
        XCTAssertEqual(uv(1, 0).x, 0, accuracy: 1e-6); XCTAssertEqual(uv(1, 0).y, 0, accuracy: 1e-6)
        XCTAssertEqual(uv(0, 1).x, 1, accuracy: 1e-6); XCTAssertEqual(uv(0, 1).y, 1, accuracy: 1e-6)
    }

    func testEditStackRoundTripAndGroup() throws {
        var p = EditParameters()
        p.crop = CropParameters(centre: [0.4, 0.6], size: [0.5, 0.25], angle: -3.5, aspect: 2)
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"crop\""))
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.crop, p.crop)
        XCTAssertNil(EditStack(parameters: EditParameters()).modules.crop, "no crop, no module")

        XCTAssertFalse(EditGroup.lookGroups.contains(.crop), "a crop is per frame; never pasted by default")
        let stack = EditStack(parameters: p)
        XCTAssertTrue(stack.presentGroups.contains(.crop))
        let merged = EditStack().merged(with: stack, groups: [.crop])
        XCTAssertEqual(merged.modules.crop, stack.modules.crop)
    }

    /// GPU: crop the left half of a 2×1 red/green texture → 1×1 red; the
    /// right half → green. Proves the pack kernel samples through the map.
    func testExporterCrops() throws {
        let gpu = try GPUContext()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2, height: 1, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead]
        let tex = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        let px: [Float16] = [1, 0, 0, 1,  0, 1, 0, 1]
        px.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }

        func pixel(_ crop: CropParameters) throws -> (r: UInt8, g: UInt8, w: Int, h: Int) {
            let image = try Exporter(gpu: gpu).cgImage(from: tex, colorSpace: .sRGB, crop: crop)
            var bytes = [UInt8](repeating: 0, count: 4 * image.width * image.height)
            let ctx = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: 4 * image.width, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (bytes[0], bytes[1], image.width, image.height)
        }
        let left = try pixel(CropParameters(centre: [0.25, 0.5], size: [0.5, 1]))
        XCTAssertEqual(left.w, 1); XCTAssertEqual(left.h, 1)
        XCTAssertGreaterThan(left.r, 200); XCTAssertLessThan(left.g, 50)
        let right = try pixel(CropParameters(centre: [0.75, 0.5], size: [0.5, 1]))
        XCTAssertGreaterThan(right.g, 200); XCTAssertLessThan(right.r, 50)
    }
}
