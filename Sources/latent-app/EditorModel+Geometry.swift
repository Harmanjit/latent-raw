import Foundation
import CoreGraphics
import simd
import PixelEngine
import MLKit

/// What the geometry tools (Upright, Guided Upright, the straighten
/// ruler) need beyond the edit itself. Held in one published value on
/// the model so the tools don't each need a stored property there.
struct GeometryToolState: Equatable {
    /// Guided Upright: drags on the image draw guides.
    var guidedToolActive = false
    /// The crop tool's ruler: the next drag on the image draws a line to
    /// straighten by, as ⌘-drag always does.
    var straightenLineArmed = false
    /// An Upright analysis or Auto straighten is reading the picture.
    var analysing = false
    /// The lines found in the open picture, kept while its lens settings
    /// stay the same, so trying one Upright mode after another is instant.
    var lines: FoundLines?

    struct FoundLines: Equatable {
        /// Which picture and lens settings they were found on.
        let key: String
        let segments: [LineSegment]
    }
}

extension EditorModel {
    // MARK: - Transform

    /// The space the open image's perspective matrix works in.
    var perspectiveSpace: PerspectiveSpace? {
        guard let session, let pipeline else { return nil }
        return pipeline.perspectiveSpace(session: session, parameters: parameters)
    }

    /// Changes the transform in one edit step; with Constrain Crop on, the
    /// crop is refitted to the picture in the same step.
    func setTransform(_ change: (inout PerspectiveCorrection) -> Void) {
        guard hasImage else { return }
        var p = parameters
        change(&p.perspective)
        if p.perspective.constrainCrop {
            p.crop = constrainedCrop(for: p)
            straightenBase = nil
        }
        parameters = p
    }

    /// The largest crop of the current shape and angle that shows only
    /// picture under `p`'s lens corrections and transform.
    func constrainedCrop(for p: EditParameters) -> CropParameters {
        guard let session, let pipeline else { return p.crop }
        let s = sensorSize
        return p.crop.fitted(sensorSize: s) { point in
            let raw = pipeline.rawSensorPoint(forOutputPoint: SIMD2(Float(point.x), Float(point.y)),
                                              session: session, parameters: p)
            return raw.x >= 0 && raw.y >= 0 && raw.x <= Float(s.width) && raw.y <= Float(s.height)
        }
    }

    func setConstrainCrop(_ on: Bool) {
        setTransform { $0.constrainCrop = on }
    }

    /// Flip Horizontal or Vertical: the picture, its crop and its masks are
    /// mirrored together, so the result is exactly the mirror image of
    /// what was on screen. Spots, red-eye and touch-up are stored on the
    /// raw grid and follow the picture by themselves; model-made masks are
    /// made again on the flipped picture.
    func flip(horizontal: Bool) {
        guard hasImage else { return }
        var p = parameters
        p.perspective.flip(horizontal: horizontal)
        if !p.crop.isIdentity {
            p.crop = p.crop.mirrored(horizontal: horizontal)
        }
        p.locals = p.locals.map { local in
            var mirrored = local
            mirrored.shape = local.shape.mirrored(horizontal: horizontal)
            return mirrored
        }
        straightenBase = nil
        parameters = p
    }

    func resetTransform() {
        setTransform { $0.resetTransform() }
        geometry.guidedToolActive = false
    }

    // MARK: - Upright

    /// Which Upright mode is on, or nil for Off.
    var uprightMode: UprightCorrection.Mode? { parameters.perspective.upright?.mode }

    /// Picks an Upright mode (nil turns it off). Every mode but Guided
    /// reads the picture's lines, which takes a moment the first time.
    func setUpright(_ mode: UprightCorrection.Mode?) {
        guard hasImage else { return }
        guard let mode else {
            geometry.guidedToolActive = false
            setTransform { $0.upright = nil }
            return
        }
        if mode == .guided {
            let kept = uprightMode == .guided ? parameters.perspective.upright?.guides : nil
            setTransform { $0.upright = Self.guidedCorrection(kept, space: perspectiveSpace) }
            setGuidedToolActive(true)
            return
        }
        geometry.guidedToolActive = false
        withPictureLines { [weak self] lines, space in
            guard let self else { return }
            let forward = UprightSolver.solve(mode, lines: lines, corners: space.corners)
            self.setTransform {
                $0.upright = UprightCorrection(mode: mode, matrix: forward.map { UprightCorrection.encoded($0.inverse) })
            }
            self.status = forward == nil
                ? "Upright \(mode.title) found no straight lines to work from"
                : "Upright \(mode.title) applied"
        }
    }

    /// Runs the chosen mode's analysis again, after a lens change say.
    func updateUpright() {
        guard let mode = uprightMode, mode != .guided else { return }
        geometry.lines = nil
        setUpright(mode)
    }

    static func guidedCorrection(_ guides: [UprightGuide]?, space: PerspectiveSpace?) -> UprightCorrection {
        let usable = guides ?? []
        let forward = space.flatMap { UprightSolver.solveGuided(usable.map(\.segment), corners: $0.corners) }
        return UprightCorrection(mode: .guided, matrix: forward.map { UprightCorrection.encoded($0.inverse) },
                                 guides: usable.isEmpty ? nil : usable)
    }

    func setGuidedToolActive(_ on: Bool) {
        geometry.guidedToolActive = on
        guard on else { return }
        // One on-image tool at a time.
        cropToolActive = false
        healToolActive = false; redEyeToolActive = false; dustToolActive = false; touchUpToolActive = false
        maskTool = .none
    }

    // MARK: - Guides

    /// The guides on the canvas as the user sees them now, in canvas pixels.
    var guideCanvasLines: [(CGPoint, CGPoint)] {
        guard let space = perspectiveSpace, let guides = parameters.perspective.upright?.guides else { return [] }
        let t = parameters.perspective, f = frame
        func canvas(_ n: SIMD2<Float>) -> CGPoint {
            f.canvasPoint(fromSensorPoint: space.sensorPoint(t.outputPoint(forSource: n)))
        }
        return guides.map { (canvas($0.start), canvas($0.end)) }
    }

    /// A canvas point in the space guides are stored in, under the
    /// transform shown now.
    func guideSourcePoint(fromCanvas p: CGPoint) -> SIMD2<Float>? {
        guard let space = perspectiveSpace else { return nil }
        let sensor = frame.sensorPoint(fromCanvasPoint: p)
        return parameters.perspective.sourcePoint(forOutput: space.normalized(sensor))
    }

    /// Adds a guide drawn from `a` to `b` (canvas pixels). The fifth and
    /// later are refused, as Lightroom does.
    func addGuide(fromCanvas a: CGPoint, to b: CGPoint) {
        guard hasImage, let s = guideSourcePoint(fromCanvas: a), let e = guideSourcePoint(fromCanvas: b) else { return }
        var guides = parameters.perspective.upright?.guides ?? []
        guard guides.count < UprightCorrection.maximumGuides else {
            status = "Guided Upright takes up to \(UprightCorrection.maximumGuides) guides; ⌥-click one to remove it"
            return
        }
        guard simd_distance(s, e) > 0.02 else { return }
        guides.append(UprightGuide(s, e))
        setGuides(guides)
    }

    /// Moves one end of a guide to `p` (canvas pixels).
    func moveGuide(_ index: Int, end: Bool, toCanvas p: CGPoint, from start: PerspectiveCorrection) {
        guard var guides = parameters.perspective.upright?.guides, guides.indices.contains(index),
              let space = perspectiveSpace else { return }
        // Measured under the transform as it was when the drag began: the
        // picture moves under the pointer as the correction updates.
        let n = start.sourcePoint(forOutput: space.normalized(frame.sensorPoint(fromCanvasPoint: p)))
        if end { guides[index].x1 = n.x; guides[index].y1 = n.y } else { guides[index].x0 = n.x; guides[index].y0 = n.y }
        setGuides(guides)
    }

    func removeGuide(_ index: Int) {
        guard var guides = parameters.perspective.upright?.guides, guides.indices.contains(index) else { return }
        guides.remove(at: index)
        setGuides(guides)
    }

    func clearGuides() { setGuides([]) }

    private func setGuides(_ guides: [UprightGuide]) {
        let space = perspectiveSpace
        setTransform { $0.upright = Self.guidedCorrection(guides, space: space) }
    }

    // MARK: - Straighten

    /// Auto in the crop panel: the straighten angle that levels the
    /// picture's lines as they are after the transform.
    func autoStraighten() {
        guard hasImage else { return }
        withPictureLines { [weak self] lines, _ in
            guard let self else { return }
            let t = self.parameters.perspective
            let shown = lines.map { LineSegment(t.outputPoint(forSource: $0.a), t.outputPoint(forSource: $0.b)) }
            guard let angle = UprightSolver.autoStraightenAngle(shown) else {
                self.status = "Auto straighten found no level or upright lines to go by"
                return
            }
            self.straightenBase = nil
            self.setStraighten(angle)
            self.status = String(format: "Straightened by %.2f°", angle)
        }
    }

    /// The ruler: the straighten angle that makes a line drawn from `a`
    /// to `b` on the crop tool's canvas level, or plumb if it is nearer
    /// upright.
    func straighten(alongCanvasLineFrom a: CGPoint, to b: CGPoint) {
        guard hasImage else { return }
        let f = frame
        let sa = f.sensorPoint(fromCanvasPoint: a), sb = f.sensorPoint(fromCanvasPoint: b)
        let line = LineSegment(SIMD2(Float(sa.x), Float(sa.y)), SIMD2(Float(sb.x), Float(sb.y)))
        guard line.length > 4 else { return }
        straightenBase = nil
        setStraighten(UprightSolver.straightenAngle(for: line))
        geometry.straightenLineArmed = false
    }

    // MARK: - Reading the picture's lines

    /// Which lens settings the lines depend on (the transform doesn't
    /// matter: they are found on a render without it).
    private var lineKey: String? {
        guard let session else { return nil }
        let p = parameters
        return "\(ObjectIdentifier(session).hashValue) \(p.lensDistortion) \(p.lensTCA) \(p.manualDistortion)"
    }

    /// Calls `use` with the picture's lines in `PerspectiveSpace`, finding
    /// them first if need be: a render of the defaults with the edit's lens
    /// settings and no perspective, about a thousand pixels across, then
    /// the line detector off the main thread.
    func withPictureLines(_ use: @escaping @MainActor ([LineSegment], PerspectiveSpace) -> Void) {
        guard let key = lineKey, let space = perspectiveSpace else { return }
        if let found = geometry.lines, found.key == key {
            use(found.segments, space)
            return
        }
        guard !geometry.analysing else { return }
        let image: CGImage
        do {
            image = try uprightInputImage()
        } catch {
            status = "Couldn't read the picture's lines: \(error.localizedDescription)"
            return
        }
        geometry.analysing = true
        status = "Finding straight lines…"
        Task { @MainActor [weak self] in
            let lines = await Task.detached(priority: .userInitiated) {
                UprightAnalysis.lines(in: image, space: space)
            }.value
            guard let self else { return }
            self.geometry.analysing = false
            // Another picture, or other lens settings, by now.
            guard self.lineKey == key else { return }
            self.geometry.lines = GeometryToolState.FoundLines(key: key, segments: lines)
            use(lines, space)
        }
    }

    private func uprightInputImage() throws -> CGImage {
        guard let session, let pipeline, let gpu = gpuContext else { throw AIMaskError.noResult }
        let longEdge = max(session.file.summary.rawWidth, session.file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / 2048.0).rounded(.up)))
        var input = ExportWorker.modelMaskInputParameters(defaults: defaultParameters, geometry: parameters)
        input.perspective = .none
        defer { session.releasePooledTextures(in: .analysis) }
        return try session.withTexturePool(.analysis) {
            let tex = try pipeline.render(session, scale: .binned(quads: quads), parameters: input,
                                          output: .file(.sRGB))
            return try Exporter(gpu: gpu).cgImage(from: tex, colorSpace: .sRGB)
        }
    }
}
