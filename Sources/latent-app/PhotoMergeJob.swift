import AppKit
import Catalog
import MergeKit
import PixelEngine

/// Runs an HDR merge in the background once the dialog's Merge is pressed,
/// and publishes its progress for the library panel.
///
/// **Taking turns with exports.** A merge renders every frame at full size,
/// as an export does, so it takes the export queue's one GPU job slot
/// (`ExportQueue.claimSlot`): it doesn't start while an export runs, and
/// Export waits while it runs.
///
/// **Quitting.** It registers with `OutputJobs`, which holds off sleep and
/// has quitting ask first, as for a contact sheet: quitting cancels the
/// merge and waits for it to tidy up, so neither a DNG nor a sidecar with
/// no photo is left behind.
///
/// **Committing** (docs/PhotoMerge.md §5), in this order:
/// 1. Plan a free name beside the reference photo: "DSC_0107-HDR.dng", then
///    "-HDR-2"… (`MergeNaming`; a file, a sidecar and a row must all be free).
/// 2. The engine merges the pixels, then calls back to have the result's
///    sidecar written with the recipe (`Library.writeMergeRecipe`) before it
///    writes the DNG. A sidecar in place first means a crash between the two
///    leaves a recipe waiting for its photo, never a photo without one.
/// 3. If the engine throws or is cancelled after that, the sidecar is taken
///    back (`Library.discardMergeRecipe`). A name taken at the last moment
///    plans a new name and merges again, as exports do.
/// 4. On success the folder is read again and the new photo selected.
@MainActor
final class PhotoMergeQueue: ObservableObject {
    @Published private(set) var isRunning = false
    /// The result's file name, once planned: "DSC_0107-HDR.dng".
    @Published private(set) var name = ""
    /// The engine's last report; nil until its first.
    @Published private(set) var progress: HDRMergeProgress?
    /// How the last merge ended, for the panel: "Merged DSC_0107-HDR.dng
    /// in 8.2 s". Failures go to the status bar instead.
    @Published private(set) var summary = ""

    /// The GPU slot shared with exports.
    let gpuSlot: ExportQueue
    let jobs: OutputJobs
    /// Takes a DNG out of the way that an engine left behind despite
    /// throwing; into the Trash, so nothing is lost if it wasn't ours after
    /// all. Replaceable so tests don't fill the Trash.
    var removeStrayResult: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private var task: Task<Void, Never>?
    /// Bumped for every merge, so a late progress report from an earlier
    /// one can't show under the next.
    private var generation = 0

    /// How many times a merge is run when its name keeps being taken at
    /// the last moment, as for exports.
    static let attemptLimit = 3

    init(gpuSlot: ExportQueue, jobs: OutputJobs = .shared) {
        self.gpuSlot = gpuSlot
        self.jobs = jobs
    }

    /// Starts merging `analysis`, whose frames are the files of `records`
    /// (one each, in the analysis's order), into the open folder of
    /// `library`. Returns false, doing nothing, when a merge or an export
    /// already holds the GPU or the folder has gone.
    @discardableResult
    func start(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions = HDRMergeOptions(),
               records: [ImageRecord], library: Library, engine: any HDRMerging) -> Bool {
        let referenceIndex = options.referenceIndex ?? analysis.referenceIndex
        guard !isRunning, let catalog = library.catalog, records.count == analysis.frames.count,
              records.indices.contains(referenceIndex), gpuSlot.claimSlot() else { return false }
        generation += 1
        isRunning = true
        progress = nil
        summary = ""
        let reference = records[referenceIndex]
        name = (MergeNaming.candidate(forReference: reference.relPath, suffix: "HDR", number: 1) as NSString)
            .lastPathComponent
        let job = jobs.begin(.photoMerge, name: reference.fileName, cancel: { [weak self] in self?.cancel() })
        let request = Request(analysis: analysis, options: options, records: records, reference: reference,
                              library: library, catalog: catalog, engine: engine, generation: generation)
        // Holds the queue until the merge has tidied up, so the slot and the
        // job are always given back.
        task = Task {
            // Renders let go with an export sheet may still be stopping.
            await ExportPreviewRenderer.waitForDiscardedRenders()
            let started = Date()
            let outcome = await run(request)
            await finish(request, outcome: outcome, elapsed: Date().timeIntervalSince(started))
            isRunning = false
            gpuSlot.releaseSlot()
            jobs.end(job)
        }
        return true
    }

    /// Stops the merge; it tidies up and ends a moment later.
    func cancel() {
        task?.cancel()
    }

    /// Returns once the merge under way, if any, has ended and tidied up.
    func waitUntilDone() async {
        await task?.value
    }

    // MARK: - The merge

    private struct Request {
        let analysis: HDRMergeAnalysis
        let options: HDRMergeOptions
        let records: [ImageRecord]
        let reference: ImageRecord
        let library: Library
        let catalog: Catalog
        let engine: any HDRMerging
        let generation: Int
    }

    private enum Outcome {
        case merged(relPath: String)
        case cancelled
        case failed(Error)
    }

    /// Set once the result's sidecar is on disk, from the engine's thread.
    private final class SidecarWritten: @unchecked Sendable {
        private let lock = NSLock()
        private var written = false
        var isSet: Bool { lock.withLock { written } }
        func set() { lock.withLock { written = true } }
    }

    private func run(_ request: Request) async -> Outcome {
        let library = request.library, catalog = request.catalog
        for attempt in 1...Self.attemptLimit {
            guard !Task.isCancelled else { return .cancelled }
            let relPath: String
            do {
                relPath = try await catalog.planMergeResult(forReference: request.reference.relPath, suffix: "HDR")
            } catch {
                return .failed(error)
            }
            name = (relPath as NSString).lastPathComponent
            let destination = await catalog.fileURL(forRelPath: relPath)
            let sources = request.records.map { Self.source($0, forResultAt: relPath) }
            let sidecar = SidecarWritten()
            let generation = request.generation
            do {
                _ = try await request.engine.merge(
                    request.analysis, options: request.options, sources: sources, to: destination,
                    prepareSidecar: { recipe in
                        let json = String(decoding: try recipe.jsonData(), as: UTF8.self)
                        try await library.writeMergeRecipe(json, forNewImageAt: relPath, in: catalog)
                        sidecar.set()
                    },
                    progress: { [weak self] report in
                        // In the order the engine reported, on the main thread.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self, self.isRunning, self.generation == generation else { return }
                                self.progress = report
                            }
                        }
                    })
                return .merged(relPath: relPath)
            } catch {
                // Something took the name after it was planned: the DNG's
                // (the engine's write found a file there) or the sidecar's.
                let fileTaken = error is SafeFileWriter.DestinationExists
                let nameTaken = fileTaken
                    || error as? FileOperations.NameProblem == .taken((relPath as NSString).lastPathComponent)
                if sidecar.isSet {
                    // The name was free when the sidecar went in, so a file
                    // under it now is the engine's, unless the engine said
                    // another file took the name.
                    if !fileTaken, FileOperations.identity(destination) != nil {
                        do {
                            try removeStrayResult(destination)
                        } catch {
                            Log.export.error("HDR merge: could not remove the unfinished \(destination.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                        }
                    }
                    do {
                        try await library.discardMergeRecipe(forNewImageAt: relPath, in: catalog,
                                                             fileTookTheName: fileTaken)
                    } catch {
                        Log.export.error("HDR merge: could not remove the sidecar of \(relPath, privacy: .private): \(String(describing: error), privacy: .public)")
                    }
                }
                if error is CancellationError || Task.isCancelled { return .cancelled }
                if nameTaken, attempt < Self.attemptLimit { continue }
                return .failed(error)
            }
        }
        return .cancelled
    }

    /// Reads the folder again and selects the result, or says what went wrong.
    private func finish(_ request: Request, outcome: Outcome, elapsed: TimeInterval) async {
        let library = request.library
        switch outcome {
        case .merged(let relPath):
            let fileName = (relPath as NSString).lastPathComponent
            summary = String(format: "Merged %@ in %.1f s", fileName, elapsed)
            // Another folder may be open by now; the result is catalogued
            // when that one is opened again.
            if request.catalog === library.catalog {
                do {
                    try await library.refresh()
                    reveal(relPath, in: library)
                } catch {
                    library.lastError = "Reading the folder after the HDR merge failed: \(error)"
                }
            }
            Announcement.post("HDR merge finished: \(fileName)")
        case .cancelled:
            summary = "HDR merge cancelled"
        case .failed(let error):
            summary = ""
            library.lastError = "HDR merge failed: \(Self.describe(error))"
        }
    }

    /// Selects the result in the grid, which scrolls to it. A filter that
    /// would hide it is cleared: the user has just asked for this photo.
    private func reveal(_ relPath: String, in library: Library) {
        guard let id = library.images.first(where: { $0.relPath == relPath })?.id else { return }
        if !library.visibleImages.contains(where: { $0.id == id }) { library.filter = LibraryFilter() }
        library.setSelection([id], primary: id)
    }

    // MARK: - Words and paths

    /// The progress bar's value for VoiceOver: "Merging photo 2 of 3, 40 percent".
    static func spokenProgress(_ progress: HDRMergeProgress?) -> String {
        guard let progress else { return "Starting" }
        let percent = "\(Int((min(max(progress.fraction, 0), 1) * 100).rounded())) percent"
        return progress.stage.isEmpty ? percent : "\(progress.stage), \(percent)"
    }

    /// An error as the status bar says it.
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// The recipe's record of a source photo: where it is from the result's
    /// folder, its hash as the catalog stores it, and when it was taken.
    static func source(_ record: ImageRecord, forResultAt resultRelPath: String) -> MergeRecipe.Source {
        MergeRecipe.Source(path: relativePath(record.relPath, fromFolderOf: resultRelPath),
                           hash: record.xxhash.map { String(format: "%02x", $0) }.joined(),
                           captureTime: record.captureTime ?? 0)
    }

    /// `relPath` as seen from the folder holding `resultRelPath`, both
    /// relative to the catalog: "A.NEF" beside it, "../Day 3/B.NEF" in a
    /// sibling folder.
    static func relativePath(_ relPath: String, fromFolderOf resultRelPath: String) -> String {
        let folder = (resultRelPath as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)
        let target = relPath.split(separator: "/").map(String.init)
        var shared = 0
        while shared < folder.count, shared < target.count - 1, folder[shared] == target[shared] { shared += 1 }
        let up = Array(repeating: "..", count: folder.count - shared)
        return (up + target[shared...]).joined(separator: "/")
    }
}
