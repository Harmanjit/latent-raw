import XCTest
import PixelEngine
import RawCore
@testable import MergeKit

/// Deghosting and clip feathering on synthetic brackets whose truth is
/// known: something that moved must come from one frame only, noise must not
/// count as movement, and a long exposure's moved leaf must not punch a hole
/// in a clipped sky.
final class DeghostTests: XCTestCase {
    /// Where the moving square is in each of the three frames: inside the
    /// 200 px green patch at x 200..<400, y 240..<420, 40 px wide.
    static let squareColumns = [210, 280, 350]
    static let squareRow = 300
    static let squareSize = 40
    static let squareRadiance = SIMD3<Float>(repeating: 0.15)
    /// The patch the square moves over (SyntheticBracket.Layout.patches[1]).
    static let backgroundRadiance = SIMD3<Float>(0.3, 1.0, 0.4) * 0.1

    /// The test scene with a grey square in a different place in each frame,
    /// with noise.
    static func movingSquareBracket() throws -> [URL] {
        var frames = SyntheticBracket.frames(HDRTestSupport.threeExposures)
        for i in frames.indices {
            frames[i].patches = [SyntheticBracket.Patch(x: squareColumns[i], y: squareRow, width: squareSize,
                                                        height: squareSize, radiance: squareRadiance)]
        }
        return try HDRTestSupport.bracket("movingSquare3", frames, noise: true)
    }

    /// The mean merged value over a square's interior (8 px in from its
    /// edges, clear of demosaicing and the mask's feathered edge).
    static func interiorMean(_ merged: HDRTestSupport.Merged, column: Int) -> SIMD3<Double> {
        var sum = SIMD3<Double>(), count = 0.0
        for y in (squareRow + 8)..<(squareRow + squareSize - 8) {
            for x in (column + 8)..<(column + squareSize - 8) {
                sum += SIMD3<Double>(merged.pixel(x, y))
                count += 1
            }
        }
        return sum / count
    }

    /// With the middle frame as the reference, the square must appear where
    /// that frame has it, at its full brightness, and nowhere else: the
    /// other two frames' squares are replaced by the patch behind them.
    /// Without deghosting all three squares show, blended.
    func testMovingSquareComesFromTheReferenceFrameOnly() async throws {
        let urls = try Self.movingSquareBracket()
        let merger = try HDRTestSupport.merger()
        let square = SyntheticBracket.mergeUnits(Self.squareRadiance, brightest: 4)
        let background = SyntheticBracket.mergeUnits(Self.backgroundRadiance, brightest: 4)

        for amount in [DeghostAmount.medium, .high] {
            let progress = ProgressLog()
            let analysis = try await merger.analyse(urls)
            let folder = try Fixtures.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (result, report) = try await merger.mergeWithReport(
                analysis, options: HDRMergeOptions(referenceIndex: 1, deghost: amount),
                sources: HDRTestSupport.sources(urls), to: folder.appendingPathComponent("merged-HDR.dng"),
                prepareSidecar: { _ in }, progress: { progress.append($0) })
            let merged = try HDRTestSupport.readBack(result.url)

            let atReference = Self.interiorMean(merged, column: Self.squareColumns[1])
            XCTAssertLessThan(HDRMergeTests.relativeError(atReference, square), 0.03,
                              "\(amount): the reference frame's square is \(atReference), want \(square)")
            for i in [0, 2] {
                let elsewhere = Self.interiorMean(merged, column: Self.squareColumns[i])
                XCTAssertLessThan(HDRMergeTests.relativeError(elsewhere, background), 0.03,
                                  "\(amount): frame \(i)'s square left \(elsewhere), want \(background)")
            }

            XCTAssertEqual(report.ghostMaskedFractions.count, 3)
            XCTAssertEqual(report.ghostMaskedFractions[1], 0, "the reference is never masked")
            for i in [0, 2] {
                XCTAssertGreaterThan(report.ghostFlaggedFractions[i], 0)
                XCTAssertLessThan(report.ghostMaskedFractions[i], 0.05, "\(amount): only around the squares")
            }
            XCTAssertEqual(result.recipe.options["deghost"], .string(amount.rawValue))
            let stages = progress.values.map(\.stage)
            XCTAssertTrue(stages.contains("Looking for movement in photo 3 of 3"))
            XCTAssertTrue(stages.contains("Comparing photo 3 of 3"))
            XCTAssertTrue(stages.contains("Masking movement in photo 1 of 3"))
            XCTAssertTrue(stages.contains("Merging photo 3 of 3"))
            XCTAssertEqual(progress.values.map(\.fraction), progress.values.map(\.fraction).sorted())
        }

        // The control: without deghosting the brighter frame's patch
        // outweighs the reference's square, which comes out far too dark.
        let (_, result, report, folder) = try await HDRTestSupport.merge(
            urls, merger: merger, options: HDRMergeOptions(referenceIndex: 1))
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(report.ghostMaskedFractions, [])
        let merged = try HDRTestSupport.readBack(result.url)
        let blended = Self.interiorMean(merged, column: Self.squareColumns[1])
        XCTAssertGreaterThan(HDRMergeTests.relativeError(blended, square), 0.15)
    }

    /// A still scene with noise, sharp edges, a ramp from crushed to clipped
    /// and an exposure 0.09 stops off its EXIF: at medium, under 0.1% of any
    /// frame may count as moving, or be masked.
    func testStaticNoisySceneIsHardlyFlagged() async throws {
        let (_, _, report, folder) = try await HDRTestSupport.merge(
            try HDRTestSupport.noisyBracket(), options: HDRMergeOptions(deghost: .medium))
        try? FileManager.default.removeItem(at: folder)
        print("Static noisy bracket at medium: flagged \(report.ghostFlaggedFractions), masked \(report.ghostMaskedFractions)")
        XCTAssertEqual(report.ghostFlaggedFractions.count, 3)
        for (flagged, masked) in zip(report.ghostFlaggedFractions, report.ghostMaskedFractions) {
            XCTAssertLessThan(flagged, 0.001, "flagged \(report.ghostFlaggedFractions)")
            XCTAssertLessThan(masked, 0.001, "masked \(report.ghostMaskedFractions)")
        }
    }

    /// A bright sky, clipped in the two longer exposures, with a dark leaf
    /// that crossed it during the longest one only. Weighted pixel by pixel,
    /// the leaf's unclipped pixels outweigh the short exposure's sky and
    /// punch a dark hole in it; faded out by its neighbourhood, the long
    /// exposure leaves the sky alone.
    func testClipFeatheringRemovesHolesWhereALeafMovedOverClippedSky() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (width, height) = (480, 320)
        let sky = SIMD3<Float>(repeating: 2), ground = SIMD3<Float>(repeating: 0.02)
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let value = y < 240 ? sky : ground
                let i = (y * width + x) * 3
                rgb[i] = value.x; rgb[i + 1] = value.y; rgb[i + 2] = value.z
            }
        }
        let scene = SyntheticBracket.Scene(width: width, height: height, rgb: rgb)
        let leaf = SyntheticBracket.Patch(x: 100, y: 100, width: 24, height: 24, radiance: SIMD3(repeating: 0.05))
        var frames = SyntheticBracket.frames(HDRTestSupport.threeExposures)
        frames[0].patches = [leaf]
        let urls = try SyntheticBracket.write(frames, of: scene, noise: false, to: folder, name: "leaf")
        let skyUnits = SyntheticBracket.mergeUnits(sky, brightest: 4)

        func darkestAroundTheLeaf(_ feather: HDRClipFeather) async throws -> Double {
            let merger = try HDRTestSupport.merger(clipFeather: feather)
            let (_, result, _, output) = try await HDRTestSupport.merge(urls, merger: merger)
            defer { try? FileManager.default.removeItem(at: output) }
            let merged = try HDRTestSupport.readBack(result.url)
            var darkest = Double.infinity
            for y in (leaf.y - 4)..<(leaf.y + leaf.height + 4) {
                for x in (leaf.x - 4)..<(leaf.x + leaf.width + 4) {
                    darkest = min(darkest, Double(merged.pixel(x, y).y) / skyUnits.y)
                }
            }
            return darkest
        }

        let feathered = try await darkestAroundTheLeaf(.standard)
        XCTAssertGreaterThan(feathered, 0.97, "the sky around the leaf drops to \(feathered) of its brightness")
        // The control: with nothing eroded or blurred, only the blocks at
        // the leaf's edge fade out, and its middle is a hole.
        let unfeathered = try await darkestAroundTheLeaf(HDRClipFeather(erodeRadius: 0, sigma: 0))
        XCTAssertLessThan(unfeathered, 0.5, "without feathering the hole should show")
    }

    /// Deghosting keeps a handful of quarter-size textures and one small
    /// mask per frame on the CPU, so five frames peak no higher on the GPU
    /// than three.
    func testGPUMemoryIsFlatWithDeghosting() async throws {
        let three = try HDRTestSupport.noisyBracket()
        let five = try HDRTestSupport.bracket("noisy5", SyntheticBracket.frames([16, 4, 1, 0.25, 0.0625]), noise: true)
        let merger = try HDRTestSupport.merger()
        let options = HDRMergeOptions(deghost: .medium)
        _ = try await HDRTestSupport.merge(three, merger: merger, options: options)
        let (_, _, threeReport, threeFolder) = try await HDRTestSupport.merge(three, merger: merger, options: options)
        let (_, _, fiveReport, fiveFolder) = try await HDRTestSupport.merge(five, merger: merger, options: options)
        try? FileManager.default.removeItem(at: threeFolder)
        try? FileManager.default.removeItem(at: fiveFolder)
        let slack = HDRMergeAccumulator.estimatedPeakBytes(width: 1200, height: 800) / 50
        XCTAssertGreaterThan(threeReport.peakGPUBytes, 0)
        XCTAssertLessThanOrEqual(fiveReport.peakGPUBytes, threeReport.peakGPUBytes + slack,
                                 "3 frames peaked at \(threeReport.peakGPUBytes) bytes, 5 at \(fiveReport.peakGPUBytes)")
    }

    /// Options saved before deghosting existed decode with it off.
    func testOptionsWithoutDeghostDecodeAsNone() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(HDRMergeOptions.self, from: Data(#"{"referenceIndex":2}"#.utf8))
        XCTAssertEqual(old, HDRMergeOptions(referenceIndex: 2, deghost: .none))
        XCTAssertEqual(try decoder.decode(HDRMergeOptions.self, from: Data("{}".utf8)), HDRMergeOptions())
        let options = HDRMergeOptions(referenceIndex: nil, deghost: .high)
        XCTAssertEqual(try decoder.decode(HDRMergeOptions.self, from: JSONEncoder().encode(options)), options)
        XCTAssertThrowsError(try decoder.decode(HDRMergeOptions.self, from: Data(#"{"deghost":"extreme"}"#.utf8)))
    }

    /// Every amount but none has settings, each stricter than the last.
    func testAmountsGrowStricter() throws {
        XCTAssertNil(DeghostAmount.none.settings)
        let settings = try [DeghostAmount.low, .medium, .high].map { try XCTUnwrap($0.settings) }
        for (looser, stricter) in zip(settings, settings.dropFirst()) {
            XCTAssertLessThan(stricter.gapStops, looser.gapStops)
            XCTAssertLessThan(stricter.patchCount, looser.patchCount)
        }
        XCTAssertEqual(HDRMerger.recipeOptions(HDRMergeOptions(deghost: .low)),
                       ["deghost": .string("low"), "clipFeather": .number(1)])
    }
}
