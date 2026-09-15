import XCTest
@testable import MergeKit

/// `HDRMerger.analyse` on synthetic brackets whose true exposures are
/// known: the measured exposures, the warnings, the reference frame.
final class HDRAnalysisTests: XCTestCase {
    /// Three frames 2 stops apart, with noise, and the middle frame's EXIF
    /// off by 0.09 stops: the pixels must give the truth within 0.02 stops.
    func testMeasuredExposuresMatchTheTruth() async throws {
        let urls = try HDRTestSupport.noisyBracket()
        // Given darkest first: the analysis sorts brightest first.
        let analysis = try await HDRTestSupport.merger().analyse(urls.reversed())
        XCTAssertEqual(analysis.frames.map(\.url), urls)
        let truth = [0.0, -2, -4]
        for (frame, want) in zip(analysis.frames, truth) {
            XCTAssertEqual(frame.relativeEV, want, accuracy: 0.02, "\(frame.url.lastPathComponent)")
        }
        XCTAssertEqual(analysis.frames[1].exifRelativeEV, log2((1.0 / 64) / (4.0 / 60)), accuracy: 1e-5)
        XCTAssertEqual(analysis.frames[2].exifRelativeEV, -4, accuracy: 1e-5)
        XCTAssertEqual(analysis.exposureRangeStops, 4, accuracy: 0.02)
        // 0.09 stops of EXIF error is under the warning's 0.25, and a tripod
        // bracket must not look misaligned.
        XCTAssertEqual(analysis.warnings, [])
        XCTAssertEqual([analysis.width, analysis.height], [1200, 800])
        // This scene's clipped patches and edge cost the brighter frames
        // more than its shadows cost the darkest one.
        XCTAssertEqual(analysis.referenceIndex, 2, "the frame that loses least to clipping and noise")
        let clipped = analysis.frames.map(\.clippedFraction)
        XCTAssertGreaterThan(clipped[0], clipped[1])
        XCTAssertGreaterThan(clipped[1], clipped[2])
        XCTAssertGreaterThan(clipped[2], 0.005, "the disc is clipped even in the darkest frame")
        // 1200 x 800 in 512 px tiles: 3 x 2 full tiles of half floats, plus the previews.
        XCTAssertEqual(analysis.estimatedOutputBytes, Int64(6 * 512 * 512 * 6) + 2_000_000)
    }

    func testFiveFrameBracket() async throws {
        let urls = try HDRTestSupport.bracket("noisy5", SyntheticBracket.frames([16, 4, 1, 0.25, 0.0625]), noise: true)
        let analysis = try await HDRTestSupport.merger().analyse(urls)
        for (frame, want) in zip(analysis.frames, [0.0, -2, -4, -6, -8]) {
            XCTAssertEqual(frame.relativeEV, want, accuracy: 0.02, "\(frame.url.lastPathComponent)")
        }
        XCTAssertEqual(analysis.warnings, [])
    }

    /// EXIF half a stop out: the measurement is used, and the dialog is told.
    func testExifHalfAStopOutWarns() async throws {
        var frames = SyntheticBracket.frames(HDRTestSupport.threeExposures)
        frames[1] = SyntheticBracket.Frame(exposure: 1, exifShutter: pow(2, 0.5) / 60)
        let urls = try HDRTestSupport.bracket("exifHalfStop", frames, noise: true)
        let analysis = try await HDRTestSupport.merger().analyse(urls)
        XCTAssertEqual(analysis.frames[1].relativeEV, -2, accuracy: 0.02)
        XCTAssertEqual(analysis.frames[2].relativeEV, -4, accuracy: 0.02)
        guard case .exposureMetadataDisagrees(let index, let exif, let measured)? = analysis.warnings.first,
              analysis.warnings.count == 1 else {
            return XCTFail("expected one exposure warning, got \(analysis.warnings)")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(exif, -1.5, accuracy: 1e-4)
        XCTAssertEqual(measured, -2, accuracy: 0.02)
    }

    /// A measurement more than a stop from the EXIF isn't trusted: EXIF wins.
    func testMeasurementFarFromExifFallsBackToExif() async throws {
        var frames = SyntheticBracket.frames(HDRTestSupport.threeExposures)
        frames[1] = SyntheticBracket.Frame(exposure: 1, exifShutter: pow(2, 1.5) / 60)
        let urls = try HDRTestSupport.bracket("exifStopAndAHalf", frames, noise: true)
        let analysis = try await HDRTestSupport.merger().analyse(urls)
        for frame in analysis.frames {
            XCTAssertEqual(frame.relativeEV, frame.exifRelativeEV, accuracy: 1e-9)
        }
        XCTAssertEqual(analysis.frames[1].relativeEV, -0.5, accuracy: 1e-4)
        XCTAssertEqual(analysis.warnings, [])
    }

    /// The middle frame moved 5 px: the check must say so, and by about that much.
    func testShiftedFrameWarnsMisaligned() async throws {
        var frames = SyntheticBracket.frames(HDRTestSupport.threeExposures)
        frames[1].shiftX = 5
        let urls = try HDRTestSupport.bracket("shifted5", frames, noise: true)
        let analysis = try await HDRTestSupport.merger().analyse(urls)
        let shifts = analysis.warnings.compactMap { warning -> Double? in
            if case .framesLookMisaligned(let pixels) = warning { return pixels }
            return nil
        }
        XCTAssertEqual(shifts.count, 1, "\(analysis.warnings)")
        XCTAssertEqual(shifts.first ?? 0, 5, accuracy: 1)
    }

    func testSmallExposureRangeWarns() async throws {
        let urls = try HDRTestSupport.bracket("small", SyntheticBracket.frames([1, 0.6]), noise: true)
        let analysis = try await HDRTestSupport.merger().analyse(urls)
        XCTAssertEqual(analysis.frames[1].relativeEV, log2(0.6), accuracy: 0.02)
        guard case .smallExposureRange(let stops)? = analysis.warnings.first else {
            return XCTFail("expected a small-range warning, got \(analysis.warnings)")
        }
        XCTAssertEqual(stops, -log2(0.6), accuracy: 0.02)
    }

    // MARK: - The arithmetic alone

    func testExifExposure() {
        XCTAssertEqual(HDRExposure.exifExposure(shutter: 1.0 / 60, iso: 100, aperture: 8)!, 100.0 / 60 / 64, accuracy: 1e-12)
        XCTAssertEqual(HDRExposure.exifExposure(shutter: 1, iso: 0, aperture: 0), 100, "unknown ISO and aperture cancel")
        XCTAssertNil(HDRExposure.exifExposure(shutter: 0, iso: 100, aperture: 8))
    }

    func testPairStopsFallsBackWithTooFewSamples() {
        XCTAssertEqual(HDRExposure.pairStops(measured: 2.1, samples: 4999, exif: 2).stops, 2)
        XCTAssertEqual(HDRExposure.pairStops(measured: 2.1, samples: 5000, exif: 2).stops, 2.1)
        XCTAssertEqual(HDRExposure.pairStops(measured: 3.1, samples: 90000, exif: 2).stops, 2)
        XCTAssertEqual(HDRExposure.pairStops(measured: nil, samples: 0, exif: 2).stops, 2)
    }

    func testReferenceIsTheLeastLostFrameTiesToTheMiddle() {
        XCTAssertEqual(HDRExposure.referenceIndex(clipped: [0.3, 0.1, 0.01], crushed: [0.0, 0.05, 0.4]), 1)
        XCTAssertEqual(HDRExposure.referenceIndex(clipped: [0.1, 0.1, 0.1], crushed: [0, 0, 0]), 1)
        XCTAssertEqual(HDRExposure.referenceIndex(clipped: [0.5, 0.2], crushed: [0, 0]), 1)
    }

    /// Phase correlation on a detailed image moved by a known amount.
    func testPhaseCorrelationFindsAKnownShift() throws {
        let (w, h) = (300, 200)
        var random = SplitMix64(seed: 42)
        let texture = (0..<((w + 20) * (h + 20))).map { _ in random.uniform() }
        // The same texture seen through a window moved `dx` right and `dy` down.
        func image(dx: Int, dy: Int) -> [Double] {
            (0..<(w * h)).map { i in texture[(i / w + 10 - dy) * (w + 20) + i % w + 10 - dx] }
        }
        let same = try XCTUnwrap(HDRAlignmentCheck.shift(image(dx: 0, dy: 0), image(dx: 0, dy: 0), width: w, height: h))
        XCTAssertEqual(same.length, 0, accuracy: 1e-6)
        XCTAssertEqual(same.peak, 1, accuracy: 0.01)
        let moved = try XCTUnwrap(HDRAlignmentCheck.shift(image(dx: 0, dy: 0), image(dx: 3, dy: -2), width: w, height: h))
        XCTAssertEqual(moved.dx, 3, accuracy: 0.1)
        XCTAssertEqual(moved.dy, -2, accuracy: 0.1)
        XCTAssertGreaterThan(moved.peak, 0.5)
        var other = SplitMix64(seed: 7)
        let unrelated = (0..<(w * h)).map { _ in other.uniform() }
        let none = try XCTUnwrap(HDRAlignmentCheck.shift(image(dx: 0, dy: 0), unrelated, width: w, height: h))
        XCTAssertLessThan(none.peak, HDRAlignmentCheck.minimumPeak, "unrelated images have no clear peak")
    }
}
