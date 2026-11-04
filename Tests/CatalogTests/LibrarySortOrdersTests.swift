import XCTest
@testable import Catalog

/// Lightroom's other grid orders (LibrarySortOrders.swift): what each key
/// reads, its first direction, and missing values last either way.
final class LibrarySortOrdersTests: XCTestCase {
    private func record(_ id: Int64, _ name: String, configure: (inout ImageRecord) -> Void = { _ in }) -> ImageRecord {
        var r = ImageRecord(id: id, relPath: name, preservedName: nil, size: 1, mtime: 1, xxhash: Data(),
                            captureTime: 100, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                            focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
                            sidecarMtime: nil, thumbKey: nil)
        configure(&r)
        return r
    }

    private func names(_ records: [ImageRecord], _ key: LibrarySortKey, ascending: Bool,
                       editStats: [Int64: LibraryEditStat] = [:]) -> [String] {
        records.sorted(by: LibrarySort(key: key, ascending: ascending), editStats: editStats).map(\.relPath)
    }

    func testEveryKeyHasATitleAndSortsWithoutCrashing() {
        let records = [record(1, "a.NEF"), record(2, "b.jpg")]
        XCTAssertEqual(Set(LibrarySortKey.allCases.map(\.title)).count, LibrarySortKey.allCases.count)
        for key in LibrarySortKey.allCases {
            XCTAssertEqual(records.sorted(by: LibrarySort(key: key, ascending: true)).count, 2, "\(key)")
        }
    }

    func testNaturalDirections() {
        for key in [LibrarySortKey.editTime, .editCount, .pick, .rating, .captureTime] {
            XCTAssertFalse(LibrarySortMemory.naturalAscending(key), "\(key)")
        }
        for key in [LibrarySortKey.addedOrder, .labelColour, .fileType, .aspectRatio, .camera, .iso, .focalLength, .title] {
            XCTAssertTrue(LibrarySortMemory.naturalAscending(key), "\(key)")
        }
    }

    func testPickPutsPicksFirstAndRejectsLast() {
        let records = [record(1, "r.NEF") { $0.flag = -1 }, record(2, "u.NEF"), record(3, "p.NEF") { $0.flag = 1 }]
        XCTAssertEqual(names(records, .pick, ascending: false), ["p.NEF", "u.NEF", "r.NEF"])
        XCTAssertEqual(names(records, .pick, ascending: true), ["r.NEF", "u.NEF", "p.NEF"])
    }

    func testLabelColourFollowsLightroomsOrderWithCustomThenNoneLast() {
        let records = [record(1, "none.NEF"), record(2, "blue.NEF") { $0.label = "Blue" },
                       record(3, "custom.NEF") { $0.label = "Approved" }, record(4, "red.NEF") { $0.label = "red" },
                       record(5, "green.NEF") { $0.label = "Green" }]
        XCTAssertEqual(names(records, .labelColour, ascending: true),
                       ["red.NEF", "green.NEF", "blue.NEF", "custom.NEF", "none.NEF"])
        XCTAssertEqual(names(records, .labelColour, ascending: false),
                       ["custom.NEF", "blue.NEF", "green.NEF", "red.NEF", "none.NEF"], "no label stays last")
        // Label text goes alphabetically by what the label says.
        XCTAssertEqual(names(records, .labelText, ascending: true),
                       ["custom.NEF", "blue.NEF", "green.NEF", "red.NEF", "none.NEF"])
    }

    func testFileTypeAndExtension() {
        let records = [record(1, "a.jpg"), record(2, "b.NEF"), record(3, "c.dng"), record(4, "d.CR3"), record(5, "e.tif")]
        XCTAssertEqual(LibrarySortKey.fileType(of: records[1]), "Raw")
        XCTAssertEqual(LibrarySortKey.fileType(of: records[3]), "Raw")
        XCTAssertEqual(names(records, .fileType, ascending: true), ["c.dng", "a.jpg", "b.NEF", "d.CR3", "e.tif"])
        XCTAssertEqual(names(records, .fileExtension, ascending: true), ["d.CR3", "c.dng", "a.jpg", "b.NEF", "e.tif"])
    }

    func testAspectRatioReadsTheOrientationAndTheUsersTurns() {
        let records = [
            record(1, "landscape.NEF") { $0.width = 6000; $0.height = 4000 },
            record(2, "portrait.NEF") { $0.width = 6000; $0.height = 4000; $0.orientation = 6 },
            record(3, "turned.NEF") { $0.width = 6000; $0.height = 4000; $0.userRotation = 1 },
            record(4, "square.NEF") { $0.width = 4000; $0.height = 4000 },
            record(5, "unknown.NEF"),
        ]
        let sorted = names(records, .aspectRatio, ascending: true)
        XCTAssertEqual(Array(sorted.prefix(2)).sorted(), ["portrait.NEF", "turned.NEF"])
        XCTAssertEqual(Array(sorted.suffix(3)), ["square.NEF", "landscape.NEF", "unknown.NEF"])
        // Turned by the camera and back by the user: landscape again.
        let both = record(6, "both.NEF") { $0.width = 6000; $0.height = 4000; $0.orientation = 5; $0.userRotation = 3 }
        XCTAssertEqual(LibrarySortKey.aspectRatio(of: both) ?? 0, 1.5, accuracy: 1e-9)
    }

    func testMetadataKeysPutMissingValuesLast() {
        let records = [record(1, "none.NEF"), record(2, "b.NEF") { $0.iso = 3200; $0.focal = 85; $0.camera = "Z 8"; $0.title = "Beach" },
                       record(3, "a.NEF") { $0.iso = 100; $0.focal = 24; $0.camera = "D750"; $0.lens = "24-70"; $0.title = "  " }]
        XCTAssertEqual(names(records, .iso, ascending: true), ["a.NEF", "b.NEF", "none.NEF"])
        XCTAssertEqual(names(records, .iso, ascending: false), ["b.NEF", "a.NEF", "none.NEF"])
        XCTAssertEqual(names(records, .focalLength, ascending: true), ["a.NEF", "b.NEF", "none.NEF"])
        XCTAssertEqual(names(records, .camera, ascending: true), ["a.NEF", "b.NEF", "none.NEF"])
        XCTAssertEqual(names(records, .lens, ascending: false), ["a.NEF", "b.NEF", "none.NEF"])
        XCTAssertEqual(names(records, .title, ascending: true), ["b.NEF", "a.NEF", "none.NEF"], "a blank title is none")
    }

    func testEditTimeAndCountReadTheEditStats() {
        let records = [record(1, "old.NEF"), record(2, "new.NEF"), record(3, "never.NEF")]
        let stats: [Int64: LibraryEditStat] = [1: LibraryEditStat(updatedAt: 1000, steps: 9), 2: LibraryEditStat(updatedAt: 5000, steps: 0)]
        XCTAssertEqual(names(records, .editTime, ascending: false, editStats: stats), ["new.NEF", "old.NEF", "never.NEF"])
        XCTAssertEqual(names(records, .editCount, ascending: false, editStats: stats), ["old.NEF", "new.NEF", "never.NEF"])
        XCTAssertEqual(names(records, .addedOrder, ascending: true), ["old.NEF", "new.NEF", "never.NEF"])
    }

    func testTiesFallBackToThePath() {
        let records = [record(1, "c.NEF"), record(2, "a.NEF"), record(3, "b.NEF")]
        XCTAssertEqual(names(records, .pick, ascending: false), ["a.NEF", "b.NEF", "c.NEF"])
        XCTAssertEqual(names(records, .pick, ascending: true), ["a.NEF", "b.NEF", "c.NEF"])
    }

    func testAChangeMovesARecordOnlyUnderAKeyThatReadsIt() {
        let old = record(1, "a.NEF")
        var picked = old
        picked.flag = 1
        XCTAssertTrue(LibrarySort(key: .pick, ascending: false).dependsOnChange(from: old, to: picked))
        XCTAssertFalse(LibrarySort(key: .iso, ascending: false).dependsOnChange(from: old, to: picked))
        var labelled = old
        labelled.label = "Red"
        XCTAssertTrue(LibrarySort(key: .labelColour, ascending: true).dependsOnChange(from: old, to: labelled))
    }
}

/// Edit time and Edit count through a real catalog: the statistics are
/// read when such a key is chosen and again after an edit is saved.
@MainActor
final class LibraryEditStatsSortTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let sample = try TestAssets.d750Path()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-editstats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["A.NEF", "B.NEF", "C.NEF"] {
            try FileManager.default.copyItem(atPath: sample, toPath: folder.appendingPathComponent(name).path)
        }
        self.folder = folder
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func waitForStats(_ library: Library, count: Int) async throws {
        for _ in 0..<200 where library.editStats.count < count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testEditCountAndTimeSortsFollowSavedEdits() async throws {
        let library = Library()
        try await library.open(folder: folder)
        func id(_ name: String) -> Int64 { library.images.first { $0.fileName == name }!.id! }
        let edit = #"{"schema":1,"process":"1.0","modules":{"exposure":{"ev":0.5}}}"#

        try await library.saveEditStack(edit, schemaVersion: 1, processVersion: "1.0", forImageID: id("B.NEF"))
        try await library.setHistory([(edit, 1), (edit, 2), (edit, 3)], forImageID: id("A.NEF"))
        try await library.saveEditStack(edit, schemaVersion: 1, processVersion: "1.0", forImageID: id("A.NEF"))
        XCTAssertTrue(library.editStats.isEmpty, "nothing is read while no edit sort is chosen")

        library.chooseSortKey(.editCount)
        try await waitForStats(library, count: 2)
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF", "B.NEF", "C.NEF"])

        // Edited last comes first under Edit time.
        library.chooseSortKey(.editTime)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await library.saveEditStack(edit, schemaVersion: 1, processVersion: "1.0", forImageID: id("C.NEF"))
        try await waitForStats(library, count: 3)
        XCTAssertEqual(library.visibleImages.first?.fileName, "C.NEF")
        XCTAssertEqual(library.visibleImages.count, 3)
    }
}
