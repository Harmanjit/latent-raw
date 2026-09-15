import XCTest
import simd
@testable import MergeKit

/// Known homographies between synthetic frames cut from a real photo (the
/// golden D750 NEF), recovered by `FrameAligner` to within 0.3 px at the
/// corners: shifts, rotations, scale changes, a camera turning about its
/// lens, and HDR exposure gaps with clipping and noise.
///
/// Each test prints a row for the accuracy table in the alignment report.
final class AlignAccuracyTests: XCTestCase {
    static let width = 1600, height = 1067
    static var centre: SIMD2<Double> { SIMD2(Double(width), Double(height)) / 2 }

    /// Aligns a synthetic pair related by `truth` and checks the estimate.
    @discardableResult
    private func check(_ name: String, truth: simd_double3x3, model: AlignmentModel = .hdr,
                       referenceGain: Double = 1, movingGain: Double = 1,
                       width: Int = AlignAccuracyTests.width, height: Int = AlignAccuracyTests.height,
                       tolerance: Double = 0.3, file: StaticString = #filePath, line: UInt = #line) throws -> AlignmentResult {
        let (reference, moving) = try AlignTestSupport.pair(truth: truth, width: width, height: height,
                                                            referenceGain: referenceGain, movingGain: movingGain)
        let start = Date()
        let result = FrameAligner().align(moving: moving, reference: reference, model: model)
        let seconds = Date().timeIntervalSince(start)
        let error = Homography.maxCornerDistance(result.estimatedHomography, truth, width: width, height: height)
        print(String(format: "align-accuracy | %@ | moved %.2f px | error %.3f px | NCC %.4f | converged %@ | %.2f s",
                     name, Homography.maxCornerShift(truth, width: width, height: height), error, result.ncc,
                     result.converged ? "yes" : "no", seconds))
        XCTAssertTrue(result.accepted, "\(name): rejected \(String(describing: result.rejection))", file: file, line: line)
        XCTAssertLessThan(error, tolerance, "\(name): corner error", file: file, line: line)
        return result
    }

    func testShifts() throws {
        try check("shift 0.3 px", truth: Homography.translation(0.3, -0.2))
        try check("shift 3.7 px", truth: Homography.translation(3.7, 1.9))
        try check("shift 25 px", truth: Homography.translation(-25.4, 11.2))
        try check("shift 200 px", truth: Homography.translation(200, -35.5))
    }

    func testRotations() throws {
        let c = Self.centre
        try check("rotate 0.2 deg", truth: Homography.rotation(degrees: 0.2, about: c))
        try check("rotate 1 deg + shift", truth: Homography.translation(4.2, -2.6) * Homography.rotation(degrees: -1, about: c))
        try check("rotate 3 deg + shift", truth: Homography.translation(-9.5, 6.1) * Homography.rotation(degrees: 3, about: c))
    }

    func testScaleChanges() throws {
        let c = Self.centre
        try check("scale 0.5%", truth: Homography.rotation(degrees: 0, scale: 1.005, about: c))
        try check("scale 1.5% + rotate 0.5 deg", truth: Homography.rotation(degrees: 0.5, scale: 0.985, about: c))
        // Beyond the HDR limit: recovered as a panorama pair would be.
        try check("scale 3% (panorama)", truth: Homography.rotation(degrees: -0.3, scale: 1.03, about: c),
                  model: .panorama)
    }

    /// A camera turning about its lens: shift plus keystone, as handheld
    /// frames really move.
    func testCameraRotation() throws {
        let focal = 1.2 * Double(Self.width)
        try check("turn yaw 1.5 pitch -0.8 roll 0.3 deg",
                  truth: Homography.cameraRotation(yaw: 1.5, pitch: -0.8, roll: 0.3, focalLength: focal,
                                                   principalPoint: Self.centre))
        try check("turn yaw -4 pitch 2 deg (wide)",
                  truth: Homography.cameraRotation(yaw: -4, pitch: 2, roll: 0, focalLength: 0.8 * Double(Self.width),
                                                   principalPoint: Self.centre))
    }

    /// Handheld brackets 2, 4 and 8 stops apart: the brighter frame is
    /// exposed 2 stops over, so its highlights clip; the darker one's
    /// shadows sink into noise.
    func testExposureGaps() throws {
        let handheld = Homography.translation(6.2, -3.1)
            * Homography.cameraRotation(yaw: 0.2, pitch: 0.15, roll: 0.4, focalLength: 1.2 * Double(Self.width),
                                        principalPoint: Self.centre)
        for gap in [2.0, 4, 8] {
            try check("HDR \(Int(gap)) EV apart, handheld", truth: handheld, referenceGain: 4,
                      movingGain: 4 / pow(2, gap))
        }
    }

    /// Frames bigger than the finest level (3600 px here), so the pyramid's
    /// first reduction is a real one; homographies stay in full-size pixels.
    func testLargeFrame() throws {
        let width = 3600, height = 2400
        let truth = Homography.translation(38.5, -12.25)
            * Homography.rotation(degrees: 0.5, about: SIMD2(Double(width), Double(height)) / 2)
        let scene = try AlignTestSupport.scene()
        // The scene magnified 1.25x, so a 3600 px view fits inside it.
        let magnify = Homography.translation(Double(scene.width) / 2, Double(scene.height) / 2)
            * Homography.scale(0.8, 0.8) * Homography.translation(-Double(width) / 2, -Double(height) / 2)
        let a = AlignTestSupport.frame(scene, width: width, height: height, viewToScene: magnify, gain: 1, seed: 11)
        let b = AlignTestSupport.frame(scene, width: width, height: height, viewToScene: magnify * truth, gain: 1, seed: 12)
        let reference = AlignTestSupport.alignmentImage(a, gain: 1), moving = AlignTestSupport.alignmentImage(b, gain: 1)
        XCTAssertEqual(reference.finest.width, 3200)
        let result = FrameAligner().align(moving: moving, reference: reference, model: .hdr)
        let error = Homography.maxCornerDistance(result.estimatedHomography, truth, width: width, height: height)
        print(String(format: "align-accuracy | 3600 px frame, shift + rotate 0.5 deg | error %.3f px | NCC %.4f",
                     error, result.ncc))
        XCTAssertTrue(result.accepted)
        XCTAssertLessThan(error, 0.3)
    }

    /// A tripod pair (no movement, different exposure and noise) needs no
    /// warp: the homography comes back exactly the identity.
    func testTripodNeedsNoWarp() throws {
        let result = try check("tripod, 2 EV apart", truth: Homography.identity, referenceGain: 2, movingGain: 0.5)
        XCTAssertEqual(result.homography, Homography.identity)
        XCTAssertFalse(result.needsWarp)
        XCTAssertLessThan(result.maxCornerShift, 0.1)
    }
}
