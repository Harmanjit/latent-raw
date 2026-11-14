import XCTest
import Metal
import simd
@testable import PixelEngine

/// The colour picker's spaces and area statistics, and where a colour
/// lands on the vectorscope.
final class PixelReadoutSpaceTests: XCTestCase {
    func testStandardTextIsTheOriginalReadout() {
        let r = PixelReadout(linearDisplayP3: SIMD3(0.2, 0.4, 0.1))
        let p = r.percent, lab = r.lab
        XCTAssertEqual(r.text(in: .standard),
                       String(format: "R %.0f  G %.0f  B %.0f %%   L %.0f  a %.0f  b %.0f",
                              p.x, p.y, p.z, lab.x, lab.y, lab.z))
    }

    func testWhiteInEverySpace() {
        let white = PixelReadout(linearDisplayP3: SIMD3(repeating: 1))
        XCTAssertEqual(white.rgb255.x, 255, accuracy: 0.01)
        XCTAssertEqual(white.hsl.y, 0, accuracy: 0.01)
        XCTAssertEqual(white.hsl.z, 100, accuracy: 0.01)
        XCTAssertEqual(white.lch.x, 100, accuracy: 0.2)
        XCTAssertLessThan(white.lch.y, 0.5)
        XCTAssertEqual(white.text(in: .rgb255), "R 255  G 255  B 255")
    }

    func testPureRedHSL() {
        let red = PixelReadout(linearDisplayP3: SIMD3(1, 0, 0))
        let hsl = red.hsl
        XCTAssertEqual(hsl.x, 0, accuracy: 0.01)
        XCTAssertEqual(hsl.y, 100, accuracy: 0.01)
        XCTAssertEqual(hsl.z, 50, accuracy: 0.01)
        XCTAssertEqual(red.text(in: .hsl), "H 0°  S 100  L 50 %")
    }

    func testLChMatchesLab() {
        let r = PixelReadout(linearDisplayP3: SIMD3(0.1, 0.3, 0.6))
        let lab = r.lab, lch = r.lch
        XCTAssertEqual(lch.x, lab.x, accuracy: 1e-4)
        XCTAssertEqual(lch.y, (lab.y * lab.y + lab.z * lab.z).squareRoot(), accuracy: 1e-3)
        XCTAssertEqual(lch.y * cos(lch.z * .pi / 180), lab.y, accuracy: 1e-2)
        XCTAssertEqual(lch.y * sin(lch.z * .pi / 180), lab.z, accuracy: 1e-2)
        XCTAssertGreaterThanOrEqual(lch.z, 0)
        XCTAssertLessThan(lch.z, 360)
    }

    func testAreaMeanAndRange() throws {
        XCTAssertNil(PixelAreaStatistics(pixels: []))
        let stats = try XCTUnwrap(PixelAreaStatistics(pixels: [SIMD3(0, 0, 0), SIMD3(1, 0.5, 0.25)]))
        XCTAssertEqual(stats.mean.linear, SIMD3(0.5, 0.25, 0.125))
        let range = stats.range(in: .rgb255)
        XCTAssertEqual(range.min, SIMD3(0, 0, 0))
        XCTAssertEqual(range.max.x, 255, accuracy: 0.01)
        XCTAssertEqual(range.max.y, PixelReadout(linearDisplayP3: SIMD3(0.5, 0.5, 0.5)).rgb255.y, accuracy: 0.01)
    }

    func testSampleSizes() {
        XCTAssertEqual(PixelSampleSize.allCases.map(\.radius), [0, 2, 7, 15])
        XCTAssertEqual(PixelSampleSize.point.title, "Point")
        XCTAssertEqual(PixelSampleSize.thirtyOne.title, "31 px")
    }

    func testNeutralSitsInTheCentreAndSkinNearTheILine() throws {
        let grey = Vectorscope.position(ofLinear: SIMD3(repeating: 0.3))
        XCTAssertEqual(grey.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(grey.y, 0.5, accuracy: 1e-5)
        XCTAssertNil(Vectorscope.angle(ofLinear: SIMD3(repeating: 0.3)))
        // A typical light skin tone, linear.
        let skin = SIMD3<Float>(0.6, 0.32, 0.21)
        let angle = try XCTUnwrap(Vectorscope.angle(ofLinear: skin))
        XCTAssertEqual(angle, 123, accuracy: 8)
    }

    /// The kernel puts a flat colour in the bin `position` predicts.
    func testPositionMatchesTheKernel() throws {
        let gpu: GPUContext
        do { gpu = try GPUContext() } catch { throw XCTSkip("No Metal device") }
        let scopes = try ScopeCalculator(gpu: gpu)
        let colour = SIMD3<Float>(0.7, 0.2, 0.05)
        let size = 8
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size, height: size,
                                                            mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(gpu.device.makeTexture(descriptor: desc))
        var halfs = [Float16](repeating: 1, count: size * size * 4)
        for i in 0..<(size * size) {
            halfs[i * 4] = Float16(colour.x); halfs[i * 4 + 1] = Float16(colour.y); halfs[i * 4 + 2] = Float16(colour.z)
        }
        halfs.withUnsafeBytes { bytes in
            tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: bytes.baseAddress!, bytesPerRow: size * 8)
        }
        let scope = try XCTUnwrap(scopes.computeVectorscope(from: tex, inputIsLinear: true))
        let n = Vectorscope.size
        let bin = try XCTUnwrap(scope.counts.firstIndex { $0 > 0 })
        let rounded = SIMD3<Float>(Float(Float16(colour.x)), Float(Float16(colour.y)), Float(Float16(colour.z)))
        let p = Vectorscope.position(ofLinear: rounded) * Float(n - 1)
        XCTAssertEqual(bin % n, Int(p.x + 0.5))
        XCTAssertEqual(bin / n, Int(p.y + 0.5))
    }
}
