import XCTest
import Combine
@testable import Catalog
import PixelEngine
@testable import latent_app

// The one batch-job queue (docs/Retouch.md §8) against a fake job: Remove
// Dust and Find Faces are tested in their own files. The photos are the
// tiny float DNGs of PhotoMergeTests, which the catalog opens like any raw.

/// A stand-in selection job that follows a script per photo and records
/// what it was given.
final class FakeSelectionJob: SelectionJob, @unchecked Sendable {
    enum Script: Sendable {
        /// Writes "{"schema":1,"dust":<count>}" with `count` spots.
        case write(count: Int)
        /// Leaves the photo alone, having counted `count`.
        case leave(count: Int)
        /// Clears the photo's edit.
        case clear
        /// Throws, so the photo is skipped with a note.
        case fail(String)
        /// Waits to be cancelled.
        case waitForCancel
    }

    private let lock = NSLock()
    private var scripts: [String: Script]
    private var _inputs: [SelectionJobInput] = []
    private var _gateOpen = true
    /// The one photo the closed gate holds; nil holds every photo.
    private var _heldName: String?
    private var _prepared = 0
    private var _processing = ""
    let prepareError: (any Error)?
    let note: String?

    init(_ scripts: [String: Script], prepareError: (any Error)? = nil, note: String? = nil) {
        self.scripts = scripts
        self.prepareError = prepareError
        self.note = note
    }

    /// What `process` was given, in order.
    var inputs: [SelectionJobInput] { lock.withLock { _inputs } }
    var prepared: Int { lock.withLock { _prepared } }
    /// The photo being processed, while the gate is closed.
    var processing: String { lock.withLock { _processing } }

    /// Holds `process` at its start until `openGate`: every photo's, or
    /// only `name`'s.
    func closeGate(for name: String? = nil) { lock.withLock { _gateOpen = false; _heldName = name } }
    func openGate() { lock.withLock { _gateOpen = true } }

    static func json(_ count: Int) -> String { "{\"schema\":1,\"dust\":\(count)}" }

    let title = "Dust removal"
    let outputKind = OutputJobs.Kind.dustRemoval
    let undoName = "Remove Dust"

    func prepare(gpu: GPUContext, progress: @Sendable (MergeProgress) -> Void) async throws {
        lock.withLock { _prepared += 1 }
        progress(MergeProgress(fraction: 0, stage: "Preparing"))
        if let prepareError { throw prepareError }
    }

    func process(_ input: SelectionJobInput, gpu: GPUContext) async throws -> SelectionJobResult {
        lock.withLock { _inputs.append(input); _processing = input.record.fileName }
        while lock.withLock({ !_gateOpen && (_heldName == nil || _heldName == input.record.fileName) }) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        switch lock.withLock({ scripts[input.record.fileName] }) ?? .leave(count: 0) {
        case .write(let count):
            return SelectionJobResult(newJSON: .some(Self.json(count)), count: count, note: note)
        case .leave(let count):
            return SelectionJobResult(newJSON: nil, count: count)
        case .clear:
            return SelectionJobResult(newJSON: .some(nil), count: 0)
        case .fail(let reason):
            throw Failure(reason: reason)
        case .waitForCancel:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
    }

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    func summary(changed: Int, counted: Int, skipped: Int, elapsed: TimeInterval) -> String {
        "Removed dust from \(changed) photos (\(counted) spots), \(skipped) skipped"
    }

    func announcement(changed: Int) -> String { "Dust removal finished: \(changed) photos" }
}

@MainActor
final class SelectionJobQueueTests: XCTestCase {
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
        XCTAssertEqual(made.records.count, 3, "the catalog opens the stand-in DNGs")
        return made
    }

    private func queue(_ jobs: OutputJobs = OutputJobs(), exports: ExportQueue = ExportQueue()) -> SelectionJobQueue {
        SelectionJobQueue(gpuSlot: exports, jobs: jobs)
    }

    private func stored(_ library: Library, _ name: String) async throws -> String? {
        let id = try XCTUnwrap(library.images.first { $0.fileName == name }?.id)
        return try await library.catalog!.storedEdit(forImageID: id)?.json
    }

    /// Every photo's result is written at the end, in one undo group,
    /// holding the GPU slot, a job and a keep-awake activity until then;
    /// the editor is told which photos changed, as after an undo.
    func testWritesThePhotosInOneUndoGroupAndReleasesTheSlot() async throws {
        let photos = try await photos()
        let manager = UndoManager()
        photos.library.undoManager = manager
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 3), "DSC_0107.dng": .write(count: 4),
                                    "DSC_0108.dng": .leave(count: 0)])
        let jobs = OutputJobs()
        let exports = ExportQueue()
        let queue = queue(jobs, exports: exports)
        let held = ExportActivity.activeCount
        var restored: [(Set<Int64>, Library.RestoredAspect)] = []
        photos.library.didRestoreImages = { restored.append(($0, $1)) }
        var seen: [MergeProgress] = []
        let watch = queue.$progress.dropFirst().sink { if let progress = $0 { seen.append(progress) } }
        defer { watch.cancel() }

        XCTAssertTrue(queue.start(job, records: photos.records, library: photos.library, gpu: gpu))
        XCTAssertTrue(queue.isRunning)
        XCTAssertEqual(queue.title, "Dust removal")
        XCTAssertEqual(jobs.running.map(\.kind), [.dustRemoval])
        XCTAssertEqual(jobs.running.map(\.name), ["DSC_0106.dng"])
        XCTAssertEqual(ExportActivity.activeCount, held + 1)
        XCTAssertTrue(exports.isGPUBusy, "exports wait")
        XCTAssertFalse(queue.start(job, records: photos.records, library: photos.library, gpu: gpu),
                       "one job at a time")

        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        XCTAssertEqual(job.prepared, 1)
        XCTAssertEqual(job.inputs.map(\.record.fileName), BracketFolder.names)
        XCTAssertEqual(job.inputs.map(\.storedJSON), [nil, nil, nil], "nothing was stored yet")
        XCTAssertEqual(job.inputs.map(\.fileURL.lastPathComponent), BracketFolder.names)
        let stored1 = try await stored(photos.library, "DSC_0106.dng")
        XCTAssertEqual(stored1, FakeSelectionJob.json(3))
        let stored2 = try await stored(photos.library, "DSC_0107.dng")
        XCTAssertEqual(stored2, FakeSelectionJob.json(4))
        let stored3 = try await stored(photos.library, "DSC_0108.dng")
        XCTAssertNil(stored3, "left alone")
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust (2 Images)")
        XCTAssertEqual(manager.groupingLevel, 0, "no group left open")
        XCTAssertEqual(queue.summary, "Removed dust from 2 photos (7 spots), 0 skipped")
        XCTAssertEqual(queue.notes, [])
        XCTAssertNil(photos.library.lastError)
        let ids = Set(photos.records.prefix(2).compactMap(\.id))
        XCTAssertEqual(restored.map(\.0), [ids], "the editor reloads a changed image")
        XCTAssertEqual(restored.map(\.1), [.edits])
        XCTAssertEqual(seen.map(\.stage), ["Preparing", "Photo 1 of 3: DSC_0106.dng", "Photo 2 of 3: DSC_0107.dng",
                                            "Photo 3 of 3: DSC_0108.dng", "Saving"])
        XCTAssertEqual(SelectionJobQueue.spokenProgress(seen[2]), "Photo 2 of 3: DSC_0107.dng, 33 percent")
        XCTAssertFalse(queue.isRunning)
        XCTAssertFalse(jobs.isRunning)
        XCTAssertFalse(exports.isGPUBusy)
        XCTAssertEqual(ExportActivity.activeCount, held)

        // One group: undo takes every photo back at once.
        manager.undo()
        await photos.library.waitForPendingWork()
        let stored4 = try await stored(photos.library, "DSC_0106.dng")
        XCTAssertNil(stored4)
        let stored5 = try await stored(photos.library, "DSC_0107.dng")
        XCTAssertNil(stored5)
        XCTAssertFalse(manager.canUndo)
    }

    /// The job reads the edit as stored, may clear it, and the user's own
    /// patches in a stored edit reach the job unchanged.
    func testTheStoredEditReachesTheJobAndCanBeCleared() async throws {
        let photos = try await photos()
        let existing = "{\"schema\":1,\"heals\":[{\"id\":\"A\"}]}"
        let id = try XCTUnwrap(photos.records[0].id)
        try await photos.library.saveEditStack(existing, schemaVersion: EditStack.schemaVersion,
                                               processVersion: EditStack.processVersion, forImageID: id)
        let job = FakeSelectionJob(["DSC_0106.dng": .clear, "DSC_0107.dng": .leave(count: 2)])
        let queue = queue()
        queue.start(job, records: photos.records, library: photos.library, gpu: gpu)
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        XCTAssertEqual(job.inputs.first?.storedJSON, existing)
        let stored6 = try await stored(photos.library, "DSC_0106.dng")
        XCTAssertNil(stored6, "cleared")
        XCTAssertEqual(queue.summary, "Removed dust from 1 photos (2 spots), 0 skipped",
                       "a photo left alone still counts what it found")
    }

    /// A photo the job can't read is noted and the others are still written.
    func testAPhotoThatFailsIsNotedAndTheOthersAreWritten() async throws {
        let photos = try await photos()
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 1), "DSC_0107.dng": .fail("the file is damaged"),
                                    "DSC_0108.dng": .write(count: 2)], note: "Sensitivity was lowered")
        let queue = queue()
        queue.start(job, records: photos.records, library: photos.library, gpu: gpu)
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        let stored7 = try await stored(photos.library, "DSC_0106.dng")
        XCTAssertEqual(stored7, FakeSelectionJob.json(1))
        let stored8 = try await stored(photos.library, "DSC_0107.dng")
        XCTAssertNil(stored8)
        let stored9 = try await stored(photos.library, "DSC_0108.dng")
        XCTAssertEqual(stored9, FakeSelectionJob.json(2))
        XCTAssertEqual(queue.notes, ["Sensitivity was lowered", "DSC_0107.dng couldn’t be read: the file is damaged",
                                     "Sensitivity was lowered"])
        XCTAssertEqual(queue.summary, "Removed dust from 2 photos (3 spots), 0 skipped")
        XCTAssertNil(photos.library.lastError, "a note, not an error")
    }

    /// Cancel from the panel (or quitting): the photos done are written,
    /// the rest are left, and no error is shown.
    func testCancelKeepsThePhotosDone() async throws {
        let photos = try await photos()
        let manager = UndoManager()
        photos.library.undoManager = manager
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 5), "DSC_0107.dng": .waitForCancel,
                                    "DSC_0108.dng": .write(count: 5)])
        let jobs = OutputJobs()
        let queue = queue(jobs)
        queue.start(job, records: photos.records, library: photos.library, gpu: gpu)
        await waitUntil("the second photo") { job.processing == "DSC_0107.dng" }

        let text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still removing sensor dust from photos")
        XCTAssertEqual(text.information, "Quitting now stops the dust removal, which keeps the photos already done.")
        jobs.cancelAll()
        await jobs.waitUntilDone()
        await photos.library.waitForPendingWork()
        XCTAssertFalse(queue.isRunning)
        let stored10 = try await stored(photos.library, "DSC_0106.dng")
        XCTAssertEqual(stored10, FakeSelectionJob.json(5))
        let stored11 = try await stored(photos.library, "DSC_0107.dng")
        XCTAssertNil(stored11)
        let stored12 = try await stored(photos.library, "DSC_0108.dng")
        XCTAssertNil(stored12, "never reached")
        XCTAssertEqual(job.inputs.map(\.record.fileName), ["DSC_0106.dng", "DSC_0107.dng"])
        XCTAssertEqual(queue.summary, "Dust removal cancelled · 1 photo kept")
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust")
        XCTAssertNil(photos.library.lastError)
        XCTAssertFalse(photos.library.hasPendingWork)
    }

    /// Cancelled before any photo is done: nothing is written and nothing filed.
    func testCancelWithNothingDoneWritesNothing() async throws {
        let photos = try await photos()
        let manager = UndoManager()
        photos.library.undoManager = manager
        let job = FakeSelectionJob(["DSC_0106.dng": .waitForCancel])
        let queue = queue()
        queue.start(job, records: photos.records, library: photos.library, gpu: gpu)
        await waitUntil("the first photo") { job.processing == "DSC_0106.dng" }
        queue.cancel()
        await queue.waitUntilDone()
        XCTAssertEqual(queue.summary, "Dust removal cancelled")
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(photos.library.hasPendingWork)
    }

    /// An edit the user makes after the job has read a photo stands: that
    /// photo is skipped and named, the others are written.
    func testAPhotoEditedMeanwhileIsSkippedAndNoted() async throws {
        let photos = try await photos()
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 1), "DSC_0107.dng": .write(count: 2),
                                    "DSC_0108.dng": .write(count: 3)])
        job.closeGate(for: "DSC_0107.dng")
        let queue = queue()
        var restored: [Set<Int64>] = []
        photos.library.didRestoreImages = { ids, _ in restored.append(ids) }
        queue.start(job, records: photos.records, library: photos.library, gpu: gpu)
        await waitUntil("the second photo") { job.processing == "DSC_0107.dng" }
        // The job has read the second photo's edit (none); the user edits
        // it while the job works on it.
        XCTAssertEqual(job.inputs.last?.storedJSON, nil)
        let meanwhile = "{\"schema\":1,\"exposure\":1}"
        let id = try XCTUnwrap(photos.records[1].id)
        try await photos.library.saveEditStack(meanwhile, schemaVersion: EditStack.schemaVersion,
                                               processVersion: EditStack.processVersion, forImageID: id)
        job.openGate()
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        let stored13 = try await stored(photos.library, "DSC_0106.dng")
        XCTAssertEqual(stored13, FakeSelectionJob.json(1))
        let stored14 = try await stored(photos.library, "DSC_0107.dng")
        XCTAssertEqual(stored14, meanwhile, "the user's edit stands")
        let stored15 = try await stored(photos.library, "DSC_0108.dng")
        XCTAssertEqual(stored15, FakeSelectionJob.json(3))
        XCTAssertEqual(queue.notes, ["DSC_0107.dng was edited while dust removal ran, so it was left alone"])
        XCTAssertEqual(queue.summary, "Removed dust from 2 photos (4 spots), 1 skipped")
        XCTAssertEqual(restored, [Set([photos.records[0].id!, photos.records[2].id!])])
    }

    /// A photo removed from the folder while the job runs is left alone.
    func testAPhotoNoLongerListedIsSkipped() async throws {
        let photos = try await photos()
        var records = photos.records
        var gone = records[2]
        gone.id = 424_242
        records[2] = gone
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 1), "DSC_0108.dng": .write(count: 1)])
        let queue = queue()
        queue.start(job, records: records, library: photos.library, gpu: gpu)
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        XCTAssertEqual(queue.notes, ["image 424242 is no longer in the folder, so it was left alone"])
        XCTAssertEqual(queue.summary, "Removed dust from 1 photos (1 spots), 1 skipped")
    }

    /// A job whose preparation fails does nothing and says why in the status bar.
    func testAFailedPrepareReportsAndWritesNothing() async throws {
        let photos = try await photos()
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 1)],
                                   prepareError: FakeSelectionJob.Failure(reason: "the reference photo has no dust"))
        let jobs = OutputJobs()
        let queue = queue(jobs)
        queue.start(job, records: photos.records, library: photos.library, gpu: gpu)
        await queue.waitUntilDone()
        XCTAssertEqual(job.inputs.count, 0)
        XCTAssertEqual(photos.library.lastError, "Dust removal failed: the reference photo has no dust")
        XCTAssertEqual(queue.summary, "")
        XCTAssertFalse(jobs.isRunning)
        XCTAssertFalse(queue.gpuSlot.isGPUBusy)
    }

    /// An export holding the GPU refuses the job; so does an empty
    /// selection or a closed folder; and the job takes the slot from exports.
    func testTheJobTakesTurnsWithExports() async throws {
        let photos = try await photos()
        let exports = ExportQueue()
        XCTAssertTrue(exports.claimSlot())
        let jobs = OutputJobs()
        let queue = queue(jobs, exports: exports)
        let job = FakeSelectionJob([:])
        XCTAssertFalse(queue.start(job, records: photos.records, library: photos.library, gpu: gpu))
        XCTAssertFalse(queue.isRunning)
        XCTAssertFalse(jobs.isRunning)
        exports.releaseSlot()
        XCTAssertFalse(queue.start(job, records: [], library: photos.library, gpu: gpu), "nothing to do")
        XCTAssertFalse(exports.isGPUBusy, "nothing taken")
        XCTAssertFalse(queue.start(job, records: photos.records, library: Library(), gpu: gpu), "no folder open")
        XCTAssertFalse(exports.isGPUBusy)
        XCTAssertEqual(job.prepared, 0)
    }

    /// Between photos the worker waits while memory pressure is critical,
    /// rather than open the next raw in the middle of a shortage.
    func testPausesBetweenPhotosAtCriticalMemoryPressure() async throws {
        let photos = try await photos()
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 1), "DSC_0107.dng": .write(count: 1),
                                    "DSC_0108.dng": .write(count: 1)])
        job.closeGate()
        let queue = queue()
        queue.start(job, records: photos.records, library: photos.library, gpu: gpu)
        await waitUntil("the first photo") { job.processing == "DSC_0106.dng" }
        queue.setMemoryPressure(.critical)
        job.openGate()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(job.inputs.map(\.record.fileName), ["DSC_0106.dng"], "the second photo waits")
        XCTAssertTrue(queue.isRunning)
        queue.setMemoryPressure(.normal)
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        XCTAssertEqual(job.inputs.map(\.record.fileName), BracketFolder.names)
        XCTAssertEqual(queue.summary, "Removed dust from 3 photos (3 spots), 0 skipped")
    }

    /// A cancel while paused for memory still commits the photos done.
    func testCancelWhilePausedKeepsThePhotosDone() async throws {
        let photos = try await photos()
        let job = FakeSelectionJob(["DSC_0106.dng": .write(count: 1), "DSC_0107.dng": .write(count: 1)])
        job.closeGate()
        let queue = queue()
        queue.start(job, records: photos.records, library: photos.library, gpu: gpu)
        await waitUntil("the first photo") { job.processing == "DSC_0106.dng" }
        queue.setMemoryPressure(.critical)
        job.openGate()
        try await Task.sleep(for: .milliseconds(100))
        queue.cancel()
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        let stored16 = try await stored(photos.library, "DSC_0106.dng")
        XCTAssertEqual(stored16, FakeSelectionJob.json(1))
        let stored17 = try await stored(photos.library, "DSC_0107.dng")
        XCTAssertNil(stored17)
        XCTAssertEqual(queue.summary, "Dust removal cancelled · 1 photo kept")
    }
}
