import XCTest
@testable import Catalog

/// The bulk listing reconcile scans with must see what the Foundation
/// listing it replaced saw, to the millisecond: a time that differed by one
/// would mark every file of every catalog as changed after an update.
final class DirectoryListingTests: XCTestCase {
    var folder: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory
            .appendingPathComponent("latent-listing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? fm.removeItem(at: folder) }
    }

    private func setTimes(_ url: URL, seconds: Int, nanoseconds: Int) {
        var times = [timespec(tv_sec: seconds, tv_nsec: nanoseconds), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW), 0)
    }

    func testTimesAndSizesMatchFoundationToTheBit() throws {
        var rng = SystemRandomNumberGenerator()
        for i in 0..<400 {
            let url = folder.appendingPathComponent("F\(i).NEF")
            try Data(repeating: UInt8(i & 0xFF), count: i * 7).write(to: url)
            // Half on a half-millisecond, where rounding is decided by the
            // last bit of the conversion.
            let nanos = i % 2 == 0 ? Int.random(in: 0...999, using: &rng) * 1_000_000 + 500_000
                : Int.random(in: 0...999_999_999, using: &rng)
            setTimes(url, seconds: Int.random(in: 0...2_000_000_000, using: &rng), nanoseconds: nanos)
        }
        let entries = try DirectoryListing.entries(of: folder)
        XCTAssertEqual(entries.count, 400)
        for entry in entries {
            let url = folder.appendingPathComponent(entry.name)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            XCTAssertEqual(entry.kind, .file)
            XCTAssertEqual(entry.size, Int64(values.fileSize ?? -1), entry.name)
            XCTAssertEqual(DirectoryListing.date(entry.modified), values.contentModificationDate, entry.name)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            XCTAssertEqual(DirectoryListing.date(entry.modified), attributes[.modificationDate] as? Date, entry.name)
        }
    }

    func testKindsAndHiddenEntriesMatchTheFoundationListing() throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent("A.NEF"))
        try Data("x".utf8).write(to: folder.appendingPathComponent(".dot.NEF"))
        let flagged = folder.appendingPathComponent("Flagged.NEF")
        try Data("x".utf8).write(to: flagged)
        XCTAssertEqual(chflags(flagged.path, UInt32(UF_HIDDEN)), 0)
        try fm.createDirectory(at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("Link.NEF"),
                                  withDestinationURL: folder.appendingPathComponent("A.NEF"))
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("Pipe.NEF").path, 0o600), 0)

        let entries = try DirectoryListing.entries(of: folder)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["A.NEF"]?.kind, .file)
        XCTAssertEqual(byName["Sub"]?.kind, .directory)
        XCTAssertEqual(byName["Link.NEF"]?.kind, .symbolicLink)
        XCTAssertEqual(byName["Pipe.NEF"]?.kind, .other)

        let visible = Set(entries.filter { !$0.isHidden }.map(\.name))
        let foundation = Set(try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]).map(\.lastPathComponent))
        XCTAssertEqual(visible, foundation)
        XCTAssertFalse(visible.contains("Flagged.NEF"))
        XCTAssertFalse(visible.contains(".dot.NEF"))
    }

    func testSlowListingAgreesWithTheBulkOne() throws {
        for i in 0..<20 { try Data(count: i).write(to: folder.appendingPathComponent("F\(i).NEF")) }
        try fm.createDirectory(at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: false)
        let bulk = try DirectoryListing.entries(of: folder).sorted { $0.name < $1.name }
        let slow = try DirectoryListing.slowEntries(of: folder).sorted { $0.name < $1.name }
        XCTAssertEqual(bulk, slow)
    }

    func testUnreadableDirectoryThrows() {
        XCTAssertThrowsError(try DirectoryListing.entries(of: folder.appendingPathComponent("missing")))
    }

    /// A refresh after an update must find every file unchanged: reconcile
    /// reads a folder catalogued with the old listing's times the same.
    func testRefreshFindsFilesUnchangedAcrossManyTimes() async throws {
        _ = try TestAssets.d750URL()
        var rng = SystemRandomNumberGenerator()
        for i in 0..<6 {
            let url = folder.appendingPathComponent("D\(i).NEF")
            try TestAssets.copyD750(to: url, variant: i)
            setTimes(url, seconds: Int.random(in: 1_000_000_000...1_900_000_000, using: &rng),
                     nanoseconds: Int.random(in: 0...999, using: &rng) * 1_000_000 + 500_000)
        }
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        for record in try await catalog.allImages() {
            let values = try folder.appendingPathComponent(record.relPath)
                .resourceValues(forKeys: [.contentModificationDateKey])
            XCTAssertEqual(record.mtime, ImageRecord.milliseconds(values.contentModificationDate ?? .distantPast))
        }
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.unchanged, 6, "\(report)")
        XCTAssertEqual(report.modified + report.added + report.removed, 0, "\(report)")
    }
}
