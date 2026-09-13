import XCTest
@testable import PixelEngine
@testable import RawCore

final class SoftProofTests: XCTestCase {
    func testSRGBProofPassesInGamutAndFlagsOutOfGamut() throws {
        let lut = try SoftProofLUT.build(.sRGB)
        // Mid grey is in every gamut: unchanged, not flagged.
        let grey = lut.lookup(SIMD3(0.2, 0.2, 0.2))
        XCTAssertEqual(grey.color.x, 0.2, accuracy: 0.01)
        XCTAssertFalse(grey.clipped)
        // Pure Rec.2020 green lies far outside sRGB: it moves and is flagged.
        let green = lut.lookup(SIMD3(0.0, 0.8, 0.0))
        XCTAssertTrue(green.clipped)
        XCTAssertGreaterThan(green.color.x + green.color.z, 0.02, "clipping desaturates it")
        XCTAssertGreaterThan(lut.outOfGamutFraction, 0.05)
        XCTAssertLessThan(lut.outOfGamutFraction, 0.8)
        // P3 is wider than sRGB, so fewer colours clip.
        let p3 = try SoftProofLUT.build(.displayP3)
        XCTAssertLessThan(p3.outOfGamutFraction, lut.outOfGamutFraction)
    }

    func testICCProfileProofViaColorSync() throws {
        let url = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let lut = try SoftProofLUT.build(.icc(url))
        let grey = lut.lookup(SIMD3(0.3, 0.3, 0.3))
        XCTAssertEqual(grey.color.y, 0.3, accuracy: 0.02)
        XCTAssertFalse(grey.clipped)
        XCTAssertTrue(lut.lookup(SIMD3(0.0, 0.8, 0.0)).clipped, "Rec.2020 green is outside sRGB")
        // Round trip through ColorSync and through our own matrices should
        // agree for the same profile, within the table's precision.
        let matrix = try SoftProofLUT.build(.sRGB)
        XCTAssertEqual(lut.outOfGamutFraction, matrix.outOfGamutFraction, accuracy: 0.15)
    }

    func testProofRendersAndWarningPaintsGrey() throws {
        let path = TestAssets.path("HSB_6548.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        p.hsl.saturation = Array(repeating: 1, count: 8)   // push colours out of sRGB

        func render(_ output: RenderOutput) throws -> [Float16] {
            try TextureReadback.float16Pixels(of: try pipeline.render(session, scale: .binned(quads: 4),
                                                                      parameters: p, output: output), gpu: gpu)
        }
        var plain = RenderOutput.file(.sRGB)
        let a = try render(plain)
        plain.proof = try SoftProofLUT.build(.sRGB)
        let b = try render(plain)
        XCTAssertEqual(a.count, b.count)
        // Proofing to the same space the file is encoded in changes little
        // for in-gamut pixels but must not be a no-op for the pushed ones.
        var changed = 0
        for i in stride(from: 0, to: a.count, by: 4) where abs(Float(a[i]) - Float(b[i])) > 0.01 { changed += 1 }
        XCTAssertGreaterThan(changed, 0)

        plain.gamutWarning = true
        let c = try render(plain)
        var greys = 0
        for i in stride(from: 0, to: c.count, by: 4) {
            let r = Float(c[i]), g = Float(c[i + 1]), bl = Float(c[i + 2])
            // sRGB-encoded 0.5 linear is ~0.735.
            if abs(r - 0.735) < 0.01 && abs(g - 0.735) < 0.01 && abs(bl - 0.735) < 0.01 { greys += 1 }
        }
        XCTAssertGreaterThan(greys, 100, "warning should paint clipped pixels grey")
    }
}
