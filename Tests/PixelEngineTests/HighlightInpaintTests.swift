import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// Highlight Reconstruction › Inpaint Opposed (HighlightInpaint.swift):
/// the whole-frame estimate, the kernel, the stored method and the stage
/// in a render.
final class HighlightInpaintTests: XCTestCase {
    typealias F = RawReconstructionFixtures

    /// A red background with a disc whose red photosites clip.
    static func clippedDiscFile(width: Int = 96, height: Int = 64) throws -> RawFile {
        try F.file(width: width, height: height) { x, y in
            let dx = Float(x - width / 2), dy = Float(y - height / 2)
            return dx * dx + dy * dy < 14 * 14 ? SIMD3(1000, 800, 600) : SIMD3(450, 300, 200)
        }
    }

    // MARK: - The estimate

    func testEstimateTakesTheRingsColour() throws {
        let file = try Self.clippedDiscFile()
        let s = file.summary
        let samples = try XCTUnwrap(file.rawSensorPlane())
        let estimate = HighlightInpaint.estimate(samples: samples, width: s.rawWidth, height: s.rawHeight,
                                                 order: F.order, blackLevel: 0, whiteLevel: 1000, threshold: 0.85)
        XCTAssertGreaterThan(estimate.clippedCount, 0)
        XCTAssertGreaterThanOrEqual(estimate.ringCount, HighlightInpaintEstimate.minimumRing)
        // The ring is all background: 0.45, 0.3, 0.2 of white.
        let mean = estimate.sums / Double(estimate.ringCount)
        XCTAssertEqual(mean.x, 0.45, accuracy: 0.01)
        XCTAssertEqual(mean.y, 0.30, accuracy: 0.01)
        XCTAssertEqual(mean.z, 0.20, accuracy: 0.01)
        // White-balanced (2, 1, 1.5): 0.9, 0.3, 0.3, so red is three times
        // the mean of the other two.
        let ratio = estimate.ratio(multipliers: SIMD3(2, 1, 1.5))
        XCTAssertEqual(ratio.x, 3, accuracy: 0.05)
        XCTAssertEqual(ratio.y, 0.5, accuracy: 0.02)
    }

    func testWithoutClippingTheRatioIsNeutral() throws {
        let file = try F.file(width: 64, height: 48) { _, _ in SIMD3(450, 300, 200) }
        let samples = try XCTUnwrap(file.rawSensorPlane())
        let estimate = HighlightInpaint.estimate(samples: samples, width: 64, height: 48, order: F.order,
                                                 blackLevel: 0, whiteLevel: 1000, threshold: 0.85)
        XCTAssertEqual(estimate.clippedCount, 0)
        XCTAssertEqual(estimate.ringCount, 0)
        XCTAssertEqual(estimate.ratio(multipliers: SIMD3(2, 1, 1.5)), SIMD3(repeating: 1))
    }

    // MARK: - The kernel

    func testKernelRebuildsOnlyClippedChannelsAndNeverDarkens() throws {
        let gpu = try GPUContext()
        // Clip at 2 in every channel: an unclipped pixel, one with red
        // clipped, one with red clipped but brighter than the rebuilt
        // value would be.
        let pixels: [Float] = [0.5, 0.3, 0.4, 1,
                               2.0, 0.9, 0.9, 1,
                               2.4, 0.2, 0.1, 1]
        let input = try F.texture(pixels, width: 3, height: 1, gpu: gpu)
        let output = try F.texture([Float](repeating: 0, count: 12), width: 3, height: 1, gpu: gpu)
        var params = HighlightInpaintParamsGPU(clipLevel: SIMD4(2, 2, 2, 0), ratio: SIMD4(3, 1, 1, 0),
                                               threshold: 0.85, amount: 1)
        let pso = try gpu.lazyPipeline(.highlightInpaintOpposed)
        let cmd = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        let enc = try XCTUnwrap(cmd.makeComputeCommandEncoder())
        enc.setComputePipelineState(pso)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        enc.setBytes(&params, length: MemoryLayout<HighlightInpaintParamsGPU>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: 3, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 3, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let out = try F.floats(output, gpu: gpu)
        XCTAssertEqual(Array(out[0..<3]), [0.5, 0.3, 0.4], "unclipped pixels pass through")
        XCTAssertEqual(out[4], 2.7, accuracy: 1e-5, "red rebuilt: the mean of green and blue times the ratio")
        XCTAssertEqual(out[5], 0.9, accuracy: 1e-5)
        XCTAssertEqual(out[8], 2.4, accuracy: 1e-5, "a clipped channel is never lowered")
    }

    // MARK: - The stored method

    func testMethodIsStoredOnlyWhenNotTheBlend() throws {
        var p = EditParameters()
        XCTAssertFalse(try EditStack(parameters: p).encodeJSON().contains("method\":\"inpaint"))
        XCTAssertFalse(try EditStack(parameters: p).encodeJSON().contains("\"embedded\""))
        p.highlightMethod = .inpaintOpposed
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"method\":\"inpaintOpposed\""))
        XCTAssertEqual(try EditStack.decode(json: json).parameters().highlightMethod, .inpaintOpposed)
        // A stack from before the method existed reads as the blend.
        let old = json.replacingOccurrences(of: "\"method\":\"inpaintOpposed\",", with: "")
        XCTAssertEqual(try EditStack.decode(json: old).parameters().highlightMethod, .blend)
        XCTAssertNotEqual(p, EditParameters())
    }

    // MARK: - In a render

    /// The stage lifts the clipped disc's red above the clip level towards
    /// the background's colour and leaves the background alone; the
    /// colour kernel's blend is off while it runs.
    func testStageRebuildsTheClippedDisc() throws {
        let gpu = try GPUContext()
        let file = try Self.clippedDiscFile()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        p.highlightMethod = .inpaintOpposed
        let multipliers = session.multipliers(for: p.whiteBalance)
        let camera = try pipeline.renderCameraRGB(session, scale: .full, parameters: p)
        let before = try F.floats(camera, gpu: gpu)
        let cmd = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        let rebuilt = try HighlightInpaintStage.encode(input: camera, session: session, multipliers: multipliers,
                                                       parameters: p, preview: false, gpu: gpu, commandBuffer: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        let after = try F.floats(rebuilt, gpu: gpu)
        let w = camera.width
        let centre = ((camera.height / 2) * w + w / 2) * 4
        let corner = (4 * w + 4) * 4
        let clip = session.highlightClipLevel(multipliers: multipliers)
        XCTAssertEqual(before[centre], clip.x, accuracy: 0.01, "the disc's red is clipped")
        XCTAssertGreaterThan(after[centre], clip.x * 1.1, "and rebuilt above the clip level")
        XCTAssertEqual(after[centre + 1], before[centre + 1], accuracy: 1e-3, "green wasn't clipped")
        for c in 0..<3 { XCTAssertEqual(after[corner + c], before[corner + c], accuracy: 1e-3) }
        XCTAssertTrue(HighlightInpaintStage.isActive(p, session: session))
        XCTAssertEqual(HighlightInpaintStage.blendStrength(p, session: session), 0)
        p.highlightMethod = .blend
        XCTAssertEqual(HighlightInpaintStage.blendStrength(p, session: session), p.highlightRecovery)

        // The full render runs it, and differs from the blend's.
        var inpaint = EditParameters(); inpaint.highlightMethod = .inpaintOpposed
        let a = try F.floats(pipeline.render(session, parameters: inpaint, output: .sceneLinear), gpu: gpu)
        let b = try F.floats(pipeline.render(session, parameters: EditParameters(), output: .sceneLinear), gpu: gpu)
        XCTAssertNotEqual(a[centre], b[centre], accuracy: 1e-3)
        XCTAssertEqual(a[corner], b[corner], accuracy: 1e-3)
    }

    /// On the golden raw: a tile renders exactly what the same pixels of a
    /// larger render hold, because the estimate is the whole frame's.
    func testTilesAgreeOnTheGoldenRaw() throws {
        let path = TestAssets.path(TestAssets.goldenName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "golden raw missing")
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        p.whiteBalance = .asShot
        p.highlightMethod = .inpaintOpposed
        p.lensDistortion = false; p.lensTCA = false; p.lensVignetting = false
        let s = session.file.summary
        let (x, y) = ((s.rawWidth / 2) & ~1, (s.rawHeight / 2) & ~1)
        let big = try F.floats(pipeline.render(session, scale: .region(x: x - 64, y: y - 64, width: 256, height: 256),
                                               parameters: p), gpu: gpu)
        let small = try F.floats(pipeline.render(session, scale: .region(x: x, y: y, width: 96, height: 96),
                                                 parameters: p), gpu: gpu)
        var worst: Float = 0
        for ty in 16..<80 {
            for tx in 16..<80 {
                for c in 0..<3 {
                    worst = max(worst, abs(small[(ty * 96 + tx) * 4 + c] - big[((ty + 64) * 256 + tx + 64) * 4 + c]))
                }
            }
        }
        XCTAssertLessThan(worst, 1e-3)
        XCTAssertNotNil(HighlightInpaint.estimate(for: session, threshold: p.highlightThreshold))
    }
}
