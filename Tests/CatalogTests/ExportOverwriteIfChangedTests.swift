import XCTest
@testable import Catalog

/// Overwrite if edit changed: an existing export is replaced only when the
/// photo's sidecar (or the photo) is newer than the file.
final class ExportOverwriteIfChangedTests: XCTestCase {
    private func record(_ relPath: String, sidecarMtime: Int64?) -> ImageRecord {
        ImageRecord(id: 1, relPath: relPath, preservedName: nil, size: 1, mtime: 1_700_000_000_000,
                    xxhash: Data(count: 8), captureTime: 1_789_321_260, camera: nil, lens: nil, lensId: nil,
                    iso: nil, shutter: nil, aperture: nil, focal: nil, width: nil, height: nil,
                    orientation: nil, rating: 0, label: nil, flag: 0, sidecarMtime: sidecarMtime, thumbKey: nil)
    }

    private let out = URL(fileURLWithPath: "/out", isDirectory: true)

    /// Every listed file exists, written at `written` (seconds since 1970).
    private func probe(files: [String: TimeInterval], folders: [String] = []) -> ExportBatchPlanner.Probe {
        ExportBatchPlanner.Probe(
            item: { url in folders.contains(url.path) ? .folder : files[url.path] != nil ? .file : nil },
            isCaseSensitive: { _ in false },
            modificationDate: { url in files[url.path].map { Date(timeIntervalSince1970: $0) } })
    }

    func testReplacesOnlyWhatChangedSinceItWasWritten() {
        let edited = record("a.NEF", sidecarMtime: 1_800_000_000_000)       // edited at 1.8e9 s
        let untouched = record("b.NEF", sidecarMtime: 1_700_000_500_000)
        let fresh = record("c.NEF", sidecarMtime: 1_900_000_000_000)
        let options = ExportBatchPlanner.Options(template: "{name}", fileExtension: "jpg",
                                                 collision: .replaceIfChanged)
        let plan = ExportBatchPlanner.plan([edited, untouched, fresh], into: out, options: options,
                                           probe: probe(files: ["/out/a.jpg": 1_750_000_000,
                                                                "/out/b.jpg": 1_750_000_000]))
        XCTAssertEqual(plan.outputs.map(\.action), [.replace, .skip, .write])
        XCTAssertEqual(plan.outputs.map(\.url.lastPathComponent), ["a.jpg", "b.jpg", "c.jpg"])
    }

    func testAFolderInTheWayFailsAndANewFileIsSkippedOnRecheck() {
        let options = ExportBatchPlanner.Options(template: "{name}", fileExtension: "jpg",
                                                 collision: .replaceIfChanged)
        let blocked = ExportBatchPlanner.plan([record("a.NEF", sidecarMtime: nil)], into: out, options: options,
                                              probe: probe(files: [:], folders: ["/out/a.jpg"]))
        if case .fail = blocked.outputs[0].action {} else { XCTFail("a folder can't be replaced") }

        var plan = ExportBatchPlanner.plan([record("a.NEF", sidecarMtime: nil)], into: out, options: options,
                                           probe: probe(files: [:]))
        XCTAssertEqual(plan.outputs[0].action, .write)
        // A file that appeared since planning is newer than the edit.
        XCTAssertEqual(plan.recheck(0, probe: probe(files: ["/out/a.jpg": 1_999_000_000])).action, .skip)
    }

    func testNoFileDateCountsAsChanged() {
        XCTAssertTrue(ExportBatchPlanner.editChanged(record("a.NEF", sidecarMtime: nil), since: nil))
        XCTAssertFalse(ExportBatchPlanner.editChanged(record("a.NEF", sidecarMtime: nil),
                                                      since: Date(timeIntervalSince1970: 1_700_000_001)))
    }
}
