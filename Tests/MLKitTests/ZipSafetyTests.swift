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

    /// Temp folders the importer has made and not cleaned up.
    func staging() -> Set<String> {
        let fm = FileManager.default
        return Set(((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("latent-import-") })
    }

    /// A zip written by Python's zipfile from `script`, which gets the
    /// zip's path as its argument.
    func pythonZip(named name: String, in root: URL, _ script: String) throws -> URL {
        let zip = root.appendingPathComponent(name)
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-c", script, zip.path]
        try py.run(); py.waitUntilExit()
        XCTAssertEqual(py.terminationStatus, 0)
        return zip
    }

    /// The size an archive unpacks to is bounded while ditto runs and
    /// once it is done: an archive's own sizes are its claim, and a small
    /// archive of zeros unpacks to a thousand times its size. Refused,
    /// with the staging folder gone.
    func testArchiveBombIsRefused() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-zip-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let zip = try pythonZip(named: "bomb.zip", in: root, """
        import zipfile, sys
        with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('Fake.mlpackage/Data/zeros.bin', b'\\0' * (16 << 20))
        """)
        XCTAssertLessThan(try XCTUnwrap(fm.attributesOfItem(atPath: zip.path)[.size] as? Int), 1 << 20, "a small archive")
        let before = staging()
        let limit: Int64 = 1 << 20
        XCTAssertThrowsError(try ModelImporter.stageArchive(zip, unpackedLimit: limit)) { error in
            XCTAssertEqual(error as? ModelImportError, .archiveTooLarge(limit))
            XCTAssertTrue("\(error as! ModelImportError)".contains("MB, far more than a model needs"), "\(error)")
        }
        XCTAssertEqual(staging(), before, "the staging folder is removed")
        XCTAssertGreaterThan(ModelImporter.maximumUnpackedBytes, 1 << 30, "a real model fits")
    }

    /// More entries than a model could have are refused before anything
    /// is unpacked.
    func testTooManyEntriesAreRefused() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-zip-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let count = ModelImporter.maximumArchiveEntries + 1
        let zip = try pythonZip(named: "many.zip", in: root, """
        import zipfile, sys
        with zipfile.ZipFile(sys.argv[1], 'w') as z:
            for i in range(\(count)):
                z.writestr('Fake.mlpackage/f%d' % i, '')
        """)
        let before = staging()
        XCTAssertThrowsError(try ModelImporter.stageArchive(zip)) { error in
            XCTAssertEqual(error as? ModelImportError, .archiveTooManyEntries(count))
        }
        XCTAssertEqual(staging(), before)
    }

    /// An archive ditto complains about at length (a name too long for
    /// the file system, per entry) must not wedge the import on a full
    /// pipe: ditto ends, the first complaint is the sentence, and the
    /// staging folder goes.
    func testDittoComplaintsEndTheImport() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-zip-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let zip = try pythonZip(named: "long.zip", in: root, """
        import zipfile, sys
        with zipfile.ZipFile(sys.argv[1], 'w') as z:
            z.writestr('Fake.mlpackage/ok.txt', 'fine')
            for i in range(400):
                z.writestr('Fake.mlpackage/n%04d' % i + 'x' * 300, 'x')
        """)
        let before = staging()
        let t0 = Date()
        XCTAssertThrowsError(try ModelImporter.stageArchive(zip)) { error in
            guard case .unzipFailed(let why)? = error as? ModelImportError else { return XCTFail("\(error)") }
            XCTAssertFalse(why.contains("\n"), "one line: \(why.prefix(120))")
            XCTAssertLessThan(why.count, 600, "not the whole log")
            XCTAssertFalse(why.contains(fm.temporaryDirectory.path), "no path")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 30, "ditto was not left blocked on its pipe")
        XCTAssertEqual(staging(), before)
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
