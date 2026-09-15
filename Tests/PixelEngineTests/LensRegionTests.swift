import XCTest
import simd
@testable import PixelEngine
@testable import RawCore
import LensKit

/// A region render (the 100% zoom tile, the magnifier, `latent-cli render
/// --region`) with lens corrections must be exactly that part of the full
/// render. It used to demosaic only the region, so the lens pass, which
/// reads each pixel from somewhere else in the frame, clamped at the
/// region's border and smeared a band of streaks along it.
final class LensRegionTests: XCTestCase {
    /// Largest allowed difference, in encoded output values. The lens pass
    /// reads a region's pixels with exactly the arithmetic of the full
    /// render (its own bilinear read, not the GPU sampler, whose few bits
    /// of sub-texel position used to differ between texture sizes by up to
    /// 0.05 on a hard edge), so the regions below come out identical to
    /// the full render (measured: exactly 0). The band this guards against
    /// measured 0.03 to 0.48.
    static let tolerance: Float = 1e-4


    /// Renders `regions` and the full frame with `parameters`, and returns
    /// the largest channel difference between each region and the same
    /// pixels of the full render, with where it occurred.
    private func compareRegions(path: String, parameters: EditParameters,
                                regions: [(x: Int, y: Int, w: Int, h: Int)]) throws -> [(Float, String)] {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        XCTAssertTrue(RenderPipeline.wantsLensCorrection(session: session, parameters: parameters),
                      "the test needs the lens pass to run")

        let fullTexture = try pipeline.render(session, scale: .full, parameters: parameters)
        let full = try TextureReadback.float16Pixels(of: fullTexture, gpu: gpu)
        let fullWidth = fullTexture.width

        var results: [(Float, String)] = []
        for r in regions {
            var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
            let texture = try pipeline.render(session, scale: .region(x: r.x, y: r.y, width: r.w, height: r.h),
                                              parameters: parameters, info: &info)
            XCTAssertEqual(texture.width, r.w)
            XCTAssertEqual(texture.height, r.h)
            XCTAssertEqual(Int(info.sensorRect.width), r.w, "the returned region is the requested one")
            let pixels = try TextureReadback.float16Pixels(of: texture, gpu: gpu)
            let ox = Int(info.sensorRect.minX), oy = Int(info.sensorRect.minY)
            var worst: Float = 0, edgeWorst: Float = 0, over = 0
            var at = (0, 0)
            // Every pixel, borders included: the border is where it went wrong.
            for y in 0..<texture.height {
                for x in 0..<texture.width {
                    let i = (y * texture.width + x) * 4, f = ((y + oy) * fullWidth + x + ox) * 4
                    let edge = min(x, y, texture.width - 1 - x, texture.height - 1 - y) < 12
                    for c in 0..<3 {
                        let d = abs(Float(pixels[i + c]) - Float(full[f + c]))
                        if d > worst { worst = d; at = (x, y) }
                        if edge { edgeWorst = max(edgeWorst, d) }
                        if d > 1e-3 { over += 1 }
                    }
                }
            }
            results.append((worst, "region \(r) worst \(worst) at \(at), border worst \(edgeWorst), \(over) samples over 1e-3"))
        }
        return results
    }

    /// The golden D750 file (in CI), whose Tamron 35mm profile has
    /// distortion, TCA and vignetting. Regions on every edge, where the
    /// lens pass reads furthest from the pixel it writes, and one against
    /// the sensor's corner, where reads leave the frame and must clamp
    /// exactly as the full render does.
    func testRegionsWithLensProfileMatchTheFullRender() throws {
        let path = TestAssets.path("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let regions = [(x: 2700, y: 120, w: 700, h: 300), (x: 1001, y: 3601, w: 800, h: 300),
                       (x: 60, y: 1800, w: 300, h: 500), (x: 5600, y: 1500, w: 400, h: 600),
                       (x: 0, y: 0, w: 500, h: 400), (x: 2900, y: 1900, w: 256, h: 256)]
        for (worst, label) in try compareRegions(path: path, parameters: EditParameters(), regions: regions) {
            XCTAssertLessThanOrEqual(worst, Self.tolerance, label)
        }
    }

    /// Keystone and manual distortion move reads much further than a
    /// profile does.
    func testRegionsWithKeystoneAndManualDistortionMatchTheFullRender() throws {
        let path = TestAssets.path("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        var parameters = EditParameters()
        parameters.perspective = PerspectiveCorrection(vertical: 0.4, horizontal: -0.2)
        parameters.manualDistortion = 0.15
        let regions = [(x: 2700, y: 120, w: 700, h: 300), (x: 400, y: 3500, w: 600, h: 400),
                       (x: 5400, y: 200, w: 500, h: 500)]
        for (worst, label) in try compareRegions(path: path, parameters: parameters, regions: regions) {
            XCTAssertLessThanOrEqual(worst, Self.tolerance, label)
        }
    }

    /// The case the band was first seen on: the Ihrke bracket's tree
    /// against the sky, `latent-cli render IMG_7224.CR2 --region
    /// 2900,500,900,600`.
    func testCanonBracketRegionHasNoEdgeBand() throws {
        let path = TestAssets.path("merge/ihrke-tripod-bracket/IMG_7224.CR2")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        for (worst, label) in try compareRegions(path: path, parameters: EditParameters(),
                                                 regions: [(x: 2900, y: 500, w: 900, h: 600)]) {
            XCTAssertLessThanOrEqual(worst, Self.tolerance, label)
        }
    }

    /// A linear source (a Photo Merge result, say) enters the pipeline
    /// after the demosaic but goes through the same region planning.
    func testLinearSourceRegionWithKeystoneMatchesTheFullRender() throws {
        var parameters = EditParameters()
        parameters.perspective = PerspectiveCorrection(vertical: -0.4, horizontal: 0.3)
        parameters.manualDistortion = -0.2
        let regions = [(x: 500, y: 0, w: 300, h: 200), (x: 20, y: 600, w: 400, h: 200), (x: 1000, y: 300, w: 200, h: 250)]
        for (worst, label) in try compareRegions(path: LinearFixtures.path(LinearFixtures.ramp), parameters: parameters,
                                                 regions: regions) {
            XCTAssertLessThanOrEqual(worst, Self.tolerance, label)
        }
    }

    // MARK: - The source window, without a GPU

    func testSourceWindowIsTheRegionPlusApronWhenNothingMoves() {
        let sampling = RenderPipeline.LensSampling(sensorSize: SIMD2(6000, 4000),
                                                   vignetting: VignettingModel(k1: -0.3, k2: 0, k3: 0))
        let window = RenderPipeline.lensSourceWindow(for: CGRect(x: 1000, y: 800, width: 512, height: 384),
                                                     sampling: sampling)
        XCTAssertEqual(window, CGRect(x: 984, y: 784, width: 544, height: 416))
        // Clamped to the sensor, origin even.
        let corner = RenderPipeline.lensSourceWindow(for: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                     sampling: sampling)
        XCTAssertEqual(corner, CGRect(x: 0, y: 0, width: 116, height: 116))
    }

    func testSourceWindowHoldsEveryReadOfTheRegion() {
        // Strong barrel distortion with its auto scale, TCA, and keystone.
        let model = DistortionModel.ptlens(a: 0.0108, b: -0.0342, c: 0.0157)
        let size = SIMD2<Float>(6032, 4032)
        let scale = LensCorrection.autoScale(for: model, cropRatio: 1, width: 6032, height: 4032)
        let sampling = RenderPipeline.LensSampling(
            sensorSize: size, autoScale: scale, distortion: model, manualDistortion: 0.1,
            tca: TCAModel(red: SIMD3(0, 0, 1.001), blue: SIMD3(0, 0, 0.999)),
            perspectiveInverse: PerspectiveCorrection(vertical: 0.3, horizontal: 0.1).inverseMatrix)
        let sensor = CGRect(x: 0, y: 0, width: 6032, height: 4032)
        for region in [CGRect(x: 2800, y: 100, width: 600, height: 300), CGRect(x: 100, y: 3700, width: 900, height: 300),
                       CGRect(x: 5700, y: 1800, width: 300, height: 400)] {
            let window = RenderPipeline.lensSourceWindow(for: region, sampling: sampling)
            XCTAssertTrue(window.contains(region))
            XCTAssertEqual(Int(window.minX) % 2, 0)
            XCTAssertEqual(Int(window.minY) % 2, 0)
            // Every pixel of the region, reads clamped to the sensor as the
            // sampler does, must land at least a pixel inside the window.
            var y = region.minY + 0.5
            while y < region.maxY {
                var x = region.minX + 0.5
                while x < region.maxX {
                    for p in sampling.sourcePoints(forSensorPoint: SIMD2(Float(x), Float(y))) {
                        let clamped = CGPoint(x: min(max(CGFloat(p.x), sensor.minX), sensor.maxX),
                                              y: min(max(CGFloat(p.y), sensor.minY), sensor.maxY))
                        let inside = window.insetBy(dx: 1, dy: 1)
                        XCTAssertTrue(inside.contains(clamped) || !sensor.insetBy(dx: 1, dy: 1).contains(clamped),
                                      "\(region): read \(p) outside \(window)")
                    }
                    x += 7
                }
                y += 7
            }
        }
    }
}
