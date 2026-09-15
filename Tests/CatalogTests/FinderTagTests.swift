import XCTest
@testable import Catalog

/// Finder tags: parsing Finder's attribute, the stored form, the filter,
/// and reconcile reading them (and never writing them).
final class FinderTagTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-findertags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Sets tags as Finder stores them: a binary property list of "Name\nN".
    static func setFinderTags(_ entries: [String], on url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, FinderTag.attributeName, bytes.baseAddress, data.count, 0, 0)
        }
        XCTAssertEqual(result, 0, "setxattr failed: \(errno)")
    }

    static func removeFinderTags(from url: URL) {
        removexattr(url.path, FinderTag.attributeName, 0)
    }

    func testParsesColoursAndNamesWithoutThem() {
        let tags = FinderTag.parse(["Red\n6", "Work\n0", "Blue", "Client\n4", "Red\n2", "\n3"])
        XCTAssertEqual(tags, [FinderTag(name: "Red", colorIndex: 6), FinderTag(name: "Work", colorIndex: 0),
                              FinderTag(name: "Blue", colorIndex: 4), FinderTag(name: "Client", colorIndex: 4)],
                       "a standard name without a colour takes Finder's; duplicates and empty names go")
        XCTAssertEqual(FinderTag(name: "x", colorIndex: 9).colorIndex, 0, "out of range is no colour")
    }

    func testStoredFormRoundTripsAndAnswersContains() {
        let tags = [FinderTag(name: "Red", colorIndex: 6), FinderTag(name: "2024 trip", colorIndex: 0),
                    FinderTag(name: "a b: c", colorIndex: 4)]
        let stored = FinderTag.encode(tags)
        XCTAssertEqual(stored, "6Red\n02024 trip\n4a b: c")
        XCTAssertEqual(FinderTag.decode(stored), tags)
        XCTAssertNil(FinderTag.encode([]))
        XCTAssertEqual(FinderTag.decode(nil), [])
        XCTAssertTrue(FinderTag.stored(stored, contains: "2024 trip"))
        XCTAssertFalse(FinderTag.stored(stored, contains: "Re"))
        XCTAssertFalse(FinderTag.stored(nil, contains: "Red"))
    }

    func testReadsTheAttributeOfAFile() throws {
        let file = folder.appendingPathComponent("a.NEF")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertEqual(FinderTag.read(from: file), [], "untagged")
        try Self.setFinderTags(["Green\n2", "Keep"], on: file)
        XCTAssertEqual(FinderTag.read(from: file), [FinderTag(name: "Green", colorIndex: 2),
                                                    FinderTag(name: "Keep", colorIndex: 0)])
        // What the system setter writes reads the same way.
        try (file as NSURL).setResourceValue(["Purple"], forKey: .tagNamesKey)
        XCTAssertEqual(FinderTag.read(from: file).map(\.name), ["Purple"])
        XCTAssertEqual(FinderTag.read(from: file).first?.colorIndex, 3)
    }

    func testFilterByTag() {
        var record = ImageRecord(id: 1, relPath: "a.NEF", preservedName: nil, size: 1, mtime: 0,
                                 xxhash: Data(count: 8), captureTime: nil, camera: nil, lens: nil, lensId: nil,
                                 iso: nil, shutter: nil, aperture: nil, focal: nil, width: nil, height: nil,
                                 orientation: nil, rating: 0, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
        var filter = LibraryFilter()
        filter.finderTag = "Red"
        XCTAssertTrue(filter.isActive)
        XCTAssertFalse(filter.matches(record, isEdited: false, keywords: []))
        var tagged = record
        tagged.finderTags = FinderTag.encode([FinderTag(name: "Red", colorIndex: 6)])
        XCTAssertTrue(filter.matches(tagged, isEdited: false, keywords: []))
        XCTAssertTrue(filter.dependsOnChange(from: record, to: tagged))
        filter.finderTag = nil
        XCTAssertFalse(filter.dependsOnChange(from: record, to: tagged), "no tag filter, no refilter")
        record.rating = 2
        XCTAssertFalse(LibrarySort(key: .custom, ascending: true).dependsOnChange(from: tagged, to: tagged))
    }

    /// Reconcile reads tags with the listing, refreshes them when only the
    /// tags changed, keeps them through a rename, and leaves the file alone.
    func testReconcileReadsAndRefreshesTags() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        let file = folder.appendingPathComponent("A.NEF")
        try FileManager.default.copyItem(atPath: ReconcileTests.sampleNEF, toPath: file.path)
        try Self.setFinderTags(["Red\n6"], on: file)
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        var images = try await catalog.allImages()
        XCTAssertEqual(images.first?.tags, [FinderTag(name: "Red", colorIndex: 6)])

        let mtime = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try Self.setFinderTags(["Red\n6", "Work\n0"], on: file)
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.unchanged, 1)
        XCTAssertEqual(report.tagsChanged, 1)
        images = try await catalog.allImages()
        XCTAssertEqual(images.first?.tags.map(\.name), ["Red", "Work"])

        report = try await catalog.reconcile()
        XCTAssertEqual(report.tagsChanged, 0, "unchanged tags write nothing")

        Self.removeFinderTags(from: file)
        _ = try await catalog.reconcile()
        images = try await catalog.allImages()
        XCTAssertNil(images.first?.finderTags)

        try Self.setFinderTags(["Blue\n4"], on: file)
        let renamed = folder.appendingPathComponent("B.NEF")
        try FileManager.default.moveItem(at: file, to: renamed)
        report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 1)
        images = try await catalog.allImages()
        XCTAssertEqual(images.map(\.relPath), ["B.NEF"])
        XCTAssertEqual(images.first?.tags.map(\.name), ["Blue"])
        XCTAssertEqual(FinderTag.read(from: renamed).map(\.name), ["Blue"], "read, never rewritten")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: renamed.path)[.modificationDate] as? Date,
                       mtime, "the original's content date is untouched")
    }
}
