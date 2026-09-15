import XCTest
import simd
import PixelEngine
@testable import MergeKit

/// Auto Align inside the HDR merge: what the analysis reports, what the plan
/// does with links the aligner rejected, and merges of synthetic brackets
/// whose frames moved by a known amount.
final class HDRAutoAlignTests: XCTestCase {
    // MARK: - The plan, from links alone

    /// A link as the aligner reports it: accepted with this homography, or
    /// rejected for too little detail.
    private func link(_ h: simd_double3x3, accepted: Bool = true) -> AlignmentResult {
        var result = AlignmentResult.identity
        result.estimatedHomography = h
        result.homography = accepted ? h : Homography.identity
        result.maxCornerShift = Homography.maxCornerShift(h, width: 1000, height: 800)
        result.accepted = accepted
        result.rejection = accepted ? nil : .notEnoughDetail
        return result
    }

    /// Accepted links carry every frame to the reference, whichever it is.
    func testAcceptedLinksAlignEveryFrameToTheReference() {
        let alignment = HDRMergeAlignment(
            links: [link(Homography.translation(3, 0)), link(Homography.translation(0, 4))],
            chainOrder: [0, 1, 2], neighbourShiftPixels: [nil, nil], width: 1000, height: 800)

        let middle = alignment.plan(reference: 1)
        XCTAssertEqual(middle.frames, [.aligned(shiftPixels: 3), .reference, .aligned(shiftPixels: 4)])
        XCTAssertEqual(Homography.apply(middle.homographies[0], SIMD2(10, 10)), SIMD2(13, 10))
        XCTAssertEqual(Homography.apply(middle.homographies[2], SIMD2(10, 10)).y, 6, accuracy: 1e-9,
                       "the link read the other way round")
        XCTAssertTrue(middle.warps)
        XCTAssertEqual(middle.largestShiftPixels, 4)

        let last = alignment.plan(reference: 2)
        XCTAssertEqual(Homography.apply(last.homographies[0], SIMD2(10, 10)).x, 13, accuracy: 1e-9)
        XCTAssertEqual(Homography.apply(last.homographies[0], SIMD2(10, 10)).y, 14, accuracy: 1e-9, "both links")
        XCTAssertEqual(last.frames[2], .reference)
    }

    /// A rejected link that phase correlation says barely moved (or can't
    /// judge) counts as no movement: the frame beyond it is merged unaligned,
    /// and frames further along stay lined up with it.
    func testARejectedLinkThatBarelyMovedMergesUnaligned() {
        for shift in [0.8, nil] as [Double?] {
            let alignment = HDRMergeAlignment(
                links: [link(Homography.translation(9, 0), accepted: false), link(Homography.translation(2, 0)),
                        link(Homography.translation(0, 5))],
                chainOrder: [0, 1, 2, 3], neighbourShiftPixels: [shift, nil, nil], width: 1000, height: 800)
            let plan = alignment.plan(reference: 3)
            XCTAssertEqual(plan.frames[0], .unaligned, "\(String(describing: shift))")
            XCTAssertEqual(plan.frames[1], .aligned(shiftPixels: 29.squareRoot()), "both accepted links")
            XCTAssertEqual(Homography.apply(plan.homographies[0], SIMD2(0, 0)).x, 2, accuracy: 1e-9,
                           "carried along the accepted links, not by the rejected estimate")
            XCTAssertTrue(plan.includes(0))
        }
    }

    /// A rejected link that phase correlation says moved several pixels
    /// leaves the frames beyond it out, unless that would leave the
    /// reference alone.
    func testARejectedLinkThatMovedFarLeavesFramesOut() {
        let alignment = HDRMergeAlignment(
            links: [link(Homography.translation(1, 0)), link(Homography.translation(12, 0), accepted: false)],
            chainOrder: [0, 1, 2], neighbourShiftPixels: [nil, 11.5], width: 1000, height: 800)
        let plan = alignment.plan(reference: 1)
        XCTAssertEqual(plan.frames, [.aligned(shiftPixels: 1), .reference, .leftOut])
        XCTAssertFalse(plan.includes(2))
        XCTAssertEqual(plan.homographies[2], Homography.identity)

        // With the last frame as the reference, the first two lie beyond the
        // rejected link, and leaving both out would leave it alone.
        let alone = alignment.plan(reference: 2)
        XCTAssertEqual(alone.frames, [.unaligned, .unaligned, .reference], "a merge keeps at least two frames")
        XCTAssertTrue((0..<3).allSatisfy { alone.includes($0) })
    }

    /// The chain follows the order frames were read in, which the analysis
    /// may have reordered: the plan answers in the analysis's order.
    func testChainOrderMapsToTheAnalysisOrder() {
        let alignment = HDRMergeAlignment(
            links: [link(Homography.translation(3, 0)), link(Homography.translation(0, 4))],
            chainOrder: [1, 0, 2], neighbourShiftPixels: [nil, nil], width: 1000, height: 800)
        // Chain position 1 (the analysis's frame 0) is the reference.
        let plan = alignment.plan(reference: 0)
        XCTAssertEqual(plan.frames, [.reference, .aligned(shiftPixels: 3), .aligned(shiftPixels: 4)])
    }

    // MARK: - Options and the recipe

    func testOptionsWithoutAutoAlignDecodeWithItOn() throws {
        let decoder = JSONDecoder()
        XCTAssertTrue(try decoder.decode(HDRMergeOptions.self, from: Data(#"{"deghost":"low"}"#.utf8)).autoAlign)
        let off = HDRMergeOptions(deghost: .medium, autoAlign: false)
        XCTAssertEqual(try decoder.decode(HDRMergeOptions.self, from: JSONEncoder().encode(off)), off)
        XCTAssertTrue(HDRMergeOptions().autoAlign)
    }

    func testTheRecipeRecordsWhatAutoAlignDid() {
        XCTAssertEqual(HDRMerger.recipeOptions(HDRMergeOptions(autoAlign: false)),
                       ["deghost": .string("none"), "clipFeather": .number(1), "autoAlign": .bool(false)])
        let alignment = HDRMergeAlignment(
            links: [link(Homography.translation(3.14159, 0)), link(Homography.translation(12, 0), accepted: false)],
            chainOrder: [0, 1, 2], neighbourShiftPixels: [nil, 11.5], width: 1000, height: 800)
        XCTAssertEqual(HDRMerger.recipeOptions(HDRMergeOptions(), alignment: alignment.plan(reference: 1)), [
            "deghost": .string("none"), "clipFeather": .number(1), "autoAlign": .bool(true),
            "alignmentShifts": .array([.number(3.14), .number(0), .null]), "leftOut": .array([.number(2)]),
        ])
    }

    /// Aligning adds the warped frame and its clip mask, 9 bytes a pixel.
    func testAligningAddsTheWarpedFrameToTheMemoryEstimate() {
        let plain = HDRMergeAccumulator.estimatedPeakBytes(width: 6000, height: 4000)
        XCTAssertEqual(HDRMergeAccumulator.estimatedPeakBytes(width: 6000, height: 4000, aligned: true) - plain,
                       9 * 6000 * 4000)
    }

    // MARK: - Real merges of synthetic brackets

    /// The middle frame moved 5 px: Auto Align measures it and says nothing,
    /// where with Auto Align off the analysis warns.
    func testAShiftedFrameIsAlignedInsteadOfWarnedAbout() async throws {
        var frames = SyntheticBracket.frames(HDRTestSupport.threeExposures)
        frames[1].shiftX = 5
        let urls = try HDRTestSupport.bracket("shifted5", frames, noise: true)
        let merger = try HDRTestSupport.merger()

        let aligned = try await merger.analyse(urls)
        XCTAssertEqual(aligned.warnings, [], "aligned automatically")
        let alignment = try XCTUnwrap(aligned.alignment)
        XCTAssertTrue(alignment.links.allSatisfy(\.accepted), "\(alignment.links.map(\.rejection))")
        XCTAssertEqual(aligned.frames[aligned.referenceIndex].alignmentShiftPixels, 0)
        XCTAssertTrue(aligned.frames.allSatisfy { $0.alignmentShiftPixels != nil })
        // Judged where the scene has detail: most of this scene is flat
        // patches, which pin a homography's shift but not its slight
        // perspective, so the corners (and the reported shifts) can be a few
        // pixels out where there is nothing to see anyway.
        let plan = alignment.plan(reference: aligned.referenceIndex)
        let textured = SIMD2<Double>(900, 510)
        for (i, want) in [(0, 0.0), (1, -5.0), (2, 0.0)] {
            let moved = Homography.apply(plan.homographies[i], textured) - textured
            XCTAssertEqual(moved.x, want, accuracy: 0.5, "frame \(i) moved \(moved)")
            XCTAssertEqual(moved.y, 0, accuracy: 0.5, "frame \(i) moved \(moved)")
        }

        let unaligned = try await merger.analyse(urls, options: HDRMergeOptions(autoAlign: false))
        XCTAssertNil(unaligned.alignment)
        XCTAssertTrue(unaligned.frames.allSatisfy { $0.alignmentShiftPixels == nil })
        guard case .framesLookMisaligned(let pixels)? = unaligned.warnings.first else {
            return XCTFail("expected the misalignment warning, got \(unaligned.warnings)")
        }
        XCTAssertEqual(pixels, 5, accuracy: 1)
    }

    /// Noiseless frames with the middle one moved 5 px: aligned, the merge
    /// matches the scene as closely as a tripod bracket's does, including
    /// the strip along the edge the moved frame doesn't cover; unaligned,
    /// its textured part is visibly off.
    func testAShiftedFrameMergesAsSharpAsATripodBracket() async throws {
        var frames = SyntheticBracket.frames(HDRTestSupport.threeExposures)
        frames[1].shiftX = 5
        let urls = try HDRTestSupport.bracket("clean-shifted5", frames, noise: false)
        let scene = HDRTestSupport.scene
        let merger = try HDRTestSupport.merger()

        func texturedError(_ options: HDRMergeOptions) async throws -> (mean: Double, merged: HDRTestSupport.Merged,
                                                                        recipe: MergeRecipe) {
            let (_, result, _, folder) = try await HDRTestSupport.merge(urls, merger: merger, options: options)
            defer { try? FileManager.default.removeItem(at: folder) }
            let merged = try HDRTestSupport.readBack(result.url)
            var sum = 0.0, count = 0.0
            for y in stride(from: 440, to: 580, by: 2) {
                for x in stride(from: 620, to: 1180, by: 2) {
                    let want = SyntheticBracket.mergeUnits(scene.radiance(x: x, y: y), brightest: 4)
                    sum += HDRMergeTests.relativeError(SIMD3<Double>(merged.pixel(x, y)), want)
                    count += 1
                }
            }
            return (sum / count, merged, result.recipe)
        }

        let aligned = try await texturedError(HDRMergeOptions())
        let unaligned = try await texturedError(HDRMergeOptions(autoAlign: false))
        print("Shifted bracket, textured area: mean error aligned \(aligned.mean), unaligned \(unaligned.mean)")
        XCTAssertLessThan(aligned.mean, 0.01)
        XCTAssertGreaterThan(unaligned.mean, 3 * aligned.mean)
        XCTAssertEqual(aligned.recipe.options["autoAlign"], .bool(true))
        XCTAssertEqual(unaligned.recipe.options["autoAlign"], .bool(false))

        // The columns the moved frame doesn't reach (at the right, where it
        // was moved back from) come from the other two frames, not from nothing.
        for x in [0, 2, 1195, 1199] {
            for y in [100, 300, 500, 700] {
                let got = SIMD3<Double>(aligned.merged.pixel(x, y))
                XCTAssertTrue(got.x.isFinite && got.y.isFinite && got.z.isFinite, "(\(x), \(y))")
                let want = SyntheticBracket.mergeUnits(scene.radiance(x: x, y: y), brightest: 4)
                XCTAssertLessThan(HDRMergeTests.relativeError(got, want), 0.05, "(\(x), \(y)): \(got), want \(want)")
            }
        }
    }

    /// Deghosting on a handheld bracket: the first frame moved 6 px and the
    /// square moved between every frame. Each frame's measurement is lined
    /// up with the reference before it is compared, so the square comes from
    /// the reference only, and the moved frame's still parts aren't mistaken
    /// for movement.
    func testDeghostingComparesFramesAfterAligningThem() async throws {
        var frames = SyntheticBracket.frames(HDRTestSupport.threeExposures)
        frames[0].shiftX = 6
        for i in frames.indices {
            // In each frame's own pixels: the moved frame's square is drawn
            // 6 px further right, so it lands at `squareColumns[0]` once aligned.
            frames[i].patches = [SyntheticBracket.Patch(
                x: DeghostTests.squareColumns[i] + frames[i].shiftX, y: DeghostTests.squareRow,
                width: DeghostTests.squareSize, height: DeghostTests.squareSize,
                radiance: DeghostTests.squareRadiance)]
        }
        let urls = try HDRTestSupport.bracket("movingSquareShifted", frames, noise: true)
        let square = SyntheticBracket.mergeUnits(DeghostTests.squareRadiance, brightest: 4)
        let background = SyntheticBracket.mergeUnits(DeghostTests.backgroundRadiance, brightest: 4)

        let (analysis, result, report, folder) = try await HDRTestSupport.merge(
            urls, options: HDRMergeOptions(referenceIndex: 1, deghost: .medium))
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(analysis.warnings, [])
        // Measured with the moved frame lined up, the exposures are true.
        for (frame, want) in zip(analysis.frames, [0.0, -2, -4]) {
            XCTAssertEqual(frame.relativeEV, want, accuracy: 0.02, "\(analysis.frames.map(\.relativeEV))")
        }
        let merged = try HDRTestSupport.readBack(result.url)
        let atReference = DeghostTests.interiorMean(merged, column: DeghostTests.squareColumns[1])
        XCTAssertLessThan(HDRMergeTests.relativeError(atReference, square), 0.03, "\(atReference), want \(square)")
        for i in [0, 2] {
            let elsewhere = DeghostTests.interiorMean(merged, column: DeghostTests.squareColumns[i])
            XCTAssertLessThan(HDRMergeTests.relativeError(elsewhere, background), 0.03,
                              "frame \(i)'s square left \(elsewhere), want \(background)")
        }
        print("Shifted moving square at medium: flagged \(report.ghostFlaggedFractions), masked \(report.ghostMaskedFractions)")
        XCTAssertLessThan(report.ghostMaskedFractions[0], 0.05, "only around the squares, not the whole moved frame")
        guard case .array(let shifts)? = result.recipe.options["alignmentShifts"], case .number(let moved)? = shifts.first
        else { return XCTFail("no alignment shifts in \(result.recipe.options)") }
        XCTAssertGreaterThan(moved, 5, "the first frame was lined up")
        let homography = try XCTUnwrap(analysis.alignment).plan(reference: 1).homographies[0]
        let textured = SIMD2<Double>(900, 510)
        XCTAssertEqual((Homography.apply(homography, textured) - textured).x, -6, accuracy: 0.5)
    }
}
