import XCTest
@testable import MLKit

final class ZipSafetyTests: XCTestCase {
    func testEntryChecks() {
        XCTAssertTrue(ModelDownloader.entriesAreSafe(["A.mlpackage/", "A.mlpackage/Data/x.bin", "", " "]))
        XCTAssertFalse(ModelDownloader.entriesAreSafe(["../evil"]))
        XCTAssertFalse(ModelDownloader.entriesAreSafe(["a/../../evil"]))
        XCTAssertFalse(ModelDownloader.entriesAreSafe(["/etc/passwd"]))
        XCTAssertFalse(ModelDownloader.entriesAreSafe(["ok", "..\\evil"]))
    }

    /// A real archive with a climbing entry is refused before anything is
    /// written, and the target it would have escaped to stays untouched.
    func testClimbingArchiveIsRefused() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-zip-\(UUID().uuidString)")
        let models = root.appendingPathComponent("models")
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
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

        XCTAssertThrowsError(try ModelDownloader.unzip(zip, into: models, replacing: models.appendingPathComponent("Fake.mlpackage")))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("escaped.txt").path), "nothing escaped")
        XCTAssertFalse(fm.fileExists(atPath: models.appendingPathComponent("Fake.mlpackage").path), "nothing partial")
    }
}
