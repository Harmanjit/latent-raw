import XCTest
import Combine
@testable import Catalog
import PixelEngine
import RawCore
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

    /// A job's result names the frame its geometry is measured on: a
    /// stack whose only module was a pasted touch-up has none, and read
    /// back on a bordered camera its boxes would otherwise be moved.
    func testAJobResultNamesTheActiveAreaFrame() throws {
        var pasted = TouchUp()
        pasted.skinSmoothing = 40
        pasted.faces = [TouchUpFace(boundingBox: SIMD4(0.5, 0.4, 0.2, 0.3))]
        pasted.blemishes = [HealPatch(target: [0.55, 0.45], source: [0.6, 0.45], radius: 0.01)]
        var stack = EditStack()
        stack.modules.touchup = pasted
        XCTAssertNil(stack.frame, "as the Library paste writes it")

        let result = try SelectionJobResult.writing(stack, count: 1)
        let json = try XCTUnwrap(result.newJSON ?? nil)
        let written = try EditStack.decode(json: json)
        XCTAssertEqual(written.frame, EditStack.activeAreaFrame)
        XCTAssertEqual(result.count, 1)
        // A readout 140 columns wider than the picture on the left.
        let bordered = SensorActiveArea(left: 140, top: 0, width: 5860, height: 4000, fullWidth: 6000, fullHeight: 4000)
        let read = written.migratingGeometry(to: bordered)
        XCTAssertEqual(read.modules.touchup?.faces.map(\.boundingBox), pasted.faces.map(\.boundingBox))
        XCTAssertEqual(read.modules.touchup?.blemishes, pasted.blemishes)
        let unnamed = stack.migratingGeometry(to: bordered)
        XCTAssertNotEqual(unnamed.modules.touchup?.faces.map(\.boundingBox), pasted.faces.map(\.boundingBox),
                          "without the name the boxes move")
    }
}

// MARK: - Remove Dust on the queue

/// A folder of synthetic "dirty sensor" photos (`DustDNG`): two from a
/// Nikon D750 and one from a Canon, all with the same dust, which the
/// catalog opens like any raw.
@MainActor
struct DustFolder {
    static let names = ["DSC_0201.dng", "DSC_0202.dng", "IMG_0203.dng"]

    let base: URL
    let root: URL
    let library: Library

    static func make() async throws -> DustFolder {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-remove-dust-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Dusty", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DustDNG.write(to: root.appendingPathComponent(names[0]), seed: 1)
        try DustDNG.write(to: root.appendingPathComponent(names[1]), seed: 2)
        try DustDNG.write(to: root.appendingPathComponent(names[2]), make: "Canon", model: "EOS R5", seed: 3)
        let library = Library()
        try await library.open(folder: root, defaultSubfolderMode: .independent)
        return DustFolder(base: base, root: root, library: library)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    var records: [ImageRecord] {
        Self.names.compactMap { name in library.images.first { $0.fileName == name } }
    }

    var store: DustMapStore { DustMapStore(url: base.appendingPathComponent("dust-maps.json")) }

    /// A map of the discs for the Nikon, as a reference photo would give.
    var nikonMap: DustMap {
        let short = Float(min(DustDNG.width, DustDNG.height))
        return DustMap(camera: "Nikon D750", sensorSize: SIMD2(DustDNG.width, DustDNG.height), referenceName: "sky.dng",
                       spots: DustDNG.spots.map {
                           DustMapSpot(centre: $0.centre / DustDNG.sensorSize, radius: $0.radius / short, contrast: 0.5)
                       })
    }
}

/// A real job with a gate before each photo, so a test can hold the
/// queue between photos and cancel it there.
final class GatedJob: SelectionJob, @unchecked Sendable {
    let job: DustRemovalJob
    private let lock = NSLock()
    private var _gateOpen = true
    private var _heldName: String?
    private var _processing = ""

    init(_ job: DustRemovalJob) { self.job = job }

    var processing: String { lock.withLock { _processing } }
    func closeGate(for name: String) { lock.withLock { _gateOpen = false; _heldName = name } }
    func openGate() { lock.withLock { _gateOpen = true } }

    var title: String { job.title }
    var outputKind: OutputJobs.Kind { job.outputKind }
    var undoName: String { job.undoName }

    func prepare(gpu: GPUContext, progress: @Sendable (MergeProgress) -> Void) async throws {
        try await job.prepare(gpu: gpu, progress: progress)
    }

    func process(_ input: SelectionJobInput, gpu: GPUContext) async throws -> SelectionJobResult {
        lock.withLock { _processing = input.record.fileName }
        while lock.withLock({ !_gateOpen && _heldName == input.record.fileName }) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        return try await job.process(input, gpu: gpu)
    }

    func summary(changed: Int, counted: Int, skipped: Int, elapsed: TimeInterval) -> String {
        job.summary(changed: changed, counted: counted, skipped: skipped, elapsed: elapsed)
    }

    func announcement(changed: Int) -> String { job.announcement(changed: changed) }
}

@MainActor
final class DustRemovalJobTests: XCTestCase {
    nonisolated(unsafe) var folder: DustFolder?
    nonisolated(unsafe) var gpuContext: GPUContext?

    override func setUp() async throws {
        gpuContext = try await GPUContext.shared()
        folder = try await DustFolder.make()
        XCTAssertEqual(folder?.records.count, 3, "the catalog opens the stand-in DNGs")
    }

    override func tearDown() async throws {
        await MainActor.run { folder?.remove() }
    }

    private var gpu: GPUContext { gpuContext! }
    private var photos: DustFolder { folder! }

    private func stored(_ name: String) async throws -> EditStack? {
        let id = try XCTUnwrap(photos.library.images.first { $0.fileName == name }?.id)
        guard let json = try await photos.library.catalog!.storedEdit(forImageID: id)?.json else { return nil }
        return try EditStack.decode(json: json)
    }

    private func run(_ job: any SelectionJob, records: [ImageRecord]? = nil) async -> SelectionJobQueue {
        let queue = SelectionJobQueue(gpuSlot: ExportQueue(), jobs: OutputJobs())
        XCTAssertTrue(queue.start(job, records: records ?? photos.records, library: photos.library, gpu: gpu))
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        return queue
    }

    /// Find spots: every photo is analysed and its discs healed, in one
    /// undo group, with the frame named; a user's own patch in a stored
    /// edit is kept beside the new spots.
    func testFindSpotsHealsEveryPhotoInOneUndoGroupKeepingUserHeals() async throws {
        let manager = UndoManager()
        photos.library.undoManager = manager
        let heal = HealPatch(target: [0.9, 0.9], source: [0.8, 0.9], radius: 0.03)
        var edit = EditParameters()
        edit.exposureEV = 0.5
        edit.heals = [heal]
        let existing = EditStack(parameters: edit)
        let id = try XCTUnwrap(photos.records[1].id)
        try await photos.library.saveEditStack(try existing.encodeJSON(), schemaVersion: EditStack.schemaVersion,
                                               processVersion: EditStack.processVersion, forImageID: id)

        let queue = await run(DustRemovalJob(method: .find, options: DustDetector.Options(), store: photos.store))
        for name in DustFolder.names {
            let written = try await stored(name)
            let stack = try XCTUnwrap(written, name)
            XCTAssertEqual(stack.modules.dust?.count, DustDNG.spots.count, name)
            XCTAssertEqual(stack.frame, EditStack.activeAreaFrame, name)
            for patch in stack.modules.dust ?? [] {
                XCTAssertNotNil(DustDNG.spot(under: patch), "\(name): a patch sits on a disc")
            }
        }
        let editedStack = try await stored(DustFolder.names[1])
        let edited = try XCTUnwrap(editedStack)
        XCTAssertEqual(edited.modules.heal, [heal], "the user's patch is untouched")
        XCTAssertEqual(edited.modules.exposure?.ev, 0.5)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust (3 Images)")
        XCTAssertTrue(queue.summary.hasPrefix("Removed dust from 3 photos (\(3 * DustDNG.spots.count) spots) in "),
                      queue.summary)
        XCTAssertEqual(queue.notes, [])
        XCTAssertNil(photos.library.lastError)

        // A second run finds the same spots already patched: nothing changes.
        let again = await run(DustRemovalJob(method: .find, options: DustDetector.Options(), store: photos.store))
        XCTAssertTrue(again.summary.hasPrefix("No dust spots found in "), again.summary)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust (3 Images)", "nothing new filed")
    }

    /// Use dust map: the map's spots are verified in each photo of its
    /// camera; a photo from another camera is skipped with a note.
    func testADustMapSkipsAnotherCameraWithANote() async throws {
        let job = DustRemovalJob(method: .map(photos.nikonMap), options: DustDetector.Options(), store: photos.store)
        let queue = await run(job)
        let first = try await stored(DustFolder.names[0])
        XCTAssertEqual(first?.modules.dust?.count, DustDNG.spots.count)
        let second = try await stored(DustFolder.names[1])
        XCTAssertEqual(second?.modules.dust?.count, DustDNG.spots.count)
        let canon = try await stored(DustFolder.names[2])
        XCTAssertNil(canon, "the Canon is left alone")
        XCTAssertEqual(queue.notes, ["IMG_0203.dng is from a Canon EOS R5, not the map’s Nikon D750, so it was skipped"])
        XCTAssertTrue(queue.summary.hasPrefix("Removed dust from 2 photos (\(2 * DustDNG.spots.count) spots) in "),
                      queue.summary)
    }

    /// New dust map from a reference photo: `prepare` finds the discs in
    /// the reference and saves them as a map for its camera, which the
    /// photos are then checked against.
    func testAReferencePhotoMakesAMapThatIsSavedAndUsed() async throws {
        let reference = photos.root.appendingPathComponent(DustFolder.names[0])
        let job = DustRemovalJob(method: .reference(url: reference, name: DustFolder.names[0]),
                                 options: DustDetector.Options(), store: photos.store)
        var seen: [String] = []
        let queue = SelectionJobQueue(gpuSlot: ExportQueue(), jobs: OutputJobs())
        let watch = queue.$progress.sink { if let stage = $0?.stage { seen.append(stage) } }
        defer { watch.cancel() }
        XCTAssertTrue(queue.start(job, records: photos.records, library: photos.library, gpu: gpu))
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()

        let maps = photos.store.load()
        XCTAssertEqual(maps.count, 1)
        let map = try XCTUnwrap(maps.first)
        XCTAssertEqual(map.camera, "Nikon D750")
        XCTAssertEqual(map.sensorSize, SIMD2(DustDNG.width, DustDNG.height))
        XCTAssertEqual(map.referenceName, DustFolder.names[0])
        XCTAssertEqual(map.spots.count, DustDNG.spots.count)
        XCTAssertEqual(job.map?.id, map.id)
        XCTAssertEqual(seen.first, "Looking for dust in DSC_0201.dng")
        let second = try await stored(DustFolder.names[1])
        XCTAssertEqual(second?.modules.dust?.count, DustDNG.spots.count)
        let canon = try await stored(DustFolder.names[2])
        XCTAssertNil(canon)
        XCTAssertEqual(queue.notes.count, 1, "the Canon")

        // A reference with no dust makes no map and stops the job.
        let clean = photos.base.appendingPathComponent("clean.dng")
        try DustDNG.write(to: clean, spots: [])
        let failing = DustRemovalJob(method: .reference(url: clean, name: "clean.dng"), options: DustDetector.Options(),
                                     store: photos.store)
        let failed = await run(failing)
        XCTAssertEqual(photos.library.lastError,
                       "Dust removal failed: No dust spots were found in clean.dng, so no dust map was made. "
                       + "Try a higher sensitivity, or a photo of a plain sky at f/16")
        XCTAssertEqual(failed.summary, "")
        XCTAssertEqual(photos.store.load().count, 1, "no second map")
    }

    /// A photo the job can't read is noted and the others are written.
    func testAPhotoThatCannotBeReadIsNoted() async throws {
        try Data("not a raw any more".utf8).write(to: photos.root.appendingPathComponent(DustFolder.names[1]))
        let queue = await run(DustRemovalJob(method: .find, options: DustDetector.Options(), store: photos.store))
        let first = try await stored(DustFolder.names[0])
        XCTAssertEqual(first?.modules.dust?.count, DustDNG.spots.count)
        let broken = try await stored(DustFolder.names[1])
        XCTAssertNil(broken)
        let third = try await stored(DustFolder.names[2])
        XCTAssertEqual(third?.modules.dust?.count, DustDNG.spots.count)
        XCTAssertEqual(queue.notes.count, 1)
        XCTAssertTrue(queue.notes[0].hasPrefix("DSC_0202.dng couldn’t be read: "), queue.notes[0])
        XCTAssertTrue(queue.summary.hasPrefix("Removed dust from 2 photos"), queue.summary)
        XCTAssertNil(photos.library.lastError, "a note, not an error")
    }

    /// Cancelled between photos: the photos done are written and the rest
    /// are left, in one undo group of their own.
    func testCancelKeepsThePhotosDone() async throws {
        let manager = UndoManager()
        photos.library.undoManager = manager
        let job = GatedJob(DustRemovalJob(method: .find, options: DustDetector.Options(), store: photos.store))
        job.closeGate(for: DustFolder.names[1])
        let queue = SelectionJobQueue(gpuSlot: ExportQueue(), jobs: OutputJobs())
        XCTAssertTrue(queue.start(job, records: photos.records, library: photos.library, gpu: gpu))
        await waitUntil("the second photo", seconds: 30) { job.processing == DustFolder.names[1] }
        queue.cancel()
        await queue.waitUntilDone()
        await photos.library.waitForPendingWork()
        let first = try await stored(DustFolder.names[0])
        XCTAssertEqual(first?.modules.dust?.count, DustDNG.spots.count)
        let second = try await stored(DustFolder.names[1])
        XCTAssertNil(second)
        let third = try await stored(DustFolder.names[2])
        XCTAssertNil(third, "never reached")
        XCTAssertEqual(queue.summary, "Dust removal cancelled · 1 photo kept")
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust")
        XCTAssertNil(photos.library.lastError)
    }

    func testTheWordsOfTheSummary() {
        let job = DustRemovalJob(method: .find, options: DustDetector.Options())
        XCTAssertEqual(job.summary(changed: 11, counted: 412, skipped: 0, elapsed: 38.2), "Removed dust from 11 photos (412 spots) in 38 s")
        XCTAssertEqual(job.summary(changed: 1, counted: 1, skipped: 1, elapsed: 2.34), "Removed dust from 1 photo (1 spot) in 2.3 s · 1 skipped")
        XCTAssertEqual(job.summary(changed: 0, counted: 0, skipped: 0, elapsed: 12), "No dust spots found in 12 s")
        XCTAssertEqual(job.announcement(changed: 11), "Dust removal finished: removed dust from 11 photos")
        XCTAssertEqual(job.announcement(changed: 0), "Dust removal finished: no dust spots found")
        XCTAssertEqual(job.title, "Dust removal")
        XCTAssertEqual(job.undoName, "Remove Dust")
        XCTAssertEqual(job.outputKind, .dustRemoval)
        XCTAssertEqual(DustRemovalError.noDustInReference("sky.nef").errorDescription,
                       "No dust spots were found in sky.nef, so no dust map was made. Try a higher sensitivity, or a photo of a plain sky at f/16")
    }
}
