import Foundation
import simd
import PixelEngine

extension EditorModel {
    // MARK: - Spot removal tool

    var selectedHeal: HealPatch? {
        guard let i = selectedHealIndex, i < parameters.heals.count else { return nil }
        return parameters.heals[i]
    }

    /// Radius of the selected patch (or the default), in sensor pixels.
    var activeHealRadiusPixels: Float {
        get { (selectedHeal?.radius ?? healRadius) * Float(min(sensorSize.width, sensorSize.height)) }
        set {
            let short = Float(min(sensorSize.width, sensorSize.height))
            guard short > 0 else { return }
            let r = max(0.001, min(0.25, newValue / short))
            healRadius = r
            if let i = selectedHealIndex, i < parameters.heals.count { parameters.heals[i].radius = r }
        }
    }
    var activeHealFeather: Float {
        get { selectedHeal?.feather ?? healFeather }
        set {
            healFeather = newValue
            if let i = selectedHealIndex, i < parameters.heals.count { parameters.heals[i].feather = newValue }
        }
    }
    var activeHealMode: HealPatch.Mode {
        get { selectedHeal?.mode ?? healMode }
        set {
            healMode = newValue
            if let i = selectedHealIndex, i < parameters.heals.count { parameters.heals[i].mode = newValue }
        }
    }

    func deleteSelectedHeal() {
        guard let i = selectedHealIndex, i < parameters.heals.count else { return }
        parameters.heals.remove(at: i)
        selectedHealIndex = parameters.heals.isEmpty ? nil : min(i, parameters.heals.count - 1)
    }

    func clearHeals() {
        parameters.heals = []
        selectedHealIndex = nil
    }

    /// Which patch and which of its circles (or strokes) is under `p`
    /// (normalized sensor).
    private func hitHeal(_ p: SIMD2<Float>) -> (index: Int, isSource: Bool, offset: SIMD2<Float>)? {
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        // Selected patch first, then the most recent on top.
        var order = Array(parameters.heals.indices.reversed())
        if let s = selectedHealIndex, let k = order.firstIndex(of: s) { order.remove(at: k); order.insert(s, at: 0) }
        for i in order {
            let h = parameters.heals[i]
            let rPx = h.radius * short
            if h.isStroke {
                // A thin stroke is hard to grab by its width alone.
                let reach = max(rPx, HealStrokeHandle.minimumGrabPixels / Float(max(viewport.zoom, 1e-6)))
                if h.distancePixels(from: p, atSource: true, sensorSize: sensorSize) <= reach { return (i, true, p - h.source) }
                if h.distancePixels(from: p, sensorSize: sensorSize) <= reach { return (i, false, p - h.target) }
                continue
            }
            if simd_length((p - h.source) * size) <= rPx { return (i, true, p - h.source) }
            if simd_length((p - h.target) * size) <= rPx { return (i, false, p - h.target) }
        }
        return nil
    }

    func healToolBegan(at screen: CGPoint) {
        guard hasImage else { return }
        let p = sensorNormalized(screen)
        if let hit = hitHeal(p) {
            selectedHealIndex = hit.index
            healDrag = hit.isSource ? .movingSource(hit.index, hit.offset) : .movingTarget(hit.index, hit.offset)
            return
        }
        guard parameters.heals.count < HealPatch.maximumCount else {
            status = "At most \(HealPatch.maximumCount) spot patches per image"
            return
        }
        if healShape == .brush {
            // Painted strokes become a patch when the drag ends.
            selectedHealIndex = nil
            paintingHealStroke = [p]
            healDrag = .painting
            return
        }
        // Default source: 2.5 radii to the right, or to the left near the edge.
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        var offset = SIMD2(2.5 * healRadius * short / size.x, 0)
        if p.x + offset.x + healRadius * short / size.x > 1 { offset = -offset }
        let source = simd_clamp(p + offset, SIMD2(0, 0), SIMD2(1, 1))
        parameters.heals.append(HealPatch(target: p, source: source, radius: healRadius,
                                          feather: healFeather, mode: healMode))
        selectedHealIndex = parameters.heals.count - 1
        healDrag = .placing(parameters.heals.count - 1)
    }

    func healToolMoved(to screen: CGPoint) {
        guard let healDrag else { return }
        let p = simd_clamp(sensorNormalized(screen), SIMD2(0, 0), SIMD2(1, 1))
        switch healDrag {
        case .placing(let i) where i < parameters.heals.count:
            parameters.heals[i].source = p
        case .movingTarget(let i, let off) where i < parameters.heals.count:
            parameters.heals[i].target = simd_clamp(p - off, SIMD2(0, 0), SIMD2(1, 1))
        case .movingSource(let i, let off) where i < parameters.heals.count:
            parameters.heals[i].source = simd_clamp(p - off, SIMD2(0, 0), SIMD2(1, 1))
        case .painting:
            addPaintedPoint(p)
        default:
            break
        }
    }

    func healToolEnded() {
        if case .painting = healDrag { finishPaintedStroke() }
        healDrag = nil
    }

    /// Turns off every on-image tool. Called when the viewport is about
    /// to be used for viewing only (Loupe, Compare) and by Escape.
    func disarmTools() {
        healToolActive = false
        redEyeToolActive = false
        cropToolActive = false
        maskTool = .none
        healDrag = nil
        redEyeDrag = nil
        paintingHealStroke = []
    }

    // MARK: - Image tools (dispatch)

    /// Whether drags on the image belong to a tool rather than panning.
    var imageToolActive: Bool { maskToolActive || healToolActive || redEyeToolActive }

    func imageToolBegan(at screen: CGPoint, exclude: Bool) {
        if healToolActive { healToolBegan(at: screen); return }
        if redEyeToolActive { redEyeToolBegan(at: screen); return }
        promptModifierExclude = exclude
        maskToolBegan(at: screen)
    }
    func imageToolMoved(to screen: CGPoint) {
        if healToolActive { healToolMoved(to: screen) }
        else if redEyeToolActive { redEyeToolMoved(to: screen) }
        else { maskToolMoved(to: screen) }
    }
    func imageToolEnded() {
        if healToolActive { healToolEnded() }
        else if redEyeToolActive { redEyeToolEnded() }
        else { maskToolEnded() }
    }
}
