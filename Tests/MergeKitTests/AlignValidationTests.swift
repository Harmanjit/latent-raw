import XCTest
import simd
@testable import MergeKit

/// The checks that decide whether an alignment can be trusted, and the
/// chaining of neighbour alignments to a reference.
final class AlignValidationTests: XCTestCase {
    static let width = 1000, height = 667

    /// Two views of different parts of the scene share no content: whatever
    /// the refinement finds, it must not be accepted.
    func testDifferentImagesAreRejected() throws {
        let scene = try AlignTestSupport.scene()
        let left = AlignTestSupport.frame(scene, width: Self.width, height: Self.height,
                                          viewToScene: Homography.translation(40, 300), gain: 1, seed: 1)
        let right = AlignTestSupport.frame(scene, width: Self.width, height: Self.height,
                                           viewToScene: Homography.translation(Double(scene.width - Self.width - 40), 900),
                                           gain: 1, seed: 2)
        let result = FrameAligner().align(moving: AlignTestSupport.alignmentImage(right, gain: 1),
                                          reference: AlignTestSupport.alignmentImage(left, gain: 1), model: .hdr)
        print("align-validation | different images | NCC \(result.ncc) | \(String(describing: result.rejection))")
        XCTAssertFalse(result.accepted)
        XCTAssertNotNil(result.rejection)
        XCTAssertEqual(result.homography, Homography.identity, "a rejected alignment warps nothing")
    }

    /// NCC separates a right answer from a wrong one: the true homography
    /// scores well above 0.9, while no movement at all (for frames 30 px
    /// apart) or an answer 10 px off scores below it.
    func testCorrelationSeparatesRightFromWrong() throws {
        let truth = Homography.translation(30, -20)
        let (reference, moving) = try AlignTestSupport.pair(truth: truth, width: Self.width, height: Self.height)
        let aligner = FrameAligner()
        let right = aligner.score(truth, moving: moving, reference: reference)
        let still = aligner.score(Homography.identity, moving: moving, reference: reference)
        let off = aligner.score(Homography.translation(8, 6) * truth, moving: moving, reference: reference)
        print("align-validation | NCC truth \(right.ncc) | identity \(still.ncc) | 10 px off \(off.ncc)")
        XCTAssertGreaterThan(right.ncc, 0.98)
        XCTAssertLessThan(still.ncc, aligner.minimumNCC)
        XCTAssertLessThan(off.ncc, aligner.minimumNCC)
        XCTAssertGreaterThan(right.overlapFraction, 0.9)
    }

    func testHDRRejectsScaleChanges() throws {
        let truth = Homography.rotation(degrees: 0, scale: 1.03,
                                        about: SIMD2(Double(Self.width), Double(Self.height)) / 2)
        let (reference, moving) = try AlignTestSupport.pair(truth: truth, width: Self.width, height: Self.height)
        let result = FrameAligner().align(moving: moving, reference: reference, model: .hdr)
        XCTAssertFalse(result.accepted)
        guard case .scaleChange(let fraction) = result.rejection else {
            return XCTFail("expected a scale change rejection, got \(String(describing: result.rejection))")
        }
        XCTAssertEqual(fraction, 0.03, accuracy: 0.002)
    }

    /// 12 stops apart, the frames share no tones both record well.
    func testExposuresWithNoSharedRangeAreRejected() throws {
        let (reference, moving) = try AlignTestSupport.pair(truth: Homography.identity, width: 400, height: 267,
                                                            referenceGain: 1, movingGain: pow(2, -12), noise: false)
        let result = FrameAligner().align(moving: moving, reference: reference, model: .hdr)
        XCTAssertEqual(result.rejection, .noSharedExposureRange)
        XCTAssertFalse(result.accepted)
    }

    /// Panorama frames overlapping by 3% of their width are too little to trust.
    func testTooLittleOverlapIsRejected() throws {
        let truth = Homography.translation(0.97 * Double(Self.width), 0)
        let (reference, moving) = try AlignTestSupport.pair(truth: truth, width: Self.width, height: Self.height)
        let result = FrameAligner().align(moving: moving, reference: reference, model: .panorama)
        XCTAssertFalse(result.accepted)
    }

    /// A panorama pair with 30% overlap is found without any initial guess.
    func testPanoramaPairWithSmallOverlap() throws {
        let truth = Homography.translation(-0.7 * Double(Self.width), 14.5)
        let (reference, moving) = try AlignTestSupport.pair(truth: truth, width: Self.width, height: Self.height)
        let result = FrameAligner().align(moving: moving, reference: reference, model: .panorama)
        let error = Homography.maxCornerDistance(result.estimatedHomography, truth, width: Self.width, height: Self.height)
        print("align-validation | panorama 30% overlap | error \(error) | overlap \(result.overlapFraction)")
        XCTAssertTrue(result.accepted, String(describing: result.rejection))
        XCTAssertLessThan(error, 0.3)
        XCTAssertEqual(result.overlapFraction, 0.3, accuracy: 0.02)
    }

    // MARK: - Chains

    /// Composition alone: links k -> k + 1 multiplied along the way to the
    /// reference, inverted on the far side, and a rejected link breaking
    /// only the frames beyond it.
    func testChainComposesLinks() {
        let w = 6000, h = 4000
        let links = [Homography.translation(3, 1), Homography.rotation(degrees: 0.2, about: SIMD2(3000, 2000)),
                     Homography.translation(-2, 5), Homography.translation(0.02, 0.01)]
        func accepted(_ h: simd_double3x3) -> AlignmentResult {
            var r = AlignmentResult.identity
            r.estimatedHomography = h
            r.homography = h
            return r
        }
        let results = FrameAligner.chain(links.map(accepted), reference: 2, width: w, height: h)
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results[2], .identity)
        let expected = [links[1] * links[0], links[1], Homography.identity, links[2].inverse,
                        links[2].inverse * links[3].inverse]
        for (index, want) in expected.enumerated() {
            XCTAssertLessThan(Homography.maxCornerDistance(results[index].estimatedHomography, want, width: w, height: h),
                              1e-9, "frame \(index)")
        }

        var broken = links.map(accepted)
        broken[3].accepted = false
        broken[3].rejection = .lowCorrelation(ncc: 0.5)
        let partial = FrameAligner.chain(broken, reference: 1, width: w, height: h)
        XCTAssertTrue(partial[0].accepted && partial[2].accepted && partial[3].accepted)
        XCTAssertEqual(partial[4].rejection, .chainBroken(link: 3))
        XCTAssertEqual(partial[4].homography, Homography.identity)
    }

    /// A synthetic handheld bracket 2 stops apart per frame (8 in all):
    /// each frame carried to the second one by the chain, within 0.3 px.
    func testBracketChainRecoversEveryFrame() throws {
        let scene = try AlignTestSupport.scene()
        let (w, h) = (Self.width, Self.height)
        let centre = SIMD2(Double(w), Double(h)) / 2
        let crop = Homography.translation(Double(scene.width - w) / 2, Double(scene.height - h) / 2)
        // Each frame's own movement from an imaginary steady view.
        let poses = [Homography.translation(3.2, -1.1) * Homography.rotation(degrees: 0.3, about: centre),
                     Homography.identity,
                     Homography.translation(-4.5, 2.25),
                     Homography.cameraRotation(yaw: 0.3, pitch: -0.2, roll: -0.25, focalLength: 1200, principalPoint: centre),
                     Homography.translation(7.75, 5.5) * Homography.rotation(degrees: -0.4, about: centre)]
        let gains = [4.0, 1, 0.25, 0.0625, 0.015625]
        let images = zip(poses, gains).enumerated().map { index, frame in
            AlignTestSupport.alignmentImage(
                AlignTestSupport.frame(scene, width: w, height: h, viewToScene: crop * frame.0, gain: frame.1,
                                       seed: 100 + UInt64(index)),
                gain: frame.1)
        }
        let reference = 1
        let results = FrameAligner().alignBracket(images, reference: reference)
        for (index, result) in results.enumerated() {
            // moving(p) shows the steady view at pose p, the reference at
            // pose_ref p', so moving -> reference = pose_ref⁻¹ pose.
            let truth = poses[reference].inverse * poses[index]
            let error = Homography.maxCornerDistance(result.estimatedHomography, truth, width: w, height: h)
            print(String(format: "align-chain | frame %d | error %.3f px | NCC %.4f", index, error, result.ncc))
            XCTAssertTrue(result.accepted, "frame \(index): \(String(describing: result.rejection))")
            XCTAssertLessThan(error, 0.3, "frame \(index)")
        }
    }
}
