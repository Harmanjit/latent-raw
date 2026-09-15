import Foundation
import CoreGraphics
import simd
import PixelEngine
import MLKit

/// What a drag on empty image does with the spot removal tool.
enum HealShape: String, CaseIterable, Identifiable {
    /// A circle: click a spot, or drag from it to choose the source.
    case spot
    /// A painted stroke, for wires, hairs and dust streaks.
    case brush

    var id: String { rawValue }
}

enum HealStrokeHandle {
    /// However thin a stroke, it can be grabbed this many drawable pixels
    /// from its path.
    static let minimumGrabPixels: Float = 8
}

extension EditorModel {
    // MARK: - Painting a heal stroke

    /// Adds a point to the stroke being painted, once the mouse has moved a
    /// quarter of the brush radius, so a slow drag doesn't pile up points.
    func addPaintedPoint(_ p: SIMD2<Float>) {
        let scale = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let spacing = 0.25 * healRadius * min(scale.x, scale.y)
        guard let last = paintingHealStroke.last else { paintingHealStroke = [p]; return }
        guard simd_length((p - last) * scale) >= max(spacing, 1) else { return }
        paintingHealStroke.append(p)
        // A very long drag is simplified as it goes, so the overlay and the
        // final simplification stay quick.
        if paintingHealStroke.count > 4 * HealPatch.maximumStrokePoints {
            paintingHealStroke = HealPatch.simplifiedStroke(paintingHealStroke, radius: healRadius, sensorSize: sensorSize)
        }
    }

    /// Turns the painted path into one patch: a stroke, or a circle when
    /// the mouse barely moved, each with its source placed automatically.
    func finishPaintedStroke() {
        let path = paintingHealStroke
        paintingHealStroke = []
        guard let first = path.first, parameters.heals.count < HealPatch.maximumCount else { return }
        let scale = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let reach = path.map { simd_length(($0 - first) * scale) }.max() ?? 0
        let patch: HealPatch?
        if reach < healRadius * min(scale.x, scale.y) * 0.5 {
            let offset = HealPatch.automaticStrokeOffset([first], radius: healRadius, sensorSize: sensorSize)
            patch = HealPatch(target: first, source: simd_clamp(first + offset, SIMD2(0, 0), SIMD2(1, 1)),
                              radius: healRadius, feather: healFeather, mode: healMode)
        } else {
            patch = HealPatch.stroke(path: path, radius: healRadius, feather: healFeather, mode: healMode,
                                     sensorSize: sensorSize)
        }
        guard let patch else { return }
        parameters.heals.append(patch)
        selectedHealIndex = parameters.heals.count - 1
    }

    // MARK: - Red-eye tool

    enum RedEyeDrag {
        /// A new spot: dragging sizes it from its centre.
        case sizing(Int)
        case moving(Int, SIMD2<Float>)
        case resizing(Int)
    }

    var selectedRedEye: RedEyeSpot? {
        guard let i = selectedRedEyeIndex, i < parameters.redEyes.count else { return nil }
        return parameters.redEyes[i]
    }

    /// Radius of the selected spot (or the default), in sensor pixels.
    var activeRedEyeRadiusPixels: Float {
        get { (selectedRedEye?.radius ?? redEyeRadius) * Float(min(sensorSize.width, sensorSize.height)) }
        set {
            let short = Float(min(sensorSize.width, sensorSize.height))
            guard short > 0 else { return }
            let r = max(0.0005, min(0.1, newValue / short))
            redEyeRadius = r
            if let i = selectedRedEyeIndex, i < parameters.redEyes.count { parameters.redEyes[i].radius = r }
        }
    }

    var activeRedEyeStrength: Float {
        get { selectedRedEye?.strength ?? 1 }
        set {
            guard let i = selectedRedEyeIndex, i < parameters.redEyes.count else { return }
            parameters.redEyes[i].strength = min(max(newValue, 0), 1)
        }
    }

    func deleteSelectedRedEye() {
        guard let i = selectedRedEyeIndex, i < parameters.redEyes.count else { return }
        parameters.redEyes.remove(at: i)
        selectedRedEyeIndex = parameters.redEyes.isEmpty ? nil : min(i, parameters.redEyes.count - 1)
    }

    func clearRedEyes() {
        parameters.redEyes = []
        selectedRedEyeIndex = nil
    }

    /// The spot under `p` (normalized sensor), and whether `p` is on its
    /// rim, which resizes, rather than inside, which moves.
    private func hitRedEye(_ p: SIMD2<Float>) -> (index: Int, onRim: Bool)? {
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        let grab = HealStrokeHandle.minimumGrabPixels / Float(max(viewport.zoom, 1e-6))
        var order = Array(parameters.redEyes.indices.reversed())
        if let s = selectedRedEyeIndex, let k = order.firstIndex(of: s) { order.remove(at: k); order.insert(s, at: 0) }
        for i in order {
            let spot = parameters.redEyes[i]
            let d = simd_length((p - spot.centre) * size), r = spot.radius * short
            // The rim band is at most half the radius deep, so a small spot
            // seen from far out still has a middle to move it by.
            if abs(d - r) <= min(grab, 0.5 * r) { return (i, true) }
            if d < r { return (i, false) }
        }
        return nil
    }

    func redEyeToolBegan(at screen: CGPoint) {
        guard hasImage else { return }
        let p = simd_clamp(sensorNormalized(screen), SIMD2(0, 0), SIMD2(1, 1))
        if let hit = hitRedEye(p) {
            selectedRedEyeIndex = hit.index
            redEyeDrag = hit.onRim ? .resizing(hit.index) : .moving(hit.index, p - parameters.redEyes[hit.index].centre)
            return
        }
        guard parameters.redEyes.count < RedEyeSpot.maximumCount else {
            status = "At most \(RedEyeSpot.maximumCount) red-eye spots per image"
            return
        }
        parameters.redEyes.append(RedEyeSpot(centre: p, radius: redEyeRadius))
        selectedRedEyeIndex = parameters.redEyes.count - 1
        redEyeDrag = .sizing(parameters.redEyes.count - 1)
    }

    func redEyeToolMoved(to screen: CGPoint) {
        guard let redEyeDrag else { return }
        let p = simd_clamp(sensorNormalized(screen), SIMD2(0, 0), SIMD2(1, 1))
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        switch redEyeDrag {
        case .moving(let i, let off) where i < parameters.redEyes.count:
            parameters.redEyes[i].centre = simd_clamp(p - off, SIMD2(0, 0), SIMD2(1, 1))
        case .sizing(let i) where i < parameters.redEyes.count, .resizing(let i) where i < parameters.redEyes.count:
            let d = simd_length((p - parameters.redEyes[i].centre) * size)
            // A click that wobbles a pixel or two keeps the default size.
            if case .sizing = redEyeDrag, d < 3 { return }
            activeRedEyeRadiusPixels = max(d, 2)
        default:
            break
        }
    }

    func redEyeToolEnded() { redEyeDrag = nil }

    /// Finds red eyes with Vision's face landmarks on a small render of the
    /// edit, and adds a spot for each red pupil that has none yet.
    func autoDetectRedEyes() {
        guard let session, let pipeline, let gpu = gpuContext, !detectingRedEyes else { return }
        let summary = session.file.summary
        // About 1600 px on the long edge: faces big enough to show red eyes
        // are found there. No lens geometry, so pixels are sensor positions.
        let quads = max(1, Int((Double(max(summary.rawWidth, summary.rawHeight)) / 3200).rounded(.up)))
        var look = parameters
        look.redEyes = []
        look.lensDistortion = false
        look.lensTCA = false
        look.manualDistortion = 0
        look.perspective = .none
        let image: CGImage
        do {
            let texture = try pipeline.render(session, scale: .binned(quads: quads), parameters: look,
                                              output: .file(.sRGB))
            image = try Exporter(gpu: gpu).cgImage(from: texture, colorSpace: .sRGB)
        } catch {
            status = "Red-eye detection failed: \(error)"
            return
        }
        detectingRedEyes = true
        status = "Looking for red eyes…"
        let input = RedEyeInput(cgImage: image, rotation: rotation)
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                RedEyeDetector.detect(in: input.cgImage, rotation: input.rotation)
            }.value
            guard let self else { return }
            self.detectingRedEyes = false
            // The user may have moved to another image meanwhile.
            guard self.session === session else { return }
            let short = Float(min(self.sensorSize.width, self.sensorSize.height))
            let size = SIMD2(Float(self.sensorSize.width), Float(self.sensorSize.height))
            var spots = self.parameters.redEyes
            let before = spots.count
            for spot in found where spots.count < RedEyeSpot.maximumCount {
                let covered = spots.contains { simd_length(($0.centre - spot.centre) * size) < $0.radius * short }
                if !covered { spots.append(spot) }
            }
            let added = spots.count - before
            if added > 0 {
                self.parameters.redEyes = spots
                self.selectedRedEyeIndex = spots.count - 1
            }
            self.status = SpokenText.redEyesFound(added: added, detected: found.count)
            Announcement.post(self.status)
        }
    }
}

/// The detector's input, carried to the detached task: CGImage is immutable
/// but not marked Sendable.
private struct RedEyeInput: @unchecked Sendable {
    let cgImage: CGImage
    let rotation: ImageRotation
}
