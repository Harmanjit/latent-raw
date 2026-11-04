import Foundation
import CoreGraphics
import Catalog
import RawCore
import PixelEngine
import MLKit

// MARK: - Flat-Field Correction over a selection

/// Photo › Flat-Field Correction… (docs/wiki/Develop-Lens-Corrections),
/// run by the `SelectionJobQueue`: `prepare` makes the reference's gain
/// map once and caches it by the file's hash (`FlatFieldCache`), and
/// every photo then gets the correction written into its edit with the
/// reference's path relative to its own folder. The photos themselves
/// aren't opened beyond their metadata, so a hundred take a moment.
///
/// A photo whose sensor has another shape than the reference's (another
/// body, a crop mode), or the reference itself, is left alone with a note.
final class FlatFieldJob: SelectionJob, @unchecked Sendable {
    let referenceURL: URL
    let amount: Float

    private let lock = NSLock()
    private var prepared: (hash: String, map: FlatFieldGainMap)?

    init(referenceURL: URL, amount: Float) {
        self.referenceURL = referenceURL
        self.amount = min(max(amount, 0), 1)
    }

    let title = "Flat-field correction"
    let outputKind = OutputJobs.Kind.batchEdit
    let undoName = "Flat-Field Correction"

    func prepare(gpu: GPUContext, progress: @Sendable (MergeProgress) -> Void) async throws {
        progress(MergeProgress(fraction: 0, stage: "Measuring \(referenceURL.lastPathComponent)"))
        let made = try FlatFieldCache.shared.makeGainMap(referenceAt: referenceURL, gpu: gpu)
        lock.withLock { prepared = made }
    }

    func process(_ input: SelectionJobInput, gpu: GPUContext) async throws -> SelectionJobResult {
        guard let prepared = lock.withLock({ prepared }) else { return SelectionJobResult() }
        let name = input.record.fileName
        if input.fileURL.standardizedFileURL == referenceURL.standardizedFileURL {
            return SelectionJobResult(note: "\(name) is the flat-field reference, so it was left alone")
        }
        let summary = try RawFile(path: input.fileURL.path, metadataOnly: true).summary
        let aspect = Float(summary.rawWidth) / Float(max(1, summary.rawHeight))
        guard prepared.map.fits(aspect: aspect) else {
            return SelectionJobResult(note: FlatFieldError.shapeMismatch(name).errorDescription)
        }
        // Read and written as stored: only the one module changes, so
        // the stack's frame and geometry stay exactly as they were.
        var stack = try input.storedJSON.map { try EditStack.decode(json: $0) } ?? EditStack()
        let correction = FlatFieldCorrection(
            reference: FlatFieldCorrection.relativePath(from: input.fileURL, to: referenceURL),
            hash: prepared.hash, amount: amount)
        guard stack.modules.flatfield != correction else { return SelectionJobResult() }
        stack.modules.flatfield = correction
        return SelectionJobResult(newJSON: .some(try stack.encodeJSON()), count: 1)
    }

    func summary(changed: Int, counted: Int, skipped: Int, elapsed: TimeInterval) -> String {
        var text = "Flat-field correction applied to \(changed) photo\(changed == 1 ? "" : "s")"
        if skipped > 0 { text += " · \(skipped) skipped" }
        return text
    }

    func announcement(changed: Int) -> String {
        "Flat-field correction applied to \(changed) photo\(changed == 1 ? "" : "s")"
    }
}

// MARK: - Upright Mode, pasted

/// A pasted Upright Mode (Copy Settings' Upright Mode without Upright
/// Transforms) carries the mode and no matrix: this job runs the analysis
/// on each photo it landed on, as picking the mode in the panel does,
/// and writes the photo's own correction, refitting the crop when
/// Constrain Crop is on.
struct UprightAnalysisJob: SelectionJob {
    let title = "Upright analysis"
    let outputKind = OutputJobs.Kind.batchEdit
    let undoName = "Upright"

    /// Whether a stored stack has a mode waiting for its analysis.
    static func needsAnalysis(_ stack: EditStack) -> Bool {
        guard let upright = stack.modules.perspective?.upright else { return false }
        return upright.mode != .guided && upright.matrix == nil
    }

    func prepare(gpu: GPUContext, progress: @Sendable (MergeProgress) -> Void) async throws {}

    func process(_ input: SelectionJobInput, gpu: GPUContext) async throws -> SelectionJobResult {
        guard let json = input.storedJSON else { return SelectionJobResult() }
        let file = try RawFile(path: input.fileURL.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        // Migrated onto the active area as it is read, and written with
        // the frame named, so a refitted crop shares the stack's frame.
        var stack = session.stackForThisImage(try EditStack.decode(json: json))
        guard Self.needsAnalysis(stack), let mode = stack.modules.perspective?.upright?.mode else {
            return SelectionJobResult()
        }
        var parameters = try ExportPlan.parameters(editStackJSON: json, session: session, colorSpace: .sRGB)
        let space = pipeline.perspectiveSpace(session: session, parameters: parameters)
        let image = try Self.analysisImage(session: session, pipeline: pipeline, gpu: gpu, parameters: parameters)
        try Task.checkCancellation()
        let lines = UprightAnalysis.lines(in: image, space: space)
        guard let forward = UprightSolver.solve(mode, lines: lines, corners: space.corners) else {
            return SelectionJobResult(note: "\(input.record.fileName): Upright \(mode.title) found no straight lines, so it was left uncorrected")
        }
        parameters.perspective.upright = UprightCorrection(mode: mode, matrix: UprightCorrection.encoded(forward.inverse))
        if parameters.perspective.constrainCrop {
            let size = CGSize(width: file.summary.rawWidth, height: file.summary.rawHeight)
            let fitted = parameters
            parameters.crop = parameters.crop.fitted(sensorSize: size) { point in
                let raw = pipeline.rawSensorPoint(forOutputPoint: SIMD2(Float(point.x), Float(point.y)),
                                                  session: session, parameters: fitted)
                return raw.x >= 0 && raw.y >= 0 && raw.x <= Float(size.width) && raw.y <= Float(size.height)
            }
        }
        let rebuilt = EditStack(parameters: parameters)
        stack.modules.perspective = rebuilt.modules.perspective
        stack.modules.crop = rebuilt.modules.crop
        return try .writing(stack, count: 1)
    }

    /// What the editor reads lines from (`EditorModel.uprightInputImage`):
    /// the defaults with the edit's lens settings and no perspective, about
    /// a thousand pixels across.
    static func analysisImage(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                              parameters: EditParameters) throws -> CGImage {
        let longEdge = max(session.file.summary.rawWidth, session.file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / 2048.0).rounded(.up)))
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        var input = ExportWorker.modelMaskInputParameters(defaults: defaults, geometry: parameters)
        input.perspective = .none
        defer { session.releasePooledTextures(in: .analysis) }
        return try session.withTexturePool(.analysis) {
            let texture = try pipeline.render(session, scale: .binned(quads: quads), parameters: input,
                                              output: .file(.sRGB))
            return try Exporter(gpu: gpu).cgImage(from: texture, colorSpace: .sRGB)
        }
    }

    func summary(changed: Int, counted: Int, skipped: Int, elapsed: TimeInterval) -> String {
        var text = "Upright analysed on \(changed) photo\(changed == 1 ? "" : "s")"
        if skipped > 0 { text += " · \(skipped) skipped" }
        return text
    }

    func announcement(changed: Int) -> String {
        "Upright analysed on \(changed) photo\(changed == 1 ? "" : "s")"
    }
}

/// Starting the Upright job after a paste or a preset: after any job the
/// paste already started (Find Faces), since the queue runs one at a time.
@MainActor
enum PastedUpright {
    static func start(_ records: [ImageRecord], queue: SelectionJobQueue, library: Library, gpu: GPUContext) {
        guard !records.isEmpty else { return }
        Task { @MainActor in
            await queue.waitUntilDone()
            if !queue.start(UprightAnalysisJob(), records: records, library: library, gpu: gpu) {
                library.lastError = refused
            }
        }
    }

    static let refused = "The Upright mode was pasted, but it couldn’t be analysed on each photo: an export or another "
        + "job is using the graphics processor. Open each photo in Develop and press Update, or paste again "
        + "when it finishes."
}
