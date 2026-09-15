import XCTest
import PixelEngine
import simd
@testable import MergeKit

/// The kernels' projection maths against PanoramaMath, and the plan's
/// tiling arithmetic.
final class PanoBlendMappingTests: XCTestCase {
    /// For every projection, the frame pixel the GPU finds for output pixels
    /// all over a photo and 16 px around it (as far as a sample's taps
    /// reach) matches PanoramaMath in double precision within 1e-3 px: on
    /// panoramas about 45,000 px wide at full resolution (where absolute
    /// float coordinates would be 4e-3 px coarse), for a D750 with a 50 mm
    /// lens (f = 8,379 px) and a 24 mm one (f = 4,022 px), photos that cross
    /// the ±180 degree line included, at output scales 1 and 0.37, at level
    /// 0 and on the 1/8 grid. (Measured: 4.4e-4 px at worst, on this Mac.)
    func testKernelMappingMatchesPanoramaMath() throws {
        let gpu = try HDRTestSupport.gpu()
        let kernels = MergePanoBlendKernels(gpu: gpu)
        var report: [String] = []
        for (focal, sampleScale) in [(8379.0, 0.5), (4022.0, 1.0)] {
            let width = 4016, height = 6016
            for projection in [PanoramaProjection.perspective, .cylindrical, .spherical] {
                let shots: [PanoBlendTestSupport.Shot] = projection == .perspective
                    ? [.init(yaw: -0.3, pitch: 0.1, roll: 0.02), .init(yaw: 0.25, pitch: -0.05, roll: -0.03)]
                    : [.init(yaw: -2.6, pitch: 0.05, roll: 0.01), .init(yaw: 0.1, pitch: -0.3, roll: -0.02),
                       .init(yaw: 2.7, pitch: 0.2, roll: 0.03)]
                let cameras = PanoBlendTestSupport.cameras(shots, width: width, height: height, focal: focal)
                let (layout, _) = PanoBlendTestSupport.layout(cameras, projection: projection,
                                                              pixelsPerRadian: focal, scale: 1)
                if projection != .perspective, focal > 8000 { XCTAssertGreaterThan(layout.canvas.width, 40_000) }
                var worstOverall = 0.0
                for scale in [1.0, 0.37] {
                    let outputWidth = Int(Double(layout.canvas.width) * scale)
                    let outputHeight = Int(Double(layout.canvas.height) * scale)
                    for (position, camera) in cameras.enumerated() {
                        let bounds = PanoramaBlendGeometry.outputBounds(
                            camera: camera, frame: PanoramaPreparedFrame(frameIndex: 0, width: 2008, height: 3008,
                                                                         sampleScale: 0.5),
                            canvas: layout.canvas, scale: scale, outputWidth: outputWidth, outputHeight: outputHeight,
                            reach: 64)
                        let mapping = PanoramaBlendGeometry.mapping(
                            camera: camera, position: position, canvas: layout.canvas, scale: scale,
                            sampleScale: sampleScale, bounds: bounds)
                        for step in [1, 8] {
                            let worst = try worstError(kernels: kernels, mapping: mapping, camera: camera,
                                                       layout: layout, scale: scale, step: step,
                                                       outputWidth: outputWidth, outputHeight: outputHeight)
                            XCTAssertLessThan(worst, 1e-3,
                                              "\(projection) f \(focal) camera \(position) scale \(scale) step \(step)")
                            worstOverall = max(worstOverall, worst)
                        }
                    }
                }
                report.append(String(format: "%@ f %.0f: worst %.2e full-resolution px, %.2e prepared px",
                                     projection.rawValue, focal, worstOverall, worstOverall * sampleScale))
            }
        }
        print(report.joined(separator: "\n"))
    }

    /// The largest distance between the GPU's and PanoramaMath's frame pixel
    /// over 6 x 6 patches of 64 x 4 grid pixels spread across the photo's
    /// bounds, in full-resolution pixels.
    private func worstError(kernels: MergePanoBlendKernels, mapping: MergePanoBlendKernels.FrameMapping,
                            camera: PanoramaCamera, layout: PanoramaLayout, scale: Double, step: Int,
                            outputWidth: Int, outputHeight: Int) throws -> Double {
        let bounds = try XCTUnwrap(PanoramaBlendGeometry.outputBounds(
            camera: camera, frame: PanoramaPreparedFrame(frameIndex: 0, width: 2008, height: 3008, sampleScale: 0.5),
            canvas: layout.canvas, scale: scale, outputWidth: outputWidth, outputHeight: outputHeight, reach: 0))
        let canvasWidth = (outputWidth + step - 1) / step, canvasHeight = (outputHeight + step - 1) / step
        var worst = 0.0
        for j in 0..<6 {
            for i in 0..<6 {
                let gx = min((bounds.x + bounds.width * i / 5) / step, canvasWidth - 64)
                let gy = min((bounds.y + bounds.height * j / 5) / step, canvasHeight - 4)
                let place = MergePanoBlendKernels.Place(x: max(gx, 0), y: max(gy, 0), width: 64, height: 4)
                let grid = MergePanoBlendKernels.Grid(place: place, canvasWidth: canvasWidth,
                                                      canvasHeight: canvasHeight, step: step)
                let mapped = try kernels.mapPixels(mapping: mapping, grid: grid)
                for row in 0..<place.height {
                    for column in 0..<place.width {
                        let value = mapped[row * place.width + column]
                        let outputPixel = SIMD2(Double((place.x + column) * step), Double((place.y + row) * step))
                            + 0.5 * Double(step) - 0.5
                        let canvasPixel = (outputPixel + 0.5) / scale
                        guard let d = PanoramaMath.direction(canvasPixel: canvasPixel, canvas: layout.canvas),
                              let expected = PanoramaMath.framePixel(direction: d, camera: camera) else { continue }
                        // Only points a sample can use matter: on the photo or up
                        // to 16 px past its edge (a sample's taps reach at most 9).
                        guard expected.x > -16, expected.y > -16, expected.x < Double(camera.width) + 16,
                              expected.y < Double(camera.height) + 16 else { continue }
                        XCTAssertEqual(value.z, 1, "in front of the camera")
                        worst = max(worst, simd_distance(SIMD2(Double(value.x), Double(value.y)) + camera.principalPoint,
                                                         expected))
                    }
                }
            }
        }
        return worst
    }

    /// The footprint the kernel reports is prepared pixels per grid pixel.
    func testFootprintIsPreparedPixelsPerGridPixel() throws {
        let gpu = try HDRTestSupport.gpu()
        let kernels = MergePanoBlendKernels(gpu: gpu)
        let camera = PanoramaCamera(frameIndex: 0, rotation: PanoBlendTestSupport.rotation(yaw: 0), focalLengthPixels: 1000,
                                    principalPoint: SIMD2(500, 400), width: 1000, height: 800, exposureGain: 1)
        let canvas = PanoramaCanvas(projection: .perspective, pixelsPerRadian: 1000, origin: SIMD2(-500, -400),
                                    width: 1000, height: 800)
        // Output at 0.25 of the canvas, frames decoded at half size: each
        // output pixel spans 4 full-resolution pixels, 2 prepared ones.
        let mapping = PanoramaBlendGeometry.mapping(camera: camera, position: 0, canvas: canvas, scale: 0.25,
                                                    sampleScale: 0.5,
                                                    bounds: PixelRegion(x: 0, y: 0, width: 250, height: 200))
        let place = MergePanoBlendKernels.Place(x: 120, y: 95, width: 10, height: 10)
        let mapped = try kernels.mapPixels(mapping: mapping, grid: .init(place: place, canvasWidth: 250,
                                                                         canvasHeight: 200, step: 1))
        for value in mapped { XCTAssertEqual(value.w, 2, accuracy: 1e-3) }
        let coarse = try kernels.mapPixels(mapping: mapping, grid: .init(place: .init(x: 15, y: 12, width: 2, height: 2),
                                                                         canvasWidth: 32, canvasHeight: 25, step: 8))
        for value in coarse { XCTAssertEqual(value.w, 16, accuracy: 1e-2) }
        // Pixel (125, 100)'s centre is canvas (502, 402): 2 px right of and
        // 2 px below the principal point.
        let centre = mapped[5 * 10 + 5]
        XCTAssertEqual(centre.x, 2, accuracy: 1e-3)
        XCTAssertEqual(centre.y, 2, accuracy: 1e-3)
    }

    func testApronIsTheSmallestThatWorks() {
        for levels in 3...5 {
            let apron = PanoramaBlendPlan.requiredApron(tiledLevels: levels)
            XCTAssertEqual(apron % (1 << levels), 0)
            XCTAssertTrue(PanoramaBlendPlan.apronSuffices(apron, tiledLevels: levels))
            XCTAssertFalse(PanoramaBlendPlan.apronSuffices(apron - (1 << levels), tiledLevels: levels))
            print("tiled levels \(levels): apron \(apron) px")
        }
    }

    func testTiledLevelsKeepTheSharedLevelSmall() {
        XCTAssertEqual(PanoramaBlendPlan.tiledLevels(width: 16_384, height: 6_000), 3)
        XCTAssertEqual(PanoramaBlendPlan.tiledLevels(width: 32_768, height: 6_000), 3)
        XCTAssertEqual(PanoramaBlendPlan.tiledLevels(width: 45_000, height: 6_000), 4)
        XCTAssertEqual(PanoramaBlendPlan.tiledLevels(width: 300, height: 200), 3)
    }

    func testBandsFollowTheOverlap() {
        // 1.3 x 2^bands <= half overlap.
        XCTAssertEqual(PanoramaBlendPlan.bands(halfOverlap: 330, tiledLevels: 3, width: 16_384, height: 6_000), 7)
        XCTAssertEqual(PanoramaBlendPlan.bands(halfOverlap: 340, tiledLevels: 3, width: 16_384, height: 6_000), 8)
        XCTAssertEqual(PanoramaBlendPlan.bands(halfOverlap: 10, tiledLevels: 3, width: 16_384, height: 6_000), 4)
        XCTAssertEqual(PanoramaBlendPlan.bands(halfOverlap: nil, tiledLevels: 3, width: 16_384, height: 6_000), 4)
        XCTAssertEqual(PanoramaBlendPlan.bands(halfOverlap: 1e6, tiledLevels: 3, width: 1_000, height: 600), 9)
    }

    func testChamferDistance() {
        // A 7 x 5 map inside everywhere: the centre is 3 pixels from the
        // outside beyond the map's edge.
        let d = PanoramaStitcher.distanceToOutside([Bool](repeating: true, count: 35), width: 7, height: 5)
        XCTAssertEqual(d[2 * 7 + 3], 3, accuracy: 1e-5)
        XCTAssertEqual(d[0], 1, accuracy: 1e-5)
    }
}
