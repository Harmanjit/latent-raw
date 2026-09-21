import Foundation
import CoreGraphics
import RawCore
import PixelEngine
import MLKit

extension EditorModel {
    // MARK: - Local adjustments

    var selectedLocal: LocalAdjustment? {
        guard let i = selectedLocalIndex, i < parameters.locals.count else { return nil }
        return parameters.locals[i]
    }

    /// Adds a local with sensible starting geometry, selects it, and arms
    /// the matching tool so the next drag on the image places it.
    func addLocal(_ kind: MaskTool) {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        let n = parameters.locals.count + 1
        let local: LocalAdjustment
        switch kind {
        case .linear:
            local = LocalAdjustment(name: "Gradient \(n)", shape: .linear(start: SIMD2(0.5, 0.0), end: SIMD2(0.5, 0.5)))
        case .radial:
            local = LocalAdjustment(name: "Radial \(n)", shape: .radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.3, 0.3), feather: 0.5))
        case .brush, .erase:
            local = LocalAdjustment(name: "Brush \(n)", shape: .brush(strokes: []))
        case .prompt:
            addPromptedMask()
            return
        case .none:
            local = LocalAdjustment(name: "Whole image \(n)", shape: .whole)
        }
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        maskTool = kind == .none ? .none : (kind == .erase ? .brush : kind)
    }

    /// Adds a model-generated mask made with the kind's default model
    /// (Settings › AI › Models for a subject, the installed class model
    /// for a class) and starts generating its pixels.
    func addAIMask(_ kind: AIMaskKind) {
        addAIMask(kind, modelVersion: kind.modelVersion)
    }

    /// A subject mask made with `entry` rather than the default: the Add
    /// menu's Subject submenu.
    func addAIMask(model entry: ModelEntry) {
        addAIMask(.subject, modelVersion: entry.modelVersion)
    }

    /// The model runs off the main thread on a small sRGB copy of the
    /// image rendered *unrotated*, so the mask lands in sensor coordinates
    /// like every other mask; the edit records which model made it.
    private func addAIMask(_ kind: AIMaskKind, modelVersion: String) {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        let local = LocalAdjustment(name: kind.displayName,
                                    shape: .ai(kind: kind.rawValue, modelVersion: modelVersion))
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        showMaskOverlay = true
        generateAIMask(for: local)
    }

    /// Makes the mask at `index` again with another model: an ordinary
    /// parameter change that rewrites the stored `modelVersion`, drops
    /// the old pixels and regenerates; undo and history cover it because
    /// the restore paths run `syncModelMasks`, which does the same for a
    /// shape they bring back. A click-to-select mask keeps its points
    /// and answers them against the new model's encoding.
    func rerunMask(at index: Int, with entry: ModelEntry) {
        guard index < parameters.locals.count, let session else { return }
        let local = parameters.locals[index]
        switch local.shape {
        case .ai(let kind, _):
            parameters.locals[index].shape = .ai(kind: kind, modelVersion: entry.modelVersion)
        case .prompted(let points, _):
            parameters.locals[index].shape = .prompted(points: points, modelVersion: entry.modelVersion)
        default:
            return
        }
        session.setAIMask(nil, forLocal: local.id)
        generateAIMask(for: parameters.locals[index])
        rerender()
    }

    /// Regenerates masks for AI locals that have no pixels yet — after
    /// opening an image whose edit contains them. One encoding per
    /// distinct click-to-select model the edit names.
    func regenerateMissingAIMasks() {
        guard let session else { return }
        for local in parameters.locals where local.shape.isModelGenerated {
            if !session.hasAIMask(forLocal: local.id), !generatingMasks.contains(local.id) {
                generateAIMask(for: local)
            }
        }
    }

    /// Undo, Redo, a history jump or a snapshot put `parameters` back
    /// without touching the session, whose mask pixels are keyed by the
    /// local's id alone: a model-generated local whose stored shape came
    /// back different (another model, other prompt points) would keep
    /// rendering the pixels of the shape it no longer names. Those are
    /// dropped and made again; a local with no pixels at all gets them
    /// too, as on open. Called from the restore paths with the value
    /// `parameters` had before.
    func syncModelMasks(from old: EditParameters) {
        guard let session else { return }
        let before = Dictionary(old.locals.map { ($0.id, $0.shape) }, uniquingKeysWith: { a, _ in a })
        for local in parameters.locals where local.shape.isModelGenerated {
            if let previous = before[local.id], previous != local.shape {
                session.setAIMask(nil, forLocal: local.id)
                generateAIMask(for: local)
            } else if !session.hasAIMask(forLocal: local.id), !generatingMasks.contains(local.id) {
                generateAIMask(for: local)
            }
        }
    }

    /// The image as the models see it: ~1000 px on the long edge, encoded
    /// sRGB, unrotated so masks land in sensor coordinates. Rendered from
    /// the pipeline with the image's defaults (no locals, so a mask never
    /// depends on the edits it will drive).
    private func modelInputImage() throws -> CGImage {
        guard let session, let pipeline, let gpu = gpuContext else { throw AIMaskError.noResult }
        let longEdge = max(session.file.summary.rawWidth, session.file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / 2048.0).rounded(.up)))
        var neutral = defaultParameters
        neutral.locals = []
        // Its own pool, as for red-eye detection: never the preview's textures.
        defer { session.releasePooledTextures(in: .analysis) }
        return try session.withTexturePool(.analysis) {
            let tex = try pipeline.render(session, scale: .binned(quads: quads), parameters: neutral,
                                          output: .file(.sRGB))
            return try Exporter(gpu: gpu).cgImage(from: tex, colorSpace: .sRGB)
        }
    }

    private func generateAIMask(for local: LocalAdjustment) {
        guard let session else { return }
        if case .prompted = local.shape { updatePromptedMask(for: local); return }
        guard case .ai(let kindName, let modelVersion) = local.shape,
              let kind = AIMaskKind(storedName: kindName) else { return }
        generatingMasks.insert(local.id)
        let runner = ModelMenus.runningModelName(for: kind, modelVersion: modelVersion)
        status = "Generating \(kind.maskNoun) mask with \(runner)…"

        let image: CGImage
        do {
            image = try modelInputImage()
        } catch {
            generatingMasks.remove(local.id)
            status = "Mask failed: \(error)"
            return
        }
        let input = SendableImage(cgImage: image)
        let localID = local.id
        // The analysis render is unrotated; the subject models turn it
        // upright themselves and turn the mask back (SubjectSegmenter).
        let rotation = self.rotation
        // Swift 6 concurrency shape: only Sendable values (the image
        // wrapper, the kind and the stored version) cross into the
        // detached task; the result comes back as a value, and the
        // main-actor task below is the only place that touches the model
        // or the session.
        Task { @MainActor [weak self] in
            let outcome: Result<AIMaskGenerator.Result, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try await AIMaskGenerator.generate(kind, modelVersion: modelVersion,
                                                                       from: input.cgImage, rotation: rotation))
                } catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.generatingMasks.remove(localID)
            switch outcome {
            case .success(let result):
                // The user may have moved to another image while the model
                // ran, or Undo may have given the local back its previous
                // model: pixels for a shape the edit no longer names would
                // land on top of the ones being made for it.
                guard self.session === session,
                      let now = self.parameters.locals.first(where: { $0.id == localID }),
                      case .ai(_, let current) = now.shape, current == modelVersion else { return }
                session.setAIMask(result.mask, forLocal: localID)
                let made = result.substitutedModel.map { "\(runner), \($0) is not installed" } ?? runner
                self.status = String(format: "%@ mask (%@): %.0f ms on device, %.0f%% of the frame",
                                     kind.maskNoun.capitalized, made, result.seconds * 1000,
                                     result.mask.coverage * 100)
                self.rerender()
            case .failure(let error):
                self.status = "\(kind.maskNoun.capitalized) mask failed: \(error)"
            }
        }
    }

    // MARK: Click-to-select (Segment Anything 2)

    /// A click-to-select model is there to run: the preferred one, else
    /// the bundled SAM 2.1 Small.
    var promptedModelAvailable: Bool { ModelRegistry.shared.defaultPrompted() != nil }

    /// Adds a click-to-select mask made with the default model and arms
    /// the prompt tool.
    func addPromptedMask() {
        guard let entry = ModelRegistry.shared.defaultPrompted() else { return }
        addPromptedMask(model: entry)
    }

    /// Adds a click-to-select mask made with `entry` and arms the prompt
    /// tool. The image is encoded for that model in the background right
    /// away so the first click is quick.
    func addPromptedMask(model entry: ModelEntry) {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        let local = LocalAdjustment(name: "Selection \(parameters.locals.count + 1)",
                                    shape: .prompted(points: [], modelVersion: entry.modelVersion))
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        maskTool = .prompt
        showMaskOverlay = true
        ensurePromptSession(for: entry.id)
    }

    /// The id of the model that answers a stored click-to-select version:
    /// the one named when it is installed, else the default (what export
    /// does, `ExportWorker.regenerateMasks`); nil with no model at all.
    func promptModelID(for modelVersion: String) -> String? {
        ModelMenus.promptedEntry(running: modelVersion, registry: .shared)?.id
    }

    /// Encodes the open image for one click-to-select model, unless it
    /// is encoded or being encoded already.
    private func ensurePromptSession(for id: String) {
        guard promptSessions[id] == nil, promptEncoding[id] == nil, let session else { return }
        let image: CGImage
        do { image = try modelInputImage() } catch {
            promptStatus[id] = "Click-to-select unavailable: \(error)"
            return
        }
        let input = SendableImage(cgImage: image)
        promptStatus[id] = "Encoding image for click-to-select…"
        promptEncoding[id] = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> SAM2Session? in
                guard let models = await ModelRegistry.shared.prompted(id: id) else { return nil }
                return try? SAM2Session(models: models, image: input.cgImage)
            }.value
            // Awaiting the detached encode does not carry this task's
            // cancellation into it, so a memory warning that cancelled
            // the encode (`resetPromptSessions`) is checked here: the
            // encoding it asked to be rid of must not land after all.
            guard let self, !Task.isCancelled, self.session === session else { return nil }
            self.promptSessions[id] = result
            self.promptEncoding[id] = nil
            self.promptStatus[id] = result.map { String(format: "Image encoded in %.0f ms — click the subject; option-click to exclude", $0.encodeSeconds * 1000) }
                ?? "Click-to-select unavailable (the model could not be loaded)"
            // Any prompted locals of this model that were waiting for the encoding.
            for local in self.parameters.locals {
                if case .prompted(let pts, let version) = local.shape, !pts.isEmpty,
                   self.promptModelID(for: version) == id {
                    self.updatePromptedMask(for: local)
                }
            }
            return result
        }
    }

    /// Forgets every encoding: the image is closing, or memory is short.
    /// `keeping` survives (the model the armed prompt tool is clicking
    /// against); an encoding under way for it goes on.
    func resetPromptSessions(keeping kept: String? = nil) {
        for (id, task) in promptEncoding where id != kept { task.cancel() }
        promptEncoding = promptEncoding.filter { $0.key == kept }
        promptSessions = promptSessions.filter { $0.key == kept }
        promptStatus = promptStatus.filter { $0.key == kept }
    }

    /// A click on the image while the prompt tool is armed.
    func promptClick(at screen: CGPoint, foreground: Bool) {
        guard let i = selectedLocalIndex, i < parameters.locals.count,
              case .prompted(var points, let version) = parameters.locals[i].shape else { return }
        let p = sensorNormalized(screen)
        points.append(MaskPromptPoint(x: p.x, y: p.y, foreground: foreground))
        parameters.locals[i].shape = .prompted(points: points, modelVersion: version)
        updatePromptedMask(for: parameters.locals[i])
    }

    func clearPromptPoints() {
        guard let i = selectedLocalIndex, i < parameters.locals.count,
              case .prompted(_, let version) = parameters.locals[i].shape else { return }
        parameters.locals[i].shape = .prompted(points: [], modelVersion: version)
        session?.setAIMask(nil, forLocal: parameters.locals[i].id)
        rerender()
    }

    private func updatePromptedMask(for local: LocalAdjustment) {
        guard case .prompted(let points, let version) = local.shape, let session else { return }
        guard !points.isEmpty, let id = promptModelID(for: version) else { return }
        guard let sam = promptSessions[id] else { ensurePromptSession(for: id); return }
        let prompts = points.map { PromptPoint(x: $0.x, y: $0.y, foreground: $0.foreground) }
        let localID = local.id
        let shape = local.shape
        generatingMasks.insert(localID)
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try sam.predict(points: prompts) }
            }.value
            guard let self, self.session === session else { return }
            self.generatingMasks.remove(localID)
            switch outcome {
            case .success(let prediction):
                // Another click or Undo changed the points meanwhile: the
                // answer to the old ones would land on the new mask.
                guard self.parameters.locals.first(where: { $0.id == localID })?.shape == shape else { return }
                session.setAIMask(prediction.mask, forLocal: localID)
                self.status = String(format: "Selection: %.0f ms, confidence %.2f, %.0f%% of the frame",
                                     prediction.seconds * 1000, prediction.score, prediction.mask.coverage * 100)
                self.rerender()
            case .failure(let error):
                self.status = "Selection failed: \(error)"
            }
        }
    }

    // MARK: - Mask tool

    func removeSelectedLocal() {
        guard let i = selectedLocalIndex, i < parameters.locals.count else { return }
        parameters.locals.remove(at: i)
        selectedLocalIndex = parameters.locals.isEmpty ? nil : min(i, parameters.locals.count - 1)
    }

    /// Whether drags on the image should shape a mask instead of panning.
    var maskToolActive: Bool { maskTool != .none && selectedLocal != nil && !cropToolActive }

    /// Screen pixel -> normalized sensor coordinate, through the viewport
    /// (rotated image space) and the rotation (back to the sensor). The
    /// point is on the output grid: what the viewport shows, after the
    /// lens stage has moved pixels.
    func sensorNormalized(_ screen: CGPoint) -> SIMD2<Float> {
        let canvas = viewport.sensorPoint(forScreenPoint: screen, drawableSize: drawableSize)
        let sensor = frame.sensorPoint(fromCanvasPoint: canvas)
        return SIMD2(Float(sensor.x / sensorSize.width), Float(sensor.y / sensorSize.height))
    }

    /// Output-grid normalised point -> raw grid, through the lens map. A
    /// heal patch is applied before the lens stage, so a click on the
    /// corrected image goes through here to the pixel it is over; the
    /// point itself without lens correction.
    func rawNormalized(_ out: SIMD2<Float>) -> SIMD2<Float> {
        guard let pipeline, let session, sensorSize.width > 0, sensorSize.height > 0 else { return out }
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        return pipeline.rawSensorPoint(forOutputPoint: out * size, session: session, parameters: parameters) / size
    }

    /// The inverse: where a raw-grid normalised point (a stored patch
    /// target or face box) shows on the corrected image the overlays draw
    /// on.
    func outputNormalized(_ raw: SIMD2<Float>) -> SIMD2<Float> {
        guard let pipeline, let session, sensorSize.width > 0, sensorSize.height > 0 else { return raw }
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        return pipeline.outputSensorPoint(forRawPoint: raw * size, session: session, parameters: parameters) / size
    }

    func maskToolBegan(at screen: CGPoint) {
        guard let i = selectedLocalIndex, i < parameters.locals.count else { return }
        if maskTool == .prompt {
            promptClick(at: screen, foreground: !promptModifierExclude)
            return
        }
        let p = sensorNormalized(screen)
        isDraggingMask = true
        switch (maskTool, parameters.locals[i].shape) {
        case (.linear, _):
            parameters.locals[i].shape = .linear(start: p, end: p)
        case (.radial, _):
            parameters.locals[i].shape = .radial(centre: p, radii: SIMD2(0.001, 0.001), feather: currentFeather(i))
        case (.brush, .brush(var strokes)), (.erase, .brush(var strokes)):
            strokes.append(BrushStroke(points: [p], radius: brushRadius, feather: brushFeather,
                                       flow: brushFlow, erase: maskTool == .erase))
            parameters.locals[i].shape = .brush(strokes: strokes)
            lastDab = p
        default:
            break
        }
    }

    func maskToolMoved(to screen: CGPoint) {
        guard isDraggingMask, let i = selectedLocalIndex, i < parameters.locals.count else { return }
        let p = sensorNormalized(screen)
        switch (maskTool, parameters.locals[i].shape) {
        case (.linear, .linear(let start, _)):
            parameters.locals[i].shape = .linear(start: start, end: p)
        case (.radial, .radial(let centre, _, let feather)):
            // Distance in sensor pixels as a fraction of the short side, so
            // the circle is round whatever the aspect ratio.
            let d = (p - centre) * SIMD2(Float(sensorSize.width), Float(sensorSize.height))
            let r = max((d.x * d.x + d.y * d.y).squareRoot() / Float(min(sensorSize.width, sensorSize.height)), 0.005)
            parameters.locals[i].shape = .radial(centre: centre, radii: SIMD2(r, r), feather: feather)
        case (.brush, .brush(var strokes)), (.erase, .brush(var strokes)):
            // Space dabs at a quarter radius so the stroke reads as continuous.
            guard var last = strokes.popLast() else { return }
            let spacing = brushRadius * 0.25
            let scale = SIMD2(Float(sensorSize.width), Float(sensorSize.height)) / Float(min(sensorSize.width, sensorSize.height))
            let from = lastDab ?? p
            let delta = (p - from) * scale
            let dist = (delta.x * delta.x + delta.y * delta.y).squareRoot()
            // A zero size would make the dab count infinite, which traps.
            if spacing > 0, dist >= spacing {
                let steps = Int(dist / spacing)
                for k in 1...steps {
                    last.points.append(from + (p - from) * (Float(k) / Float(steps)))
                }
                lastDab = p
            }
            strokes.append(last)
            parameters.locals[i].shape = .brush(strokes: strokes)
        default:
            break
        }
    }

    func maskToolEnded() {
        isDraggingMask = false
        lastDab = nil
        // A gradient or radial is placed once; further drags would move it
        // again, which is rarely what's wanted. Brushes keep painting.
        if maskTool == .linear || maskTool == .radial { maskTool = .none }
    }

    private func currentFeather(_ i: Int) -> Float {
        if case .radial(_, _, let f) = parameters.locals[i].shape { return f }
        return 0.5
    }
}
