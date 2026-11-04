import XCTest
@testable import Catalog

/// The main-thread work behind the grid and the menus, on a 20,000-image
/// folder (DESIGN.md's scrolling target). Each test times the code as it
/// was (copied here as the reference) against the code as it is, checks
/// both give the same answer, and prints both times: `PERF` lines in the
/// test log. The bounds are loose, for CI's slower runners.
@MainActor
final class LibraryPerformanceTests: XCTestCase {
    nonisolated static let count = 20_000

    /// Made-up records shaped like a real shoot: a few cameras, bursts that
    /// share a capture second, some ratings, virtual copies now and then.
    nonisolated static func records(_ count: Int = count) -> [ImageRecord] {
        (0..<count).map { index in
            var path = String(format: "2024/Day %02d/DSC_%05d.NEF", index % 7, (index * 7919) % 100_000)
            if index % 97 == 0 { path += "#vc002-0a1b2c3d" }
            var record = ImageRecord(id: Int64(index + 1), relPath: path, size: 1, mtime: Int64(index % 5000),
                                     xxhash: Data(count: 8),
                                     captureTime: index % 50 == 0 ? nil : Int64(1_700_000_000 + (index * 31) % 90_000 / 3),
                                     camera: index % 3 == 0 ? "NIKON D750" : "NIKON Z 8",
                                     rating: index % 6, flag: 0)
            record.title = index % 10 == 0 ? "Harbour \(index)" : nil
            return record
        }
    }

    /// Seconds for `body`, best of `runs`.
    private func time(runs: Int = 3, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return best
    }

    private func report(_ what: String, before: Double, after: Double) {
        print(String(format: "PERF %@: %.2f ms before, %.2f ms after (%.1fx)",
                     what, before * 1000, after * 1000, before / max(after, 1e-9)))
    }

    // MARK: - Sorting

    /// The sort as it was: records compared and moved directly, names
    /// worked out at every comparison.
    private func referenceSorted(_ records: [ImageRecord], by sort: LibrarySort) -> [ImageRecord] {
        func optional<T: Comparable>(_ x: T?, _ y: T?, _ a: ImageRecord, _ b: ImageRecord) -> Bool {
            switch (x, y) {
            case (nil, nil): return a.relPath < b.relPath
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?):
                if x == y { return a.relPath < b.relPath }
                return sort.ascending ? x < y : x > y
            }
        }
        return records.sorted { a, b in
            switch sort.key {
            case .captureTime: return optional(a.captureTime, b.captureTime, a, b)
            case .rating: return optional(a.rating > 0 ? a.rating : nil, b.rating > 0 ? b.rating : nil, a, b)
            case .modified: return optional(a.mtime, b.mtime, a, b)
            case .fileName:
                let c = a.sourceFileName.localizedStandardCompare(b.sourceFileName)
                if c == .orderedSame { return a.relPath < b.relPath }
                return sort.ascending ? c == .orderedAscending : c == .orderedDescending
            default: return false
            }
        }
    }

    func testSortsMatchTheOldOrderAndAreFaster() {
        let records = Self.records().shuffled()
        for key in [LibrarySortKey.captureTime, .fileName, .rating, .modified] {
            for ascending in [false, true] {
                let sort = LibrarySort(key: key, ascending: ascending)
                let expected = referenceSorted(records, by: sort)
                let actual = records.sorted(by: sort)
                XCTAssertEqual(actual.map(\.id), expected.map(\.id), "\(key) \(ascending)")
                guard ascending else { continue }
                let before = time(runs: 2) { _ = referenceSorted(records, by: sort) }
                let after = time(runs: 2) { _ = records.sorted(by: sort) }
                report("sort 20k by \(key.rawValue)", before: before, after: after)
                XCTAssertLessThan(after, 2.0)
            }
        }
    }

    // MARK: - Filtering

    func testTextSearchKeepsItsMatchesAndIsFaster() {
        let records = Self.records()
        var filter = LibraryFilter()
        filter.text = "harbour 1"
        let needle = filter.text.trimmingCharacters(in: .whitespaces)
        let reference = { (record: ImageRecord) -> Bool in
            [record.fileName, record.title ?? "", record.caption ?? ""]
                .contains { $0.range(of: needle, options: .caseInsensitive) != nil }
        }
        let expected = records.filter(reference).map(\.id)
        let actual = records.filter { filter.matches($0, isEdited: false, keywords: []) }.map(\.id)
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(actual.isEmpty)
        let before = time { _ = records.filter(reference) }
        let after = time { _ = records.filter { filter.matches($0, isEdited: false, keywords: []) } }
        report("text filter over 20k", before: before, after: after)
        XCTAssertLessThan(after, 1.0)
    }

    // MARK: - Selection

    func testSelectedImageLookupsUseTheIndex() {
        let records = Self.records()
        let library = Library()
        library.replaceImagesForTesting(records)
        let last = records[records.count - 1]
        let some = Set(records.suffix(5).compactMap(\.id))
        library.setSelection(some, primary: last.id)

        XCTAssertEqual(library.selectedImage?.id, last.id)
        XCTAssertEqual(library.selectedImages.map(\.id), records.filter { some.contains($0.id!) }.map(\.id),
                       "in folder order, as before")

        // What one redraw of the main window asks: the menu state reads the
        // primary and the selection, captions and panels the primary again.
        let reads = 50
        let before = time(runs: 1) {
            for _ in 0..<reads {
                _ = records.first { $0.id == library.selectedImageID }
                _ = records.filter { $0.id.map(library.selectedImageIDs.contains) ?? false }
            }
        }
        let after = time {
            for _ in 0..<reads {
                _ = library.selectedImage
                _ = library.selectedImages
            }
        }
        report("\(reads) primary+selection reads, 20k folder", before: before, after: after)
        XCTAssertLessThan(after, before)

        // A new list rebuilds the index.
        library.replaceImagesForTesting(Array(records.prefix(10)))
        XCTAssertNil(library.selectedImage, "the old primary isn't in the new list")
        library.setSelection([records[3].id!], primary: records[3].id)
        XCTAssertEqual(library.selectedImage?.id, records[3].id)
    }

    /// Keeping only the selected ids still in a refreshed list. It tested
    /// every selected id against every image: with everything selected in a
    /// big folder, a folder-watcher refresh froze the window for seconds.
    func testKeepingTheSelectionAfterARefreshIsLinear() {
        let records = Self.records(5_000)
        let selected = Set(records.compactMap(\.id))
        let before = time(runs: 1) { _ = selected.filter { id in records.contains { $0.id == id } } }
        let library = Library()
        library.replaceImagesForTesting(records)
        let after = time(runs: 1) {
            let index = library.imageIndexByID
            _ = selected.filter { index[$0] != nil }
        }
        report("selection kept after refresh, 5k of 5k selected", before: before, after: after)
        XCTAssertLessThan(after, before)
    }
}
