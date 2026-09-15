import XCTest
import Metal
import simd
import ColorKit
@testable import PixelEngine

/// Red-eye removal: the stored form and the kernel on a synthetic eye.
final class RedEyeTests: XCTestCase {
    func testEditStackRoundTripAndAbsentWhenEmpty() throws {
        XCTAssertNil(EditStack(parameters: EditParameters()).modules.redeye)
        XCTAssertFalse(try EditStack(parameters: EditParameters()).encodeJSON().contains("redeye"))
        var p = EditParameters()
        p.redEyes = [RedEyeSpot(centre: [0.4, 0.3], radius: 0.01, strength: 0.8)]
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"redeye\""))
        XCTAssertEqual(try EditStack.decode(json: json).parameters().redEyes, p.redEyes)
        XCTAssertNotEqual(p, EditParameters())
        // Copied and pasted with spot removal, never with the look.
        XCTAssertTrue(EditStack(parameters: p).presentGroups.contains(.heal))
        XCTAssertNil(EditStack(parameters: p).restricted(to: EditGroup.lookGroups).modules.redeye)
        XCTAssertEqual(EditStack().merged(with: EditStack(parameters: p), groups: [.heal]).modules.redeye, p.redEyes)
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(), to: EditStack(parameters: p)).contains("Red-Eye"), true)
        // A spot missing keys loads with defaults.
        let lenient = try JSONDecoder().decode(RedEyeSpot.self, from: Data(#"{"centre":[0.1,0.2]}"#.utf8))
        XCTAssertEqual(lenient.radius, RedEyeSpot.defaultRadius)
        XCTAssertEqual(lenient.strength, 1)
    }

    /// Linear Display P3 from 8-bit sRGB, for the CPU measure.
    static func linearP3(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        func d(_ v: Float) -> Float { let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let linear = SIMD3<Float>(d(r), d(g), d(b))
        let xyz: SIMD3<Float> = ColorKit.sRGBToXYZ * linear
        return ColorKit.displayP3ToXYZ.inverse * xyz
    }

    func testPupilRedMeasure() {
        for (c, red) in [((200, 40, 40), true), ((170, 70, 55), true), ((140, 20, 45), true),
                         ((90, 40, 20), false), ((120, 70, 40), false), ((224, 172, 140), false),
                         ((250, 250, 250), false)] as [((Float, Float, Float), Bool)] {
            XCTAssertEqual(RedEyeTuning.isPupilRed(Self.linearP3(c.0, c.1, c.2)), red, "\(c)")
        }
    }

    static let w = 160, h = 100
    /// Rec.2020 linear (the camera matrix is identity here): skin, a red
    /// pupil in a brown iris at (50, 50) with a catchlight, and a dark
    /// pupil in a brown iris at (120, 50).
    static func eyes(_ x: Int, _ y: Int) -> SIMD3<Double> {
        func inDisc(_ cx: Double, _ cy: Double, _ r: Double) -> Bool {
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
            return dx * dx + dy * dy <= r * r
        }
        let c: SIMD3<Float>
        if inDisc(47, 47, 2) { c = linearP3(255, 255, 255) }
        else if inDisc(50, 50, 7) { c = linearP3(200, 40, 40) }
        else if inDisc(120, 50, 7) { c = linearP3(30, 25, 25) }
        else if inDisc(50, 50, 14) || inDisc(120, 50, 14) { c = linearP3(120, 70, 40) }
        else { c = linearP3(224, 172, 140) }
        let xyz: SIMD3<Float> = ColorKit.displayP3ToXYZ * c
        let rec2020: SIMD3<Float> = ColorKit.rec2020ToXYZ.inverse * xyz
        return SIMD3(Double(rec2020.x), Double(rec2020.y), Double(rec2020.z))
    }

    func testKernelNeutralisesOnlyTheRedPupil() throws {
        let gpu = try GPUContext()
        let size = SIMD2<Float>(Float(Self.w), Float(Self.h))
        let input = try HealQualityTests.texture(width: Self.w, height: Self.h, gpu: gpu) { Self.eyes($0, $1) }
        func run(_ spots: [RedEyeSpot]) throws -> (Int, Int) -> SIMD3<Double> {
            let output = try XCTUnwrap(gpu.makePrivateTexture(width: Self.w, height: Self.h, pixelFormat: .rgba16Float))
            let cmd = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
            try HealStage.encode(patches: [], redEyes: spots, input: input, output: output, sensorSize: size,
                                 tileOrigin: .zero, binSpan: 1, gpu: gpu, commandBuffer: cmd)
            cmd.commit(); cmd.waitUntilCompleted()
            let px = try TextureReadback.float16Pixels(of: output, gpu: gpu)
            return { x, y in
                let i = (y * Self.w + x) * 4
                return SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
            }
        }
        let toP3 = RedEyeTuning.cameraToP3(matrix_identity_float3x3)
        func p3(_ c: SIMD3<Double>) -> SIMD3<Float> { toP3 * SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)) }

        // Circles generous enough to hold both whole irises.
        let radius: Float = 16.0 / 100
        let out = try run([RedEyeSpot(centre: SIMD2(50, 50) / size, radius: radius),
                           RedEyeSpot(centre: SIMD2(120, 50) / size, radius: radius)])
        let pupil = p3(out(52, 52))
        XCTAssertLessThan(RedEyeTuning.redness(pupil), 1.1, "the red pupil is neutral: \(pupil)")
        XCTAssertLessThan(pupil.x, p3(Self.eyes(52, 52)).x * 0.2, "and dark")
        for (x, y, what) in [(50, 60, "iris"), (120, 52, "dark pupil"), (120, 60, "other iris"),
                             (47, 47, "catchlight"), (50, 70, "skin inside the circle"), (5, 5, "skin outside")] {
            XCTAssertLessThan(simd_reduce_max(simd_abs(out(x, y) - Self.eyes(x, y))), 2e-3, what)
        }
        // No strength, no change.
        let none = try run([RedEyeSpot(centre: SIMD2(50, 50) / size, radius: radius, strength: 0)])
        XCTAssertLessThan(simd_reduce_max(simd_abs(none(52, 52) - Self.eyes(52, 52))), 1e-3)
    }
}
