import XCTest
@testable import Catalog

final class LibraryFilterTests: XCTestCase {
    private func record(_ id: Int64, name: String, rating: Int = 0, flag: Int = 0,
                        camera: String? = "Nikon D750", lens: String? = nil,
                        captured: Int64? = nil, mtime: Int64 = 0) -> ImageRecord {
        ImageRecord(id: id, relPath: name, preservedName: nil, size: 1, mtime: mtime,
                    xxhash: Data(count: 8), captureTime: captured, camera: camera, lens: lens,
                    lensId: nil, iso: nil, shutter: nil, aperture: nil, focal: nil,
                    width: nil, height: nil, orientation: nil, rating: rating, label: nil,
                    flag: flag, sidecarMtime: nil, thumbKey: nil)
    }

    func testDefaultFilterIsInactiveAndMatchesEverything() {
        let f = LibraryFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertTrue(f.matches(record(1, name: "a.nef"), isEdited: false, keywords: []))
    }

    func testRatingThresholdAndFlags() {
        var f = LibraryFilter()
        f.minRating = 3
        XCTAssertTrue(f.isActive)
        XCTAssertFalse(f.matches(record(1, name: "a", rating: 2), isEdited: false, keywords: []))
        XCTAssertTrue(f.matches(record(1, name: "a", rating: 3), isEdited: false, keywords: []))

        f = LibraryFilter()
        f.flags = [.picked]
        XCTAssertTrue(f.matches(record(1, name: "a", flag: 1), isEdited: false, keywords: []))
        XCTAssertFalse(f.matches(record(1, name: "a", flag: 0), isEdited: false, keywords: []))
        f.flags.insert(.none)
        XCTAssertTrue(f.matches(record(1, name: "a", flag: 0), isEdited: false, keywords: []))
        XCTAssertFalse(f.matches(record(1, name: "a", flag: -1), isEdited: false, keywords: []))
    }

    func testAttributeKeywordEditedAndText() {
        var f = LibraryFilter()
        f.camera = "Nikon D750"
        XCTAssertTrue(f.matches(record(1, name: "a"), isEdited: false, keywords: []))
        XCTAssertFalse(f.matches(record(1, name: "a", camera: "Sony A7"), isEdited: false, keywords: []))

        f = LibraryFilter(); f.keyword = "portrait"
        XCTAssertTrue(f.matches(record(1, name: "a"), isEdited: false, keywords: ["portrait", "studio"]))
        XCTAssertFalse(f.matches(record(1, name: "a"), isEdited: false, keywords: ["studio"]))

        f = LibraryFilter(); f.editedOnly = true
        XCTAssertTrue(f.matches(record(1, name: "a"), isEdited: true, keywords: []))
        XCTAssertFalse(f.matches(record(1, name: "a"), isEdited: false, keywords: []))

        f = LibraryFilter(); f.text = "  hsb_26 "
        XCTAssertTrue(f.matches(record(1, name: "Day/HSB_2615.NEF"), isEdited: false, keywords: []))
        XCTAssertFalse(f.matches(record(1, name: "Day/DSC_0001.NEF"), isEdited: false, keywords: []))
        f.text = "   "
        XCTAssertFalse(f.isActive, "whitespace-only search is no search")
    }

    func testSortByCaptureTimeNilLastEitherDirection() {
        let list = [record(1, name: "b", captured: 100), record(2, name: "a", captured: nil),
                    record(3, name: "c", captured: 300)]
        XCTAssertEqual(list.sorted(by: .default).map(\.id), [3, 1, 2], "newest first, undated last")
        XCTAssertEqual(list.sorted(by: LibrarySort(key: .captureTime, ascending: true)).map(\.id), [1, 3, 2])
    }

    func testSortByNameIsNaturalAndByRatingPutsUnratedLast() {
        let list = [record(1, name: "img10.nef"), record(2, name: "img2.nef"), record(3, name: "img1.nef")]
        XCTAssertEqual(list.sorted(by: LibrarySort(key: .fileName, ascending: true)).map(\.id), [3, 2, 1],
                       "img2 before img10: numeric-aware comparison")

        let rated = [record(1, name: "a", rating: 0), record(2, name: "b", rating: 5), record(3, name: "c", rating: 2)]
        XCTAssertEqual(rated.sorted(by: LibrarySort(key: .rating, ascending: false)).map(\.id), [2, 3, 1])
        XCTAssertEqual(rated.sorted(by: LibrarySort(key: .rating, ascending: true)).map(\.id), [3, 2, 1])
    }

    func testSortIsStableOnTies() {
        let list = [record(2, name: "b", captured: 5), record(1, name: "a", captured: 5)]
        XCTAssertEqual(list.sorted(by: .default).map(\.id), [1, 2], "ties break by path")
    }
}
