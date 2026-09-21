import AppKit
import Catalog
import PixelEngine

/// One photo for a `SelectionJob` to work on: its catalog row, where its
/// file is, and the edit stored for it when the job read it.
struct SelectionJobInput: Sendable {
    let record: ImageRecord
    let fileURL: URL
    /// As read before processing; the commit expects it unchanged, so an
    /// edit the user makes meanwhile is never overwritten.
    let storedJSON: String?
}

/// What a `SelectionJob` made of one photo.
struct SelectionJobResult: Sendable {
    /// nil: leave the image alone; .some(nil): clear its edit; .some(json):
    /// write it.
    var newJSON: String??
    /// Spots or faces found, for the summary.
    var count: Int
    /// Shown in the library panel (orange); nil for nothing to say.
    var note: String?

    init(newJSON: String?? = nil, count: Int = 0, note: String? = nil) {
        self.newJSON = newJSON
        self.count = count
        self.note = note
    }

    /// The result that writes `stack`, whose geometry the job measured on
    /// the image's active area, with that frame named. A stack whose only
    /// module was a pasted touch-up carries no frame, and a stack with
    /// readout-frame patches was migrated as it was read; either way the
    /// boxes and patches the job adds sit on the active area, and written
    /// without the name they would be moved by the masked border on the
    /// next open of a bordered camera's photo.
    static func writing(_ stack: EditStack, count: Int) throws -> SelectionJobResult {
        var stack = stack
        stack.frame = EditStack.activeAreaFrame
        return SelectionJobResult(newJSON: .some(try stack.encodeJSON()), count: count)
    }
}

/// A job the `SelectionJobQueue` runs over explicit catalog rows, one photo
/// at a time: Remove Dust (`DustRemovalJob`) and Find Faces (`FaceFindJob`).
/// The job opens the raw and works out the new edit; the queue does the
/// rest (docs/Retouch.md §8).
protocol SelectionJob: Sendable {
    /// The panel's label and the first words of the status bar's messages:
    /// "Dust removal" / "Finding faces".
    var title: String { get }
    /// .dustRemoval / .findFaces
    var outputKind: OutputJobs.Kind { get }
    /// "Remove Dust" / "Find Faces": the undo group's name, before the
    /// count the library adds.
    var undoName: String { get }
    /// Once before the loop, off the main actor (analyse a reference photo,
    /// save a map); throwing aborts the job.
    func prepare(gpu: GPUContext, progress: @Sendable (MergeProgress) -> Void) async throws
    /// One image, off the main actor, one RawFile/ImageSession at a time;
    /// throwing skips it with a note.
    func process(_ input: SelectionJobInput, gpu: GPUContext) async throws -> SelectionJobResult
    /// "Removed dust from 11 photos (412 spots) in 38 s".
    func summary(changed: Int, counted: Int, skipped: Int, elapsed: TimeInterval) -> String
    /// What VoiceOver says when the job is done.
    func announcement(changed: Int) -> String
}

/// Runs a `SelectionJob` over the selection in the background and
/// publishes its progress for the library panel. The `PhotoMergeQueue`
/// shape: one job at a time, of either kind.
///
/// **Taking turns with exports.** A job renders every photo at least
/// once, so it takes the export queue's one GPU job slot
/// (`ExportQueue.claimSlot`): it doesn't start while an export or a merge
/// runs, and they wait while it runs.
///
/// **Quitting.** It registers with `OutputJobs`, which holds off sleep and
/// has quitting ask first: quitting cancels the job, which keeps the
/// photos already done.
///
/// **Committing.** Nothing is written while the job runs. Each photo's
/// result is kept, and once the loop ends (or is cancelled, for the
/// photos done) they are written together through
/// `Library.setEdits(_:expecting:undoName:)` inside `library.perform`, so
/// quitting waits for the write: ONE undo group, "Remove Dust (12
/// Images)". A photo whose stored edit changed meanwhile is skipped and
/// noted, never overwritten. `library.didRestoreImages?(changedIDs,
/// .edits)` is then called, which reloads the editor if the open image is
/// among them, exactly as an undo does. Before the queue reads the stored
/// edits, ContentView flushes the open image's pending save, so the edit
/// the job reads is the one on screen; and just before the commit the
/// queue calls `beforeCommit`, which ContentView points at the same flush
/// and a wait for the catalog's pending writes, so an edit made while
/// the job ran is on record and its photo is skipped rather than
/// overwritten, and the reload that follows has nothing pending to save
/// over the job's result.
///
/// The commit goes to the catalog the job read. Image ids restart in
/// every catalog, so if another folder is open by then the job's edits
/// would land on that folder's photos: the commit is refused instead,
/// and the panel says the folder changed. ContentView also cancels the
/// job when a folder is about to be replaced, so the worker stops early.
///
/// **Memory.** The worker is a detached task holding one photo at a time
/// (that is the job's business), and between photos it waits while memory
/// pressure is critical rather than open the next raw in the middle of a
/// shortage.
@MainActor
final class SelectionJobQueue: ObservableObject {
    @Published private(set) var isRunning = false
    /// The running (or last) job's title, for the panel: "Dust removal".
    @Published private(set) var title = ""
    /// The worker's last report; nil until its first.
    @Published private(set) var progress: MergeProgress?
    /// How the last job ended, for the panel: "Removed dust from 11 photos
    /// (412 spots) in 38 s". Failures go to the status bar instead.
    @Published private(set) var summary = ""
    /// What is worth saying about a job that finished: photos that couldn't
    /// be read, photos left alone because their edit changed meanwhile,
    /// and whatever the job itself noted.
    @Published private(set) var notes: [String] = []

    /// The GPU slot shared with exports and Photo Merge.
    let gpuSlot: ExportQueue
    let jobs: OutputJobs
    /// Called once the worker is done, before its results are written:
    /// the lead saves the open image's pending edit here and waits for
    /// the catalog's pending writes, so the commit compares against what
    /// the user has really done.
    var beforeCommit: (@MainActor () async -> Void)?

    private var task: Task<Void, Never>?
    /// Bumped for every job, so a late progress report from an earlier one
    /// can't show under the next.
    private var generation = 0

    /// The memory pressure the worker reads between photos. Written on the
    /// main thread by the monitor, read from the worker's thread.
    private let pressure = PressureLevel()
    private var pressureMonitor: MemoryPressureMonitor?

    init(gpuSlot: ExportQueue, jobs: OutputJobs = .shared) {
        self.gpuSlot = gpuSlot
        self.jobs = jobs
        pressureMonitor = MemoryPressureMonitor { [pressure] level in pressure.level = level }
    }

    /// What the worker takes the memory pressure to be. The monitor sets
    /// it; tests set it to see the worker pause.
    func setMemoryPressure(_ level: MemoryPressureLevel) {
        pressure.level = level
    }

    /// How long the worker waits between looks at the pressure while it is
    /// critical.
    static let pressurePollInterval: Duration = .milliseconds(250)

    /// Starts `job` over `records` in the open folder of `library`. Returns
    /// false, doing nothing, when a job, a merge or an export already holds
    /// the GPU, the folder is gone or `records` is empty.
    @discardableResult
    func start(_ job: any SelectionJob, records: [ImageRecord], library: Library, gpu: GPUContext) -> Bool {
        guard !isRunning, !records.isEmpty, let catalog = library.catalog, gpuSlot.claimSlot() else { return false }
        generation += 1
        let generation = generation
        title = job.title
        isRunning = true
        progress = nil
        summary = ""
        notes = []
        let outputJob = jobs.begin(job.outputKind, name: records[0].fileName,
                                   cancel: { [weak self] in self?.cancel() })
        task = Task {
            // Renders let go with an export sheet may still be stopping.
            await ExportPreviewRenderer.waitForDiscardedRenders()
            let started = Date()
            let outcome = await run(job, records: records, catalog: catalog, gpu: gpu, generation: generation)
            await finish(job, outcome: outcome, elapsed: Date().timeIntervalSince(started),
                         library: library, catalog: catalog)
            isRunning = false
            gpuSlot.releaseSlot()
            jobs.end(outputJob)
        }
        return true
    }

    /// Stops the job after the photo under way; what is done is committed
    /// and the queue ends a moment later.
    func cancel() {
        task?.cancel()
    }

    /// Returns once the job under way, if any, has ended and committed.
    func waitUntilDone() async {
        await task?.value
    }

    // MARK: - The worker

    /// A note from the worker: the job's own words, or a photo it couldn't
    /// read, put into words on the main actor (`PhotoMergeQueue.describe`
    /// lives there).
    private enum WorkerNote: Sendable {
        case text(String)
        case couldNotRead(String, any Error)
    }

    /// What the loop over the photos produced, brought back to the main
    /// actor for the commit.
    private struct WorkerOutcome: Sendable {
        /// The edits to write, by image id, and what each image's stored
        /// edit was when the job read it.
        var edits: [Int64: String?] = [:]
        var expected: [Int64: String?] = [:]
        /// Spots or faces found, by image id, for the summary.
        var counts: [Int64: Int] = [:]
        var notes: [WorkerNote] = []
        var cancelled = false
        /// `prepare` threw: nothing was done.
        var failure: (any Error)?
    }

    private func run(_ job: any SelectionJob, records: [ImageRecord], catalog: Catalog, gpu: GPUContext,
                     generation: Int) async -> WorkerOutcome {
        let pressure = pressure
        let report: @Sendable (MergeProgress) -> Void = { [weak self] progress in
            // In the order the worker reported, on the main thread.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.generation == generation else { return }
                    self.progress = progress
                }
            }
        }
        // Detached: the photos are read and rendered off the main thread,
        // and a slow raw never holds the window.
        let worker = Task.detached(priority: .userInitiated) {
            var outcome = WorkerOutcome()
            do {
                try await job.prepare(gpu: gpu, progress: report)
            } catch is CancellationError {
                outcome.cancelled = true
                return outcome
            } catch {
                outcome.failure = error
                return outcome
            }
            for (index, record) in records.enumerated() {
                guard let id = record.id else { continue }
                do {
                    try Task.checkCancellation()
                    // Between photos, not in the middle of one: the raw
                    // under way is the memory that matters.
                    while pressure.level == .critical {
                        try await Task.sleep(for: Self.pressurePollInterval)
                        try Task.checkCancellation()
                    }
                } catch {
                    outcome.cancelled = true
                    break
                }
                report(MergeProgress(fraction: Double(index) / Double(records.count),
                                     stage: "Photo \(index + 1) of \(records.count): \(record.fileName)"))
                let storedJSON: String?
                do {
                    storedJSON = try await catalog.storedEdit(forImageID: id)?.json
                } catch {
                    outcome.notes.append(.couldNotRead(record.fileName, error))
                    continue
                }
                let input = SelectionJobInput(record: record, fileURL: await catalog.fileURL(forRelPath: record.relPath),
                                              storedJSON: storedJSON)
                do {
                    let result = try await job.process(input, gpu: gpu)
                    if let newJSON = result.newJSON {
                        outcome.edits[id] = newJSON
                        outcome.expected[id] = storedJSON
                    }
                    outcome.counts[id] = result.count
                    if let note = result.note { outcome.notes.append(.text(note)) }
                } catch is CancellationError {
                    outcome.cancelled = true
                    break
                } catch {
                    if Task.isCancelled {
                        outcome.cancelled = true
                        break
                    }
                    outcome.notes.append(.couldNotRead(record.fileName, error))
                }
            }
            if !outcome.cancelled {
                report(MergeProgress(fraction: 1, stage: "Saving"))
            }
            return outcome
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // MARK: - The commit

    /// Writes what the worker made, in one undo group, and says how it went.
    /// `catalog` is the one the job read; the commit is refused when it is
    /// no longer the open one.
    private func finish(_ job: any SelectionJob, outcome: WorkerOutcome, elapsed: TimeInterval,
                        library: Library, catalog: Catalog) async {
        if let failure = outcome.failure {
            summary = ""
            library.lastError = "\(job.title) failed: \(PhotoMergeQueue.describe(failure))"
            return
        }
        var notes = outcome.notes.map { note in
            switch note {
            case .text(let text): text
            case .couldNotRead(let name, let error): "\(name) couldn’t be read: \(PhotoMergeQueue.describe(error))"
            }
        }
        var changed = 0
        var counted = 0
        if !outcome.edits.isEmpty {
            await beforeCommit?()
            // The ids the job holds are this catalog's; in another folder
            // they are other photos.
            guard catalog === library.catalog else {
                summary = "\(job.title) cancelled · the folder changed, so nothing was written"
                self.notes = notes
                return
            }
            // Inside `perform`, so quitting waits for the write and a
            // failure goes to the status bar as every catalog write's does.
            let committed: Result<Library.TransformOutcome, any Error> = await withCheckedContinuation { continuation in
                library.perform(job.title) {
                    do {
                        let written = try await library.setEdits(outcome.edits, expecting: outcome.expected,
                                                                 schemaVersion: EditStack.schemaVersion,
                                                                 processVersion: EditStack.processVersion,
                                                                 undoName: job.undoName)
                        continuation.resume(returning: .success(written))
                    } catch {
                        continuation.resume(returning: .failure(error))
                        throw error
                    }
                }
            }
            // Whether the write went through or stopped partway (the status
            // bar has its error), the photos holding the job's edit are
            // reloaded, or the editor's next save would put its old edit
            // back over the job's.
            let landed = await landedIDs(outcome, in: catalog, library: library)
            guard case .success(let written) = committed else {
                if !landed.isEmpty { library.didRestoreImages?(landed, .edits) }
                summary = landed.isEmpty ? ""
                    : "\(job.title) stopped · \(landed.count) photo\(landed.count == 1 ? "" : "s") kept"
                self.notes = notes
                return
            }
            changed = written.changed
            // A photo left alone still counts what it found; one with an
            // edit counts once the edit is in.
            counted = outcome.counts.filter { !outcome.edits.keys.contains($0.key) || landed.contains($0.key) }
                .values.reduce(0, +)
            notes += written.skipped.map { name in
                name.hasPrefix("image ")
                    ? "\(name) is no longer in the folder, so it was left alone"
                    : "\(name) was edited while \(job.title.lowercased()) ran, so it was left alone"
            }
            if !landed.isEmpty { library.didRestoreImages?(landed, .edits) }
            if outcome.cancelled {
                summary = "\(job.title) cancelled · \(changed) photo\(changed == 1 ? "" : "s") kept"
            } else {
                summary = job.summary(changed: changed, counted: counted, skipped: written.skipped.count,
                                      elapsed: elapsed)
            }
        } else if outcome.cancelled {
            summary = "\(job.title) cancelled"
        } else {
            counted = outcome.counts.values.reduce(0, +)
            summary = job.summary(changed: 0, counted: counted, skipped: 0, elapsed: elapsed)
        }
        self.notes = notes
        if !outcome.cancelled {
            Announcement.post(job.announcement(changed: changed)
                              + (notes.isEmpty ? ""
                                 : ", with \(notes.count) note\(notes.count == 1 ? "" : "s") in the library panel"))
        }
    }

    /// The photos, still in the folder, whose stored edit is now the job's:
    /// the ones the commit wrote, and any that already held it. Read back
    /// from the catalog rather than worked out from the names the library
    /// reports as skipped, which two photos in included subfolders can
    /// share; one that can't be read is counted in, since reloading a
    /// photo the job left alone costs nothing and not reloading one it
    /// wrote loses the job's work on the editor's next save.
    private func landedIDs(_ outcome: WorkerOutcome, in catalog: Catalog, library: Library) async -> Set<Int64> {
        let listed = Set(library.images.compactMap(\.id))
        var landed: Set<Int64> = []
        for (id, next) in outcome.edits where listed.contains(id) {
            do {
                if try await catalog.storedEdit(forImageID: id)?.json == next { landed.insert(id) }
            } catch {
                landed.insert(id)
            }
        }
        return landed
    }

    /// The progress bar's value for VoiceOver: "Photo 3 of 12: DSC_0107.NEF,
    /// 25 percent".
    static func spokenProgress(_ progress: MergeProgress?) -> String {
        PhotoMergeQueue.spokenProgress(progress)
    }
}

/// The memory pressure level as the worker's thread reads it.
private final class PressureLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var current: MemoryPressureLevel = .normal
    var level: MemoryPressureLevel {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
