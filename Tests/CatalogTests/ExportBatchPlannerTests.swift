import XCTest
@testable import Catalog

final class ExportBatchPlannerTests: XCTestCase {
    private func record(_ relPath: String, captured: Int64 = 1_789_321_260) -> ImageRecord {
        ImageRecord(id: 1, relPath: relPath, preservedName: nil, size: 1, mtime: 1_700_000_000_000,
                    xxhash: Data(count: 8), captureTime: captured, camera: nil, lens: nil, lensId: nil,
                    iso: nil, shutter: nil, aperture: nil, focal: nil, width: nil, height: nil,
                    orientation: nil, rating: 0, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    private let out = URL(fileURLWithPath: "/out", isDirectory: true)

    /// A disk holding `files` and `folders` (absolute paths), case-insensitive
    /// unless asked, as APFS usually is.
    private func probe(files: [String] = [], folders: [String] = [], caseSensitive: Bool = false)
        -> ExportBatchPlanner.Probe {
        @Sendable func fold(_ s: String) -> String {
            let n = s.precomposedStringWithCanonicalMapping
            return caseSensitive ? n : n.lowercased()
        }
        let fileSet = Set(files.map(fold)), folderSet = Set(folders.map(fold))
        return ExportBatchPlanner.Probe(
            item: { url in
                let key = fold(url.path)
                return folderSet.contains(key) ? .folder : fileSet.contains(key) ? .file : nil
            },
            isCaseSensitive: { _ in caseSensitive })
    }

    private func options(_ template: String = "{name}", _ collision: ExportNaming.Collision = .addNumber,
                         dateSubfolders: Bool = false) -> ExportBatchPlanner.Options {
        .init(template: template, fileExtension: "jpg", collision: collision, dateSubfolders: dateSubfolders,
              catalogName: "Shoot", timeZone: TimeZone(identifier: "UTC")!)
    }

    private func names(_ plan: ExportBatchPlan) -> [String] { plan.outputs.map { $0.relativePath(to: out) } }

    /// Two images whose template gives one name (same file name in two
    /// included subfolders) never overwrite each other, whatever the policy.
    func testSameNameWithinTheBatchIsNumberedUnderEveryPolicy() {
        let records = [record("A/DSC_1.NEF"), record("B/DSC_1.NEF"), record("C/dsc_1.NEF"), record("D/DSC_2.NEF")]
        for collision in ExportNaming.Collision.allCases {
            let plan = ExportBatchPlanner.plan(records, into: out, options: options("{name}", collision), probe: probe())
            XCTAssertEqual(names(plan), ["DSC_1.jpg", "DSC_1-1.jpg", "dsc_1-2.jpg", "DSC_2.jpg"], "\(collision)")
            XCTAssertEqual(plan.outputs.map(\.action), [.write, .write, .write, .write])
            XCTAssertEqual(plan.sharedNameCount, 2)
            XCTAssertEqual(plan.existingCount, 0)
        }
    }

    func testCaseSensitiveVolumesKeepCaseOnlyDifferencesApart() {
        let records = [record("A/DSC_1.NEF"), record("B/dsc_1.NEF")]
        let plan = ExportBatchPlanner.plan(records, into: out, options: options(),
                                           probe: probe(caseSensitive: true))
        XCTAssertEqual(names(plan), ["DSC_1.jpg", "dsc_1.jpg"])
    }

    func testNamesDifferingOnlyInUnicodeNormalisationClash() {
        let records = [record("A/caf\u{E9}.NEF"), record("B/cafe\u{301}.NEF")]
        let plan = ExportBatchPlanner.plan(records, into: out, options: options(), probe: probe(caseSensitive: true))
        XCTAssertEqual(plan.outputs[1].url.lastPathComponent, "cafe\u{301}-1.jpg")
        XCTAssertTrue(plan.outputs[1].sharesName)
    }

    func testExistingFilesFollowThePolicy() {
        let records = [record("DSC_1.NEF"), record("DSC_2.NEF")]
        let disk = probe(files: ["/out/DSC_1.jpg", "/out/DSC_1-1.jpg"])

        let numbered = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .addNumber), probe: disk)
        XCTAssertEqual(names(numbered), ["DSC_1-2.jpg", "DSC_2.jpg"])
        XCTAssertEqual(numbered.existingCount, 1)

        let replaced = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .replace), probe: disk)
        XCTAssertEqual(names(replaced), ["DSC_1.jpg", "DSC_2.jpg"])
        XCTAssertEqual(replaced.outputs.map(\.action), [.replace, .write])
        XCTAssertEqual(replaced.count(.replace), 1)

        let skipped = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .skip), probe: disk)
        XCTAssertEqual(skipped.outputs.map(\.action), [.skip, .write])
        XCTAssertEqual(skipped.count(.skip), 1)
    }

    /// Exporting the same batch again with Replace replaces the files the
    /// first export wrote, numbered ones included, instead of adding more.
    func testReexportingWithReplaceGivesTheSameNames() {
        let records = [record("A/DSC_1.NEF"), record("B/DSC_1.NEF")]
        let first = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .replace), probe: probe())
        XCTAssertEqual(names(first), ["DSC_1.jpg", "DSC_1-1.jpg"])
        let again = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .replace),
                                            probe: probe(files: ["/out/DSC_1.jpg", "/out/DSC_1-1.jpg"]))
        XCTAssertEqual(names(again), ["DSC_1.jpg", "DSC_1-1.jpg"])
        XCTAssertEqual(again.outputs.map(\.action), [.replace, .replace])
        // Skip skips both, rather than writing a numbered copy of the second.
        let skip = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .skip),
                                           probe: probe(files: ["/out/DSC_1.jpg", "/out/DSC_1-1.jpg"]))
        XCTAssertEqual(skip.outputs.map(\.action), [.skip, .skip])
    }

    func testAFolderIsNeverReplaced() {
        let records = [record("DSC_1.NEF")]
        let disk = probe(folders: ["/out/DSC_1.jpg"])
        let replaced = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .replace), probe: disk)
        guard case .fail = replaced.outputs[0].action else { return XCTFail("a folder must not be replaced") }
        XCTAssertEqual(replaced.failures.count, 1)
        let numbered = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .addNumber), probe: disk)
        XCTAssertEqual(names(numbered), ["DSC_1-1.jpg"])
    }

    func testDateSubfoldersKeepNamesApartPerFolder() {
        let day1: Int64 = 1_789_321_260, day2 = day1 + 86_400
        let records = [record("A.NEF", captured: day1), record("A.NEF", captured: day2),
                       record("x/A.NEF", captured: day1)]
        let plan = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .replace, dateSubfolders: true),
                                           probe: probe(files: ["/out/2026-09-14/A.jpg"]))
        XCTAssertEqual(names(plan), ["2026-09-13/A.jpg", "2026-09-14/A.jpg", "2026-09-13/A-1.jpg"])
        XCTAssertEqual(plan.outputs.map(\.action), [.write, .replace, .write])

        // A file where the date folder should go fails those images only.
        let blocked = ExportBatchPlanner.plan(records, into: out, options: options(dateSubfolders: true),
                                              probe: probe(files: ["/out/2026-09-13"]))
        XCTAssertEqual(blocked.failures.map(\.index), [0, 2])
        XCTAssertEqual(blocked.outputs[1].action, .write)
    }

    func testTheFirstFileAndUnknownTokensComeFromThePlan() {
        let records = [record("DSC_1.NEF")]
        let plan = ExportBatchPlanner.plan(records, into: out, options: options("{nmae}_{seq}"), probe: .nothingOnDisk)
        XCTAssertEqual(plan.unknownTokens, ["{nmae}"])
        XCTAssertEqual(names(plan), ["{nmae}_001.jpg"])
    }

    /// A thousand images all named by their capture date are numbered in
    /// one pass, not by counting up from 1 for each.
    func testManySameNamesPlanQuickly() {
        let records = (0..<3000).map { record("IMG_\($0).NEF") }
        let clock = ContinuousClock()
        var plan: ExportBatchPlan?
        let elapsed = clock.measure {
            plan = ExportBatchPlanner.plan(records, into: out, options: options("{date}"), probe: probe())
        }
        XCTAssertEqual(plan?.outputs.last?.url.lastPathComponent, "2026-09-13-2999.jpg")
        XCTAssertEqual(Set(plan?.outputs.map(\.url) ?? []).count, 3000)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    /// A file can also take the name while the image renders; the commit
    /// then refuses to replace it and the queue settles the same output
    /// again, which must move on to the next free name (or skip) each time.
    func testRecheckAgainAfterAFileTookTheSettledName() {
        let records = [record("A.NEF"), record("B.NEF")]
        var plan = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .addNumber), probe: probe())
        XCTAssertEqual(plan.recheck(0, probe: probe(files: ["/out/A.jpg"])).url.lastPathComponent, "A-1.jpg")
        let again = plan.recheck(0, probe: probe(files: ["/out/A.jpg", "/out/A-1.jpg"]))
        XCTAssertEqual(again.url.lastPathComponent, "A-2.jpg")
        XCTAssertEqual(again.action, .write)

        var skip = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .skip), probe: probe())
        XCTAssertEqual(skip.recheck(0, probe: probe()).action, .write)
        XCTAssertEqual(skip.recheck(0, probe: probe(files: ["/out/A.jpg"])).action, .skip)
    }

    /// Just before writing, the queue looks again: a file that appeared
    /// under a planned name meanwhile is numbered, replaced or skipped as
    /// the policy says, and never takes a name promised to another output.
    func testRecheckSettlesFilesThatAppearedAfterPlanning() {
        let records = [record("A.NEF"), record("B.NEF"), record("A-1.NEF")]
        var plan = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .addNumber), probe: probe())
        XCTAssertEqual(names(plan), ["A.jpg", "B.jpg", "A-1.jpg"])
        let later = probe(files: ["/out/A.jpg"])
        XCTAssertEqual(plan.recheck(0, probe: later).url.lastPathComponent, "A-2.jpg",
                       "A-1.jpg is promised to the third image")
        XCTAssertEqual(plan.recheck(1, probe: later).action, .write)

        var skip = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .skip), probe: probe())
        XCTAssertEqual(skip.recheck(0, probe: later).action, .skip)
        var replace = ExportBatchPlanner.plan(records, into: out, options: options("{name}", .replace), probe: probe())
        XCTAssertEqual(replace.recheck(0, probe: later).action, .replace)
        guard case .fail = replace.recheck(1, probe: probe(folders: ["/out/B.jpg"])).action else {
            return XCTFail("a folder that appeared must not be replaced")
        }
    }

    /// The real probe, on a real folder.
    func testSystemProbeOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("B.jpg"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("A.jpg"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("C.jpg"),
                                                   withDestinationURL: folder.appendingPathComponent("gone"))
        let probe = ExportBatchPlanner.Probe.system
        XCTAssertEqual(probe.item(folder.appendingPathComponent("A.jpg")), .file)
        XCTAssertEqual(probe.item(folder.appendingPathComponent("B.jpg")), .folder)
        XCTAssertEqual(probe.item(folder.appendingPathComponent("C.jpg")), .file, "a broken link still holds the name")
        XCTAssertNil(probe.item(folder.appendingPathComponent("D.jpg")))

        let plan = ExportBatchPlanner.plan([record("A.NEF"), record("x/A.NEF"), record("B.NEF")], into: folder,
                                           options: options())
        XCTAssertEqual(plan.outputs.map(\.url.lastPathComponent), ["A-1.jpg", "A-2.jpg", "B-1.jpg"])
    }
}
