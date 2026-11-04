import XCTest
@testable import Catalog
import PixelEngine
@testable import latent_app

/// Pause and Resume on the background queues, and the Activity popover's
/// rows. The selection job runs `FakeSelectionJob` over the stand-in DNGs
/// of SelectionJobQueueTests.
@MainActor
final class JobPauseTests: XCTestCase {
    nonisolated(unsafe) var folder: BracketFolder?
    nonisolated(unsafe) var gpuContext: GPUContext?

    override func setUp() async throws {
        gpuContext = try await GPUContext.shared()
    }

    override func tearDown() async throws {
        await MainActor.run { folder?.remove() }
    }

    private var gpu: GPUContext { gpuContext! }

    private func photos() async throws -> BracketFolder {
        let made = try await BracketFolder.make()
        folder = made
        return made
    }

    private func stored(_ library: Library, _ name: String) async throws -> String? {
        let id = try XCTUnwrap(library.images.first { $0.fileName == name }?.id)
        return try await library.catalog!.storedEdit(forImageID: id)?.json
    }

    /// Pausing lets the photo under way finish and holds the next; Resume
    /// carries on and the job ends as if never paused.
    func testPauseHoldsBetweenPhotosAndResumeCarriesOn() async throws {
        let photos = try await photos()
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 1), "DSC_0107.dng": .write(count: 1),
                                    "DSC_0108.dng": .write(count: 1)])
        job.closeGate()
        let exports = ExportQueue()
        let queue = SelectionJobQueue(gpuSlot: exports, jobs: OutputJobs())
        XCTAssertTrue(queue.start(job, records: photos.records, library: photos.library, gpu: gpu))
        await waitUntil("the first photo") { job.processing == "DSC_0106.dng" }
        queue.pause()
        XCTAssertTrue(queue.isPaused)
        job.openGate()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(job.inputs.map(\.record.fileName), ["DSC_0106.dng"], "the second photo waits")
        XCTAssertTrue(queue.isRunning)
        XCTAssertTrue(exports.isGPUBusy, "a paused job keeps the GPU slot")
        let rows = BackgroundActivity.rows(library: photos.library, exportQueue: exports,
                                           photoMerge: PhotoMergeQueue(gpuSlot: exports),
                                           selectionJobs: queue, outputJobs: OutputJobs(), autoImport: nil)
        XCTAssertEqual(rows.map(\.id), ["selection"])
        XCTAssertEqual(rows.first?.stateLabel, "Paused")
        XCTAssertNotNil(rows.first?.setPaused)

        queue.resume()
        XCTAssertFalse(queue.isPaused)
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        XCTAssertEqual(job.inputs.map(\.record.fileName), BracketFolder.names)
        XCTAssertEqual(queue.summary, "Removed dust from 3 photos (3 spots), 0 skipped")
        XCTAssertFalse(queue.isPaused)
        XCTAssertFalse(exports.isGPUBusy)
    }

    /// Cancel (as quitting or a folder change does) stops a paused job
    /// without resuming it, and commits the photos already done.
    func testCancelWhilePausedCommitsThePhotosDone() async throws {
        let photos = try await photos()
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 1), "DSC_0107.dng": .write(count: 1)])
        job.closeGate()
        let queue = SelectionJobQueue(gpuSlot: ExportQueue(), jobs: OutputJobs())
        queue.start(job, records: photos.records, library: photos.library, gpu: gpu)
        await waitUntil("the first photo") { job.processing == "DSC_0106.dng" }
        queue.pause()
        job.openGate()
        try await Task.sleep(for: .milliseconds(200))
        queue.cancel()
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        let first = try await stored(photos.library, "DSC_0106.dng")
        XCTAssertEqual(first, FakeSelectionJob.json(1))
        let second = try await stored(photos.library, "DSC_0107.dng")
        XCTAssertNil(second)
        XCTAssertEqual(queue.summary, "Dust removal cancelled · 1 photo kept")
        XCTAssertFalse(queue.isPaused, "nothing runs, so nothing is paused")
    }

    /// A paused export writes nothing more until Resume, then finishes the
    /// batch; originals are copied, so no rendering is needed.
    func testExportPausesBetweenFilesAndResumes() async throws {
        let photos = try await photos()
        let out = photos.base.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var preset = ExportPreset()
        preset.fileKind = .original
        preset.revealWhenDone = false
        let exports = ExportQueue(outputJobs: OutputJobs())
        exports.start(records: photos.records, library: photos.library, preset: preset, destination: out, gpu: gpu)
        XCTAssertTrue(exports.isRunning)
        // Before the loop's first file.
        exports.pause()
        XCTAssertTrue(exports.isPaused)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(exports.done, 0, "nothing is written while paused")
        XCTAssertTrue(exports.isRunning)
        exports.resume()
        await waitUntil("the export") { !exports.isRunning }
        XCTAssertEqual(exports.done, 3, exports.failures.map(\.reason).joined(separator: "; "))
        XCTAssertFalse(exports.isPaused)
    }

    /// Cancelled while paused (quitting does the same), the export stops
    /// without writing the files it hadn't reached.
    func testExportCancelledWhilePausedStops() async throws {
        let photos = try await photos()
        let out = photos.base.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var preset = ExportPreset()
        preset.fileKind = .original
        preset.revealWhenDone = false
        let exports = ExportQueue(outputJobs: OutputJobs())
        exports.start(records: photos.records, library: photos.library, preset: preset, destination: out, gpu: gpu)
        exports.pause()
        try await Task.sleep(for: .milliseconds(200))
        await exports.stopAfterCurrentFile()
        XCTAssertFalse(exports.isRunning)
        XCTAssertFalse(exports.isPaused)
        XCTAssertEqual(exports.done, 0)
        XCTAssertTrue(exports.summary.contains("(cancelled)"), exports.summary)
    }

    /// Pause does nothing when nothing runs.
    func testPauseWhileIdleIsIgnored() {
        let exports = ExportQueue()
        exports.pause()
        XCTAssertFalse(exports.isPaused)
        let queue = SelectionJobQueue(gpuSlot: exports, jobs: OutputJobs())
        queue.pause()
        XCTAssertFalse(queue.isPaused)
    }

    /// The popover lists prints and contact sheets from `OutputJobs`, with
    /// Cancel where they have one and no Pause; idle queues list nothing.
    func testActivityRowsListOutputJobs() {
        let library = Library()
        let exports = ExportQueue()
        let outputs = OutputJobs()
        let photoMerge = PhotoMergeQueue(gpuSlot: exports)
        let selection = SelectionJobQueue(gpuSlot: exports, jobs: outputs)
        func rows() -> [ActivityRow] {
            BackgroundActivity.rows(library: library, exportQueue: exports, photoMerge: photoMerge,
                                    selectionJobs: selection, outputJobs: outputs, autoImport: nil)
        }
        XCTAssertTrue(rows().isEmpty)
        var cancelled = false
        let sheet = outputs.begin(.contactSheet, name: "Sheet.pdf", cancel: { cancelled = true })
        let print = outputs.begin(.print, name: "12 Photos")
        let listed = rows()
        XCTAssertEqual(listed.map(\.title), ["Contact sheet", "Print"])
        XCTAssertEqual(listed.map(\.detail), ["Sheet.pdf", "12 Photos"])
        XCTAssertTrue(listed.allSatisfy { $0.setPaused == nil && $0.state == .running })
        XCTAssertNil(listed[1].cancel, "a print can only be waited for")
        listed[0].cancel?()
        XCTAssertTrue(cancelled)
        outputs.end(sheet)
        outputs.end(print)
        XCTAssertTrue(rows().isEmpty)
    }
}
