import XCTest
import AppKit
@testable import Catalog
import PixelEngine
@testable import latent_app

/// The app's share of a 10,000-photo folder: configuring grid cells as they
/// scroll past (keyword badge, marks, info line), the grid's refresh of the
/// visible cells, the keywording field's completion list, and the tone
/// equalizer's mask summary after each Develop render. Each prints its time
/// as a `PERF` line; the bounds are loose, to catch an accidental O(n²).
/// On CI the timing tests run only with `LATENT_PERF=1`.
@MainActor
final class LargeFolderGridPerformanceTests: XCTestCase {
    private func requireTiming() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["CI"] != nil, environment["LATENT_PERF"] != "1" {
            throw XCTSkip("timing tests run on CI only with LATENT_PERF=1")
        }
    }

    private func time(runs: Int = 3, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return best
    }

    private func report(_ what: String, _ seconds: Double, unit: String = "ms", scale: Double = 1000) {
        print(String(format: "PERF %@: %.2f %@", what, seconds * scale, unit))
    }

    /// Made-up photos with shooting data, labels, tags, and 0 to 5 keywords.
    private func folder(_ count: Int) -> (records: [ImageRecord], keywords: [Int64: Set<String>]) {
        var records: [ImageRecord] = []
        var keywords: [Int64: Set<String>] = [:]
        for index in 0..<count {
            let id = Int64(index + 1)
            var record = ImageRecord(id: id, relPath: String(format: "2023/Day %02d/DSC_%05d.NEF", index % 30, index),
                                     size: 1, mtime: 0, xxhash: Data(count: 8), captureTime: Int64(index),
                                     camera: "NIKON Z 8", rating: index % 6, flag: index % 7 == 0 ? 1 : 0)
            record.iso = [100, 400, 1600][index % 3]
            record.aperture = [1.8, 2.8, 8][index % 3]
            record.shutter = [1.0 / 250, 1.0 / 60, 2][index % 3]
            record.label = index % 9 == 0 ? "Red" : nil
            record.finderTags = index % 5 == 0 ? FinderTag.encode([FinderTag(name: "Work", colorIndex: 6)]) : nil
            records.append(record)
            if index % 6 > 0 {
                keywords[id] = Set((0..<(index % 6)).map { "Places|Country \($0)|City \((index + $0) % 40)" })
            }
        }
        return (records, keywords)
    }

    /// Sixty cells, reused as the grid reuses them, configured for every
    /// photo of the folder in turn: what scrolling from top to bottom costs.
    func testCellConfigurationWhileScrolling() throws {
        try requireTiming()
        let (records, keywords) = folder(10_000)
        let layout = ThumbnailGridLayout(side: 160)
        let cells = (0..<60).map { _ in
            let cell = ThumbnailCellView(frame: NSRect(origin: .zero, size: layout.itemSize))
            cell.layoutInfo = layout
            return cell
        }
        func configure(_ cell: ThumbnailCellView, _ record: ImageRecord) {
            // As ThumbnailItem.update does.
            cell.setDamaged(false)
            cell.setKeywords(record.id.flatMap { keywords[$0] } ?? [])
            cell.setMarks(name: record.fileName, rating: record.rating, flag: record.flag, isEdited: false)
            cell.setTags(stored: record.finderTags)
            cell.setLabel(record.label)
            cell.setInfo(record)
            cell.setVirtualCopy(record.isVirtualCopy)
            cell.setStack(nil)
            cell.layout()
        }
        let scroll = time(runs: 1) {
            for (index, record) in records.enumerated() { configure(cells[index % cells.count], record) }
        }
        report("cell configuration while scrolling, per cell", scroll / Double(records.count), unit: "µs", scale: 1e6)
        XCTAssertLessThan(scroll / Double(records.count), 0.002)

        // The grid's refresh after a thumbnail lands or a rating changes:
        // every visible cell is given its keywords again, unchanged.
        let visible = Array(records.suffix(cells.count))
        let refreshes = 200
        let refresh = time {
            for _ in 0..<refreshes {
                for (cell, record) in zip(cells, visible) { cell.setKeywords(record.id.flatMap { keywords[$0] } ?? []) }
            }
        } / Double(refreshes)
        // The same with the badge's old way: display names sorted every time.
        let reference = time {
            for _ in 0..<refreshes {
                for record in visible {
                    _ = (record.id.flatMap { keywords[$0] } ?? []).map(KeywordPath.display)
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                }
            }
        } / Double(refreshes)
        report("keyword badges, refresh of 60 visible cells (before: sorted every time)", reference)
        report("keyword badges, refresh of 60 visible cells", refresh)
        XCTAssertLessThan(refresh, 0.01)
    }

    /// The keywording field's completion candidates at each keystroke:
    /// worked out once, then kept until the folder's keywords or the
    /// dictionary change.
    func testKeywordCompletionCandidatesAreKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latent-dict-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = KeywordDictionaryStore(url: url)
        store.record((0..<3_000).map { "Archive|Year \(2000 + $0 % 25)|Event \($0)" })
        let folderKeywords = (0..<700).map { "Places|Country \($0 % 8)|City \($0)" }.sorted()
        let expected = Array(Set(folderKeywords).union(store.dictionary.allPaths)).sorted()
        XCTAssertEqual(store.completionCandidates(folderKeywords: folderKeywords), expected)

        if ProcessInfo.processInfo.environment["CI"] == nil || ProcessInfo.processInfo.environment["LATENT_PERF"] == "1" {
            let keystrokes = 20
            let kept = time {
                for _ in 0..<keystrokes { _ = store.completionCandidates(folderKeywords: folderKeywords) }
            } / Double(keystrokes)
            let before = time(runs: 1) {
                _ = Array(Set(folderKeywords).union(store.dictionary.allPaths)).sorted()
            }
            report("keyword completion candidates per keystroke (before: merged and sorted each time)", before)
            report("keyword completion candidates per keystroke", kept)
            XCTAssertLessThan(kept, 0.005)
        }

        // A new folder keyword, or a dictionary change, is picked up.
        let more = (folderKeywords + ["Brand|New"]).sorted()
        XCTAssertTrue(store.completionCandidates(folderKeywords: more).contains("Brand|New"))
        store.record(["Fresh|Word"])
        XCTAssertTrue(store.completionCandidates(folderKeywords: more).contains("Fresh|Word"))
        XCTAssertTrue(store.completionCandidates(folderKeywords: more).contains("Fresh"), "levels above, too")
    }

    /// After each Develop render with the tone equalizer open: the mask's
    /// 5th and 95th percentiles from one sort of the 512-cell-wide grid.
    func testToneEqualizerMaskPercentilesSortOnce() throws {
        let width = 512, height = 341
        var generator = SystemRandomNumberGenerator()
        let values = (0..<(width * height)).map { _ in Float.random(in: -9...0, using: &generator) }
        let mask = ToneEqualizerMaskSnapshot(width: width, height: height, values: values, exposureEV: 0.5)
        let both = mask.percentiles([0.05, 0.95])
        XCTAssertEqual(both[0], mask.percentile(0.05))
        XCTAssertEqual(both[1], mask.percentile(0.95))
        XCTAssertEqual(ToneEqualizerMaskSnapshot(width: 0, height: 0, values: [], exposureEV: 0).percentiles([0.5]), [nil])

        if ProcessInfo.processInfo.environment["CI"] == nil || ProcessInfo.processInfo.environment["LATENT_PERF"] == "1" {
            let before = time { _ = (mask.percentile(0.05), mask.percentile(0.95)) }
            let after = time { _ = mask.percentiles([0.05, 0.95]) }
            report("tone equalizer mask percentiles per render (before: two sorts)", before)
            report("tone equalizer mask percentiles per new mask", after)
            XCTAssertLessThan(after, before)
        }
    }
}
