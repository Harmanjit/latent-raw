import XCTest
@testable import MergeKit

/// Grouping a selection into the positions of an HDR panorama: the clean
/// case, the awkward ones, and the selections that can't be grouped at all.
/// All metadata, no pixels, so these run everywhere.
final class HDRPanoGroupingTests: XCTestCase {
    /// A photo `stops` above the base exposure, taken `second` seconds in.
    private func photo(_ name: String, stops: Double, second: Double, merged: Bool = false) -> HDRPanoramaPhoto {
        // Light = shutter x ISO / f²; only the shutter varies here.
        HDRPanoramaPhoto(url: URL(fileURLWithPath: "/photos/\(name)"),
                         captureTime: Date(timeIntervalSince1970: 1_789_498_800 + second),
                         exposureSeconds: pow(2, stops) / 60, iso: 100, aperture: 8, alreadyMerged: merged)
    }

    /// `positions` brackets of `exposures` stops each, `within` seconds
    /// between the frames of a bracket and `between` between positions.
    private func sweep(positions: Int, exposures: [Double], within: Double = 1, between: Double = 4)
    -> [HDRPanoramaPhoto] {
        var photos: [HDRPanoramaPhoto] = []
        var time = 0.0
        for position in 0..<positions {
            for (index, stops) in exposures.enumerated() {
                photos.append(photo("P\(position)-\(index).NEF", stops: stops, second: time))
                time += within
            }
            time += between - within
        }
        return photos
    }

    private func frames(_ grouping: HDRPanoramaGrouping) -> [[Int]] {
        grouping.positions.map(\.frames)
    }

    // MARK: - The clean case

    func testThreeExposuresAtFivePositions() throws {
        let grouping = try HDRPanoramaGrouper.group(sweep(positions: 5, exposures: [-2, 0, 2]))
        XCTAssertEqual(frames(grouping), [[0, 1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11], [12, 13, 14]])
        XCTAssertEqual(grouping.evidence, .exposurePatternAndTiming)
        XCTAssertEqual(grouping.summaryText, "3 exposures at each of 5 positions")
        XCTAssertFalse(grouping.isUneven)
        // The middle exposure of each bracket is the position's reference.
        XCTAssertEqual(grouping.positions.map(\.reference), [1, 4, 7, 10, 13])
    }

    /// A camera that stamps whole seconds gives a burst gaps of 0; that is
    /// still a clear split against the seconds spent turning.
    func testWholeSecondTimestampsStillSplit() throws {
        // Every frame of a burst stamped the same second; positions 3 s apart.
        var photos: [HDRPanoramaPhoto] = []
        for position in 0..<4 {
            for (index, stops) in [-2.0, 0, 2].enumerated() {
                photos.append(photo("P\(position)-\(index).NEF", stops: stops, second: Double(position * 3)))
            }
        }
        XCTAssertNotNil(HDRPanoramaGrouper.cutByTimeGaps(Array(photos.indices), photos: photos))
        let grouping = try HDRPanoramaGrouper.group(photos)
        XCTAssertEqual(frames(grouping), [[0, 1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11]])
        XCTAssertEqual(grouping.evidence, .exposurePatternAndTiming)
    }

    /// Two exposures, six positions: the shortest repeating period wins,
    /// and it isn't confused by the pattern also repeating at 4 or 6.
    func testTwoExposuresAtSixPositions() throws {
        let grouping = try HDRPanoramaGrouper.group(sweep(positions: 6, exposures: [0, 2]))
        XCTAssertEqual(grouping.positions.count, 6)
        XCTAssertEqual(frames(grouping).first, [0, 1])
    }

    // MARK: - The awkward cases

    /// The photographer got one frame too few at the last position.
    func testUnevenBracketAtTheEnd() throws {
        var photos = sweep(positions: 3, exposures: [-2, 0, 2])
        photos.removeLast()
        let grouping = try HDRPanoramaGrouper.group(photos)
        XCTAssertEqual(frames(grouping), [[0, 1, 2], [3, 4, 5], [6, 7]])
        XCTAssertTrue(grouping.isUneven)
        XCTAssertEqual(grouping.summaryText, "3 positions of 3, 3 and 2 photos")
    }

    /// A position in the middle has five exposures where the others have
    /// three: the exposures no longer repeat, so the gaps decide.
    func testUnevenBracketInTheMiddle() throws {
        var photos = sweep(positions: 2, exposures: [-2, 0, 2])
        let time = photos.last!.captureTime.timeIntervalSince1970 - 1_789_498_800
        for (index, stops) in [-4.0, -2, 0, 2, 4].enumerated() {
            photos.append(photo("M-\(index).NEF", stops: stops, second: time + 4 + Double(index)))
        }
        let grouping = try HDRPanoramaGrouper.group(photos)
        XCTAssertEqual(frames(grouping), [[0, 1, 2], [3, 4, 5], [6, 7, 8, 9, 10]])
        XCTAssertEqual(grouping.evidence, .timeGaps)
        XCTAssertTrue(grouping.isUneven)
    }

    /// A stray photo between two brackets is a position of its own, and it
    /// is stitched as it is: there is nothing to merge it with.
    func testStraySinglePhoto() throws {
        var photos = sweep(positions: 2, exposures: [-2, 0, 2])
        photos.append(photo("stray.NEF", stops: 0, second: 30))
        let grouping = try HDRPanoramaGrouper.group(photos)
        XCTAssertEqual(frames(grouping), [[0, 1, 2], [3, 4, 5], [6]])
        XCTAssertFalse(grouping.positions[2].needsMerging)
        XCTAssertFalse(grouping.positions[2].alreadyMerged)
    }

    /// Photos merged earlier (linear DNGs) are positions of one, and they
    /// cut the run: a bracket can't reach across one.
    func testAlreadyMergedMixedWithRaws() throws {
        var photos = [photo("A-HDR.dng", stops: 0, second: 0, merged: true)]
        for (position, start) in [10.0, 16].enumerated() {
            for (index, stops) in [-2.0, 0, 2].enumerated() {
                photos.append(photo("P\(position)-\(index).NEF", stops: stops, second: start + Double(index)))
            }
        }
        photos.append(photo("B-HDR.dng", stops: 0, second: 60, merged: true))
        let grouping = try HDRPanoramaGrouper.group(photos)
        XCTAssertEqual(frames(grouping), [[0], [1, 2, 3], [4, 5, 6], [7]])
        XCTAssertTrue(grouping.positions[0].alreadyMerged)
        XCTAssertTrue(grouping.positions[3].alreadyMerged)
        XCTAssertFalse(grouping.positions[1].alreadyMerged)
    }

    /// Every photo is an HDR merge already: each is a position, and nothing
    /// needs merging.
    func testEveryPhotoAlreadyMerged() throws {
        let photos = (0..<4).map { photo("P\($0)-HDR.dng", stops: 0, second: Double($0) * 5, merged: true) }
        let grouping = try HDRPanoramaGrouper.group(photos)
        XCTAssertEqual(frames(grouping), [[0], [1], [2], [3]])
        XCTAssertEqual(grouping.evidence, .alreadyMerged)
        XCTAssertFalse(grouping.positions.contains { $0.needsMerging })
    }

    /// The exposures repeat but the photographer paused in the middle of a
    /// bracket, so the gaps say something else: the pattern wins, and the
    /// dialog is told the two disagreed.
    func testExposurePatternWinsOverMisleadingGaps() throws {
        // Three brackets of −2/0/+2, but the photographer paused inside the
        // first and the second, so the gaps split them in the wrong places.
        let times: [Double] = [0, 1, 10, 11, 12, 13, 22, 23, 24]
        let photos = times.enumerated().map {
            photo("F\($0.offset).NEF", stops: [-2.0, 0, 2][$0.offset % 3], second: $0.element)
        }
        XCTAssertEqual(HDRPanoramaGrouper.cutByTimeGaps(Array(photos.indices), photos: photos),
                       [[0, 1], [2, 3, 4, 5], [6, 7, 8]], "the gaps alone read it wrongly")
        let grouping = try HDRPanoramaGrouper.group(photos)
        XCTAssertEqual(frames(grouping), [[0, 1, 2], [3, 4, 5], [6, 7, 8]])
        XCTAssertEqual(grouping.evidence, .mixed)
    }

    /// Neither the exposures nor the timing can tell (every frame one
    /// second apart, the exposures not repeating cleanly), so consecutive
    /// photos are compared: a bracket's frames look alike, a move doesn't.
    func testFallsBackToOverlap() throws {
        // Exposures that don't repeat with any period, timing all equal.
        let stops: [Double] = [0, 2, -2, 0, 2, 2, -2, 0, 2]
        let photos = stops.enumerated().map { photo("F\($0.offset).NEF", stops: $0.element,
                                                    second: Double($0.offset)) }
        XCTAssertThrowsError(try HDRPanoramaGrouper.group(photos)) { error in
            XCTAssertEqual(error as? HDRPanoramaError, .cantTellPositions)
        }
        // The same photos, with the pixels asked: the view jumps after
        // every third frame.
        var asked: [Int] = []
        let grouping = try HDRPanoramaGrouper.group(photos) { pair in
            asked.append(pair)
            return pair % 3 == 2 ? 0.25 : 0.97
        }
        XCTAssertEqual(frames(grouping), [[0, 1, 2], [3, 4, 5], [6, 7, 8]])
        XCTAssertEqual(grouping.evidence, .overlap)
        XCTAssertEqual(asked, Array(0..<8), "each consecutive pair measured once")
    }

    // MARK: - Selections that can't be grouped

    func testTooFewPhotos() {
        XCTAssertThrowsError(try HDRPanoramaGrouper.group([photo("A.NEF", stops: 0, second: 0)])) { error in
            XCTAssertEqual(error as? HDRPanoramaError, .tooFewPhotos)
        }
    }

    /// One bracket and nothing else: an HDR merge, not a panorama.
    func testOneBracketIsNotAPanorama() {
        let photos = sweep(positions: 1, exposures: [-2, 0, 2])
        XCTAssertThrowsError(try HDRPanoramaGrouper.group(photos)) { error in
            XCTAssertEqual(error as? HDRPanoramaError, .tooFewPositions)
        }
    }

    /// A plain panorama: every photo the same exposure, evenly spaced.
    func testPlainPanoramaIsRefusedWithItsOwnMessage() {
        let photos = (0..<6).map { photo("P\($0).NEF", stops: 0, second: Double($0) * 3) }
        XCTAssertThrowsError(try HDRPanoramaGrouper.group(photos)) { error in
            XCTAssertEqual(error as? HDRPanoramaError, .sameExposure)
            XCTAssertTrue(HDRPanoramaError.sameExposure.errorDescription?
                .contains("Photo Merge › Panorama") == true)
        }
    }

    /// The message the plan asks for, when the evidence runs out.
    func testCantTellMessage() {
        let message = HDRPanoramaError.cantTellPositions.errorDescription ?? ""
        XCTAssertTrue(message.hasPrefix("These don’t look like brackets: each position needs the same exposures."),
                      message)
    }

    // MARK: - The pieces

    func testSplitThresholdNeedsAClearJump() {
        // Evenly spaced: no split.
        XCTAssertNil(HDRPanoramaGrouper.splitThreshold([1, 1, 1, 1], ratio: 2.5, floorValue: 1))
        // A clear one.
        XCTAssertEqual(HDRPanoramaGrouper.splitThreshold([1, 1, 5, 1], ratio: 2.5, floorValue: 1), 5)
        // Zeroes below (whole-second timestamps), a long gap above.
        XCTAssertEqual(HDRPanoramaGrouper.splitThreshold([0, 0, 3, 0], ratio: 2.5, floorValue: 1), 3)
        // Zeroes below, and above it too short to be a move.
        XCTAssertNil(HDRPanoramaGrouper.splitThreshold([0, 0, 0.5, 0], ratio: 2.5, floorValue: 1))
        // Three sizes of gap: the shortest clear one is the move, so the
        // long pause doesn't swallow the positions inside it.
        XCTAssertEqual(HDRPanoramaGrouper.splitThreshold([1, 1, 4, 1, 1, 22], ratio: 2.5, floorValue: 1), 4)
    }

    /// How the engine measures overlap when the metadata can't tell: the
    /// correlation of two thumbnails' log luminance, which two stops of
    /// exposure between them doesn't touch.
    func testOverlapCorrelationIgnoresExposureAndFallsWithTheView() {
        let width = 32, height = 24
        func thumbnail(shift: Int, exposure: Float) -> PanoramaThumbnail {
            var rgba = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    // A scene with detail everywhere and no repeats.
                    let u = Double(x + shift), v = Double(y)
                    let value = Float(0.2 + 0.15 * sin(u * 0.7) + 0.1 * cos(v * 0.5 + u * 0.13)) * exposure
                    for c in 0..<3 { rgba[(y * width + x) * 4 + c] = value }
                    rgba[(y * width + x) * 4 + 3] = 1
                }
            }
            return PanoramaThumbnail(width: width, height: height, span: 8, rgba: rgba,
                                     clippedShare: [Float](repeating: 0, count: width * height))
        }
        let base = thumbnail(shift: 0, exposure: 1)
        // The next frame of the same bracket: the same view, two stops darker.
        let sameView = thumbnail(shift: 0, exposure: 0.25)
        // The next position: most of the frame is somewhere else.
        let moved = thumbnail(shift: 20, exposure: 1)
        let alike = OverlapMeasure.correlation(base, sameView)
        let apart = OverlapMeasure.correlation(base, moved)
        XCTAssertGreaterThan(alike, 0.99, "a bracket's frames are the same view whatever their exposure")
        XCTAssertLessThan(apart, 0.7, "a new position shows something else")
        XCTAssertGreaterThan(1 - apart, 2.5 * (1 - alike), "the split rule can tell them apart")
    }

    func testLightStopsFollowShutterISOAndAperture() {
        let base = photo("A.NEF", stops: 0, second: 0)
        let brighter = HDRPanoramaPhoto(url: base.url, captureTime: base.captureTime,
                                        exposureSeconds: base.exposureSeconds, iso: 400, aperture: 8)
        XCTAssertEqual((brighter.lightStops ?? 0) - (base.lightStops ?? 0), 2, accuracy: 1e-9)
        let wider = HDRPanoramaPhoto(url: base.url, captureTime: base.captureTime,
                                     exposureSeconds: base.exposureSeconds, iso: 100, aperture: 4)
        XCTAssertEqual((wider.lightStops ?? 0) - (base.lightStops ?? 0), 2, accuracy: 1e-9)
        XCTAssertNil(HDRPanoramaPhoto(url: base.url, captureTime: base.captureTime, exposureSeconds: 0,
                                      iso: 100, aperture: 8).lightStops)
    }
}
