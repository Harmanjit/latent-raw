import Foundation
import simd
import Catalog
import PixelEngine
import RawCore

/// Photo › Remove Dust… over the selection (docs/Retouch.md §6, §8), run
/// by the `SelectionJobQueue`: every photo is analysed on this Mac and
/// its dust healed, either by looking for spots afresh or by checking a
/// dust map's spots, and the edit is written back with the new spots
/// beside the ones it had.
///
/// **Methods.** Find spots: each photo is detected on its own. Use dust
/// map: the map's spots are verified in each photo, and a photo from
/// another camera or sensor size is skipped with a note. New dust map
/// from a reference photo: `prepare` finds the spots in the reference,
/// saves them as a map for its camera, and the photos are then checked
/// against that map.
///
/// **What is written.** The stored edit, migrated onto the active area
/// (`ImageSession.stackForThisImage`), with `modules.dust` set and the
/// frame named (`SelectionJobResult.writing`): a stored stack with no
/// frame, or with readout-frame patches, is migrated in the same write,
/// or the next open would shift the dust by the masked border on
/// bordered cameras. A photo in which nothing is found is left alone.
final class DustRemovalJob: SelectionJob, @unchecked Sendable {
    enum Method: Sendable {
        /// Detect in each photo.
        case find
        /// Verify this map's spots in each photo.
        case map(DustMap)
        /// Detect in the reference, save it as a map, then verify.
        case reference(url: URL, name: String)
    }

    let method: Method
    let options: DustDetector.Options
    let store: DustMapStore

    private let lock = NSLock()
    /// The map the photos are checked against: the chosen one, or the one
    /// `prepare` made from the reference; nil for Find spots.
    private var resolvedMap: DustMap?

    init(method: Method, options: DustDetector.Options, store: DustMapStore = DustMapStore()) {
        self.method = method
        self.options = options
        self.store = store
    }

    var map: DustMap? { lock.withLock { resolvedMap } }

    let title = "Dust removal"
    let outputKind = OutputJobs.Kind.dustRemoval
    let undoName = "Remove Dust"

    // MARK: - The job

    func prepare(gpu: GPUContext, progress: @Sendable (MergeProgress) -> Void) async throws {
        switch method {
        case .find:
            return
        case .map(let map):
            lock.withLock { resolvedMap = map }
        case .reference(let url, let name):
            progress(MergeProgress(fraction: 0, stage: "Looking for dust in \(name)"))
            let file = try RawFile(path: url.path)
            let summary = file.summary
            let session = try ImageSession(file: file, gpu: gpu)
            let pipeline = RenderPipeline(gpu: gpu)
            // As shot: the map describes the sensor, not an edit.
            var parameters = EditParameters()
            parameters.whiteBalance = session.asShotWhiteBalance
            let analysis = try DustDetector.analyse(session: session, pipeline: pipeline, gpu: gpu, parameters: parameters)
            try Task.checkCancellation()
            let patches = DustDetector.detect(analysis, options: options,
                                              expectedRadius: DustPhoto.expectedRadius(for: summary), existing: [])
            guard !patches.isEmpty else { throw DustRemovalError.noDustInReference(name) }
            let map = DustMap(camera: DustPhoto.camera(for: summary),
                              sensorSize: SIMD2(summary.rawWidth, summary.rawHeight),
                              referenceName: name, referenceCaptureDate: DustPhoto.captureDate(of: summary),
                              aperture: summary.aperture > 0 ? summary.aperture : nil,
                              options: options, spots: DustDetector.mapSpots(from: patches, analysis: analysis))
            try store.add(map)
            lock.withLock { resolvedMap = map }
        }
    }

    func process(_ input: SelectionJobInput, gpu: GPUContext) async throws -> SelectionJobResult {
        let file = try RawFile(path: input.fileURL.path)
        let summary = file.summary
        let camera = DustPhoto.camera(for: summary)
        let map = self.map
        if let map {
            // A map from another body or a cropped mode would put every
            // spot in the wrong place.
            guard map.camera == camera, map.sensorSize == SIMD2(summary.rawWidth, summary.rawHeight) else {
                let other = camera.isEmpty ? "a camera the file doesn’t name" : "a \(camera)"
                return SelectionJobResult(note: "\(input.record.fileName) is from \(other), not the map’s \(map.camera), so it was skipped")
            }
        }
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        // The edit over this image's defaults, exactly as an export
        // reconstructs it: the analysis follows its white balance and
        // demosaic, and the new spots go beside its patches.
        let parameters = try ExportPlan.parameters(editStackJSON: input.storedJSON, session: session, colorSpace: .sRGB)
        try Task.checkCancellation()
        let analysis = try DustDetector.analyse(session: session, pipeline: pipeline, gpu: gpu, parameters: parameters)
        try Task.checkCancellation()
        // Never a second patch over a spot the edit already heals, by
        // hand, as a blemish or from an earlier run.
        let existing = parameters.dust + parameters.touchUp.activeBlemishes + parameters.heals
        let found: [HealPatch]
        if let map {
            found = DustDetector.verify(map.spots, in: analysis, options: options, existing: existing)
        } else {
            found = DustDetector.detect(analysis, options: options,
                                        expectedRadius: DustPhoto.expectedRadius(for: summary), existing: existing)
        }
        guard !found.isEmpty else { return SelectionJobResult(newJSON: nil, count: 0) }

        var stack = try input.storedJSON.map { try session.stackForThisImage(EditStack.decode(json: $0)) } ?? EditStack()
        let dust = Array((parameters.dust + found).prefix(HealPatch.maximumDustCount))
        stack.modules.dust = dust
        return try .writing(stack, count: dust.count - parameters.dust.count)
    }

    /// "Removed dust from 11 photos (412 spots) in 38 s", "· 1 skipped"
    /// when a photo was left alone.
    func summary(changed: Int, counted: Int, skipped: Int, elapsed: TimeInterval) -> String {
        var text = changed == 0
            ? "No dust spots found"
            : "Removed dust from \(changed) photo\(changed == 1 ? "" : "s") (\(counted) spot\(counted == 1 ? "" : "s"))"
        text += String(format: elapsed < 10 ? " in %.1f s" : " in %.0f s", elapsed)
        if skipped > 0 { text += " · \(skipped) skipped" }
        return text
    }

    func announcement(changed: Int) -> String {
        changed == 0
            ? "Dust removal finished: no dust spots found"
            : "Dust removal finished: removed dust from \(changed) photo\(changed == 1 ? "" : "s")"
    }
}

/// Why a Remove Dust job could not start.
enum DustRemovalError: Error, LocalizedError, Equatable {
    /// The reference photo showed no dust at these options, so there is
    /// no map to check the others against.
    case noDustInReference(String)

    var errorDescription: String? {
        switch self {
        case .noDustInReference(let name):
            "No dust spots were found in \(name), so no dust map was made. Try a higher sensitivity, or a photo of a plain sky at f/16"
        }
    }
}
