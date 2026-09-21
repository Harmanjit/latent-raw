import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// The raw ↔ output geometry helpers (docs/Retouch.md §7): a face box is
/// found on the corrected render and stored on the raw grid, then mapped
/// forward again on open, so the two must invert each other closely
/// enough that a seed never drifts off its face.
final class SensorPointTests: XCTestCase {
    /// Points across the frame, `inset` from the edges as a fraction.
    private func grid(_ width: Int, _ height: Int, inset: Float = 0.05) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        for j in 0...8 {
            for i in 0...8 {
                points.append(SIMD2(Float(width) * (inset + (1 - 2 * inset) * Float(i) / 8),
                                    Float(height) * (inset + (1 - 2 * inset) * Float(j) / 8)))
            }
        }
        return points
    }

    /// Output → raw → output over the whole frame; raw → output → raw over
    /// the central half only, since a raw point near the edge may lie
    /// outside what the corrected image covers at all (a pincushion
    /// correction zooms in), and then has no output point to find.
    private func assertInverse(session: ImageSession, pipeline: RenderPipeline, parameters: EditParameters,
                               label: String, file: StaticString = #filePath, line: UInt = #line) {
        let summary = session.file.summary
        var moved: Float = 0
        for p in grid(summary.rawWidth, summary.rawHeight) {
            let raw = pipeline.rawSensorPoint(forOutputPoint: p, session: session, parameters: parameters)
            let back = pipeline.outputSensorPoint(forRawPoint: raw, session: session, parameters: parameters)
            XCTAssertLessThan(simd_length(back - p), 0.05, "\(label): output \(p) → raw \(raw) → \(back)", file: file, line: line)
            moved = max(moved, simd_length(raw - p))
        }
        for p in grid(summary.rawWidth, summary.rawHeight, inset: 0.25) {
            let out = pipeline.outputSensorPoint(forRawPoint: p, session: session, parameters: parameters)
            let there = pipeline.rawSensorPoint(forOutputPoint: out, session: session, parameters: parameters)
            XCTAssertLessThan(simd_length(there - p), 0.05, "\(label): raw \(p) → output \(out) → \(there)", file: file, line: line)
        }
        XCTAssertGreaterThan(moved, 0.5, "\(label): the correction actually moves pixels", file: file, line: line)
    }

    /// Without any correction wanted (a fixture with no lens EXIF), both
    /// are the identity, exactly.
    func testIdentityWithoutLensCorrection() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.orientation6)), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        XCTAssertNil(session.lensCorrection)
        let parameters = EditParameters()
        XCTAssertFalse(RenderPipeline.wantsLensCorrection(session: session, parameters: parameters))
        for p in grid(64, 48) {
            XCTAssertEqual(pipeline.rawSensorPoint(forOutputPoint: p, session: session, parameters: parameters), p)
            XCTAssertEqual(pipeline.outputSensorPoint(forRawPoint: p, session: session, parameters: parameters), p)
        }
    }

    /// The golden D750 raw's Tamron profile (distortion, TCA, vignetting),
    /// then keystone and manual distortion on top, which move reads far
    /// further than a profile does.
    func testInverseHoldsWithinATwentiethOfAPixel() throws {
        let path = TestAssets.path(TestAssets.goldenName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "needs \(TestAssets.goldenName)")
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        XCTAssertNotNil(session.lensCorrection?.distortion, "the profile the test relies on")

        let profile = EditParameters()
        XCTAssertTrue(RenderPipeline.wantsLensCorrection(session: session, parameters: profile))
        assertInverse(session: session, pipeline: pipeline, parameters: profile, label: "profile")

        var keystone = EditParameters()
        keystone.perspective = PerspectiveCorrection(vertical: 0.3, horizontal: -0.15)
        keystone.manualDistortion = 0.15
        assertInverse(session: session, pipeline: pipeline, parameters: keystone, label: "profile + keystone + manual")

        // Manual distortion alone. −0.1 is as far as the map stays
        // one-to-one out to a 3:2 frame's corners (r = 1.8 short-side
        // halves): the slope (1 − m) + 3 m r² must stay positive.
        var manualOnly = EditParameters()
        manualOnly.lensDistortion = false; manualOnly.lensTCA = false; manualOnly.lensVignetting = false
        manualOnly.manualDistortion = -0.1
        assertInverse(session: session, pipeline: pipeline, parameters: manualOnly, label: "manual only")

        // The green channel is what a point maps through: with TCA on, the
        // raw point is the first of the three source points.
        let sampling = RenderPipeline.LensSampling(session: session, parameters: profile)
        let p = SIMD2<Float>(700, 500)
        XCTAssertEqual(pipeline.rawSensorPoint(forOutputPoint: p, session: session, parameters: profile),
                       sampling.sourcePoints(forSensorPoint: p)[0])
        XCTAssertEqual(sampling.sourcePoints(forSensorPoint: p).count, 3)
    }
}
