import XCTest
@testable import Catalog

/// Edit Capture Time and Geotag from GPX Track: the GPX reader, matching
/// photos to a track, the capture-time arithmetic, the sidecar's new
/// properties, and the Library's changes with undo and after a rebuild.
@MainActor
final class GeoTimeTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-geotime-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A small GPX 1.1 track: three points a minute apart (one given out of
    /// order, one with fractional seconds), a route point with an offset
    /// time, and a waypoint with no time.
    static let gpx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
      <wpt lat="10.0" lon="10.0"><name>No time</name></wpt>
      <trk><name>Walk</name><trkseg>
        <trkpt lat="51.0" lon="-1.0"><ele>100</ele><time>2026-05-01T10:00:00Z</time></trkpt>
        <trkpt lat="51.2" lon="-1.2"><ele>140</ele><time>2026-05-01T10:02:00Z</time></trkpt>
        <trkpt lat="51.1" lon="-1.1"><ele>120</ele><time>2026-05-01T10:01:00.000Z</time></trkpt>
      </trkseg></trk>
      <rte><rtept lat="52.0" lon="-2.0"><time>2026-05-01T12:00:00+01:00</time></rtept></rte>
    </gpx>
    """

    static func date(_ iso: String) -> Date { GPXTrack.parseTime(iso)! }

    // MARK: - GPX

    func testParsesTimedPointsInOrderAndCountsUntimedOnes() throws {
        let track = try GPXTrack.parse(Data(Self.gpx.utf8))
        XCTAssertEqual(track.points.count, 4)
        XCTAssertEqual(track.untimedPoints, 1, "the waypoint without a time")
        XCTAssertEqual(track.points.map(\.latitude), [51.0, 51.1, 51.2, 52.0], "sorted by time")
        XCTAssertEqual(track.points[0].elevation, 100)
        XCTAssertNil(track.points[3].elevation)
        XCTAssertEqual(track.points[3].time, Self.date("2026-05-01T11:00:00Z"), "an offset time is read as UTC")
        XCTAssertEqual(track.timeRange?.lowerBound, Self.date("2026-05-01T10:00:00Z"))
    }

    func testPrefixedGPXAndZonelessTimes() throws {
        let xml = """
        <g:gpx xmlns:g="http://www.topografix.com/GPX/1/0" version="1.0">
          <g:trk><g:trkseg><g:trkpt lat="1" lon="2"><g:time>2026-01-01T00:00:00</g:time></g:trkpt></g:trkseg></g:trk>
        </g:gpx>
        """
        let track = try GPXTrack.parse(Data(xml.utf8))
        XCTAssertEqual(track.points.first?.time, Self.date("2026-01-01T00:00:00Z"), "no zone means UTC")
    }

    func testRefusesWhatIsNotAUsableTrack() {
        XCTAssertThrowsError(try GPXTrack.parse(Data("<kml></kml>".utf8))) { error in
            guard case GPXTrack.ReadError.notGPX = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try GPXTrack.parse(Data("not xml at all <".utf8)))
        let untimed = #"<gpx><wpt lat="1" lon="2"/><trk><trkseg><trkpt lat="91" lon="0"><time>2026-01-01T00:00:00Z</time></trkpt></trkseg></trk></gpx>"#
        XCTAssertThrowsError(try GPXTrack.parse(Data(untimed.utf8))) { error in
            XCTAssertEqual(error as? GPXTrack.ReadError, .noTimedPoints, "no time, or a latitude out of range")
        }
    }

    func testPositionInterpolatesWithinTheGapAndStopsBeyondIt() throws {
        let track = try GPXTrack.parse(Data(Self.gpx.utf8))
        let gap: TimeInterval = 5 * 60
        // Exactly on a point.
        XCTAssertEqual(track.position(at: Self.date("2026-05-01T10:01:00Z"), maxGap: gap),
                       GeoPosition(latitude: 51.1, longitude: -1.1, altitude: 120))
        // Half way between the first two.
        let mid = try XCTUnwrap(track.position(at: Self.date("2026-05-01T10:00:30Z"), maxGap: gap))
        XCTAssertEqual(mid.latitude, 51.05, accuracy: 1e-9)
        XCTAssertEqual(mid.longitude, -1.05, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(mid.altitude), 110, accuracy: 1e-9)
        // Before the start and after the end, within and beyond the gap.
        XCTAssertEqual(track.position(at: Self.date("2026-05-01T09:57:00Z"), maxGap: gap)?.latitude, 51.0)
        XCTAssertNil(track.position(at: Self.date("2026-05-01T09:50:00Z"), maxGap: gap))
        XCTAssertEqual(track.position(at: Self.date("2026-05-01T11:04:00Z"), maxGap: gap)?.latitude, 52.0)
        XCTAssertNil(track.position(at: Self.date("2026-05-01T11:06:00Z"), maxGap: gap))
        // In the 58-minute gap between 10:02 and 11:00: near either end
        // takes that point, the middle takes none.
        XCTAssertEqual(track.position(at: Self.date("2026-05-01T10:04:00Z"), maxGap: gap)?.latitude, 51.2)
        XCTAssertEqual(track.position(at: Self.date("2026-05-01T10:57:00Z"), maxGap: gap)?.latitude, 52.0)
        XCTAssertNil(track.position(at: Self.date("2026-05-01T10:30:00Z"), maxGap: gap))
        // A tolerance longer than the gap interpolates across it.
        let bridged = try XCTUnwrap(track.position(at: Self.date("2026-05-01T10:31:00Z"), maxGap: 3600))
        XCTAssertEqual(bridged.latitude, 51.6, accuracy: 1e-9)
        XCTAssertNil(bridged.altitude, "no elevation unless both points have one")
    }

    func testInterpolationCrossesTheAntimeridianTheShortWay() {
        let a = GPXPoint(time: Date(timeIntervalSince1970: 0), latitude: 0, longitude: 179)
        let b = GPXPoint(time: Date(timeIntervalSince1970: 100), latitude: 0, longitude: -179)
        let track = GPXTrack(points: [a, b])
        let p = track.position(at: Date(timeIntervalSince1970: 75), maxGap: 1000)!
        XCTAssertEqual(p.longitude, -179.5, accuracy: 1e-9)
    }

    func testPlanMatchesByCorrectedTimeAndKeepsExistingPositions() throws {
        let track = try GPXTrack.parse(Data(Self.gpx.utf8))
        func record(_ id: Int64, _ iso: String?, gps: Bool = false) -> ImageRecord {
            var r = ImageRecord(relPath: "\(id).NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
            r.id = id
            r.captureTime = iso.map { Int64(Self.date($0).timeIntervalSince1970) }
            if gps { r.gpsLatitude = 1; r.gpsLongitude = 2 }
            return r
        }
        let records = [record(1, "2026-05-01T10:00:30Z"), record(2, "2026-05-01T10:01:00Z", gps: true),
                       record(3, "2026-05-01T08:00:00Z"), record(4, nil)]
        var plan = GeotagPlan.make(records: records, track: track, clockOffset: 0, maxGap: 300, replaceExisting: false)
        XCTAssertEqual(plan.matchedCount, 1)
        XCTAssertEqual(plan.keptCount, 1)
        XCTAssertEqual(plan.unmatchedCount, 1)
        XCTAssertEqual(plan.noCaptureTimeCount, 1)
        XCTAssertEqual(try XCTUnwrap(plan.positionsToWrite[1]).latitude, 51.05, accuracy: 1e-9)

        plan = GeotagPlan.make(records: records, track: track, clockOffset: 0, maxGap: 300, replaceExisting: true)
        XCTAssertEqual(Set(plan.positionsToWrite.keys), [1, 2], "Replace existing overwrites")

        // A camera two hours slow: the offset brings photo 3 onto the track.
        plan = GeotagPlan.make(records: records, track: track, clockOffset: 2 * 3600, maxGap: 300, replaceExisting: false)
        XCTAssertEqual(plan.positionsToWrite[3]?.latitude, 51.0)
    }

    // MARK: - Capture time

    func testCaptureTimeEditDeltas() {
        let times: [Int64] = [1_000, 400, 700]
        XCTAssertEqual(CaptureTimeEdit(mode: .shift(seconds: 90)).delta(forCaptureTimes: times), 90)
        XCTAssertEqual(CaptureTimeEdit(mode: .shift(seconds: -60), timeZoneShift: 3600).delta(forCaptureTimes: times), 3540)
        XCTAssertEqual(CaptureTimeEdit(mode: .setFirst(to: 500), timeZoneShift: 3600).delta(forCaptureTimes: times), 100,
                       "the earliest photo lands on the time given; a zone shift doesn't apply")
        XCTAssertNil(CaptureTimeEdit(mode: .shift(seconds: 5)).delta(forCaptureTimes: []))
        XCTAssertEqual(CaptureTimeEdit.seconds(days: 1, hours: 2, minutes: 3, seconds: 4), 93_784)
        // London (BST, UTC+1) to New York (EDT, UTC−4) in July: five hours earlier.
        let july = Self.date("2026-07-01T12:00:00Z")
        XCTAssertEqual(CaptureTimeEdit.timeZoneShift(from: TimeZone(identifier: "Europe/London")!,
                                                     to: TimeZone(identifier: "America/New_York")!, at: july), -5 * 3600)
    }

    func testShiftsAddUpAndCancelOut() {
        var record = ImageRecord(relPath: "A.NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
        record.captureTime = 1_000
        var state = GeoTimeState(record)
        state.shiftCaptureTime(by: 60)
        state.shiftCaptureTime(by: 30)
        XCTAssertEqual(state.captureTime, 1_090)
        XCTAssertEqual(state.captureTimeOffset, 90)
        state.shiftCaptureTime(by: -90)
        XCTAssertEqual(state.captureTime, 1_000)
        XCTAssertNil(state.captureTimeOffset, "back where it started is no correction")
        record.captureTime = nil
        var undated = GeoTimeState(record)
        undated.shiftCaptureTime(by: 60)
        XCTAssertNil(undated.captureTime)
        XCTAssertNil(undated.captureTimeOffset)
    }

    func testRowsCarryAndReadTheCorrectionAndGeotag() {
        var previous = ImageRecord(relPath: "A.NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
        previous.captureTime = 1_060
        previous.captureTimeOffset = 60
        previous.gpsLatitude = 5; previous.gpsLongitude = 6; previous.gpsTagged = true
        // The file changed on disk: read afresh, corrected again.
        var fresh = previous
        fresh.captureTime = 1_000; fresh.captureTimeOffset = nil
        fresh.gpsLatitude = nil; fresh.gpsLongitude = nil; fresh.gpsTagged = nil
        fresh.carryGeoTime(from: previous)
        XCTAssertEqual(fresh.captureTime, 1_060)
        XCTAssertEqual(fresh.fileCaptureTime, 1_000)
        XCTAssertEqual(fresh.gpsLatitude, 5)
        XCTAssertTrue(fresh.hasGPS)

        // A sidecar with another correction and no geotag.
        var fields = XMPSidecar.Fields(sourceHash: "")
        fields.captureTimeOffset = -20
        fresh.exifExtrasVersion = ExifExtras.version
        fresh.applyGeoTime(from: fields)
        XCTAssertEqual(fresh.captureTime, 980)
        XCTAssertEqual(fresh.captureTimeOffset, -20)
        XCTAssertNil(fresh.gpsLatitude)
        XCTAssertNil(fresh.gpsTagged)
        XCTAssertNil(fresh.exifExtrasVersion, "the file's own GPS is read again")
        fresh.applyGeoTime(from: nil)
        XCTAssertEqual(fresh.captureTime, 1_000)
        XCTAssertNil(fresh.captureTimeOffset)
    }

    // MARK: - Sidecar

    func testXMPCoordinates() {
        XCTAssertEqual(GeoPosition.xmpCoordinate(51.5, positive: "N", negative: "S"), "51,30.000000N")
        XCTAssertEqual(GeoPosition.xmpCoordinate(-0.1275, positive: "E", negative: "W"), "0,7.650000W")
        XCTAssertEqual(GeoPosition.xmpCoordinate(10.99999999999, positive: "N", negative: "S"), "11,0.000000N")
        XCTAssertEqual(GeoPosition.parseXMPCoordinate("51,30.0N"), 51.5)
        XCTAssertEqual(GeoPosition.parseXMPCoordinate("0,7.65W")!, -0.1275, accuracy: 1e-12)
        XCTAssertEqual(GeoPosition.parseXMPCoordinate("33,52,12S")!, -(33 + 52.0 / 60 + 12.0 / 3600), accuracy: 1e-12)
        XCTAssertEqual(GeoPosition.parseXMPCoordinate("-12.5"), -12.5)
        XCTAssertNil(GeoPosition.parseXMPCoordinate("north"))
        XCTAssertEqual(GeoPosition.parseRational("12345/100"), 123.45)
    }

    func testCorrectionAndGeotagRoundTripThroughTheSidecar() throws {
        var fields = XMPSidecar.Fields(rating: 3, sourceHash: "xxh64:0011223344556677")
        fields.captureTimeOffset = 3_600
        fields.correctedCaptureTime = 1_777_629_600
        fields.geotag = GeoPosition(latitude: -33.8688, longitude: 151.2093, altitude: -12.5)
        let url = folder.appendingPathComponent("geo.xmp")
        try XMPSidecar.write(fields, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("xmlns:exif=\"http://ns.adobe.com/exif/1.0/\""), text)
        XCTAssertTrue(text.contains("<latent:CaptureTimeOffset>3600</latent:CaptureTimeOffset>"), text)
        XCTAssertTrue(text.contains("<exif:DateTimeOriginal>"), text)
        XCTAssertTrue(text.contains("<exif:GPSLatitude>33,52.128000S</exif:GPSLatitude>"), text)
        XCTAssertTrue(text.contains("<exif:GPSAltitudeRef>1</exif:GPSAltitudeRef>"), text)
        let read = try XMPSidecar.read(from: url)
        XCTAssertEqual(read.captureTimeOffset, 3_600)
        let tag = try XCTUnwrap(read.geotag)
        XCTAssertEqual(tag.latitude, -33.8688, accuracy: 1e-8)
        XCTAssertEqual(tag.longitude, 151.2093, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(tag.altitude), -12.5, accuracy: 1e-9)
        XCTAssertEqual(read.rating, 3)
    }

    /// Without a correction or geotag nothing new is written.
    func testNoCorrectionLeavesTheSidecarAsItWas() throws {
        let fields = XMPSidecar.Fields(rating: 1, keywords: ["a"], sourceHash: "xxh64:0011223344556677")
        XCTAssertEqual(XMPSidecar.geoTimeElements(fields), "")
        XCTAssertEqual(XMPSidecar.geoTimeNamespace(fields), "")
        let url = folder.appendingPathComponent("plain.xmp")
        try XMPSidecar.write(fields, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("exif"), text)
        XCTAssertEqual(try XMPSidecar.read(from: url), fields)
    }

    // MARK: - Library

    private func openLibrary(_ manager: UndoManager) async throws -> Library {
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        XCTAssertEqual(library.images.count, 2)
        return library
    }

    private func record(_ library: Library, _ name: String) -> ImageRecord {
        library.images.first { $0.fileName == name }!
    }

    private func undo(_ manager: UndoManager, _ library: Library, redo: Bool = false) async {
        if redo { manager.redo() } else { manager.undo() }
        await library.waitForPendingWork()
    }

    func testEditCaptureTimeAndGeotagWithUndoAndAfterARebuild() async throws {
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        let manager = UndoManager()
        var library: Library! = try await openLibrary(manager)
        let original = try XCTUnwrap(record(library, "A.NEF").captureTime)
        let records = library.images

        // Shift both an hour and a half later.
        let changed = try await library.editCaptureTime(CaptureTimeEdit(mode: .shift(seconds: 5_400)), for: records)
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(record(library, "A.NEF").captureTime, original + 5_400)
        XCTAssertEqual(record(library, "B.NEF").captureTimeOffset, 5_400)
        XCTAssertEqual(manager.undoActionName, "Edit Capture Time (2 Images)")
        let sidecarURL = await library.catalog!.sidecarURL(forRelPath: "A.NEF")
        XCTAssertEqual(try XMPSidecar.read(from: sidecarURL).captureTimeOffset, 5_400)

        await undo(manager, library)
        XCTAssertEqual(record(library, "A.NEF").captureTime, original)
        XCTAssertNil(record(library, "A.NEF").captureTimeOffset)
        XCTAssertNil(try XMPSidecar.read(from: sidecarURL).captureTimeOffset)
        await undo(manager, library, redo: true)
        XCTAssertEqual(record(library, "A.NEF").captureTime, original + 5_400)

        // Geotag A only.
        let a = try XCTUnwrap(record(library, "A.NEF").id)
        let hadGPS = record(library, "B.NEF").hasGPS
        let place = GeoPosition(latitude: 48.8584, longitude: 2.2945, altitude: 35)
        try await library.applyGeotags([a: place], for: library.images)
        XCTAssertEqual(record(library, "A.NEF").gpsPosition, place)
        XCTAssertEqual(record(library, "A.NEF").gpsTagged, true)
        XCTAssertEqual(record(library, "B.NEF").hasGPS, hadGPS, "B wasn't in the plan")
        XCTAssertEqual(manager.undoActionName, "Geotag from GPX Track")

        // A rebuilt database takes both back from the sidecar.
        library = nil
        let container = folder.appendingPathComponent(Catalog.containerName)
        for name in try FileManager.default.contentsOfDirectory(atPath: container.path) where name.hasPrefix("catalog.sqlite") {
            try FileManager.default.removeItem(at: container.appendingPathComponent(name))
        }
        let reopened = try await openLibrary(UndoManager())
        let rebuilt = record(reopened, "A.NEF")
        XCTAssertEqual(rebuilt.captureTime, original + 5_400)
        XCTAssertEqual(rebuilt.captureTimeOffset, 5_400)
        let tag = try XCTUnwrap(rebuilt.gpsPosition)
        XCTAssertEqual(tag.latitude, place.latitude, accuracy: 1e-8)
        XCTAssertEqual(tag.longitude, place.longitude, accuracy: 1e-8)
        XCTAssertEqual(rebuilt.gpsTagged, true)

        // The file's EXIF read again (a newer ExifExtras) keeps the geotag.
        let catalog = try XCTUnwrap(reopened.catalog)
        try await catalog.forceExifExtrasBackfillForTesting()
        let after = try await catalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(try XCTUnwrap(after?.gpsLatitude), place.latitude, accuracy: 1e-8)
    }
}

extension Catalog {
    /// Marks every row's EXIF extras stale and reads them again.
    func forceExifExtrasBackfillForTesting() throws {
        try dbQueue.write { db in try db.execute(sql: "UPDATE images SET exif_extras_version = NULL") }
        try backfillExifExtras()
    }
}
