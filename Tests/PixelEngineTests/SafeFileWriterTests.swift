import XCTest
import CoreGraphics
import ImageIO
@testable import PixelEngine

final class SafeFileWriterTests: XCTestCase {
    struct Boom: Error {}

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func tags(_ url: URL) throws -> [String] {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    func testWritesANewFileWithoutLeftovers() throws {
        let url = folder.appendingPathComponent("new.jpg")
        var temporary: URL?
        try SafeFileWriter.replace(url) { temp in
            temporary = temp
            XCTAssertEqual(temp.deletingLastPathComponent().standardizedFileURL.path,
                           folder.resolvingSymlinksInPath().standardizedFileURL.path)
            XCTAssertTrue(temp.lastPathComponent.hasPrefix("."), "hidden while it's being written")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing under the real name yet")
            try Data([1, 2, 3]).write(to: temp)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary!.path))
        XCTAssertEqual(try contents(), ["new.jpg"])
    }

    /// Replacing keeps what Finder shows about the old file: its creation
    /// date, permissions and tags.
    func testReplacingKeepsCreationDateTagsAndPermissions() throws {
        let url = folder.appendingPathComponent("photo.jpg")
        try Data("old contents".utf8).write(to: url)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old, .posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
        try (url as NSURL).setResourceValue(["Red", "Holiday"], forKey: .tagNamesKey)

        try SafeFileWriter.write(Data("new contents".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new contents")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.creationDate] as? Date, old)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(Set(try tags(url)), ["Red", "Holiday"])
        XCTAssertEqual(try contents(), ["photo.jpg"])
    }

    /// An encoder that fails halfway, or never writes, or a folder that has
    /// gone: the old file stays whole and no temporary file is left.
    func testAFailedWriteLeavesTheOriginalAndNoTemporaryFile() throws {
        let url = folder.appendingPathComponent("photo.jpg")
        try Data("original".utf8).write(to: url)

        XCTAssertThrowsError(try SafeFileWriter.replace(url) { temp in
            try Data("half written".utf8).write(to: temp)
            throw Boom()
        }) { XCTAssertTrue($0 is Boom) }
        XCTAssertThrowsError(try SafeFileWriter.replace(url) { _ in })
        XCTAssertThrowsError(try SafeFileWriter.write(Data("x".utf8), to: folder.appendingPathComponent("gone/photo.jpg")))

        // The begin/commit form: discarded without a commit, as when an
        // export is abandoned between the two.
        do {
            let pending = try SafeFileWriter.begin(url)
            defer { pending.discard() }
            try Data("abandoned".utf8).write(to: pending.url)
        }

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        XCTAssertEqual(try contents(), ["photo.jpg"])
    }

    /// A Save panel grants the named file but not its folder, so no sibling
    /// can be created; the temporary file goes to the volume's
    /// item-replacement folder, and replacing is still atomic.
    func testFallsBackWhenTheFolderRefusesNewFiles() throws {
        let url = folder.appendingPathComponent("photo.jpg")
        try Data("old".utf8).write(to: url)
        try (url as NSURL).setResourceValue(["Blue"], forKey: .tagNamesKey)

        var written: URL?
        try SafeFileWriter.replace(url, canCreateSibling: { _ in false }) { temp in
            written = temp
            try Data("new".utf8).write(to: temp)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        XCTAssertNotEqual(written?.deletingLastPathComponent().standardizedFileURL,
                          url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL)
        XCTAssertEqual(try tags(url), ["Blue"])
        XCTAssertEqual(try contents(), ["photo.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: written!.deletingLastPathComponent().path),
                       "the scratch folder is removed afterwards")

        // And for a file that doesn't exist yet, as a new Save panel name.
        let fresh = folder.appendingPathComponent("fresh.jpg")
        try SafeFileWriter.replace(fresh, canCreateSibling: { _ in false }) { try Data("n".utf8).write(to: $0) }
        XCTAssertEqual(try contents(), ["fresh.jpg", "photo.jpg"])
    }

    /// A batch whose policy is Add a number or Skip settled the name before
    /// rendering; a file that took the name during the render must be kept,
    /// and the commit must say so rather than replace it.
    func testCreateOnlyCommitKeepsAFileThatAppearedMeanwhile() throws {
        let url = folder.appendingPathComponent("photo.jpg")
        for canCreateSibling in [true, false] {
            let pending = try SafeFileWriter.begin(url, canCreateSibling: { _ in canCreateSibling })
            defer { pending.discard() }
            try Data("export".utf8).write(to: pending.url)
            try Data("someone else's".utf8).write(to: url)
            XCTAssertThrowsError(try pending.commit(replacingExisting: false)) {
                XCTAssertTrue($0 is SafeFileWriter.DestinationExists, "\($0)")
            }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "someone else's")
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(try contents(), [])

        // A link, even a broken one, holds the name too.
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "nowhere.jpg")
        let pending = try SafeFileWriter.begin(url)
        defer { pending.discard() }
        try Data("export".utf8).write(to: pending.url)
        XCTAssertThrowsError(try pending.commit(replacingExisting: false))
        try FileManager.default.removeItem(at: url)

        // With the name free, it writes as usual.
        try pending.commit(replacingExisting: false)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "export")
        XCTAssertEqual(try contents(), ["photo.jpg"])
    }

    /// The exporter passes the choice through, and leaves no temporary file.
    func testExporterRefusesToReplaceWhenAskedNotTo() throws {
        let url = folder.appendingPathComponent("photo.png")
        try Data("existing".utf8).write(to: url)
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertThrowsError(try Exporter.write(cgImage: image, to: url, settings: ExportSettings(format: .png),
                                                replacingExisting: false)) {
            XCTAssertTrue($0 is SafeFileWriter.DestinationExists, "\($0)")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "existing")
        XCTAssertEqual(try contents(), ["photo.png"])
    }

    /// Quitting before an export finishes: the unfinished file goes, from
    /// beside the destination or from the scratch folder, and a commit
    /// that comes after can't put anything in place.
    func testAbandoningRemovesUnfinishedWrites() throws {
        let beside = folder.appendingPathComponent("beside.jpg")
        let scratch = folder.appendingPathComponent("scratch.jpg")
        let first = try SafeFileWriter.begin(beside)
        let second = try SafeFileWriter.begin(scratch, canCreateSibling: { _ in false })
        defer { first.discard(); second.discard() }
        for pending in [first, second] { try Data("unfinished".utf8).write(to: pending.url) }
        let committed = try SafeFileWriter.begin(folder.appendingPathComponent("done.jpg"))
        try Data("done".utf8).write(to: committed.url)
        try committed.commit()

        // At least these two: nothing else in this process should be writing.
        XCTAssertGreaterThanOrEqual(SafeFileWriter.abandonPendingWrites(), 2)
        XCTAssertEqual(try contents(), ["done.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.deletingLastPathComponent().path))
        XCTAssertThrowsError(try first.commit())
        XCTAssertEqual(try contents(), ["done.jpg"])
        XCTAssertEqual(SafeFileWriter.abandonPendingWrites(), 0)
    }

    func testASymbolicLinkIsWrittenThrough() throws {
        let target = folder.appendingPathComponent("target.jpg")
        try Data("old".utf8).write(to: target)
        let link = folder.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try SafeFileWriter.write(Data("new".utf8), to: link)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType,
                       .typeSymbolicLink)
        XCTAssertEqual(try contents(), ["link.jpg", "target.jpg"])
    }

    /// `replaceItemAt` would swap a file in for a folder and delete the
    /// folder with its contents, so a folder must be refused, including one
    /// that appears while the file is being encoded.
    func testAFolderIsNeverReplaced() throws {
        let url = folder.appendingPathComponent("photo.jpg")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("precious".utf8).write(to: url.appendingPathComponent("inside.txt"))
        XCTAssertThrowsError(try SafeFileWriter.write(Data("x".utf8), to: url))

        let later = folder.appendingPathComponent("later.jpg")
        XCTAssertThrowsError(try SafeFileWriter.replace(later) { temp in
            try Data("x".utf8).write(to: temp)
            try FileManager.default.createDirectory(at: later, withIntermediateDirectories: false)
            try Data("precious".utf8).write(to: later.appendingPathComponent("inside.txt"))
        })

        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("inside.txt"), encoding: .utf8), "precious")
        XCTAssertEqual(try String(contentsOf: later.appendingPathComponent("inside.txt"), encoding: .utf8), "precious")
        XCTAssertEqual(try contents(), ["later.jpg", "photo.jpg"])
    }

    func testVeryLongNamesStillGetATemporaryFile() throws {
        // 251 bytes: a legal name, but not with the temporary additions.
        // Three-byte characters, so shortening must not cut one in half.
        let url = folder.appendingPathComponent(String(repeating: "日", count: 70) + String(repeating: "a", count: 37) + ".jpg")
        XCTAssertEqual(url.lastPathComponent.utf8.count, 251)
        try Data("old".utf8).write(to: url)
        try SafeFileWriter.write(Data("new".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        XCTAssertLessThanOrEqual(SafeFileWriter.temporaryURL(for: url).lastPathComponent.utf8.count, 255)
        XCTAssertEqual(try contents().count, 1)
    }

    /// The exporter's own write: the encoded file replaces the old one
    /// whole, and nothing else is left in the folder.
    func testExporterWritesThroughATemporaryFile() throws {
        let url = folder.appendingPathComponent("export.png")
        try Data("previous export".utf8).write(to: url)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try XCTUnwrap(ctx.makeImage())

        try Exporter.write(cgImage: image, to: url, settings: ExportSettings(format: .png))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 6)
        XCTAssertEqual(try contents(), ["export.png"])

        // Into a folder that doesn't exist: an error, and nothing written anywhere.
        XCTAssertThrowsError(try Exporter.write(cgImage: image, to: folder.appendingPathComponent("gone/x.png"),
                                                settings: ExportSettings(format: .png)))
        XCTAssertEqual(try contents(), ["export.png"])
    }
}
