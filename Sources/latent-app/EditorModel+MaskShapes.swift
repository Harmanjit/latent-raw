import Foundation
import AppKit
import PixelEngine

/// Editing placed gradients and radials by their handles, the scroll
/// wheel over them, keeping the tool armed for several shapes in a row,
/// the Luminance and Channel Range eyedropper and probe, and Show Channel.
struct MaskShapeEditing {
    /// A handle drag in progress: which handle, the shape as it was at
    /// the press, and where the press was.
    struct Drag {
        let handle: MaskShapeHandle
        let shape: MaskShape
        let pressed: SIMD2<Float>
    }
    var drag: Drag?
    /// The element a kept-armed gradient or radial tool placed last: the
    /// next drag away from it places another shape instead of redrawing.
    var placedElement: UUID?
}

extension EditorModel {
    // MARK: - Keep tool armed

    static let keepMaskToolArmedKey = "maskKeepToolArmed"

    /// Mask tools ▸ Keep tool armed: a gradient or radial tool stays armed
    /// after placing a shape, so the next drag places another. Off by
    /// default, as the tools always were.
    var keepMaskToolArmed: Bool {
        UserDefaults.standard.bool(forKey: Self.keepMaskToolArmedKey)
    }

    /// With the tool kept armed and the shape it placed still selected, a
    /// press away from that shape starts a new mask (or, for a component,
    /// a new component in the same mode) of the same kind. Returns the
    /// new element, or nil when the press reshapes the current one.
    func spawnShapeIfKeptArmed(from element: MaskElement, at p: SIMD2<Float>) -> MaskElement? {
        guard keepMaskToolArmed, maskShapeEditing.placedElement == element.id,
              maskTool == .linear || maskTool == .radial, !element.shape.isEmpty else { return nil }
        // Inside a radial still moves it.
        if maskTool == .radial, element.shape.contains(p, sensorSize: sensorSizeVector) { return nil }
        let tool = maskTool
        if let component = selectedMaskComponent {
            guard canAddMaskComponent else { return nil }
            addMaskComponent(tool == .linear ? .linear : .radial, mode: component.mode)
        } else {
            guard parameters.locals.count < LocalAdjustment.maximumCount else { return nil }
            addLocal(tool)
        }
        maskShapeEditing.placedElement = nil
        return activeMaskElement
    }

    // MARK: - Handles

    var sensorSizeVector: SIMD2<Float> {
        SIMD2(Float(max(sensorSize.width, 1)), Float(max(sensorSize.height, 1)))
    }

    /// A normalised output-grid point -> the drawable pixel it shows at.
    func screenPoint(fromNormalized n: SIMD2<Float>) -> CGPoint {
        let sensor = CGPoint(x: CGFloat(n.x) * sensorSize.width, y: CGFloat(n.y) * sensorSize.height)
        let canvas = frame.canvasPoint(fromSensorPoint: sensor)
        return viewport.screenPoint(forSensorPoint: canvas, drawableSize: drawableSize)
    }

    /// Whether the handles of the selected gradient or radial are live:
    /// its own tool is armed.
    var maskHandlesActive: Bool {
        guard maskToolActive, let element = activeMaskElement else { return false }
        switch (maskTool, element.shape) {
        case (.linear, .linear), (.radial, .radial): return true
        default: return false
        }
    }

    /// The handle under a drawable-pixel point, within about 9 points.
    /// A radial's centre is left out: a press anywhere inside moves it.
    func maskHandle(atScreen screen: CGPoint) -> MaskShapeHandle? {
        guard maskHandlesActive, let element = activeMaskElement, !element.shape.isEmpty else { return nil }
        let reach = 9 * (NSScreen.main?.backingScaleFactor ?? 2)
        var best: (MaskShapeHandle, CGFloat)?
        for (handle, point) in element.shape.handlePositions(sensorSize: sensorSizeVector) where handle != .radialCentre {
            let s = screenPoint(fromNormalized: point)
            let d = hypot(s.x - screen.x, s.y - screen.y)
            if d <= reach, d < (best?.1 ?? .infinity) { best = (handle, d) }
        }
        return best?.0
    }

    /// Starts dragging a handle if the press is on one.
    func beginMaskHandleDrag(atScreen screen: CGPoint, normalized p: SIMD2<Float>) -> Bool {
        guard let handle = maskHandle(atScreen: screen), let element = activeMaskElement else { return false }
        maskShapeEditing.drag = .init(handle: handle, shape: element.shape, pressed: p)
        return true
    }

    /// Moves the dragged handle; false when no handle is being dragged.
    func moveMaskHandle(to p: SIMD2<Float>) -> Bool {
        guard let drag = maskShapeEditing.drag else { return false }
        setActiveMaskShape(drag.shape.dragging(drag.handle, from: drag.pressed, to: p, sensorSize: sensorSizeVector))
        return true
    }

    // MARK: - Scroll wheel

    /// A mouse-wheel notch over the selected gradient or radial while its
    /// tool is armed: the feather (a gradient's fade) changes, or with ⇧
    /// the mask's Amount. Returns false to let the wheel pan as usual.
    func maskToolScrolled(atScreen screen: CGPoint, delta: CGFloat, shift: Bool) -> Bool {
        guard maskHandlesActive, !isDraggingMask, delta != 0,
              let i = selectedLocalIndex, i < parameters.locals.count,
              let element = activeMaskElement,
              element.shape.contains(sensorNormalized(screen), sensorSize: sensorSizeVector) else { return false }
        let step: Float = delta > 0 ? 1 : -1
        if shift {
            parameters.locals[i].amount = min(max(parameters.locals[i].amount + step * 0.05, 0), 1)
            status = String(format: "Mask Amount %.0f%%", parameters.locals[i].amount * 100)
        } else {
            let changed = element.shape.scrollingFeather(by: step * 0.02)
            setActiveMaskShape(changed)
            if case .radial(_, _, let feather, _) = changed {
                status = String(format: "Feather %.2f", feather)
            }
        }
        return true
    }

    // MARK: - Luminance and Channel Range eyedropper

    /// The selected range component the eyedropper and probe serve, and
    /// the channel it reads (nil: displayed luminance); falls back to the
    /// mask's own Luminance range when no range component is selected.
    var selectedRangeTarget: (component: UUID?, channel: MaskChannel?)? {
        guard let local = selectedLocal else { return nil }
        if let component = selectedMaskComponent {
            switch component.source {
            case .luminance: return (component.id, nil)
            case .channel(let r): return (component.id, r.channel)
            default: return nil
            }
        }
        return local.luminanceRange != nil ? (nil, nil) : nil
    }

    func beginRangeSample(at p: SIMD2<Float>) {
        isDraggingMask = true
        lastDab = p
        maskDragBox = CGRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0, height: 0)
    }

    /// A click sets Low and High 10% either side of the value under it; a
    /// dragged rectangle sets them to the least and most inside it. The
    /// fades stay as they were. The eyedropper puts itself away.
    func finishRangeSample(_ box: CGRect) {
        defer { maskTool = .none }
        guard let target = selectedRangeTarget, let i = selectedLocalIndex, i < parameters.locals.count else { return }
        let inputs = { (w: SIMD3<Float>) in
            MaskRangeInputs(working: w, contrast: self.parameters.contrast, greyPoint: self.parameters.greyPoint,
                            toneRanges: self.parameters.toneRanges).value(target.channel)
        }
        let centre = SIMD2(Float(box.midX), Float(box.midY))
        guard let w = workingColour(at: centre) else { return }
        var values = [inputs(w)]
        if box.width > 0.003 || box.height > 0.003, let cache = colourSampleCache, cache.width > 0, cache.height > 0 {
            let x0 = max(Int(box.minX * CGFloat(cache.width)), 0), x1 = min(Int(box.maxX * CGFloat(cache.width)), cache.width - 1)
            let y0 = max(Int(box.minY * CGFloat(cache.height)), 0), y1 = min(Int(box.maxY * CGFloat(cache.height)), cache.height - 1)
            if x1 >= x0, y1 >= y0 {
                let stride = max(1, Int((Double((x1 - x0 + 1) * (y1 - y0 + 1)) / 4096).squareRoot().rounded(.up)))
                values = []
                for y in Swift.stride(from: y0, through: y1, by: stride) {
                    for x in Swift.stride(from: x0, through: x1, by: stride) {
                        let o = (y * cache.width + x) * 4
                        values.append(inputs(SIMD3(Float(cache.pixels[o]), Float(cache.pixels[o + 1]), Float(cache.pixels[o + 2]))))
                    }
                }
            }
        }
        let picked = values.count == 1
        setSelectedRangeBand { band in
            if picked {
                var around = MaskRangeBand.around(values[0], feather: band.featherLow)
                around.featherHigh = band.featherHigh
                return around.sanitised()
            }
            return MaskRangeBand(low: values.min() ?? band.low, high: values.max() ?? band.high,
                                 featherLow: band.featherLow, featherHigh: band.featherHigh).sanitised()
        }
        if let band = selectedRangeBand {
            status = String(format: "Range set from the %@: %.2f to %.2f", picked ? "picked spot" : "rectangle",
                            band.low, band.high)
        }
    }

    /// The selected range's band (component or the mask's own range).
    var selectedRangeBand: MaskRangeBand? {
        guard let target = selectedRangeTarget, let local = selectedLocal else { return nil }
        guard let id = target.component else { return local.luminanceRange?.band }
        switch local.components.first(where: { $0.id == id })?.source {
        case .luminance(let l): return l.band
        case .channel(let r): return r.band
        default: return nil
        }
    }

    func setSelectedRangeBand(_ change: (MaskRangeBand) -> MaskRangeBand) {
        guard let target = selectedRangeTarget, let i = selectedLocalIndex, i < parameters.locals.count else { return }
        guard let id = target.component else {
            if var l = parameters.locals[i].luminanceRange { l.band = change(l.band); parameters.locals[i].luminanceRange = l }
            return
        }
        guard let c = parameters.locals[i].components.firstIndex(where: { $0.id == id }) else { return }
        switch parameters.locals[i].components[c].source {
        case .luminance(var l): l.band = change(l.band); parameters.locals[i].components[c].source = .luminance(l)
        case .channel(var r): r.band = change(r.band); parameters.locals[i].components[c].source = .channel(r)
        default: break
        }
    }

    // MARK: - Probe

    /// The value the selected range reads under the pointer, from the same
    /// render without locals the eyedroppers read (one render, then kept).
    func updateMaskRangeProbe(atScreen screen: CGPoint?) {
        var value: Float?
        if let screen, hasImage, let target = selectedRangeTarget {
            let p = sensorNormalized(screen)
            if p.x >= 0, p.y >= 0, p.x <= 1, p.y <= 1, let w = workingColour(at: p) {
                value = MaskRangeInputs(working: w, contrast: parameters.contrast, greyPoint: parameters.greyPoint,
                                        toneRanges: parameters.toneRanges).value(target.channel)
            }
        }
        if maskRangeProbe != value { maskRangeProbe = value }
    }

    // MARK: - Show Channel

    /// Whether the selected component has a channel to show.
    var canShowMaskChannel: Bool { selectedMaskComponent?.showsChannel == true }

    /// The display output with Show Channel's grey, when it is on and the
    /// selected component is a range.
    func applyMaskChannelView(to output: inout RenderOutput) {
        guard showMaskChannel, let i = selectedLocalIndex, i < parameters.locals.count,
              let id = selectedMaskComponentID,
              let k = parameters.locals[i].components.firstIndex(where: { $0.id == id }),
              parameters.locals[i].components[k].showsChannel else { return }
        if output.maskOverlay != i { output.maskOverlayStyle = MaskOverlaySettings.shared.style }
        output.maskOverlay = i
        output.maskOverlayStyle.channelComponent = k
    }
}
