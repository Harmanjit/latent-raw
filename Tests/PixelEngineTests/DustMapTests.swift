import XCTest
import simd
@testable import PixelEngine

/// Dust maps end to end (docs/Retouch.md §6): a map survives JSON and the
/// store field for field, and the spots one photo's detection saves are
/// what `verify` finds again in another photo of the same sensor.
final class DustMapTests: XCTestCase {
    func testMapRoundTripsThroughJSON() throws {
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let map = DustMap(camera: "Nikon D750", sensorSize: SIMD2(6032, 4032), created: created, referenceName: "DSC_0107.NEF",
                          referenceCaptureDate: created.addingTimeInterval(-86_400 * 3), aperture: 16,
                          options: DustDetector.Options(sensitivity: 65, size: .large),
                          spots: [DustMapSpot(centre: [0.412, 0.087], radius: 0.0021, contrast: 0.31),
                                  DustMapSpot(centre: [0.9, 0.95], radius: 0.004, contrast: 0.08)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(map)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(DustMap.self, from: data)
        XCTAssertEqual(back.id, map.id)
        XCTAssertEqual(back.camera, map.camera)
        XCTAssertEqual(back.sensorSize, map.sensorSize)
        XCTAssertEqual(back.created.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(back.referenceName, map.referenceName)
        XCTAssertEqual(back.referenceCaptureDate?.timeIntervalSince1970 ?? 0, created.timeIntervalSince1970 - 86_400 * 3, accuracy: 1)
        XCTAssertEqual(back.aperture, 16)
        XCTAssertEqual(back.options, map.options)
        XCTAssertEqual(back.spots, map.spots)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"camera\":\"Nikon D750\""))
        XCTAssertTrue(text.contains("\"size\":\"large\""))
        XCTAssertTrue(text.contains("\"sensitivity\":65"))
        // Optional fields absent, and a map with no spots, still read.
        let bare = #"{"id":"7A1C0000-0000-0000-0000-000000000001","camera":"Canon EOS R5","sensorSize":[8192,5464],"created":"2026-09-12T10:00:00Z","referenceName":"IMG_0001.CR3","options":{"sensitivity":50,"size":"medium"},"spots":[]}"#
        let empty = try decoder.decode(DustMap.self, from: Data(bare.utf8))
        XCTAssertNil(empty.referenceCaptureDate)
        XCTAssertNil(empty.aperture)
        XCTAssertEqual(empty.spots, [])
        XCTAssertEqual(empty.title, "Canon EOS R5 · 12 Sep 2026 · 0 spots")
    }

    /// What the file says goes straight to the detector, whose window
    /// around a spot grows with the radius: a map with an absurd radius
    /// would take gigabytes or overflow an Int, and one with millions of
    /// spots would verify each of them per photo. Loading clamps every
    /// spot and count, and drops a map without a sensor size, so the
    /// detector runs on what is left in bounded time.
    func testLoadSanitisesWhatTheFileSays() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-dust-map-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("dust-maps.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let many = (0..<(HealPatch.maximumDustCount + 100)).map { _ in #"{"centre":[0.5,0.5],"radius":0.002,"contrast":0.2}"# }
        let json = """
        {"version": 1, "maps": [
          {"id": "7A1C0000-0000-0000-0000-000000000001", "camera": "Synthetic Camera", "sensorSize": [800, 600],
           "created": "2026-09-12T10:00:00Z", "referenceName": "r.dng", "options": {"sensitivity": 50, "size": "medium"},
           "spots": [{"centre": [0.5, 0.5], "radius": 1e30, "contrast": 0.3},
                     {"centre": [0.5, 0.5], "radius": 2.0, "contrast": 0.3},
                     {"centre": [2, -3], "radius": 0.002, "contrast": 0.3},
                     {"centre": [0.4, 0.4], "radius": -0.5, "contrast": 0.3},
                     {"centre": [0.25, 0.25], "radius": 0.003, "contrast": 0.2}]},
          {"id": "7A1C0000-0000-0000-0000-000000000002", "camera": "Synthetic Camera", "sensorSize": [800, 600],
           "created": "2026-09-13T10:00:00Z", "referenceName": "s.dng", "options": {"sensitivity": 50, "size": "medium"},
           "spots": [\(many.joined(separator: ","))]},
          {"id": "7A1C0000-0000-0000-0000-000000000003", "camera": "Synthetic Camera", "sensorSize": [0, 600],
           "created": "2026-09-14T10:00:00Z", "referenceName": "t.dng", "options": {"sensitivity": 50, "size": "medium"},
           "spots": []}
        ]}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let maps = DustMapStore(url: url).load()
        XCTAssertEqual(maps.count, 2, "a map without a sensor size is dropped")
        let first = try XCTUnwrap(maps.first { $0.referenceName == "r.dng" })
        XCTAssertEqual(first.spots.count, 5)
        XCTAssertEqual(first.spots[0].radius, DustMapSpot.maximumRadius)
        XCTAssertEqual(first.spots[1].radius, DustMapSpot.maximumRadius)
        XCTAssertEqual(first.spots[2].centre, SIMD2(1, 0))
        XCTAssertEqual(first.spots[3].radius, 0)
        XCTAssertEqual(first.spots[4], DustMapSpot(centre: [0.25, 0.25], radius: 0.003, contrast: 0.2), "a sane spot is untouched")
        XCTAssertEqual(maps.first { $0.referenceName == "s.dng" }?.spots.count, HealPatch.maximumDustCount)
        XCTAssertNil(DustMapSpot(centre: [.nan, 0.5], radius: 0.002, contrast: 0.2).sanitized)
        XCTAssertNil(DustMapSpot(centre: [0.5, 0.5], radius: .infinity, contrast: 0.2).sanitized)
        XCTAssertNil(DustMapSpot(centre: [0.5, 0.5], radius: 0.002, contrast: .nan).sanitized)
        XCTAssertGreaterThan(DustMapSpot.maximumRadius * 4000, 40 * 1.5 + 2, "the widest band's spots are kept")

        // The clamped spots verify in bounded time on a real analysis;
        // the raw ones would have cut a window of gigabytes.
        let a = DustDetectorTests.analysis(DustScene.make(noise: 0.02, spotCount: 0, decoys: false, seed: 303))
        let t0 = Date()
        _ = DustDetector.verify(first.spots, in: a, options: first.options, existing: [])
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
    }

    /// Detect on a reference photo, save as a map, load it back and verify
    /// it on a second photo of the same sensor with different noise and
    /// sky: the same spots come back, with the patch geometry the detector
    /// would give them.
    func testDetectSaveLoadVerifyRoundTrip() throws {
        let reference = DustScene.make(noise: 0.01, seed: 101)
        let a = DustDetectorTests.analysis(reference)
        let options = DustDetector.Options(sensitivity: 60, size: .medium)
        let patches = DustDetector.detect(a, options: options, expectedRadius: nil, existing: [])
        XCTAssertGreaterThan(patches.count, 8)
        let spots = DustDetector.mapSpots(from: patches, analysis: a)
        XCTAssertEqual(spots.count, patches.count)
        for spot in spots {
            XCTAssertGreaterThan(spot.contrast, 0.05, "a saved spot has the contrast the detector saw")
            XCTAssertTrue((0...1).contains(spot.centre.x) && (0...1).contains(spot.centre.y))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-dust-map-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("dust-maps.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DustMapStore(url: url)
        let map = DustMap(camera: "Synthetic Camera", sensorSize: SIMD2(Int(a.sensorSize.x), Int(a.sensorSize.y)),
                          referenceName: "reference.dng", aperture: 16, options: options, spots: spots)
        try store.add(map)
        let loaded = try XCTUnwrap(store.maps(forCamera: "Synthetic Camera").first)
        XCTAssertEqual(loaded.spots, spots)
        XCTAssertEqual(loaded.options, options)

        // The second photo: the same dust (the same seed places the same
        // spots) under a different noise realisation is the same scene
        // with different noise; `make` seeds spots and noise together, so
        // paint the reference's spots onto a fresh sky instead.
        var target = DustScene.make(noise: 0.02, spotCount: 0, decoys: false, seed: 202)
        for spot in reference.spots {
            DustScene.paint(&target.map.values, width: target.map.width, height: target.map.height,
                            around: spot.centre, reach: 2 * spot.radius + 4) { p in
                log2(1 - spot.attenuation * DustScene.profile(simd_distance(p, spot.centre), radius: spot.radius))
            }
        }
        let b = DustDetectorTests.analysis(target)
        let verified = DustDetector.verify(loaded.spots, in: b, options: loaded.options, existing: [])
        print("DustMap round trip: \(verified.count) of \(spots.count) map spots verified in the second photo")
        XCTAssertGreaterThanOrEqual(Double(verified.count) / Double(spots.count), 0.9)
        for patch in verified {
            // Each verified patch sits on a saved spot, at least as big as
            // the map said, with a source on a ring.
            let spot = try XCTUnwrap(spots.min { simd_distance($0.centre * b.sensorSize, patch.target * b.sensorSize)
                                                   < simd_distance($1.centre * b.sensorSize, patch.target * b.sensorSize) })
            let shortSide = min(b.sensorSize.x, b.sensorSize.y)
            XCTAssertLessThan(simd_distance(spot.centre * b.sensorSize, patch.target * b.sensorSize), spot.radius * shortSide + 2 * b.binSpan)
            XCTAssertGreaterThanOrEqual(patch.radius * shortSide, 1.5 * spot.radius * shortSide + 2 - 1e-3)
            XCTAssertEqual(patch.feather, 0.5)
            XCTAssertEqual(patch.mode, .heal)
            XCTAssertNotEqual(patch.source, patch.target)
        }
        // Verifying against a photo with no dust finds nothing.
        let clean = DustDetectorTests.analysis(DustScene.make(noise: 0.02, spotCount: 0, decoys: false, seed: 303))
        XCTAssertEqual(DustDetector.verify(loaded.spots, in: clean, options: loaded.options, existing: []), [])
    }
}
