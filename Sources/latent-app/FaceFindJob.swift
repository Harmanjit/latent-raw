import Foundation
import Catalog
import RawCore
import PixelEngine
import MLKit

/// Find Faces over a selection (docs/Retouch.md §7 Copy, paste, presets):
/// a pasted or preset touch-up keeps its sliders but not the faces they
/// were found on, so after the stacks are written the queue runs this
/// over every photo whose module would retouch and has no faces. Each
/// photo is opened, rendered for analysis, passed to Vision and written
/// back with its faces (and its blemishes, when the module removes
/// them), in one undo group with the others.
struct FaceFindJob: SelectionJob {
    let title = "Finding faces"
    let outputKind = OutputJobs.Kind.findFaces
    let undoName = "Find Faces"

    /// Whether a stored module is waiting for faces: a slider up or
    /// blemish removal on, and no face to apply them to. What the lead
    /// filters the targets by, and what `process` checks again.
    static func needsFaces(_ touchUp: TouchUp?) -> Bool {
        guard let t = touchUp, t.faces.isEmpty else { return false }
        return t.skinSmoothing > 0 || t.teethWhitening > 0 || t.eyes > 0 || t.blemishRemoval
    }

    /// Nothing to prepare: every photo stands alone.
    func prepare(gpu: GPUContext, progress: @Sendable (MergeProgress) -> Void) async throws {}

    func process(_ input: SelectionJobInput, gpu: GPUContext) async throws -> SelectionJobResult {
        guard let json = input.storedJSON else { return SelectionJobResult(newJSON: nil, count: 0) }
        let file = try RawFile(path: input.fileURL.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        // The stack as this image reads it: geometry from before the
        // active-area change is moved onto its sensor plane, so the boxes
        // written beside the heals share their frame.
        let stack = session.stackForThisImage(try EditStack.decode(json: json))
        guard Self.needsFaces(stack.modules.touchup), var touchUp = stack.modules.touchup else {
            return SelectionJobResult(newJSON: nil, count: 0)
        }
        let parameters = try ExportPlan.parameters(editStackJSON: json, session: session, colorSpace: .sRGB)
        let rotation = ExportPlan.rotation(for: file.summary, userRotation: input.record.userRotation)
        let render = try TouchUpAnalysis.render(session: session, pipeline: pipeline, gpu: gpu,
                                                parameters: parameters, rotation: rotation)
        try Task.checkCancellation()
        let found = TouchUpRegions.find(in: render, session: session, pipeline: pipeline, parameters: parameters)
        guard !found.faces.isEmpty else {
            return SelectionJobResult(newJSON: nil, count: 0,
                                      note: "\(input.record.fileName): no face found, so it was left alone")
        }
        touchUp.faces = found.faces
        touchUp.modelVersion = FaceLandmarker.modelVersion
        if touchUp.blemishRemoval {
            try Task.checkCancellation()
            touchUp.blemishes = BlemishFinder.find(in: render, masks: found.masks, touchUp: touchUp,
                                                   existing: parameters.heals + parameters.dust,
                                                   session: session, pipeline: pipeline, parameters: parameters)
        }
        var written = stack
        written.modules.touchup = touchUp
        return SelectionJobResult(newJSON: .some(try written.encodeJSON()), count: found.faces.count)
    }

    /// "Found faces in 8 photos"; a photo that changed meanwhile or
    /// couldn't be read is a note in the panel.
    func summary(changed: Int, counted: Int, skipped: Int, elapsed: TimeInterval) -> String {
        var text = "Found faces in \(changed) photo\(changed == 1 ? "" : "s")"
        if counted > changed { text += " (\(counted) faces)" }
        if skipped > 0 { text += " · \(skipped) skipped" }
        return text
    }

    func announcement(changed: Int) -> String {
        changed == 0 ? "Face search finished: no faces found" : "Found faces in \(changed) photo\(changed == 1 ? "" : "s")"
    }
}
