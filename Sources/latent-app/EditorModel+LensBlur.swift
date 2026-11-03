import CoreGraphics
import Foundation
import simd
import PixelEngine
import MLKit

/// What the editor knows about Lens Blur beyond the edit itself: the
/// depth map's job and source, its histogram for the Focus Range bar,
/// and the two display switches (Show Depth, Pick Focus). Its own object
/// so the editor gains one stored property, and the panel observes it
/// beside the editor.
@MainActor
final class LensBlurState: ObservableObject {
    /// "Making the depth map…", what made it, or why it failed.
    @Published var status = ""
    @Published var building = false
    /// What made the session's depth map (LensBlurDepth.displayName's
    /// input); nil until one is made for the open image.
    @Published var source: String?
    /// How much of the frame lies at each depth, far to near (DepthMap.histogram).
    @Published var histogram: [Float] = []
    /// Show Depth: the depth map in colour in place of the picture.
    @Published var showDepth = false
    /// The next click on the image sets the focus range around what was
    /// clicked. One click, then off.
    @Published var pickingFocus = false

    /// The build under way, if any; a newer one replaces it.
    var task: Task<Void, Never>?
    /// The lens and keystone settings the depth map was made on.
    var geometryKey: String?
    /// Waits out a lens or keystone drag before making the map again.
    var geometryTask: Task<Void, Never>?
    /// The session the state above describes; another one means a new
    /// image, and everything above is forgotten.
    var sessionID: ObjectIdentifier?
}

// Lens Blur in the editor (docs/wiki/Develop.md, "Lens Blur"): the depth
// map's life, the focus picker and the panel's actions.
//
// The depth map is derived, never stored: it is made from the analysis
// render the model masks use, on a detached task, and applied only if
// the same image is still open on the same lens and keystone grid. It is
// made when the blur is first turned up, when Show Depth wants it, on
// open when the edit has a blur, and again after a lens or keystone
// change (300 ms after the last), as the model masks are.
extension EditorModel {
    /// The open session's state, or a fresh one after an image change.
    private func lensBlurStateForSession() -> LensBlurState? {
        guard let session else { return nil }
        let state = lensBlurState
        let id = ObjectIdentifier(session)
        if state.sessionID != id {
            state.task?.cancel()
            state.task = nil
            state.geometryTask?.cancel()
            state.geometryTask = nil
            state.sessionID = id
            state.geometryKey = nil
            state.source = nil
            state.histogram = []
            state.building = false
            state.status = ""
            state.pickingFocus = false
        }
        return state
    }

    /// Called from `parameters`' didSet with the previous value. Undo, a
    /// history jump, a snapshot and a paste all come through here too.
    func lensBlurParametersDidChange(from old: EditParameters) {
        guard hasImage, let session, let state = lensBlurStateForSession() else { return }
        let blur = parameters.lensBlur
        guard blur.isActive || state.showDepth else { return }
        if !session.hasDepthMap {
            if state.task == nil { buildDepthMap() }
            return
        }
        // Another depth source named (a paste, or the model menu): the map
        // on hand is not what the edit asks for.
        if blur.depthModel != old.lensBlur.depthModel, let wanted = blur.depthModel, wanted != state.source {
            buildDepthMap()
            return
        }
        let key = Self.touchUpGeometryKey(of: parameters)
        guard key != Self.touchUpGeometryKey(of: old) else { return }
        state.geometryTask?.cancel()
        state.geometryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.touchUpGeometryDebounce)
            guard let self, !Task.isCancelled else { return }
            self.lensBlurState.geometryTask = nil
            if Self.touchUpGeometryKey(of: self.parameters) != self.lensBlurState.geometryKey {
                self.buildDepthMap()
            }
        }
    }

    /// On open: an edit with a blur needs its depth map before it can
    /// show it.
    func regenerateDepthMapIfNeeded() {
        guard hasImage, let session, let state = lensBlurStateForSession() else { return }
        guard parameters.lensBlur.isActive || state.showDepth, !session.hasDepthMap, state.task == nil else { return }
        buildDepthMap()
    }

    /// Makes the depth map for the open image from the source the edit
    /// names (the default one for a blur that names none) and puts it on
    /// the session.
    func buildDepthMap() {
        guard let session, let pipeline, let gpu = gpuContext, let state = lensBlurStateForSession() else { return }
        state.task?.cancel()
        let key = Self.touchUpGeometryKey(of: parameters)
        let stored = parameters.lensBlur.depthModel
        let image: CGImage
        do {
            image = try ExportWorker.depthInputImage(session: session, pipeline: pipeline, gpu: gpu,
                                                     defaults: defaultParameters, geometry: parameters)
        } catch {
            state.status = "The depth map could not be made: \(error)"
            state.building = false
            return
        }
        // Only Sendable values cross into the detached task (the image in
        // its wrapper, as the model masks pass it); the result comes back
        // as a value and is applied here, on the main actor.
        let input = SendableImage(cgImage: image)
        let rotation = self.rotation
        state.building = true
        state.status = "Making the depth map…"
        let builder = Self.depthBuilder
        state.task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await builder(input, rotation, stored)
            }.value
            guard let self, !Task.isCancelled, self.session === session else { return }
            let state = self.lensBlurState
            state.task = nil
            state.building = false
            switch result {
            case .failure(let error):
                state.status = "The depth map could not be made: \(error)"
                self.status = state.status
            case .success(let made):
                // A lens or keystone change during the build: this map is
                // for the grid before it; make it again for the one now.
                guard Self.touchUpGeometryKey(of: self.parameters) == key else {
                    self.buildDepthMap()
                    return
                }
                session.setDepthMap(made.depth)
                state.geometryKey = key
                state.source = made.depth.source
                state.histogram = made.depth.histogram()
                state.status = Self.depthStatus(source: made.depth.source, standingInFor: made.substitutedModel)
                Announcement.post(state.status)
                self.rerender()
            }
        }
    }

    /// The depth builder, replaceable so tests can stand a drawn depth map
    /// in for the models.
    typealias DepthBuilder = @Sendable (SendableImage, ImageRotation, String?) async -> Result<LensBlurDepth.Result, Error>

    static let liveDepthBuilder: DepthBuilder = { image, rotation, stored in
        do {
            return .success(try await LensBlurDepth.make(from: image.cgImage, rotation: rotation, stored: stored))
        } catch {
            return .failure(error)
        }
    }

    static var depthBuilder: DepthBuilder = liveDepthBuilder

    /// What the panel says about the map on hand.
    static func depthStatus(source: String, standingInFor missing: String?) -> String {
        let name = LensBlurDepth.displayName(of: source)
        if let missing { return "Depth from \(name), because \(missing) is not installed." }
        if source == LensBlur.subjectDepthVersion {
            return "Depth from the subject: it stays sharp and everything else blurs evenly. "
                + "Add a depth model in Settings › AI › Models for a real depth map."
        }
        return "Depth from \(name)."
    }

    // MARK: - Panel actions

    /// The Amount slider: the first move off zero also records which
    /// depth source the blur is set on, as a new mask records its model.
    func setLensBlurAmount(_ amount: Float) {
        var blur = parameters.lensBlur
        blur.amount = min(max(amount, 0), 100)
        if blur.isActive, blur.depthModel == nil {
            blur.depthModel = lensBlurState.source ?? LensBlurDepth.defaultSource()
        }
        parameters.lensBlur = blur
    }

    /// Show Depth on or off; on makes the map first if there is none.
    func setShowDepth(_ on: Bool) {
        guard lensBlurState.showDepth != on else { return }
        lensBlurState.showDepth = on
        if on { regenerateDepthMapIfNeeded() }
        rerender()
    }

    /// Pick Focus: arms a one-click picker (another tool armed meanwhile
    /// takes the click instead). Makes the map first if there is none.
    func setPickingFocus(_ on: Bool) {
        guard let state = lensBlurStateForSession() else { return }
        state.pickingFocus = on
        if on {
            if let session, !session.hasDepthMap, state.task == nil { buildDepthMap() }
            status = "Click the part of the photo to keep sharp"
        }
    }

    /// The picker's click: the focus range is set around the depth under
    /// the pointer, one history step, and the picker disarms.
    func lensBlurFocusPicked(at screen: CGPoint) {
        lensBlurState.pickingFocus = false
        guard let map = session?.depthMap else {
            status = "The depth map isn't ready yet; try again in a moment"
            return
        }
        let depth = map.depth(atNormalized: sensorNormalized(screen))
        let range = LensBlur.focusRange(around: depth)
        var blur = parameters.lensBlur
        blur.focusFar = range.far
        blur.focusNear = range.near
        parameters.lensBlur = blur
        status = String(format: "Focus set at depth %.0f %%", depth * 100)
    }

    /// Makes the map again with the default source: after a depth model is
    /// added or removed in Settings, or to swap the two planes for a model.
    func remakeDepthMap(with source: String) {
        var blur = parameters.lensBlur
        blur.depthModel = source
        parameters.lensBlur = blur   // an active blur starts the build from didSet
        if lensBlurState.task == nil { buildDepthMap() }
    }
}
