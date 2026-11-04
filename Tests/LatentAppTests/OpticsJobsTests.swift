import XCTest
@testable import Catalog
import PixelEngine
@testable import latent_app

/// Photo › Flat-Field Correction… and the pasted Upright Mode's analysis
/// (FlatFieldSheet.swift, OpticsJobs.swift).
@MainActor
final class OpticsJobsTests: XCTestCase {
    private func record(_ name: String, id: Int64) -> ImageRecord {
        var r = ImageRecord(relPath: name, size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
        r.id = id
        return r
    }

    func testCommandIsEnabledLikeRemoveDust() {
        var state = CommandState()
        state.mode = .library
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 3
        state.editorReady = true
        XCTAssertTrue(state.isEnabled(.flatFieldCorrection))
        var busy = state
        busy.exportQueueRunning = true
        XCTAssertFalse(busy.isEnabled(.flatFieldCorrection))
        var none = state
        none.selectionCount = 0
        XCTAssertFalse(none.isEnabled(.flatFieldCorrection))
        var typing = state
        typing.isEditingText = true
        XCTAssertFalse(typing.isEnabled(.flatFieldCorrection))
    }

    /// The reference is picked among the selection (or a file), and is
    /// never one of the photos the correction is written to.
    func testSheetPicksTheReferenceAmongTheSelection() {
        let folder = URL(fileURLWithPath: "/tmp/shoot")
        let names = ["DSC_1.NEF", "DSC_2.NEF", "FLAT_3.NEF"]
        let sheet = FlatFieldSheetModel(records: names.enumerated().map { record($1, id: Int64($0 + 1)) },
                                        urls: names.map { folder.appendingPathComponent($0) })
        XCTAssertEqual(sheet.referenceIndex, 2, "a file named as a flat is taken as the reference")
        XCTAssertEqual(sheet.targets.map(\.fileName), ["DSC_1.NEF", "DSC_2.NEF"])
        XCTAssertTrue(sheet.canApply)
        sheet.referenceIndex = nil
        XCTAssertFalse(sheet.canApply)
        sheet.referenceFile = URL(fileURLWithPath: "/tmp/elsewhere/diffuser.dng")
        XCTAssertEqual(sheet.targets.count, 3)
        sheet.amount = 40
        XCTAssertEqual(sheet.job()?.amount ?? 0, 0.4, accuracy: 1e-6)
    }

    func testUprightJobTargetsAndWording() {
        var p = EditParameters()
        XCTAssertFalse(UprightAnalysisJob.needsAnalysis(EditStack(parameters: p)))
        p.perspective.upright = UprightCorrection(mode: .vertical)
        XCTAssertTrue(UprightAnalysisJob.needsAnalysis(EditStack(parameters: p)))
        p.perspective.upright = UprightCorrection(mode: .vertical, matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        XCTAssertFalse(UprightAnalysisJob.needsAnalysis(EditStack(parameters: p)), "it has its correction")
        p.perspective.upright = UprightCorrection(mode: .guided)
        XCTAssertFalse(UprightAnalysisJob.needsAnalysis(EditStack(parameters: p)), "nothing to analyse")

        let job = UprightAnalysisJob()
        XCTAssertEqual(job.outputKind, .batchEdit)
        XCTAssertEqual(job.summary(changed: 3, counted: 3, skipped: 1, elapsed: 4), "Upright analysed on 3 photos · 1 skipped")
        XCTAssertEqual(FlatFieldJob(referenceURL: URL(fileURLWithPath: "/tmp/f.NEF"), amount: 1)
            .summary(changed: 1, counted: 1, skipped: 0, elapsed: 1), "Flat-field correction applied to 1 photo")
        let running = OutputJobs.Job(kind: .batchEdit, name: "DSC_1.NEF", cancel: nil,
                                     activity: ExportActivity(reason: "test"))
        defer { running.activity.end() }
        XCTAssertEqual(OutputJobs.quitAlert(for: [running]).message, "Latent is still updating the edits of photos")
    }

    /// On a real raw: a pasted mode without a matrix gets this photo's own
    /// correction, or a note when the picture has no lines to go by.
    func testUprightJobAnalysesTheRealPhoto() async throws {
        let url = URL(fileURLWithPath: try TestAssets.d750Path())
        let gpu = try GPUContext()
        var p = EditParameters()
        p.perspective.upright = UprightCorrection(mode: .auto)
        let json = try EditStack(parameters: p).encodeJSON()
        let input = SelectionJobInput(record: record(url.lastPathComponent, id: 1), fileURL: url, storedJSON: json)
        let result = try await UprightAnalysisJob().process(input, gpu: gpu)
        if let written = result.newJSON, let text = written {
            let stack = try EditStack.decode(json: text)
            XCTAssertEqual(stack.modules.perspective?.upright?.mode, .auto)
            XCTAssertEqual(stack.modules.perspective?.upright?.matrix?.count, 9)
            XCTAssertEqual(stack.frame, EditStack.activeAreaFrame)
        } else {
            XCTAssertNotNil(result.note, "left alone only with a note saying why")
        }
        // Nothing waiting: left alone.
        let done = SelectionJobInput(record: record("x", id: 2), fileURL: url,
                                     storedJSON: try EditStack(parameters: EditParameters()).encodeJSON())
        let untouched = try await UprightAnalysisJob().process(done, gpu: gpu)
        XCTAssertTrue(untouched.newJSON == nil)
    }
}
