import XCTest
import Metal
import simd
import ColorKit
@testable import PixelEngine

/// Pet Eye, the red-eye tool's second mode: the stored form and the kernel
/// on a synthetic animal eye whose pupil glows green.
final class PetEyeTests: XCTestCase {
    func testStoredFormAndRedEyeSpotsUnchanged() throws {
        // A person's spot encodes exactly as before: no kind, no catchlight.
        let human = RedEyeSpot(centre: [0.4, 0.3], radius: 0.01, kind: .human, catchlight: SIMD2(1, 0))
        XCTAssertNil(human.kind)
        XCTAssertNil(human.catchlight, "only a Pet Eye spot carries a catchlight")
        let humanJSON = String(decoding: try JSONEncoder().encode(human), as: UTF8.self)
        XCTAssertFalse(humanJSON.contains("kind"))
        XCTAssertFalse(humanJSON.contains("catchlight"))

        var p = EditParameters()
        p.redEyes = [RedEyeSpot(centre: [0.4, 0.3], radius: 0.01, kind: .pet, catchlight: SIMD2(-3, -4))]
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"pet\""))
        let back = try EditStack.decode(json: json).parameters().redEyes
        XCTAssertEqual(back.first?.kind, .pet)
        // The decode sanitises the direction to unit length.
        let glint = try XCTUnwrap(back.first?.catchlight)
        XCTAssertEqual(glint.x, -0.6, accuracy: 1e-5)
        XCTAssertEqual(glint.y, -0.8, accuracy: 1e-5)

        // A kind from a later build reads as red-eye rather than failing.
        let future = try JSONDecoder().decode(RedEyeSpot.self, from: Data(#"{"centre":[0.1,0.2],"kind":"horse"}"#.utf8))
        XCTAssertNil(future.kind)
    }

    static let w = 120, h = 80
    static func linearP3(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> { RedEyeTests.linearP3(r, g, b) }

    /// Rec.2020 linear (identity camera matrix): fur, a glowing green-yellow
    /// pupil at (40, 40), radius 8, in an amber iris of radius 14.
    static func eye(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let dx = Double(x) + 0.5 - 40, dy = Double(y) + 0.5 - 40
        let d = (dx * dx + dy * dy).squareRoot()
        let c: SIMD3<Float>
        if d <= 8 { c = linearP3(170, 240, 120) }
        else if d <= 14 { c = linearP3(190, 140, 40) }
        else { c = linearP3(120, 100, 80) }
        let xyz: SIMD3<Float> = ColorKit.displayP3ToXYZ * c
        let rec2020: SIMD3<Float> = ColorKit.rec2020ToXYZ.inverse * xyz
        return SIMD3(Double(rec2020.x), Double(rec2020.y), Double(rec2020.z))
    }

    func testKernelDarkensThePupilAndAddsACatchlight() throws {
        let gpu = try GPUContext()
        let size = SIMD2<Float>(Float(Self.w), Float(Self.h))
        let input = try HealQualityTests.texture(width: Self.w, height: Self.h, gpu: gpu) { Self.eye($0, $1) }
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
        // The circle is the pupil: radius 8 px of an 80 px short side.
        let centre = SIMD2<Float>(40, 40) / size
        let radius: Float = 8.0 / 80

        // The red-eye kernel leaves a green pupil alone: it is not red.
        let asRedEye = try run([RedEyeSpot(centre: centre, radius: radius)])
        XCTAssertLessThan(simd_reduce_max(simd_abs(asRedEye(41, 41) - Self.eye(41, 41))), 2e-3)

        let plain = try run([RedEyeSpot(centre: centre, radius: radius, kind: .pet)])
        let middle = plain(41, 41)
        XCTAssertLessThan(simd_reduce_max(middle), 0.02, "the glow becomes a dark pupil: \(middle)")
        XCTAssertLessThan(simd_reduce_max(simd_abs(plain(40, 52) - Self.eye(40, 52))), 2e-3, "the iris keeps its colour")
        XCTAssertLessThan(simd_reduce_max(simd_abs(plain(5, 5) - Self.eye(5, 5))), 1e-3, "fur outside")

        // Up and to the left on the texture: the catchlight sits about
        // three pixels from the centre that way, bright, and the opposite
        // side stays dark.
        let lit = try run([RedEyeSpot(centre: centre, radius: radius, kind: .pet,
                                      catchlight: SIMD2(-1, -1) / Float(2).squareRoot())])
        let glint = lit(37, 37), opposite = lit(42, 42)
        XCTAssertGreaterThan(simd_reduce_min(glint), 0.25, "a catchlight: \(glint)")
        XCTAssertLessThan(simd_reduce_max(opposite), 0.02)

        let none = try run([RedEyeSpot(centre: centre, radius: radius, strength: 0, kind: .pet)])
        XCTAssertLessThan(simd_reduce_max(simd_abs(none(41, 41) - Self.eye(41, 41))), 1e-3, "no strength, no change")
    }
}
