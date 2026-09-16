import AppKit
import Catalog
import MergeKit
import PixelEngine

/// Which merge a job is making. The two kinds share this whole file: the
/// GPU slot, the quit handling, the naming and the commit order are the
/// same, and only the engine, the words and the result's suffix differ.
enum PhotoMergeKind: String, Equatable, Sendable {
    case hdr
    case panorama
    /// Phase 9, experimental: a bracket at each position, merged and then
    /// stitched.
    case hdrPanorama

    /// What the result is called: "DSC_0107-HDR.dng", "DSC_0107-Pano.dng",
    /// "DSC_0107-HDRPano.dng".
    var suffix: String {
        switch self {
        case .hdr: "HDR"
        case .panorama: "Pano"
        case .hdrPanorama: "HDRPano"
        }
    }

    /// The panel's label and the first words of the status bar's messages:
    /// "HDR merge failed: …", "Panorama merge cancelled".
    var title: String {
        switch self {
        case .hdr: "HDR merge"
        case .panorama: "Panorama merge"
        case .hdrPanorama: "HDR panorama merge"
        }
    }

    /// What the status bar calls the result's first edit when it fails.
    var firstEditName: String { self == .hdr ? "Auto Settings" : "Auto Crop and Auto Settings" }
}

/// How far a merge has got, whichever engine is making it: the HDR and the
/// panorama engines report the same two things (`HDRMergeProgress`,
/// `PanoramaMergeProgress`), so the panel shows one kind of report.
struct MergeProgress: Equatable, Sendable {
    /// 0...1 over the whole merge.
    let fraction: Double
    /// A short phrase for the progress line, e.g. "Merging photo 2 of 3".
    let stage: String

    init(fraction: Double, stage: String) {
        self.fraction = fraction
        self.stage = stage
    }

    init(_ report: HDRMergeProgress) {
        self.init(fraction: report.fraction, stage: report.stage)
    }

    init(_ report: PanoramaMergeProgress) {
        self.init(fraction: report.fraction, stage: report.stage)
    }

    init(_ report: HDRPanoramaProgress) {
        self.init(fraction: report.fraction, stage: report.stage)
    }
}

/// Runs a Photo Merge in the background once a dialog's Merge is pressed,
/// and publishes its progress for the library panel.
///
/// **Taking turns with exports.** A merge renders every frame at full size,
/// as an export does, so it takes the export queue's one GPU job slot
/// (`ExportQueue.claimSlot`): it doesn't start while an export runs, and
/// Export waits while it runs. One merge at a time, of either kind.
///
/// **Quitting.** It registers with `OutputJobs`, which holds off sleep and
/// has quitting ask first, as for a contact sheet: quitting cancels the
/// merge and waits for it to tidy up, so neither a DNG nor a sidecar with
/// no photo is left behind.
///
/// **Committing** (docs/PhotoMerge.md §5), in this order:
/// 1. Plan a free name beside the reference photo: "DSC_0107-HDR.dng" or
///    "DSC_0107-Pano.dng", then "-HDR-2"… (`MergeNaming`; a file, a sidecar
///    and a row must all be free).
/// 2. The engine merges the pixels, then calls back to have the result's
///    sidecar written with the recipe (`Library.writeMergeRecipe`) before it
///    writes the DNG. A sidecar in place first means a crash between the two
///    leaves a recipe waiting for its photo, never a photo without one.
/// 3. If the engine throws or is cancelled after that, the sidecar is taken
///    back (`Library.discardMergeRecipe`). A name taken at the last moment
///    plans a new name and merges again, as exports do.
/// 4. On success the result's first edit is worked out, if it has one
///    (HDR: Auto Settings; panorama: Auto Crop's crop rectangle and Auto
///    Settings), before the GPU slot is given back; the folder is read
///    again, the edit stored through the catalog's normal edit path (so it
///    lands in the sidecar beside the recipe, and Develop's history starts
///    at the merge as it came out), and the new photo selected.
///
/// **Without the dialog** (HDR Merge Without Dialog, ⌃⇧H), the job measures
/// the photos itself first, with the options the dialog was last left with.
/// A failure goes to the status bar as usual; so do the warnings the dialog
/// would have shown, once the merge is done.
@MainActor
final class PhotoMergeQueue: ObservableObject {
    @Published private(set) var isRunning = false
    /// Which merge is running (or ran last), for the panel and the messages.
    @Published private(set) var kind: PhotoMergeKind = .hdr
    /// The result's file name, once planned: "DSC_0107-HDR.dng".
    @Published private(set) var name = ""
    /// The engine's last report; nil until its first.
    @Published private(set) var progress: MergeProgress?
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

    /// Works out the merged photo's first edit from the DNG at the URL it
    /// is given, as the catalog stores edits (nil: nothing to store).
    /// Auto Settings for both kinds, and Auto Crop's rectangle as well for
    /// a panorama.
    typealias FirstEdit = @Sendable (URL) async throws -> String?

    // MARK: - HDR

    /// Starts merging `analysis`, whose frames are the files of `records`
    /// (one each, in the analysis's order), into the open folder of
    /// `library`. Returns false, doing nothing, when a merge or an export
    /// already holds the GPU or the folder has gone.
    ///
    /// - Parameter autoSettings: the result's first edit; nil to leave the
    ///   result unedited.
    @discardableResult
    func start(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions = HDRMergeOptions(),
               records: [ImageRecord], library: Library, engine: any HDRMerging,
               autoSettings: FirstEdit? = nil) -> Bool {
        let referenceIndex = options.referenceIndex ?? analysis.referenceIndex
        guard !isRunning, let catalog = library.catalog, records.count == analysis.frames.count,
              records.indices.contains(referenceIndex), gpuSlot.claimSlot() else { return false }
        let reference = records[referenceIndex]
        name = Self.firstCandidateName(forReference: reference, kind: .hdr)
        begin(.hdr, jobName: reference.fileName, library: library, catalog: catalog) { [weak self] generation in
            guard let self else { return .cancelled }
            return await self.runHDR(HDRRequest(analysis: analysis, options: options,
                                                urls: analysis.frames.map(\.url), records: records,
                                                library: library, catalog: catalog, engine: engine,
                                                firstEdit: autoSettings, withoutDialog: false,
                                                generation: generation))
        }
        return true
    }

    /// HDR Merge Without Dialog: measures `urls` (the files of `records`,
    /// in the same order) with `options`, then merges as `start` does.
    /// Returns false, doing nothing, when a merge or an export already holds
    /// the GPU, the folder has gone or there aren't two photos.
    @discardableResult
    func startWithoutDialog(records: [ImageRecord], urls: [URL], options: HDRMergeOptions, library: Library,
                            engine: any HDRMerging, autoSettings: FirstEdit? = nil) -> Bool {
        guard !isRunning, let catalog = library.catalog, records.count >= 2, urls.count == records.count,
              gpuSlot.claimSlot() else { return false }
        name = ""
        begin(.hdr, jobName: records[0].fileName, library: library, catalog: catalog) { [weak self] generation in
            guard let self else { return .cancelled }
            return await self.runHDR(HDRRequest(analysis: nil, options: options, urls: urls, records: records,
                                                library: library, catalog: catalog, engine: engine,
                                                firstEdit: autoSettings, withoutDialog: true,
                                                generation: generation))
        }
        return true
    }

    // MARK: - Panorama

    /// Starts stitching `analysis`, whose frames are the files of `records`
    /// (one each, in the analysis's order), into the open folder of
    /// `library`. The result is named after the first photo the analysis
    /// could join to the others. Returns false, doing nothing, when a merge
    /// or an export already holds the GPU, the folder has gone or no photo
    /// was joined.
    ///
    /// - Parameter firstEdit: Auto Crop's crop rectangle and Auto Settings'
    ///   adjustments as one edit; nil to leave the result unedited.
    @discardableResult
    func startPanorama(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                       records: [ImageRecord], library: Library, engine: any PanoramaMerging,
                       firstEdit: FirstEdit? = nil) -> Bool {
        guard !isRunning, let catalog = library.catalog, records.count == analysis.frames.count,
              let referenceIndex = Self.panoramaReferenceIndex(analysis), records.indices.contains(referenceIndex),
              gpuSlot.claimSlot() else { return false }
        let reference = records[referenceIndex]
        name = Self.firstCandidateName(forReference: reference, kind: .panorama)
        begin(.panorama, jobName: reference.fileName, library: library, catalog: catalog) { [weak self] generation in
            guard let self else { return .cancelled }
            let job = MergeJob(
                kind: .panorama, reference: reference, records: records, library: library, catalog: catalog,
                generation: generation, firstEdit: firstEdit, firstEditStage: "Finishing the panorama",
                merge: { destination, sources, prepareSidecar, progress in
                    _ = try await engine.merge(analysis, options: options, sources: sources, to: destination,
                                               prepareSidecar: prepareSidecar,
                                               progress: { progress(MergeProgress($0)) })
                })
            return await self.commit(job)
        }
        return true
    }

    // MARK: - HDR Panorama (experimental)

    /// Starts merging `analysis`'s brackets and stitching them, into the
    /// open folder of `library`. `records` are the files of
    /// `analysis.photos`, one each, in that order. Returns false, doing
    /// nothing, when a merge or an export already holds the GPU, the folder
    /// has gone, or no position was joined to the rest.
    ///
    /// - Parameter firstEdit: Auto Crop's crop rectangle and Auto Settings'
    ///   adjustments as one edit, as a panorama's; nil to leave the result
    ///   unedited.
    @discardableResult
    func startHDRPanorama(_ analysis: HDRPanoramaAnalysis, options: HDRPanoramaOptions,
                          records: [ImageRecord], library: Library, engine: any HDRPanoramaMerging,
                          firstEdit: FirstEdit? = nil) -> Bool {
        guard !isRunning, let catalog = library.catalog, records.count == analysis.photos.count,
              let referenceIndex = analysis.referencePhotoIndex, records.indices.contains(referenceIndex),
              gpuSlot.claimSlot() else { return false }
        let reference = records[referenceIndex]
        name = Self.firstCandidateName(forReference: reference, kind: .hdrPanorama)
        begin(.hdrPanorama, jobName: reference.fileName, library: library, catalog: catalog) { [weak self] generation in
            guard let self else { return .cancelled }
            let job = MergeJob(
                kind: .hdrPanorama, reference: reference, records: records, library: library, catalog: catalog,
                generation: generation, firstEdit: firstEdit, firstEditStage: "Finishing the panorama",
                merge: { destination, sources, prepareSidecar, progress in
                    _ = try await engine.merge(analysis, options: options, sources: sources, to: destination,
                                               prepareSidecar: prepareSidecar,
                                               progress: { progress(MergeProgress($0)) })
                })
            return await self.commit(job)
        }
        return true
    }

    /// The photo a panorama is named after: the first one, in capture
    /// order, that the analysis joined to the rest. Nil when none was.
    static func panoramaReferenceIndex(_ analysis: PanoramaMergeAnalysis) -> Int? {
        analysis.frames.firstIndex { !$0.leftOut }
    }

    /// The name the result would take if nothing else held it, shown in the
    /// panel until the job has planned the real one.
    private static func firstCandidateName(forReference reference: ImageRecord, kind: PhotoMergeKind) -> String {
        (MergeNaming.candidate(forReference: reference.relPath, suffix: kind.suffix, number: 1) as NSString)
            .lastPathComponent
    }

    // MARK: - Running

    /// Runs `work` in the background, holding the GPU slot (already
    /// claimed), a job and the queue until it has tidied up.
    private func begin(_ kind: PhotoMergeKind, jobName: String, library: Library, catalog: Catalog,
                       _ work: @escaping (Int) async -> Outcome) {
        generation += 1
        let generation = generation
        self.kind = kind
        isRunning = true
        progress = nil
        summary = ""
        let outputKind: OutputJobs.Kind = switch kind {
        case .hdr: .photoMerge
        case .panorama: .panoramaMerge
        case .hdrPanorama: .hdrPanoramaMerge
        }
        let job = jobs.begin(outputKind, name: jobName,
                             cancel: { [weak self] in self?.cancel() })
        task = Task {
            // Renders let go with an export sheet may still be stopping.
            await ExportPreviewRenderer.waitForDiscardedRenders()
            let started = Date()
            let outcome = await work(generation)
            await finish(kind, outcome: outcome, elapsed: Date().timeIntervalSince(started),
                         library: library, catalog: catalog)
            isRunning = false
            gpuSlot.releaseSlot()
            jobs.end(job)
        }
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

    private struct HDRRequest {
        /// Nil without the dialog: the job measures the photos first.
        let analysis: HDRMergeAnalysis?
        let options: HDRMergeOptions
        /// The photos' files, as the analysis names them or will.
        let urls: [URL]
        /// One per file of `urls`; in the analysis's order when it is given.
        let records: [ImageRecord]
        let library: Library
        let catalog: Catalog
        let engine: any HDRMerging
        let firstEdit: FirstEdit?
        /// Say the analysis's warnings when done, as the dialog would have.
        let withoutDialog: Bool
        let generation: Int
    }

    /// Everything the attempt loop below needs that differs between an HDR
    /// merge and a panorama.
    private struct MergeJob {
        let kind: PhotoMergeKind
        /// The photo the result is named after and placed beside.
        let reference: ImageRecord
        /// One per source photo, in the engine's order.
        let records: [ImageRecord]
        let library: Library
        let catalog: Catalog
        let generation: Int
        /// The result's first edit; nil for none.
        let firstEdit: FirstEdit?
        /// The progress line while that edit is worked out.
        let firstEditStage: String
        /// Merges into `destination`, writing the result's sidecar through
        /// `prepareSidecar` before the DNG.
        let merge: (_ destination: URL, _ sources: [MergeRecipe.Source],
                    _ prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
                    _ progress: @escaping @Sendable (MergeProgress) -> Void) async throws -> Void
    }

    private enum Outcome {
        /// `firstEdit`: the result's first edit, or why it couldn't be
        /// worked out; nil when not asked for or there's nothing to store.
        /// `problems`: anything else to say once the result is in, such as
        /// the warnings a merge without the dialog didn't show.
        case merged(relPath: String, firstEdit: Result<String, Error>?, problems: [String])
        case cancelled
        case failed(Error)
    }

    /// The analysis and its records in its order: the request's, or, without
    /// the dialog, measured now.
    private func analysed(_ request: HDRRequest) async throws -> (HDRMergeAnalysis, [ImageRecord]) {
        if let analysis = request.analysis { return (analysis, request.records) }
        let generation = request.generation
        progress = MergeProgress(fraction: 0, stage: "Analysing \(request.urls.count) photos")
        let analysis = try await request.engine.analyse(request.urls, options: request.options)
        guard self.generation == generation else { throw CancellationError() }
        // The engine lists the photos brightest first, by its own URLs.
        let paths = request.urls.map(HDRMergeSheetModel.comparablePath)
        let records = analysis.frames.compactMap { frame in
            paths.firstIndex(of: HDRMergeSheetModel.comparablePath(frame.url)).map { request.records[$0] }
        }
        guard records.count == analysis.frames.count else { throw MergeJobError.photosChanged }
        return (analysis, records)
    }

    enum MergeJobError: Error, LocalizedError {
        case photosChanged
        var errorDescription: String? { "the photos measured aren’t the ones selected" }
    }

    /// Set once the result's sidecar is on disk, from the engine's thread.
    private final class SidecarWritten: @unchecked Sendable {
        private let lock = NSLock()
        private var written = false
        var isSet: Bool { lock.withLock { written } }
        func set() { lock.withLock { written = true } }
    }

    private func runHDR(_ request: HDRRequest) async -> Outcome {
        let analysis: HDRMergeAnalysis, records: [ImageRecord]
        do {
            (analysis, records) = try await analysed(request)
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            return .failed(error)
        }
        let referenceIndex = request.options.referenceIndex ?? analysis.referenceIndex
        guard records.indices.contains(referenceIndex) else { return .failed(MergeJobError.photosChanged) }
        let engine = request.engine, options = request.options
        let job = MergeJob(
            kind: .hdr, reference: records[referenceIndex], records: records, library: request.library,
            catalog: request.catalog, generation: request.generation, firstEdit: request.firstEdit,
            firstEditStage: "Applying Auto Settings",
            merge: { destination, sources, prepareSidecar, progress in
                _ = try await engine.merge(analysis, options: options, sources: sources, to: destination,
                                           prepareSidecar: prepareSidecar,
                                           progress: { progress(MergeProgress($0)) })
            })
        let outcome = await commit(job)
        // Without the dialog, its warnings are said once the merge is done.
        guard request.withoutDialog, case .merged(let relPath, let edit, _) = outcome else { return outcome }
        let problems = analysis.warnings(reference: referenceIndex)
            .map { HDRMergeSheetModel.text(for: $0, frames: analysis.frames) }
        return .merged(relPath: relPath, firstEdit: edit, problems: problems)
    }

    /// Plans a free name, has the engine merge into it with the sidecar
    /// written first, and takes the sidecar (and any file the engine left)
    /// back if it throws. Shared by both kinds of merge.
    private func commit(_ job: MergeJob) async -> Outcome {
        let library = job.library, catalog = job.catalog
        for attempt in 1...Self.attemptLimit {
            guard !Task.isCancelled else { return .cancelled }
            let relPath: String
            do {
                relPath = try await catalog.planMergeResult(forReference: job.reference.relPath,
                                                            suffix: job.kind.suffix)
            } catch {
                return .failed(error)
            }
            name = (relPath as NSString).lastPathComponent
            let destination = await catalog.fileURL(forRelPath: relPath)
            let sources = job.records.map { Self.source($0, forResultAt: relPath) }
            let sidecar = SidecarWritten()
            let generation = job.generation
            do {
                try await job.merge(
                    destination, sources,
                    { recipe in
                        let json = String(decoding: try recipe.jsonData(), as: UTF8.self)
                        try await library.writeMergeRecipe(json, forNewImageAt: relPath, in: catalog)
                        sidecar.set()
                    },
                    { [weak self] report in
                        // In the order the engine reported, on the main thread.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self, self.isRunning, self.generation == generation else { return }
                                self.progress = report
                            }
                        }
                    })
                // The result's first edit, while the GPU slot is still held.
                var edit: Result<String, Error>?
                if let firstEdit = job.firstEdit {
                    progress = MergeProgress(fraction: 1, stage: job.firstEditStage)
                    do {
                        if let json = try await firstEdit(destination) { edit = .success(json) }
                    } catch {
                        edit = .failure(error)
                    }
                }
                return .merged(relPath: relPath, firstEdit: edit, problems: [])
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
                            Log.export.error("\(job.kind.title, privacy: .public): could not remove the unfinished \(destination.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                        }
                    }
                    do {
                        try await library.discardMergeRecipe(forNewImageAt: relPath, in: catalog,
                                                             fileTookTheName: fileTaken)
                    } catch {
                        Log.export.error("\(job.kind.title, privacy: .public): could not remove the sidecar of \(relPath, privacy: .private): \(String(describing: error), privacy: .public)")
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
    private func finish(_ kind: PhotoMergeKind, outcome: Outcome, elapsed: TimeInterval,
                        library: Library, catalog: Catalog) async {
        switch outcome {
        case .merged(let relPath, let firstEdit, let extraProblems):
            let fileName = (relPath as NSString).lastPathComponent
            summary = String(format: "Merged %@ in %.1f s", fileName, elapsed)
            var problems: [String] = []
            // Another folder may be open by now; the result is catalogued
            // when that one is opened again (without its first edit).
            if catalog === library.catalog {
                do {
                    try await library.refresh()
                    if case .success(let json)? = firstEdit,
                       let id = library.images.first(where: { $0.relPath == relPath })?.id {
                        // Before it is selected, so Develop opens it with the edit.
                        do {
                            try await library.saveEditStack(json, schemaVersion: EditStack.schemaVersion,
                                                            processVersion: EditStack.processVersion,
                                                            forImageID: id, in: catalog)
                        } catch {
                            problems.append("\(kind.firstEditName) couldn’t be saved: \(Self.describe(error))")
                        }
                    }
                    reveal(relPath, in: library)
                } catch {
                    problems.append("Reading the folder after the \(kind.title.lowercased()) failed: \(error)")
                }
            }
            if case .failure(let error)? = firstEdit {
                problems.append("\(kind.firstEditName) couldn’t be worked out: \(Self.describe(error))")
            }
            problems += extraProblems
            if !problems.isEmpty {
                library.lastError = "\(kind.title) \(fileName) finished, but: " + problems.joined(separator: " ")
            }
            Announcement.post("\(kind.title) finished: \(fileName)")
        case .cancelled:
            summary = "\(kind.title) cancelled"
        case .failed(let error):
            summary = ""
            library.lastError = "\(kind.title) failed: \(Self.describe(error))"
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
    static func spokenProgress(_ progress: MergeProgress?) -> String {
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
