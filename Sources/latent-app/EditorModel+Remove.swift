import Foundation
import CoreGraphics
import simd
import PixelEngine
import MLKit

extension EditorModel {
    // MARK: - Content-aware Remove

    /// Whether a click-to-select model is there for Detect Objects.
    var detectObjectsAvailable: Bool { ModelRegistry.shared.defaultPrompted() != nil }

    /// A new Remove patch as the tool made it: no source (it is set to the
    /// target so switching the patch to Heal later starts from a sensible
    /// place, `sourceForModeChange`), and nil when it is larger than
    /// Remove allows, with the reason in the status bar.
    func preparedRemovePatch(_ patch: HealPatch) -> HealPatch? {
        var p = patch
        p.mode = .remove
        p.source = p.target
        guard p.removeFitsLimit(sensorSize: sensorSize) else {
            status = String(format: "Remove covers at most %.0f%% of the short side; use Heal or Clone for long wires and large areas",
                            HealPatch.maximumRemoveExtent * 100)
            return nil
        }
        return p
    }

    /// Called once a Remove patch is placed: refines it to the object
    /// under it when Detect Objects is on.
    func removePatchPlaced(_ patch: HealPatch) {
        guard patch.mode == .remove, removeDetectsObjects, detectObjectsAvailable else { return }
        detectObject(forPatch: patch.id)
    }

    /// Runs Detect Objects on the selected Remove patch again.
    func detectObjectForSelectedPatch() {
        guard let patch = selectedHeal, patch.mode == .remove else { return }
        detectObject(forPatch: patch.id)
    }

    /// Drops the selected patch's detected outline: it fills its brush again.
    func useBrushForSelectedPatch() {
        guard let i = selectedHealIndex, i < parameters.heals.count, parameters.heals[i].objectMask != nil else { return }
        parameters.heals[i].objectMask = nil
        status = "Remove fills the brushed area"
    }

    /// Finds the outline of the object a Remove patch was brushed over, with
    /// the click-to-select model on a crop of the image around the brush,
    /// and stores it on the patch, which then fills the outline instead.
    /// The patch is filled from its brush meanwhile, and keeps that if
    /// nothing is found. Storing the outline is an edit like any other, so
    /// Undo takes it back to the brush.
    func detectObject(forPatch id: UUID) {
        guard let session, let index = parameters.heals.firstIndex(where: { $0.id == id }),
              let entry = ModelRegistry.shared.defaultPrompted(), !detectingObjectIDs.contains(id) else { return }
        let patch = parameters.heals[index]
        let image: CGImage
        do { image = try modelInputImage().image } catch {
            status = "Detect Objects unavailable: \(error)"
            return
        }
        // The brush on the output grid, where the image was rendered.
        let path = patch.pathPoints().map { outputNormalized($0) }
        let aspect = Float(image.width) / Float(max(image.height, 1))
        guard let crop = RemoveDetection.cropRect(path: path, radius: patch.radius, aspect: aspect) else { return }
        let pixelRect = CGRect(x: crop.minX * CGFloat(image.width), y: crop.minY * CGFloat(image.height),
                               width: crop.width * CGFloat(image.width), height: crop.height * CGFloat(image.height)).integral
        guard let cropped = image.cropping(to: pixelRect) else { return }
        // The crop as cut, whole pixels, so the mask lands where it was made.
        let cut = CGRect(x: pixelRect.minX / CGFloat(image.width), y: pixelRect.minY / CGFloat(image.height),
                         width: pixelRect.width / CGFloat(image.width), height: pixelRect.height / CGFloat(image.height))
        let seeds = RemoveDetection.promptPoints(along: path)
        let prompts = seeds.map { s in
            PromptPoint(x: (s.x - Float(cut.minX)) / Float(cut.width),
                        y: (s.y - Float(cut.minY)) / Float(cut.height), foreground: true)
        }
        let input = SendableImage(cgImage: cropped)
        let modelID = entry.id
        detectingObjectIDs.insert(id)
        status = "Detecting the object…"
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<MaskBitmap, Error> in
                guard let models = await ModelRegistry.shared.prompted(id: modelID) else {
                    return .failure(AIMaskError.noResult)
                }
                return Result {
                    let sam = try SAM2Session(models: models, image: input.cgImage)
                    return try sam.predict(points: prompts).mask
                }
            }.value
            guard let self else { return }
            self.detectingObjectIDs.remove(id)
            // Another image, or the patch moved, reshaped or deleted since:
            // the outline would land on something else.
            guard self.session === session,
                  let i = self.parameters.heals.firstIndex(where: { $0.id == id }),
                  self.parameters.heals[i].target == patch.target,
                  self.parameters.heals[i].stroke == patch.stroke,
                  self.parameters.heals[i].mode == .remove else { return }
            switch outcome {
            case .failure(let error):
                self.status = "Detect Objects failed: \(error); the brushed area is filled"
            case .success(let segmentation):
                let found = RemoveDetection.objectMask(
                    from: segmentation, crop: cut, seeds: seeds,
                    toOutput: { self.outputNormalized($0) }, toRaw: { self.rawNormalized($0) },
                    target: patch.target, sensorSize: self.sensorSize)
                guard let found else {
                    self.status = "No object found under the brush; the brushed area is filled"
                    return
                }
                var refined = self.parameters.heals[i]
                refined.objectMask = found
                guard refined.removeFitsLimit(sensorSize: self.sensorSize) else {
                    self.status = "The object found is larger than Remove allows; the brushed area is filled"
                    return
                }
                self.parameters.heals[i] = refined
                self.status = String(format: "Object found (%.0f%% of its box); Remove fills its outline",
                                     found.coverage * 100)
            }
        }
    }

    /// Where a patch's source goes when its mode changes: a Remove patch's
    /// source is its target, so turning it into Heal or Clone places a
    /// source beside it, as a new patch would get.
    func sourceForModeChange(of patch: HealPatch, to mode: HealPatch.Mode) -> SIMD2<Float> {
        if mode == .remove { return patch.target }
        guard patch.source == patch.target else { return patch.source }
        let offset = HealPatch.automaticStrokeOffset(patch.pathPoints(), radius: patch.radius, sensorSize: sensorSize)
        return simd_clamp(patch.target + offset, SIMD2(-1, -1), SIMD2(2, 2))
    }
}
