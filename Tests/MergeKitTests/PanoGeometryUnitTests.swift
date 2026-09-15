import XCTest
import CoreGraphics
import simd
@testable import MergeKit

/// The panorama geometry's pieces on their own: rotation maths, levelling,
/// the output size rule, Auto Crop's rectangle and the EXIF focal length.
final class PanoGeometryUnitTests: XCTestCase {
    private func randomRotation(_ generator: inout PanoramaRandom) -> simd_double3x3 {
        let axis = simd_normalize(SIMD3(Double.random(in: -1...1, using: &generator),
                                        Double.random(in: -1...1, using: &generator),
                                        Double.random(in: -1...1, using: &generator)))
        return simd_double3x3(simd_quatd(angle: Double.random(in: 0...3, using: &generator), axis: axis))
    }

    // MARK: - Rotations

    func testNearestRotationAndFitRecoverRotations() {
        var generator = PanoramaRandom(seed: 42)
        for _ in 0..<50 {
            let r = randomRotation(&generator)
            // A rotation scaled and slightly disturbed comes back to itself.
            var noisy = r * 3.7
            noisy[0][1] += 1e-4
            XCTAssertLessThan(PanoramaRotation.angle(between: PanoramaRotation.nearest(to: noisy), and: r), 1e-4)
            // Two vectors are enough to fix it (the rank-2 case RANSAC draws).
            let a = [SIMD3<Double>(0.1, 0.2, 1), SIMD3(-0.3, 0.1, 1)].map(simd_normalize)
            let fitted = PanoramaRotation.fit(from: a, to: a.map { r * $0 })
            // (acos near 1 resolves angles only to about 1e-8 radians.)
            XCTAssertLessThan(PanoramaRotation.angle(between: fitted, and: r), 1e-6)
            XCTAssertEqual(fitted.determinant, 1, accuracy: 1e-9, "a proper rotation, never a reflection")
        }
        let omega = SIMD3<Double>(0.01, -0.02, 0.005)
        XCTAssertEqual(PanoramaRotation.angle(between: PanoramaRotation.exp(omega), and: matrix_identity_double3x3),
                       simd_length(omega), accuracy: 1e-12)
    }

    func testYawPitchRollConventions() {
        let yaw = 30 * Double.pi / 180
        let turned = simd_double3x3(rows: [SIMD3(cos(yaw), 0, sin(yaw)), SIMD3(0, 1, 0), SIMD3(-sin(yaw), 0, cos(yaw))])
        let angles = PanoramaRotation.yawPitchRoll(turned)
        XCTAssertEqual(angles.yaw, 30, accuracy: 1e-9, "turned right")
        XCTAssertEqual(angles.pitch, 0, accuracy: 1e-9)
        XCTAssertEqual(angles.roll, 0, accuracy: 1e-9)
        // Looking up: the camera's +z tips towards -y.
        let p = 10 * Double.pi / 180
        let up = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(p), -sin(p)), SIMD3(0, sin(p), cos(p))])
        XCTAssertEqual(PanoramaRotation.yawPitchRoll(up).pitch, 10, accuracy: 1e-9)
    }

    func testLevellingTakesOutATiltedRigAndCentresTheSweep() {
        // A sweep from -60° to +80° about the vertical, every camera pitched
        // 8° up, then the whole rig tilted 5° to the side and 3° forward.
        func rotation(yaw: Double, pitch: Double) -> simd_double3x3 {
            let (y, p) = (yaw * .pi / 180, pitch * .pi / 180)
            return simd_double3x3(rows: [SIMD3(cos(y), 0, sin(y)), SIMD3(0, 1, 0), SIMD3(-sin(y), 0, cos(y))])
                * simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(p), -sin(p)), SIMD3(0, sin(p), cos(p))])
        }
        let tilt = simd_double3x3(simd_quatd(angle: 5 * .pi / 180, axis: SIMD3(0, 0, 1)))
            * simd_double3x3(simd_quatd(angle: 3 * .pi / 180, axis: SIMD3(1, 0, 0)))
        let yaws = stride(from: -60.0, through: 80, by: 20).map { $0 }
        let cameras = yaws.map { tilt * rotation(yaw: $0, pitch: 8) }
        let level = PanoramaCameraSolver.levelling(cameras)
        for (k, camera) in cameras.enumerated() {
            let angles = PanoramaRotation.yawPitchRoll(level * camera)
            XCTAssertEqual(angles.pitch, 8, accuracy: 1e-6, "pitch restored")
            XCTAssertEqual(angles.roll, 0, accuracy: 1e-6, "no roll")
            // Centred on the sweep's middle, +10°.
            XCTAssertEqual(angles.yaw, yaws[k] - 10, accuracy: 1e-6)
        }
    }

    // MARK: - Auto Crop

    func testLargestRectangleMatchesBruteForce() {
        var generator = PanoramaRandom(seed: 7)
        for _ in 0..<30 {
            let columns = Int.random(in: 1...14, using: &generator), rows = Int.random(in: 1...9, using: &generator)
            let covered = (0..<(columns * rows)).map { _ in Double.random(in: 0...1, using: &generator) < 0.8 }
            var best = 0
            for y0 in 0..<rows {
                for x0 in 0..<columns {
                    for y1 in y0..<rows {
                        for x1 in x0..<columns {
                            var full = true
                            for y in y0...y1 where full { for x in x0...x1 where !covered[y * columns + x] { full = false } }
                            if full { best = max(best, (x1 - x0 + 1) * (y1 - y0 + 1)) }
                        }
                    }
                }
            }
            let coverage = PanoramaCanvasBuilder.Coverage(columns: columns, rows: rows, cellSize: 10, covered: covered)
            let canvas = PanoramaCanvas(projection: .cylindrical, pixelsPerRadian: 100, origin: .zero,
                                        width: columns * 10, height: rows * 10)
            let rect = PanoramaCanvasBuilder.largestRectangle(coverage, canvas: canvas)
            XCTAssertEqual(Int(rect.width * rect.height) / 100, best)
            // And it is made of covered cells only.
            for y in Int(rect.minY / 10)..<Int(rect.maxY / 10) {
                for x in Int(rect.minX / 10)..<Int(rect.maxX / 10) { XCTAssertTrue(covered[y * columns + x]) }
            }
        }
    }

    // MARK: - Output size

    func testOutputSizeWhenEverythingFits() {
        let size = PanoramaOutputSizer.size(fullWidth: 9000, fullHeight: 4000, maxTextureSide: 16_384,
                                            editPixelBudget: 41_000_000)
        XCTAssertEqual(size.scale, 1)
        XCTAssertEqual(size.limit, .none)
        XCTAssertEqual([size.width, size.height, size.decodeSpan], [9000, 4000, 1])
        XCTAssertFalse(size.needsDownsampling)
    }

    func testOutputSizeNeverUpscales() {
        let size = PanoramaOutputSizer.size(fullWidth: 800, fullHeight: 300, maxTextureSide: 16_384,
                                            editPixelBudget: 1e12)
        XCTAssertEqual(size.scale, 1)
        XCTAssertEqual([size.width, size.height], [800, 300])
    }

    func testTextureSideLimit() {
        let size = PanoramaOutputSizer.size(fullWidth: 40_000, fullHeight: 6_000, maxTextureSide: 16_384,
                                            editPixelBudget: 1e12)
        XCTAssertEqual(size.limit, .textureSide)
        XCTAssertEqual(size.scale, 0.4096, accuracy: 1e-12)
        XCTAssertEqual(size.width, 16_384, "exactly the limit, not one short")
        XCTAssertEqual(size.height, 2_457)
        XCTAssertEqual(size.decodeSpan, 2)
    }

    func testMemoryLimitAndRounding() {
        // 96 MP into 24 MP: exactly half.
        let half = PanoramaOutputSizer.size(fullWidth: 12_000, fullHeight: 8_000, maxTextureSide: 16_384,
                                            editPixelBudget: 24_000_000)
        XCTAssertEqual(half.limit, .memory)
        XCTAssertEqual(half.scale, 0.5, accuracy: 1e-12)
        XCTAssertEqual([half.width, half.height, half.decodeSpan], [6000, 4000, 2])
        // An odd size rounds down.
        let odd = PanoramaOutputSizer.size(fullWidth: 10_001, fullHeight: 3_333, maxTextureSide: 16_384,
                                           editPixelBudget: 10_001 * 3_333 * 0.49)
        XCTAssertEqual(odd.width, Int((10_001 * odd.scale).rounded(.down)))
        XCTAssertEqual(odd.height, Int((3_333 * odd.scale).rounded(.down)))
        XCTAssertLessThanOrEqual(Double(odd.width * odd.height), 10_001 * 3_333 * 0.49 + 1)
    }

    func testDecodeSpanBoundaries() {
        XCTAssertEqual(PanoramaOutputSizer.decodeSpan(scale: 1), 1)
        XCTAssertEqual(PanoramaOutputSizer.decodeSpan(scale: 0.51), 1, "above one half: full resolution")
        XCTAssertEqual(PanoramaOutputSizer.decodeSpan(scale: 0.5), 2)
        XCTAssertEqual(PanoramaOutputSizer.decodeSpan(scale: 0.34), 2)
        XCTAssertEqual(PanoramaOutputSizer.decodeSpan(scale: 1.0 / 3), 3)
        XCTAssertEqual(PanoramaOutputSizer.decodeSpan(scale: 0.26), 3)
        XCTAssertEqual(PanoramaOutputSizer.decodeSpan(scale: 0.25), 4)
        XCTAssertEqual(PanoramaOutputSizer.decodeSpan(scale: 0.1), 10)
        for scale in stride(from: 0.02, through: 0.5, by: 0.0137) {
            let k = PanoramaOutputSizer.decodeSpan(scale: scale)
            XCTAssertGreaterThanOrEqual(1 / Double(k), scale, "never decoded smaller than the output")
            XCTAssertLessThan(1 / Double(k + 1), scale, "the largest such span")
        }
    }

    /// docs/PhotoMerge.md section 4: 20 portrait frames 4000 px wide with
    /// 30% overlap make a canvas about 56,000 px wide, so s ≈ 0.29.
    func testTheTwentyFrameExampleFromThePlan() {
        let width = 4000 + 19 * 2800, height = 6000
        XCTAssertEqual(width, 57_200)
        let size = PanoramaOutputSizer.size(fullWidth: width, fullHeight: height, maxTextureSide: 16_384,
                                            editPixelBudget: PanoramaOutputSizer.editPixelBudget(
                                                recommendedWorkingSetBytes: 11_453_251_584))
        XCTAssertEqual(size.limit, .textureSide)
        XCTAssertEqual(size.scale, 0.286, accuracy: 0.001)
        XCTAssertEqual(size.width, 16_384)
        XCTAssertEqual(size.decodeSpan, 3)
    }

    /// Harman's 17-frame D750 set as `pano-layout` measured it (canvas
    /// 29,195 x 7,664 px) on a 16 GB Mac: the editing budget decides, at
    /// about 43%, decoded at half size.
    func testHarmansSetOnA16GBMac() {
        let budget = PanoramaOutputSizer.editPixelBudget(recommendedWorkingSetBytes: 11_453_251_584)
        XCTAssertEqual(budget / 1e6, 40.9, accuracy: 0.1, "about 41 MP for an M1 Pro with 16 GB")
        let size = PanoramaOutputSizer.size(fullWidth: 29_195, fullHeight: 7_664, maxTextureSide: 16_384,
                                            editPixelBudget: budget)
        XCTAssertEqual(size.limit, .memory)
        XCTAssertEqual(size.scale, 0.4276, accuracy: 0.001)
        XCTAssertEqual(size.decodeSpan, 2)
        XCTAssertLessThanOrEqual(Double(size.width * size.height), budget)
    }

    func testDeviceLimitsComeFromTheGPU() throws {
        let gpu = try HDRTestSupport.gpu()
        XCTAssertGreaterThanOrEqual(PanoramaOutputSizer.maxTextureSide(gpu.device), 8_192)
        let size = PanoramaOutputSizer.size(fullWidth: 100_000, fullHeight: 5_000, device: gpu.device)
        XCTAssertLessThanOrEqual(size.width, PanoramaOutputSizer.maxTextureSide(gpu.device))
    }

    // MARK: - EXIF

    func testFocalLengthInPixelsFromEXIF() {
        var metadata = PanoramaFrameMetadata(name: "a", captureTime: Date(), width: 4016, height: 6016,
                                             focalLengthMillimetres: 50, cropFactor: 1, exposureTime: 1.0 / 400,
                                             iso: 100, aperture: 2.8)
        XCTAssertEqual(metadata.focalLengthPixels!, 8358.6, accuracy: 0.5)
        metadata.cropFactor = 0
        XCTAssertEqual(metadata.focalLengthPixels!, 8358.6, accuracy: 0.5, "unknown crop: full frame")
        metadata.cropFactor = 1.5
        XCTAssertEqual(metadata.focalLengthPixels!, 8358.6 * 1.5, accuracy: 1)
        XCTAssertEqual(metadata.exposure!, 100.0 / 400 / 7.84, accuracy: 1e-12)
        metadata.aperture = 0
        XCTAssertNil(metadata.exposure)
    }
}
