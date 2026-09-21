import XCTest
import simd
@testable import Catalog
import PixelEngine
@testable import latent_app

// The Remove Dust dialog's model (docs/Retouch.md §6): the maps offered
// for the selection's cameras, the fallback rules for a remembered map,
// the note about photos from another camera, the reference photo, and
// the options remembered between runs. The dialog itself is a view over
// this; the job it starts is tested with the queue.
@MainActor
final class RemoveDustSheetTests: XCTestCase {
    nonisolated(unsafe) var folder: URL?
    nonisolated(unsafe) var store: DustMapStore?
    nonisolated(unsafe) var suite: String?

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-remove-dust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        store = DustMapStore(url: folder.appendingPathComponent("dust-maps.json"))
        suite = "latent.tests.removeDust.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: suite!)! }

    static let nikon = SIMD2(6032, 4032)

    /// A catalog row as the grid would hand it over.
    private func record(_ name: String, camera: String? = "Nikon D750", size: SIMD2<Int> = nikon,
                        id: Int64 = 1) -> ImageRecord {
        ImageRecord(id: id, relPath: name, preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: nil, camera: camera, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: size.x, height: size.y, orientation: 1, rating: 0, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil, finderTags: nil)
    }

    private func map(_ camera: String, created: TimeInterval, size: SIMD2<Int> = nikon, name: String = "sky.nef") -> DustMap {
        DustMap(camera: camera, sensorSize: size, created: Date(timeIntervalSince1970: created), referenceName: name,
                spots: [DustMapSpot(centre: [0.5, 0.5], radius: 0.002, contrast: 0.4)])
    }

    private func model(_ records: [ImageRecord], inMemory: Bool = false) -> RemoveDustSheetModel {
        RemoveDustSheetModel(records: records, urls: records.map { URL(fileURLWithPath: "/tmp/\($0.relPath)") },
                             inMemory: inMemory, store: store!, defaults: defaults)
    }

    /// The maps offered are those of the selection's cameras, each
    /// camera's newest first in the order the cameras appear; the map
    /// used last is chosen again when it is still there.
    func testMapsListedPerCameraAndTheRememberedOneWins() throws {
        let older = map("Nikon D750", created: 1_000)
        let newer = map("Nikon D750", created: 2_000)
        let canon = map("Canon EOS R5", created: 3_000)
        let unrelated = map("Sony ILCE-7M4", created: 4_000)
        for map in [older, newer, canon, unrelated] { try store!.add(map) }
        let records = [record("a.nef"), record("b.nef"), record("c.cr3", camera: "Canon EOS R5")]

        let fresh = model(records)
        XCTAssertEqual(fresh.maps.map(\.id), [newer.id, older.id, canon.id])
        XCTAssertEqual(fresh.method, .find, "Find spots until another way is chosen")
        XCTAssertEqual(fresh.selectedMapID, newer.id, "the popup shows the newest, ready for Use dust map")
        XCTAssertNil(fresh.noMapText)
        XCTAssertEqual(fresh.title, "Remove dust from 3 photos")

        let preferences = DustRemovalPreferences(defaults: defaults)
        preferences.method = .map
        preferences.mapID = older.id
        let remembered = model(records)
        XCTAssertEqual(remembered.method, .map)
        XCTAssertEqual(remembered.selectedMapID, older.id)
        XCTAssertEqual(remembered.selectedMap?.title, older.title)
    }

    /// A remembered map that no longer exists falls back to the first map,
    /// and with no map for these cameras to Find spots, with the popup
    /// disabled and saying why.
    func testAMissingRememberedMapFallsBackToTheFirstThenToFindSpots() throws {
        let preferences = DustRemovalPreferences(defaults: defaults)
        preferences.method = .map
        preferences.mapID = UUID()
        let records = [record("a.nef"), record("b.nef")]

        let none = model(records)
        XCTAssertEqual(none.method, .find)
        XCTAssertNil(none.selectedMapID)
        XCTAssertEqual(none.noMapText, "No dust map for Nikon D750 yet")
        XCTAssertTrue(none.canRemove, "Find spots needs nothing")
        none.method = .map
        XCTAssertFalse(none.canRemove, "no map to use")
        XCTAssertNil(none.job())

        let only = map("Nikon D750", created: 5_000)
        try store!.add(only)
        let some = model(records)
        XCTAssertEqual(some.method, .map)
        XCTAssertEqual(some.selectedMapID, only.id, "the first map stands in")
        XCTAssertTrue(some.canRemove)
        let job = try XCTUnwrap(some.job())
        guard case .map(let chosen) = job.method else { return XCTFail("a map job") }
        XCTAssertEqual(chosen.id, only.id)
        XCTAssertEqual(DustRemovalPreferences(defaults: defaults).mapID, only.id, "remembered for next time")

        let unknown = model([record("x.arw", camera: nil)])
        XCTAssertEqual(unknown.noMapText, "No dust map for this camera yet")
        XCTAssertEqual(unknown.title, "Remove dust from 1 photo")
    }

    /// The note counts the photos the job would skip: another camera, or
    /// the same camera in another sensor size; every photo skipped means
    /// nothing to do.
    func testMismatchNoteCountsPhotosFromAnotherCamera() throws {
        let nikon = map("Nikon D750", created: 1_000)
        try store!.add(nikon)
        var records = (0..<9).map { record("n\($0).nef", id: Int64($0)) }
        records += (0..<3).map { record("c\($0).cr3", camera: "Canon EOS R5", id: Int64(20 + $0)) }
        let sheet = model(records)
        XCTAssertNil(sheet.mismatchNote, "Find spots looks at each photo on its own")
        sheet.method = .map
        XCTAssertEqual(sheet.skippedCount, 3)
        XCTAssertEqual(sheet.mismatchNote, "3 of 12 photos are from another camera and will be skipped")
        XCTAssertTrue(sheet.canRemove)

        let cropped = model([record("a.nef"), record("b.nef", size: SIMD2(4016, 2680))])
        cropped.method = .map
        XCTAssertEqual(cropped.mismatchNote, "1 of 2 photos are from another camera and will be skipped")

        let all = model([record("c.cr3", camera: "Canon EOS R5")] + records.suffix(2))
        XCTAssertEqual(all.maps, [], "no map for a Canon")
        XCTAssertEqual(all.method, .find)
        let other = model(records.suffix(3))
        XCTAssertNil(other.selectedMapID)
        let mixed = model([record("a.nef")] + records.suffix(3))
        mixed.method = .map
        XCTAssertEqual(mixed.mismatchNote, "3 of 4 photos are from another camera and will be skipped")

        // Everything skipped: the reference photo is a Canon's.
        let none = model(records.prefix(2).map { $0 })
        none.useSelectedPhoto()
        XCTAssertEqual(none.method, .reference)
        XCTAssertNil(none.mismatchNote, "the selected photo is one of them")
        let single = model([record("a.nef")])
        single.method = .map
        XCTAssertNil(single.mismatchNote)
        let stranger = model([record("only.cr3", camera: "Canon EOS R5", size: SIMD2(8192, 5464))])
        stranger.method = .map
        XCTAssertNil(stranger.selectedMap, "no map for a Canon: nothing to compare")
        XCTAssertFalse(stranger.canRemove)
    }

    /// The reference photo: the selected photo says its camera at once;
    /// a chosen file is read for its camera and sensor size, and one that
    /// can't be read says so. In memory there is no reference method.
    func testTheReferencePhotoAndTheInMemoryLimits() async throws {
        let records = [record("a.nef"), record("c.cr3", camera: "Canon EOS R5", id: 2)]
        let sheet = model(records)
        sheet.method = .reference
        XCTAssertFalse(sheet.canRemove, "no reference yet")
        sheet.useSelectedPhoto()
        let reference = try XCTUnwrap(sheet.reference)
        XCTAssertEqual(reference.name, "a.nef")
        XCTAssertEqual(reference.camera, "Nikon D750")
        XCTAssertEqual(reference.sensorSize, Self.nikon)
        XCTAssertTrue(reference.isSelectedPhoto)
        XCTAssertTrue(sheet.canRemove)
        XCTAssertEqual(sheet.mismatchNote, "1 of 2 photos are from another camera and will be skipped")
        let job = try XCTUnwrap(sheet.job())
        guard case .reference(let url, let name) = job.method else { return XCTFail("a reference job") }
        XCTAssertEqual(name, "a.nef")
        XCTAssertEqual(url.lastPathComponent, "a.nef")

        // A file: read off the disk.
        let dng = folder!.appendingPathComponent("sky.dng")
        try DustDNG.write(to: dng)
        sheet.useReferenceFile(dng)
        XCTAssertTrue(sheet.isReadingReference)
        XCTAssertFalse(sheet.canRemove, "not until it is read")
        await waitUntil("the reference") { !sheet.isReadingReference }
        let read = try XCTUnwrap(sheet.reference)
        XCTAssertEqual(read.camera, "Nikon D750")
        XCTAssertEqual(read.sensorSize, SIMD2(DustDNG.width, DustDNG.height))
        XCTAssertFalse(read.isSelectedPhoto)
        XCTAssertNil(sheet.referenceProblem)
        XCTAssertEqual(sheet.mismatchNote, "All 2 photos are from another camera, so there is nothing to do",
                       "an 800 by 600 sensor matches none of them")
        XCTAssertFalse(sheet.canRemove)

        let broken = folder!.appendingPathComponent("broken.nef")
        try Data("not a raw".utf8).write(to: broken)
        sheet.useReferenceFile(broken)
        await waitUntil("the broken file") { !sheet.isReadingReference }
        XCTAssertNil(sheet.reference)
        XCTAssertTrue(sheet.referenceProblem?.hasPrefix("broken.nef couldn’t be read: ") == true,
                      String(describing: sheet.referenceProblem))
        XCTAssertFalse(sheet.canRemove)

        // Develop's open image: Find spots and Use dust map only.
        DustRemovalPreferences(defaults: defaults).method = .reference
        let memory = model([records[0]], inMemory: true)
        XCTAssertEqual(memory.method, .find, "a remembered reference method falls back")
        memory.method = .reference
        XCTAssertEqual(memory.method, .find)
    }

    /// The options are remembered as the dialog was last left, clamped,
    /// and read back by the next one; a reference is never remembered.
    func testRememberedOptionsRoundTrip() throws {
        let preferences = DustRemovalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.method, .find)
        XCTAssertEqual(preferences.sensitivity, 50)
        XCTAssertEqual(preferences.size, .medium)
        XCTAssertNil(preferences.mapID)
        XCTAssertEqual(preferences.options, DustDetector.Options())

        let sheet = model([record("a.nef")])
        sheet.sensitivity = 70
        sheet.size = .large
        sheet.remember()
        let next = model([record("a.nef")])
        XCTAssertEqual(next.sensitivity, 70)
        XCTAssertEqual(next.size, .large)
        XCTAssertEqual(next.options, DustDetector.Options(sensitivity: 70, size: .large))
        let job = try XCTUnwrap(next.job())
        XCTAssertEqual(job.options, DustDetector.Options(sensitivity: 70, size: .large))
        guard case .find = job.method else { return XCTFail("a find job") }

        preferences.sensitivity = 140
        XCTAssertEqual(preferences.sensitivity, 100, "clamped to the slider")
        defaults.set("nonsense", forKey: DustRemovalPreferences.methodKey)
        defaults.set("huge", forKey: DustRemovalPreferences.sizeKey)
        XCTAssertEqual(preferences.method, .find)
        XCTAssertEqual(preferences.size, .medium)
    }
}
