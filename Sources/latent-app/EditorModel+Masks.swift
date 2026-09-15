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

    /// Adds a model-generated mask and starts generating its pixels. The
    /// model runs off the main thread on a small sRGB copy of the image
    /// rendered *unrotated*, so the mask lands in sensor coordinates like
    /// every other mask.
    func addAIMask(_ kind: AIMaskKind) {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        let local = LocalAdjustment(name: kind.displayName,
                                    shape: .ai(kind: kind.rawValue, modelVersion: kind.modelVersion))
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        showMaskOverlay = true
        generateAIMask(for: local)
    }

    /// Regenerates masks for AI locals that have no pixels yet — after
    /// opening an image whose edit contains them.
    func regenerateMissingAIMasks() {
        guard let session else { return }
        for local in parameters.locals where local.shape.isModelGenerated {
            if !session.hasAIMask(forLocal: local.id), !generatingMasks.contains(local.id) {
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
        let tex = try pipeline.render(session, scale: .binned(quads: quads), parameters: neutral,
                                      output: .file(.sRGB))
        return try Exporter(gpu: gpu).cgImage(from: tex, colorSpace: .sRGB)
    }

    private func generateAIMask(for local: LocalAdjustment) {
        guard let session else { return }
        if case .prompted = local.shape { updatePromptedMask(for: local); return }
        guard case .ai(let kindName, _) = local.shape,
              let kind = AIMaskKind(storedName: kindName) else { return }
        generatingMasks.insert(local.id)
        status = "Generating \(kind.displayName.lowercased()) mask…"

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
        // Swift 6 concurrency shape: only Sendable values (the image
        // wrapper and the kind) cross into the detached task; the result
        // comes back as a value, and the main-actor task below is the only
        // place that touches the model or the session.
        Task { @MainActor [weak self] in
            let outcome: Result<AIMaskGenerator.Result, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try await AIMaskGenerator.generate(kind, from: input.cgImage)) }
                catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.generatingMasks.remove(localID)
            switch outcome {
            case .success(let result):
                // The user may have moved to another image while the model ran.
                guard self.session === session else { return }
                session.setAIMask(result.mask, forLocal: localID)
                self.status = String(format: "%@ mask: %.0f ms on device, %.0f%% of the frame",
                                     kind.displayName, result.seconds * 1000, result.mask.coverage * 100)
                self.rerender()
            case .failure(let error):
                self.status = "\(kind.displayName) mask failed: \(error)"
            }
        }
    }

    // MARK: Click-to-select (Segment Anything 2)

    var sam2Available: Bool { SAM2Models.isAvailable }

    /// Adds a click-to-select mask and arms the prompt tool. The image is
    /// encoded in the background right away so the first click is quick.
    func addPromptedMask() {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        let local = LocalAdjustment(name: "Selection \(parameters.locals.count + 1)",
                                    shape: .prompted(points: [], modelVersion: SAM2Models.modelVersion))
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        maskTool = .prompt
        showMaskOverlay = true
        ensureSAM2Session()
    }

    private func ensureSAM2Session() {
        guard sam2Session == nil, sam2Encoding == nil, let session else { return }
        let image: CGImage
        do { image = try modelInputImage() } catch {
            sam2Status = "Click-to-select unavailable: \(error)"
            return
        }
        let input = SendableImage(cgImage: image)
        sam2Status = "Encoding image for click-to-select…"
        sam2Encoding = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> SAM2Session? in
                guard let models = await SAM2Models.shared.value else { return nil }
                return try? SAM2Session(models: models, image: input.cgImage)
            }.value
            guard let self, self.session === session else { return nil }
            self.sam2Session = result
            self.sam2Encoding = nil
            self.sam2Status = result.map { String(format: "Image encoded in %.0f ms — click the subject; option-click to exclude", $0.encodeSeconds * 1000) }
                ?? "Click-to-select unavailable (SAM 2 models not bundled)"
            // Any prompted locals that were waiting for the encoding.
            for local in self.parameters.locals {
                if case .prompted(let pts, _) = local.shape, !pts.isEmpty { self.updatePromptedMask(for: local) }
            }
            return result
        }
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
        guard case .prompted(let points, _) = local.shape, let session else { return }
        guard !points.isEmpty else { return }
        guard let sam = sam2Session else { ensureSAM2Session(); return }
        let prompts = points.map { PromptPoint(x: $0.x, y: $0.y, foreground: $0.foreground) }
        let localID = local.id
        generatingMasks.insert(localID)
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try sam.predict(points: prompts) }
            }.value
            guard let self, self.session === session else { return }
            self.generatingMasks.remove(localID)
            switch outcome {
            case .success(let prediction):
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
    /// (rotated image space) and the rotation (back to the sensor).
    func sensorNormalized(_ screen: CGPoint) -> SIMD2<Float> {
        let canvas = viewport.sensorPoint(forScreenPoint: screen, drawableSize: drawableSize)
        let sensor = frame.sensorPoint(fromCanvasPoint: canvas)
        return SIMD2(Float(sensor.x / sensorSize.width), Float(sensor.y / sensorSize.height))
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

/// CGImage is immutable but not marked Sendable; this vouches for it.
private struct SendableImage: @unchecked Sendable { let cgImage: CGImage }
