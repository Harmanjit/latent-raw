import XCTest
import PixelEngine
import simd
@testable import MergeKit

/// The stitcher against an analytic scene: photos rendered from known
/// cameras, stitched, and compared with the scene itself.
final class PanoBlendStitchTests: XCTestCase {
    typealias Support = PanoBlendTestSupport

    /// A five-photo row, exposures 0.7 to 1.4 undone by the gains: the
    /// stitch matches the scene, shows nothing of what's outside the photos
    /// (painted a bright 3.0), and is black with alpha 0 where no photo reaches.
    func testRowMatchesTheScene() throws {
        let gpu = try HDRTestSupport.gpu()
        let row = Support.row()
        let store = try Support.store(for: row)
        let stitched = try Support.stitch(row.layout, row.output, frames: store,
                                          options: PanoramaBlendOptions(tileSize: 512), gpu: gpu)
        try Support.writeReview(stitched, name: "row-seams", seams: true)
        try Support.writeReview(stitched, name: "row", seams: false)

        var errors: [Double] = [], uncovered = 0, uncoveredWrong = 0, brightest: Float = 0
        for y in 0..<stitched.height {
            for x in 0..<stitched.width {
                let p = stitched.pixel(x, y)
                brightest = max(brightest, max(p.x, max(p.y, p.z)))
                if p.w == 0 {
                    uncovered += 1
                    if p.x != 0 || p.y != 0 || p.z != 0 { uncoveredWrong += 1 }
                    continue
                }
                // Well inside the photos: every pixel within 6 px fully covered.
                guard p.w >= 0.999, isInterior(stitched, x, y, radius: 6) else { continue }
                let truth = Support.truth(row.layout, row.output, edge: row.edge, x: x, y: y)
                for c in 0..<3 {
                    errors.append(abs(Double(p[c]) - truth[c]) / truth[c])
                }
            }
        }
        errors.sort()
        let mean = errors.reduce(0, +) / Double(errors.count)
        let p99 = errors[errors.count * 99 / 100]
        print(String(format: "row %dx%d, bands %d, apron %d: mean error %.3f%%, p99 %.2f%%, uncovered %d",
                     stitched.width, stitched.height, stitched.plan.bands, stitched.plan.apron, mean * 100, p99 * 100,
                     uncovered))
        XCTAssertLessThan(mean, 0.01)
        XCTAssertLessThan(p99, 0.05)
        XCTAssertGreaterThan(uncovered, 0, "the canvas's corners are outside every photo")
        XCTAssertEqual(uncoveredWrong, 0, "black where no photo reaches")
        XCTAssertLessThan(brightest, 1.2, "nothing of the 3.0 painted outside the photos")
        XCTAssertGreaterThan(errors.count, stitched.width * stitched.height)
    }

    /// Photos whose gains are 12% off (every other one): the multi-band
    /// blend spreads the difference out, so no seam shows as a step.
    ///
    /// Measured against the same stitch with the gains right, so resampling
    /// and the scene's own edges cancel out and only the exposure handling
    /// is left: between neighbouring pixels the two differ by far less than
    /// the 0.113 (log 1.12) a hard seam would jump.
    func testExposureDifferencesLeaveNoStepAtSeams() throws {
        let gpu = try HDRTestSupport.gpu()
        let correct = Support.row(scale: 0.9)
        let wrong = Support.row(gainError: 1.12, scale: 0.9)
        let store = try Support.store(for: correct)
        let options = PanoramaBlendOptions(tileSize: 1024, removeScratchWhenFinished: false)
        let right = try Support.stitch(correct.layout, correct.output, frames: store, options: options, gpu: gpu)
        let off = try Support.stitch(wrong.layout, wrong.output, frames: store, options: options, gpu: gpu)
        store.removeScratch()
        try Support.writeReview(off, name: "gain-error-seams", seams: true)
        // The middle seam, four times life size: the handover should be invisible.
        try Support.writeReviewCrop(off, name: "gain-error-seam-closeup",
                                    crop: PixelRegion(x: off.width / 2 - 100, y: off.height / 3, width: 200,
                                                      height: 120), zoom: 4)
        // Within a rectangle Auto Crop would keep; a photo's own outer edge,
        // where a seam can't be softened any further, lies outside it.
        let kept = off.innerRectangle
        XCTAssertGreaterThan(kept.height, off.height / 2)
        var largestAtSeams = 0.0, largestAnywhere = 0.0, crossings = 0, largestRatio = 0.0
        func ratio(_ x: Int, _ y: Int) -> Double { log(Double(off.pixel(x, y).y) / Double(right.pixel(x, y).y)) }
        for y in kept.y..<(kept.y + kept.height) {
            for x in kept.x..<(kept.x + kept.width - 1) {
                let step = abs(ratio(x + 1, y) - ratio(x, y))
                largestAnywhere = max(largestAnywhere, step)
                largestRatio = max(largestRatio, abs(ratio(x, y)))
                if off.label(x, y) != off.label(x + 1, y) {
                    crossings += 1
                    largestAtSeams = max(largestAtSeams, step)
                }
            }
        }
        print(String(format: "gain error 12%%: largest step across seams %.4f (%d crossings), anywhere %.4f, "
                     + "largest difference from the right gains %.3f, bands %d", largestAtSeams, crossings,
                     largestAnywhere, largestRatio, off.plan.bands))
        XCTAssertGreaterThan(crossings, 100)
        XCTAssertGreaterThan(largestRatio, 0.02, "the wrong gains do change the picture")
        XCTAssertLessThan(largestAtSeams, 0.005)
        XCTAssertLessThan(largestAnywhere, 0.005)
    }

    /// Tiles of 512 and 4,096 px (one tile with the apron clipped away)
    /// give the same panorama within 1e-4, as does an odd size.
    func testTileSizeDoesNotChangeTheResult() throws {
        let gpu = try HDRTestSupport.gpu()
        let row = Support.row(scale: 1)
        let store = try Support.store(for: row)
        var results: [Support.Stitched] = []
        for tile in [4096, 512, 776] {
            results.append(try Support.stitch(row.layout, row.output, frames: store,
                                              options: PanoramaBlendOptions(tileSize: tile,
                                                                            removeScratchWhenFinished: false),
                                              gpu: gpu))
        }
        store.removeScratch()
        XCTAssertEqual(results[0].plan.tileCount, 1)
        XCTAssertGreaterThan(results[1].plan.tileCount, 8)
        for other in results.dropFirst() {
            var largest: Float = 0
            for i in 0..<results[0].rgba.count {
                largest = max(largest, abs(results[0].rgba[i] - other.rgba[i]))
            }
            print("tiles \(other.plan.tileSize) px (\(other.plan.tileCount)) vs one: largest difference \(largest)")
            XCTAssertLessThan(largest, 1e-4)
        }
    }

    /// A panorama wider than the GPU's largest texture: twelve photos around
    /// 350 degrees on a 17,500 px Cylindrical canvas, stitched at full size.
    func testCanvasWiderThanTheTextureLimit() throws {
        let gpu = try HDRTestSupport.gpu()
        let focal = 2900.0
        let shots = (0..<12).map { Support.Shot(yaw: -2.75 + 0.5 * Double($0), pitch: 0.01 * Double($0 % 3),
                                                 exposure: [1, 0.8, 1.25][$0 % 3]) }
        let cameras = Support.cameras(shots, width: 2400, height: 400, focal: focal)
        let (layout, output) = Support.layout(cameras, projection: .cylindrical, pixelsPerRadian: focal, scale: 1)
        XCTAssertGreaterThan(output.width, 16_384)
        let store = try PanoramaFrameStore(parent: Support.scratchParent())
        let edge = 2 / focal
        try Support.render(cameras, shots: shots, sampleScale: 0.25, edge: edge, into: store)
        let stitched = try Support.stitch(layout, output, frames: store, options: PanoramaBlendOptions(tileSize: 2048),
                                          gpu: gpu)
        XCTAssertGreaterThanOrEqual(stitched.plan.tilesAcross, 9)
        var errors: [Double] = []
        for y in stride(from: 0, to: stitched.height, by: 7) {
            for x in stride(from: 0, to: stitched.width, by: 13) {
                let p = stitched.pixel(x, y)
                guard p.w >= 0.999, isInterior(stitched, x, y, radius: 12) else { continue }
                let truth = Support.truth(layout, output, edge: edge, x: x, y: y)
                errors.append(abs(Double(p.y) - truth.y) / truth.y)
            }
        }
        let mean = errors.reduce(0, +) / Double(errors.count)
        print(String(format: "%dx%d panorama: mean error %.3f%% over %d samples; peak textures %.0f MB",
                     stitched.width, stitched.height, mean * 100, errors.count,
                     Double(stitched.statistics.peakTextureBytes) / 1e6))
        XCTAssertGreaterThan(errors.count, 1000)
        // Photos decoded at a quarter size and shown at full size are soft
        // at the scene's 2 px edges, hence a looser bound than the row's.
        XCTAssertLessThan(mean, 0.03)
    }

    /// Two rows of three photos on a Spherical canvas, and a narrow
    /// Perspective panorama.
    func testSphericalAndPerspectiveCanvases() throws {
        let gpu = try HDRTestSupport.gpu()
        let focal = 700.0
        let sphericalShots = [-0.5, 0, 0.5].flatMap { yaw in
            [Support.Shot(yaw: yaw, pitch: 0.3, exposure: 0.9), Support.Shot(yaw: yaw + 0.05, pitch: -0.25, exposure: 1.1)]
        }
        let perspectiveShots = [Support.Shot(yaw: -0.3, exposure: 1), Support.Shot(yaw: 0.02, pitch: 0.03, exposure: 1.3),
                                Support.Shot(yaw: 0.33, pitch: -0.02, exposure: 0.8)]
        for (projection, shots) in [(PanoramaProjection.spherical, sphericalShots), (.perspective, perspectiveShots)] {
            let cameras = Support.cameras(shots, width: 800, height: 600, focal: focal)
            let (layout, output) = Support.layout(cameras, projection: projection, pixelsPerRadian: focal, scale: 0.6)
            let store = try PanoramaFrameStore(parent: Support.scratchParent())
            let edge = 2 / (focal * 0.6)
            try Support.render(cameras, shots: shots, sampleScale: 0.5, edge: edge, into: store)
            let stitched = try Support.stitch(layout, output, frames: store,
                                              options: PanoramaBlendOptions(tileSize: 512), gpu: gpu)
            try Support.writeReview(stitched, name: "\(projection.rawValue)-seams", seams: true)
            var errors: [Double] = []
            for y in 0..<stitched.height {
                for x in 0..<stitched.width {
                    let p = stitched.pixel(x, y)
                    guard p.w >= 0.999, isInterior(stitched, x, y, radius: 6) else { continue }
                    let truth = Support.truth(layout, output, edge: edge, x: x, y: y)
                    errors.append(abs(Double(p.y) - truth.y) / truth.y)
                }
            }
            let mean = errors.reduce(0, +) / Double(errors.count)
            print(String(format: "%@ %dx%d: mean error %.3f%%, bands %d", projection.rawValue, stitched.width,
                         stitched.height, mean * 100, stitched.plan.bands))
            XCTAssertGreaterThan(errors.count, stitched.width * stitched.height / 3)
            XCTAssertLessThan(mean, 0.01, "\(projection)")
        }
    }

    /// One photo on its own: with nothing to blend, the pyramid must give
    /// the warped photo back, so the panorama is just the scene, and the
    /// blend's log and exponential cancel out.
    func testOnePhotoComesBackUnchanged() throws {
        let gpu = try HDRTestSupport.gpu()
        let shots = [Support.Shot(yaw: 0, pitch: 0.02, roll: 0.01, exposure: 0.8)]
        let cameras = Support.cameras(shots, width: 800, height: 600, focal: 700)
        let (layout, output) = Support.layout(cameras, projection: .cylindrical, pixelsPerRadian: 700, scale: 1)
        let store = try PanoramaFrameStore(parent: Support.scratchParent())
        let edge = 2 / 700.0
        try Support.render(cameras, shots: shots, sampleScale: 1, edge: edge, into: store)
        let stitched = try Support.stitch(layout, output, frames: store,
                                          options: PanoramaBlendOptions(tileSize: 256), gpu: gpu)
        XCTAssertEqual(stitched.plan.bands, stitched.plan.tiledLevels + 1, "no seams: the fewest bands")
        var errors: [Double] = []
        for y in 0..<stitched.height {
            for x in 0..<stitched.width {
                let p = stitched.pixel(x, y)
                guard p.w >= 0.999, isInterior(stitched, x, y, radius: 4) else { continue }
                let truth = Support.truth(layout, output, edge: edge, x: x, y: y)
                errors.append(abs(Double(p.y) - truth.y) / truth.y)
            }
        }
        let mean = errors.reduce(0, +) / Double(errors.count)
        print(String(format: "one photo: mean error %.4f%% over %d pixels", mean * 100, errors.count))
        XCTAssertLessThan(mean, 0.005)
    }

    // MARK: - Helpers

    /// Whether every pixel within `radius` is fully covered.
    private func isInterior(_ stitched: Support.Stitched, _ x: Int, _ y: Int, radius: Int) -> Bool {
        guard x >= radius, y >= radius, x + radius < stitched.width, y + radius < stitched.height else { return false }
        for (dx, dy) in [(-radius, 0), (radius, 0), (0, -radius), (0, radius),
                         (-radius, -radius), (radius, radius), (-radius, radius), (radius, -radius)] {
            if stitched.rgba[((y + dy) * stitched.width + x + dx) * 4 + 3] < 0.999 { return false }
        }
        return true
    }
}
