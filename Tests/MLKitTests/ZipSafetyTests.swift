import XCTest
@testable import MLKit

/// The archive checks Add Model… runs before anything is written
/// (docs/Retouch.md §5; moved here from the download path).
final class ZipSafetyTests: XCTestCase {
    func testEntryChecks() {
        XCTAssertTrue(ModelImporter.entriesAreSafe(["A.mlpackage/", "A.mlpackage/Data/x.bin", "", " "]))
        XCTAssertFalse(ModelImporter.entriesAreSafe(["../evil"]))
        XCTAssertFalse(ModelImporter.entriesAreSafe(["a/../../evil"]))
        XCTAssertFalse(ModelImporter.entriesAreSafe(["/etc/passwd"]))
        XCTAssertFalse(ModelImporter.entriesAreSafe(["ok", "..\\evil"]))
    }

    /// A real archive with a climbing entry is refused before anything is
    /// unpacked: nothing escapes, and the staging folder is cleaned up.
    func testClimbingArchiveIsRefused() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-zip-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Python's zipfile writes the entry name verbatim, including "..".
        let zip = root.appendingPathComponent("evil.zip")
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-c", """
        import zipfile, sys
        with zipfile.ZipFile(sys.argv[1], 'w') as z:
            z.writestr('Fake.mlpackage/ok.txt', 'fine')
            z.writestr('../escaped.txt', 'bad')
        """, zip.path]
        try py.run(); py.waitUntilExit()
        XCTAssertEqual(py.terminationStatus, 0)

        func staging() -> Set<String> {
            Set(((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("latent-import-") })
        }
        let before = staging()
        XCTAssertThrowsError(try ModelImporter.stageArchive(zip)) { error in
            XCTAssertEqual(error as? ModelImportError, .unsafeArchive)
        }
        XCTAssertEqual(staging(), before, "the staging folder is removed")
        XCTAssertFalse(fm.fileExists(atPath: fm.temporaryDirectory.appendingPathComponent("escaped.txt").path), "nothing escaped")
    }

    /// A good archive lands in a fresh staging folder in the container's
    /// temporary directory, with the zip copy gone, and `discardStaging`
    /// removes it all.
    func testGoodArchiveIsStagedAndDiscarded() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-zip-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src/Fake.mlpackage")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "new".write(to: src.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }
        let zip = root.appendingPathComponent("Fake.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", src.path, zip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let unpacked = try ModelImporter.stageArchive(zip)
        XCTAssertTrue(unpacked.path.hasPrefix(fm.temporaryDirectory.standardizedFileURL.path)
                      || unpacked.path.hasPrefix(fm.temporaryDirectory.path))
        XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("Fake.mlpackage/marker"), encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: unpacked.deletingLastPathComponent().appendingPathComponent("archive.zip").path))
        ModelImporter.discardStaging(unpacked)
        XCTAssertFalse(fm.fileExists(atPath: unpacked.deletingLastPathComponent().path))
    }
}
