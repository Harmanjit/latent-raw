import XCTest
@testable import Catalog

/// Wave 4 filter bar: Remember Filter per Source (`FilterSourceMemory`),
/// clicks on the Ranges histograms (`RangeBarClick`) and Similar to This
/// Photo (`SimilarPhotoCriteria`).
final class FilterBarDeepeningTests: XCTestCase {
    private func record(_ id: Int64, _ path: String, camera: String? = nil, lens: String? = nil,
                        captured: Int64? = nil, rating: Int = 0) -> ImageRecord {
        ImageRecord(id: id, relPath: path, preservedName: nil, size: 1, mtime: 0,
                    xxhash: Data(count: 8), captureTime: captured, camera: camera, lens: lens,
                    lensId: nil, iso: nil, shutter: nil, aperture: nil, focal: nil,
                    width: nil, height: nil, orientation: nil, rating: rating, label: nil,
                    flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    // MARK: - Remember Filter per Source

    func testSourceKeysTellFoldersAndCollectionsApart() {
        let folder = URL(fileURLWithPath: "/Photos/Trip")
        XCTAssertNil(FilterSourceMemory.key(folder: nil, collection: 3))
        let whole = FilterSourceMemory.key(folder: folder, collection: nil)
        let lisbon = FilterSourceMemory.key(folder: folder, collection: 3)
        let other = FilterSourceMemory.key(folder: URL(fileURLWithPath: "/Photos/Home"), collection: 3)
        XCTAssertNotNil(whole)
        XCTAssertEqual(Set([whole, lisbon, other]).count, 3)
        XCTAssertEqual(FilterSourceMemory.key(folder: URL(fileURLWithPath: "/Photos/Trip/"), collection: nil), whole)
    }

    func testRememberRecallAndNeutralFiltersAreNotStored() {
        var memory = FilterSourceMemory()
        var filter = LibraryFilter()
        filter.minRating = 3
        filter.recentlyAddedIDs = [1, 2]
        memory.remember(filter, for: "a")
        XCTAssertEqual(memory.filter(for: "a").minRating, 3)
        XCTAssertNil(memory.filter(for: "a").recentlyAddedIDs, "the Recently Added list isn't a setting")
        XCTAssertEqual(memory.filter(for: "never seen"), LibraryFilter())
        memory.remember(LibraryFilter(), for: "a")
        XCTAssertTrue(memory.filters.isEmpty)
        XCTAssertTrue(memory.order.isEmpty)
    }

    func testOldestSourcesAreDroppedPastCapacity() {
        var memory = FilterSourceMemory()
        var filter = LibraryFilter()
        filter.editedOnly = true
        for i in 0...FilterSourceMemory.capacity { memory.remember(filter, for: "s\(i)") }
        XCTAssertEqual(memory.filters.count, FilterSourceMemory.capacity)
        XCTAssertNil(memory.filters["s0"])
        // Remembering again makes a source the newest.
        memory.remember(filter, for: "s1")
        memory.remember(filter, for: "new")
        XCTAssertNotNil(memory.filters["s1"])
        XCTAssertNil(memory.filters["s2"])
    }

    func testMemoryRoundTripsThroughJSON() {
        var memory = FilterSourceMemory()
        var a = LibraryFilter(); a.camera = "NIKON D750"; a.isoRange = 100...800
        var b = LibraryFilter(); b.text = "lisbon"
        memory.remember(a, for: "a")
        memory.remember(b, for: "b")
        let back = FilterSourceMemory.decode(memory.encoded())
        XCTAssertEqual(back, memory)
        XCTAssertEqual(FilterSourceMemory.decode(Data("nonsense".utf8)), FilterSourceMemory())
        XCTAssertEqual(FilterSourceMemory.decode(nil), FilterSourceMemory())
    }

    // MARK: - Clicks on the Ranges histograms

    func testPlainClickSelectsTheBarsBucket() {
        let r = RangeBarClick.apply(index: 5, clickCount: 1, extending: false, current: 0...23, anchor: nil, bucketCount: 24)
        XCTAssertEqual(r.buckets, 5...5)
        XCTAssertEqual(r.anchor, 5)
        let clamped = RangeBarClick.apply(index: 40, clickCount: 1, extending: false, current: 0...23, anchor: nil, bucketCount: 24)
        XCTAssertEqual(clamped.buckets, 23...23)
    }

    func testShiftClickExtendsFromTheLastBarClicked() {
        var r = RangeBarClick.apply(index: 5, clickCount: 1, extending: false, current: 0...23, anchor: nil, bucketCount: 24)
        r = RangeBarClick.apply(index: 9, clickCount: 1, extending: true, current: r.buckets, anchor: r.anchor, bucketCount: 24)
        XCTAssertEqual(r.buckets, 5...9)
        r = RangeBarClick.apply(index: 2, clickCount: 1, extending: true, current: r.buckets, anchor: r.anchor, bucketCount: 24)
        XCTAssertEqual(r.buckets, 2...5, "the anchor stays where the plain click was")
        // Thumbs dragged since (no anchor inside): stretch the nearer end.
        let dragged = RangeBarClick.apply(index: 12, clickCount: 1, extending: true, current: 3...6, anchor: 20, bucketCount: 24)
        XCTAssertEqual(dragged.buckets, 3...12)
        XCTAssertEqual(dragged.anchor, 3)
        // Nothing to extend while unconstrained: a plain click.
        let fresh = RangeBarClick.apply(index: 7, clickCount: 1, extending: true, current: 0...23, anchor: nil, bucketCount: 24)
        XCTAssertEqual(fresh.buckets, 7...7)
    }

    func testDoubleClickClearsTheRange() {
        let histogram = RangeHistogram(values: [100, 200, 400, 800, 1600, 3200])
        let r = RangeBarClick.apply(index: 3, clickCount: 2, extending: false, current: 3...3, anchor: 3,
                                    bucketCount: histogram.bucketCount)
        XCTAssertEqual(r.buckets, 0...(histogram.bucketCount - 1))
        XCTAssertNil(r.anchor)
        XCTAssertNil(histogram.range(buckets: r.buckets), "every bucket is no constraint")
        XCTAssertEqual(RangeBarClick.apply(index: 0, clickCount: 1, extending: false, current: 0...0, anchor: nil,
                                           bucketCount: 0).buckets, 0...0)
    }

    // MARK: - Similar to This Photo

    private let day: Int64 = 86_400

    func testSimilarFilterMatchesCameraLensAndADayEitherSide() {
        let t: Int64 = 1_700_000_000
        let reference = record(1, "A.NEF", camera: "NIKON D750", lens: "50mm f/1.8", captured: t)
        let criteria = SimilarPhotoCriteria(record: reference)
        XCTAssertTrue(criteria.matchesCamera && criteria.matchesLens && criteria.matchesDate)
        var base = LibraryFilter()
        base.minRating = 4
        base.text = "x"
        let filter = criteria.applied(to: base)
        XCTAssertEqual(filter.camera, "NIKON D750")
        XCTAssertEqual(filter.lens, "50mm f/1.8")
        XCTAssertEqual(filter.captureDateRange?.lowerBound, Date(timeIntervalSince1970: TimeInterval(t - day)))
        XCTAssertEqual(filter.captureDateRange?.upperBound, Date(timeIntervalSince1970: TimeInterval(t + day)))
        XCTAssertEqual(filter.minRating, 4, "the rest of the base is kept")
        XCTAssertTrue(criteria.isReflected(in: filter))

        let candidates = [
            reference,
            record(2, "B.NEF", camera: "NIKON D750", lens: "50mm f/1.8", captured: t + day - 60),
            record(3, "C.NEF", camera: "NIKON D750", lens: "50mm f/1.8", captured: t + day + 60),
            record(4, "D.NEF", camera: "NIKON D750", lens: "24-70mm", captured: t),
            record(5, "E.ARW", camera: "SONY A7", lens: "50mm f/1.8", captured: t),
            record(6, "F.NEF", camera: "NIKON D750", lens: "50mm f/1.8", captured: nil),
        ]
        let similar = criteria.applied(to: LibraryFilter())
        let passing = candidates.filter { similar.matches($0, isEdited: false, keywords: []) }.compactMap(\.id)
        XCTAssertEqual(passing, [1, 2])
    }

    func testPartsWidenTheSearchWhenSwitchedOff() {
        let t: Int64 = 1_700_000_000
        var criteria = SimilarPhotoCriteria(record: record(1, "A.NEF", camera: "NIKON D750", lens: "50mm", captured: t))
        criteria.matchesLens = false
        criteria.matchesDate = false
        var filter = LibraryFilter()
        filter.lens = "stale"
        filter.captureDateRange = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 1)
        filter = criteria.applied(to: filter)
        XCTAssertEqual(filter.camera, "NIKON D750")
        XCTAssertNil(filter.lens)
        XCTAssertNil(filter.captureDateRange)
        XCTAssertTrue(criteria.isReflected(in: filter))
        filter.camera = "SONY A7"
        XCTAssertFalse(criteria.isReflected(in: filter), "another camera picked: the filter is the user's again")
    }

    func testMissingValuesCannotBeSwitchedOn() {
        var criteria = SimilarPhotoCriteria(record: record(1, "A.JPG", camera: "", lens: nil, captured: 5))
        XCTAssertFalse(criteria.matchesCamera, "an empty camera counts as none")
        XCTAssertFalse(criteria.matchesLens)
        XCTAssertTrue(criteria.matchesDate)
        criteria.matchesLens = true
        XCTAssertFalse(criteria.matchesLens)
        XCTAssertNil(criteria.applied(to: LibraryFilter()).lens)
        XCTAssertTrue(criteria.hasAnyPart)
        XCTAssertFalse(SimilarPhotoCriteria(record: record(2, "B.JPG")).hasAnyPart)
    }
}

/// The Library side: remembering per collection, and Similar's chip state.
@MainActor
final class FilterBarDeepeningLibraryTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-filterbar-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in ["A.NEF", "B.NEF"].enumerated() {
            try TestAssets.copyD750(to: folder.appendingPathComponent(name), variant: index + 1)
        }
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func open() async throws -> Library {
        let library = Library()
        library.undoManager = UndoManager()
        try await library.open(folder: folder)
        return library
    }

    func testFilterCarriesOverWhileTheOptionIsOff() async throws {
        let library = try await open()
        let a = try XCTUnwrap(library.images.first?.id)
        let lisbon = try XCTUnwrap(library.collections.create(name: "Lisbon", kind: .regular, adding: [a]))
        library.filter.text = "A."
        library.collections.show(lisbon)
        XCTAssertEqual(library.filter.text, "A.", "default behaviour: one filter for every source")
        XCTAssertTrue(library.filterSourceMemory.filters.isEmpty)
        await library.collections.waitForSaves()
    }

    func testEachSourceGetsItsFilterBack() async throws {
        let library = try await open()
        var saved: [(Bool, FilterSourceMemory)] = []
        library.filterMemoryDidChange = { saved.append(($0, $1)) }
        let a = try XCTUnwrap(library.images.first?.id)
        let lisbon = try XCTUnwrap(library.collections.create(name: "Lisbon", kind: .regular, adding: [a]))
        library.filter.minRating = 2
        library.remembersFilterPerSource = true
        XCTAssertEqual(saved.last?.0, true)

        library.collections.show(lisbon)
        XCTAssertEqual(library.filter, LibraryFilter(), "a source never filtered shows everything")
        library.filter.text = "A."
        library.collections.show(nil)
        XCTAssertEqual(library.filter.minRating, 2)
        XCTAssertEqual(library.filter.text, "")
        library.collections.show(lisbon)
        XCTAssertEqual(library.filter.text, "A.")
        XCTAssertEqual(library.filter.minRating, 0)
        XCTAssertEqual(saved.last?.1.filters.count, 2, "every change reaches the app's saved copy")

        // Reopening the folder brings the folder's own filter back.
        library.collections.show(nil)
        let reopened = Library()
        reopened.restoreFilterMemory(enabled: true, memory: library.filterSourceMemory)
        try await reopened.open(folder: folder)
        XCTAssertEqual(reopened.filter.minRating, 2)
        await library.collections.waitForSaves()
    }

    func testSimilarChipFollowsTheFilter() async throws {
        let library = try await open()
        let record = try XCTUnwrap(library.images.first)
        library.filter.minRating = 5
        XCTAssertTrue(library.showSimilar(to: record))
        let criteria = try XCTUnwrap(library.similarPhotoCriteria)
        XCTAssertEqual(library.filter.minRating, 0, "the rest of the filter is cleared")
        XCTAssertEqual(library.filter.camera, record.camera)
        XCTAssertTrue(library.visibleImages.contains { $0.id == record.id }, "the photo itself always passes")

        var wider = criteria
        wider.matchesCamera = false
        wider.matchesLens = false
        wider.matchesDate = false
        library.updateSimilar(wider)
        XCTAssertEqual(library.similarPhotoCriteria, wider, "kept even with every part off")
        XCTAssertNil(library.filter.camera)

        library.updateSimilar(criteria)
        library.filter = LibraryFilter()
        XCTAssertNil(library.similarPhotoCriteria, "Clear Filters ends Similar")

        library.showSimilar(to: record)
        library.filter.minRating = 3
        XCTAssertNotNil(library.similarPhotoCriteria, "other criteria can be added on top")
        library.endSimilar()
        XCTAssertNil(library.similarPhotoCriteria)
        XCTAssertNil(library.filter.camera)
        XCTAssertEqual(library.filter.minRating, 3)
    }
}
