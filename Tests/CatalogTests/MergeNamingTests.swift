import XCTest
import GRDB
@testable import Catalog

/// Names of Photo Merge results (docs/PhotoMerge.md §5, DESIGN.md §5.7):
/// "-HDR" beside the reference photo, then "-HDR-2"…, skipping any name a
/// file, a sidecar or a catalog row already holds.
final class MergeNamingTests: XCTestCase {
    func testCandidatesFollowTheReferencePhoto() {
        XCTAssertEqual(MergeNaming.candidate(forReference: "DSC_0107.NEF", suffix: "HDR", number: 1), "DSC_0107-HDR.dng")
        XCTAssertEqual(MergeNaming.candidate(forReference: "DSC_0107.NEF", suffix: "HDR", number: 2), "DSC_0107-HDR-2.dng")
        XCTAssertEqual(MergeNaming.candidate(forReference: "Day 2/DSC_0107.NEF", suffix: "HDR", number: 3),
                       "Day 2/DSC_0107-HDR-3.dng")
        XCTAssertEqual(MergeNaming.candidate(forReference: "Day 2/IMG.1.CR3", suffix: "Pano", number: 1),
                       "Day 2/IMG.1-Pano.dng", "only the last extension goes")
    }

    func testTheFirstFreeCandidateIsChosen() {
        let taken: Set = ["A-HDR.dng", "A-HDR-2.dng"]
        XCTAssertEqual(MergeNaming.resultRelPath(forReference: "A.NEF", suffix: "HDR") { taken.contains($0) }, "A-HDR-3.dng")
        XCTAssertNil(MergeNaming.resultRelPath(forReference: "A.NEF", suffix: "HDR", limit: 2) { taken.contains($0) })
    }

    /// A reference name already near the 255-byte limit leaves no room for
    /// "-HDR.dng"; such candidates are skipped rather than tried on disk.
    func testNamesTooLongForTheDiskAreSkipped() {
        let long = String(repeating: "a", count: 250) + ".NEF"
        XCTAssertNil(MergeNaming.resultRelPath(forReference: long, suffix: "HDR", limit: 5) { _ in false })
    }

    func testTheCatalogRefusesNamesHeldByAFileASidecarOrARow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("latent-merge-naming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Day 2"), withIntermediateDirectories: true)
        let catalog = try Catalog.open(at: root)
        let reference = "Day 2/DSC_0107.NEF"

        var planned = try await catalog.planMergeResult(forReference: reference, suffix: "HDR")
        XCTAssertEqual(planned, "Day 2/DSC_0107-HDR.dng")

        // A file under the name.
        try Data("x".utf8).write(to: root.appendingPathComponent("Day 2/DSC_0107-HDR.dng"))
        planned = try await catalog.planMergeResult(forReference: reference, suffix: "HDR")
        XCTAssertEqual(planned, "Day 2/DSC_0107-HDR-2.dng")

        // A stale sidecar left by a file that has gone, with nothing else.
        let stale = await catalog.sidecarURL(forRelPath: "Day 2/DSC_0107-HDR-2.dng")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8).write(to: stale)
        planned = try await catalog.planMergeResult(forReference: reference, suffix: "HDR")
        XCTAssertEqual(planned, "Day 2/DSC_0107-HDR-3.dng")

        // A row whose file has gone.
        let row = ImageRecord(id: nil, relPath: "Day 2/DSC_0107-HDR-3.dng", preservedName: nil, size: 1, mtime: 1,
                              xxhash: Data(count: 8), captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil,
                              shutter: nil, aperture: nil, focal: nil, width: nil, height: nil, orientation: nil,
                              rating: 0, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
        try await catalog.dbQueue.write { db in
            var inserted = row
            try inserted.insert(db)
        }
        planned = try await catalog.planMergeResult(forReference: reference, suffix: "HDR")
        XCTAssertEqual(planned, "Day 2/DSC_0107-HDR-4.dng")

        // The sidecar write agrees: it refuses every taken name and takes the planned one.
        for taken in ["Day 2/DSC_0107-HDR.dng", "Day 2/DSC_0107-HDR-2.dng", "Day 2/DSC_0107-HDR-3.dng"] {
            do {
                try await catalog.writeMergeSidecar(#"{"kind":"hdr"}"#, forRelPath: taken)
                XCTFail("\(taken) was written over")
            } catch FileOperations.NameProblem.taken {
            }
        }
        try await catalog.writeMergeSidecar(#"{"kind":"hdr"}"#, forRelPath: planned)
        let nextPlanned = try await catalog.planMergeResult(forReference: reference, suffix: "HDR")
        XCTAssertEqual(nextPlanned, "Day 2/DSC_0107-HDR-5.dng", "the waiting sidecar holds its name")
    }

    /// A merge whose DNG write found another file under its name takes its
    /// sidecar back even though a file is there: that file isn't the merge.
    func testASidecarBesideAFileThatTookTheNameCanBeDiscarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("latent-merge-discard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try Catalog.open(at: root)
        try await catalog.writeMergeSidecar(#"{"kind":"hdr"}"#, forRelPath: "A-HDR.dng")
        try Data("another app".utf8).write(to: root.appendingPathComponent("A-HDR.dng"))
        let sidecar = await catalog.sidecarURL(forRelPath: "A-HDR.dng")

        try await catalog.discardMergeSidecar(forRelPath: "A-HDR.dng")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "by default a file keeps its sidecar")
        try await catalog.discardMergeSidecar(forRelPath: "A-HDR.dng", fileTookTheName: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("A-HDR.dng").path))
    }
}
