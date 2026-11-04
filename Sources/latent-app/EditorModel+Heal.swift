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
            if let i = selectedHealIndex, i < parameters.heals.count, parameters.heals[i].mode != newValue {
                var patch = parameters.heals[i]
                patch.source = sourceForModeChange(of: patch, to: newValue)
                patch.mode = newValue
                parameters.heals[i] = patch
            }
        }
    }

    func deleteSelectedHeal() {
        // Several selected (Select All, ⌘-click in the pin list): all go.
        if !healPinSelection.isEmpty {
            deleteHeals(selectedHealIDs)
            return
        }
        guard let i = selectedHealIndex, i < parameters.heals.count else { return }
        parameters.heals.remove(at: i)
        selectedHealIndex = parameters.heals.isEmpty ? nil : min(i, parameters.heals.count - 1)
    }

    func clearHeals() {
        parameters.heals = []
        selectedHealIndex = nil
        healPinSelection = []
    }

    /// Which patch and which of its circles (or strokes) is under `p`
    /// (normalised sensor, on the RAW grid: patches are stored there and
    /// the click has already been through `rawNormalized`).
    func hitHeal(_ p: SIMD2<Float>) -> (index: Int, isSource: Bool, offset: SIMD2<Float>)? {
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        // Selected patch first, then the most recent on top.
        var order = Array(parameters.heals.indices.reversed())
        if let s = selectedHealIndex, let k = order.firstIndex(of: s) { order.remove(at: k); order.insert(s, at: 0) }
        for i in order {
            let h = parameters.heals[i]
            let rPx = h.radius * short
            // A Remove patch has no source to grab; with an outline, a
            // click inside its box selects it too.
            if h.mode == .remove {
                if h.objectMask != nil, h.targetBounds(sensorSize: sensorSize).contains(
                    CGPoint(x: CGFloat(p.x) * sensorSize.width, y: CGFloat(p.y) * sensorSize.height)) {
                    return (i, false, p - h.target)
                }
                let reach = h.isStroke ? max(rPx, HealStrokeHandle.minimumGrabPixels / Float(max(viewport.zoom, 1e-6))) : rPx
                if h.distancePixels(from: p, sensorSize: sensorSize) <= reach { return (i, false, p - h.target) }
                continue
            }
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

    /// A click with the spot tool armed. The click lands on the corrected
    /// image; a patch is healed before the lens stage (RenderPipeline
    /// stage 5), so it is stored on the raw grid and the click goes
    /// through the lens map first, exactly as dust and touch-up do.
    func healToolBegan(at screen: CGPoint, option: Bool = false) {
        guard hasImage else { return }
        // Option: a click deletes the spot under it, a drag draws a marquee
        // and deletes every spot whose pin is inside (RemoveToolPins.swift).
        if option {
            healDrag = .marquee(screen)
            healMarquee = CGRect(origin: screen, size: .zero)
            return
        }
        let p = rawNormalized(sensorNormalized(screen))
        healPinSelection = []
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
        if healMode == .remove {
            // Remove has no source: the click places the patch, a drag moves it.
            guard let patch = preparedRemovePatch(HealPatch(target: p, source: p, radius: healRadius,
                                                            feather: healFeather, mode: .remove)) else { return }
            parameters.heals.append(stampingOpacity(patch))
            selectedHealIndex = parameters.heals.count - 1
            // Detect Objects runs when the button is let go, where it landed.
            healDrag = .placing(parameters.heals.count - 1)
            return
        }
        // Default source: 2.5 radii to the right, or to the left near the edge.
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        var offset = SIMD2(2.5 * healRadius * short / size.x, 0)
        if p.x + offset.x + healRadius * short / size.x > 1 { offset = -offset }
        let source = simd_clamp(p + offset, SIMD2(0, 0), SIMD2(1, 1))
        parameters.heals.append(stampingOpacity(HealPatch(target: p, source: source, radius: healRadius,
                                                          feather: healFeather, mode: healMode)))
        selectedHealIndex = parameters.heals.count - 1
        healDrag = .placing(parameters.heals.count - 1)
    }

    func healToolMoved(to screen: CGPoint) {
        guard let healDrag else { return }
        let p = simd_clamp(rawNormalized(sensorNormalized(screen)), SIMD2(0, 0), SIMD2(1, 1))
        switch healDrag {
        case .placing(let i) where i < parameters.heals.count && parameters.heals[i].mode == .remove:
            parameters.heals[i].target = p
            parameters.heals[i].source = p
        case .placing(let i) where i < parameters.heals.count:
            parameters.heals[i].source = p
        case .movingTarget(let i, let off) where i < parameters.heals.count:
            var patch = parameters.heals[i]
            patch.target = simd_clamp(p - off, SIMD2(0, 0), SIMD2(1, 1))
            // A Remove patch's source stays on its target.
            if patch.mode == .remove { patch.source = patch.target }
            parameters.heals[i] = patch
        case .movingSource(let i, let off) where i < parameters.heals.count:
            parameters.heals[i].source = simd_clamp(p - off, SIMD2(0, 0), SIMD2(1, 1))
        case .painting:
            addPaintedPoint(p)
        case .marquee(let start):
            healMarquee = CGRect(x: min(start.x, screen.x), y: min(start.y, screen.y),
                                 width: abs(screen.x - start.x), height: abs(screen.y - start.y))
        default:
            break
        }
    }

    func healToolEnded() {
        if case .painting = healDrag {
            let before = parameters.heals.count
            finishPaintedStroke()
            if healOpacity < 1, parameters.heals.count > before, let last = parameters.heals.last {
                parameters.heals[parameters.heals.count - 1] = stampingOpacity(last)
            }
        }
        if case .marquee(let start) = healDrag { finishHealMarquee(from: start) }
        if case .placing(let i) = healDrag, i < parameters.heals.count, parameters.heals[i].mode == .remove {
            removePatchPlaced(parameters.heals[i])
        }
        healDrag = nil
    }

    /// Turns off every on-image tool. Called when the viewport is about
    /// to be used for viewing only (Loupe, Compare) and by Escape.
    func disarmTools() {
        healToolActive = false
        redEyeToolActive = false
        dustToolActive = false
        touchUpToolActive = false
        cropToolActive = false
        geometry.guidedToolActive = false
        maskTool = .none
        pointColourPicking = false
        toneTool = .none
        defringePickerActive = false
        lensBlurState.pickingFocus = false
        healDrag = nil
        healMarquee = nil
        redEyeDrag = nil
        paintingHealStroke = []
    }

    // MARK: - Image tools (dispatch)

    /// Whether drags on the image belong to a tool rather than panning.
    var imageToolActive: Bool {
        maskToolActive || healToolActive || redEyeToolActive || dustToolActive || touchUpToolActive
            || pointColourPicking
            || toneTool != .none
            || lensBlurState.pickingFocus
    }

    func imageToolBegan(at screen: CGPoint, exclude: Bool) {
        // Point Colour's picker takes one click, then lets go on release.
        if pointColourPicking { pointColourPicked(at: screen); return }
        if toneTool != .none { toneToolBegan(at: screen); return }
        if healToolActive { healToolBegan(at: screen, option: exclude); return }
        if redEyeToolActive { redEyeToolBegan(at: screen); return }
        // Clicks only: a ring is removed or a spot added on the press.
        if dustToolActive { dustToolBegan(at: screen); return }
        if touchUpToolActive { touchUpToolBegan(at: screen); return }
        if lensBlurState.pickingFocus, !maskToolActive { lensBlurFocusPicked(at: screen); return }
        promptModifierExclude = exclude
        maskToolBegan(at: screen)
    }
    func imageToolMoved(to screen: CGPoint) {
        if pointColourPicking { return }
        if toneTool != .none { toneToolMoved(to: screen) }
        else if healToolActive { healToolMoved(to: screen) }
        else if redEyeToolActive { redEyeToolMoved(to: screen) }
        else if dustToolActive || touchUpToolActive { return }
        else if !maskToolActive && lensBlurState.pickingFocus { return }
        else { maskToolMoved(to: screen) }
    }
    func imageToolEnded() {
        if pointColourPicking { pointColourPicking = false; return }
        if toneTool != .none { toneToolEnded() }
        else if healToolActive { healToolEnded() }
        else if redEyeToolActive { redEyeToolEnded() }
        else if dustToolActive || touchUpToolActive { return }
        else if !maskToolActive && lensBlurState.pickingFocus { return }
        else { maskToolEnded() }
    }
}
