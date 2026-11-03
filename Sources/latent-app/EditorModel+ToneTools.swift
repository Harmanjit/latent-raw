import SwiftUI
import ColorKit
import PixelEngine

/// An on-image tool from the tone and colour panels.
enum ToneTool: Equatable {
    case none
    /// The White Balance Selector (W): click something neutral.
    case whiteBalance
    /// The Tone Curve's targeted tool: drag up or down on a tone.
    case curve
    /// The HSL panel's targeted tool, for one of its three sliders.
    case colour(HSLComponent)

    /// What the hint over the image says while it's armed.
    var hint: String {
        switch self {
        case .none: return ""
        case .whiteBalance: return "Click something that should be neutral grey or white. Esc cancels."
        case .curve: return "Drag up or down on a tone to lighten or darken it. Esc leaves the tool."
        case .colour(let c): return "Drag up or down on a colour to change its \(c.title.lowercased()). Esc leaves the tool."
        }
    }
}

/// Which of the HSL panel's three slider sets a targeted drag moves.
enum HSLComponent: Int, CaseIterable, Identifiable {
    case hue, saturation, luminance
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .luminance: return "Luminance"
        }
    }
}

/// The Tone Curve panel's two editors.
enum CurveEditorMode: String, CaseIterable, Identifiable {
    case point, parametric
    var id: String { rawValue }
    var title: String { self == .point ? "Point" : "Region" }
}

/// A targeted drag in progress: where it started and what it moves.
struct ToneToolDrag {
    enum Target {
        /// A parametric region, from its starting amount.
        case region(ParametricCurve.Region, start: Float)
        /// A point of the master point curve, from its starting height.
        case point(index: Int, start: Float)
        /// The HSL bands under a hue, each from its starting value.
        case bands(HSLComponent, weights: [Float], start: [Float])
    }
    var origin: CGPoint
    var target: Target
}

/// The colour under the pointer, for the readout under the histogram.
@MainActor
final class PixelProbe: ObservableObject {
    @Published var readout: PixelReadout?
    /// The texture pixel last read, by layer generation, and its colour:
    /// pointer moves within one pixel don't read the GPU again.
    var last: (generation: UInt64, x: Int, y: Int, colour: SIMD3<Float>)?
}

extension EditorModel {
    /// Drawable pixels of drag for a full −1…1 slider's travel.
    static let targetedDragSpan: CGFloat = 400

    func toneToolDidChange() {
        toneToolDrag = nil
        guard toneTool != .none else { return }
        healToolActive = false; redEyeToolActive = false; dustToolActive = false
        touchUpToolActive = false; cropToolActive = false; maskTool = .none
    }

    // MARK: - Sampling the picture

    /// The displayed colour (linear Display P3) at a screen point, from
    /// the full-resolution tile where it covers and the preview elsewhere;
    /// nil off the picture. One pixel is copied back, so this is cheap
    /// enough for every pointer move.
    func displayedPixel(atScreen screen: CGPoint) -> SIMD3<Float>? {
        guard hasImage, let gpu = gpuContext, let preview, drawableSize.width > 0 else { return nil }
        let canvas = viewport.sensorPoint(forScreenPoint: screen, drawableSize: drawableSize)
        let size = frame.canvasSize
        guard canvas.x >= 0, canvas.y >= 0, canvas.x < size.width, canvas.y < size.height else { return nil }
        let sensor = frame.sensorPoint(fromCanvasPoint: canvas)
        let layer: PresentLayer
        if let tile, tile.coverage.insetBy(dx: tile.inset, dy: tile.inset).contains(sensor) {
            layer = tile
        } else if preview.coverage.contains(sensor) {
            layer = preview
        } else {
            return nil
        }
        let c = layer.coverage
        let x = Int((sensor.x - c.minX) / c.width * CGFloat(layer.texture.width))
        let y = Int((sensor.y - c.minY) / c.height * CGFloat(layer.texture.height))
        if let last = pixelProbe.last, last.generation == layer.generation, last.x == x, last.y == y {
            return last.colour
        }
        guard let px = try? TextureReadback.float16Pixels(of: layer.texture, x: x, y: y, width: 1, height: 1, gpu: gpu),
              px.count >= 3 else { return nil }
        let colour = SIMD3(Float(px[0]), Float(px[1]), Float(px[2]))
        pixelProbe.last = (layer.generation, x, y, colour)
        return colour
    }

    /// The pointer moved over the image (nil: it left).
    func pointerMoved(to screen: CGPoint?) {
        let readout = screen.flatMap { displayedPixel(atScreen: $0) }.map { PixelReadout(linearDisplayP3: $0) }
        if pixelProbe.readout != readout { pixelProbe.readout = readout }
    }

    // MARK: - Clipping overlay

    /// J: both indicators on, or off.
    func toggleClipping() {
        clipping = clipping.isEmpty ? .both : []
    }

    // MARK: - White balance

    /// The menu's current choice, nil for a custom setting.
    var whiteBalancePreset: WhiteBalancePreset? {
        let auto = autoWhiteBalance.flatMap { $0.url == sourceURL ? $0.balance : nil }
        return WhiteBalancePreset.matching(parameters.whiteBalance, asShot: asShotWhiteBalance, auto: auto)
    }

    func applyWhiteBalancePreset(_ preset: WhiteBalancePreset) {
        guard hasImage else { return }
        switch preset {
        case .asShot:
            resetWhiteBalance()
        case .auto:
            guard let session, let pipeline, let gpuContext else { return }
            do {
                guard let wb = try AutoAdjust.suggestWhiteBalance(for: session, pipeline: pipeline,
                                                                  gpu: gpuContext, current: parameters) else {
                    status = "Auto white balance needs the camera's colour profile, which this file doesn't have."
                    return
                }
                autoWhiteBalance = (sourceURL, wb)
                parameters.whiteBalance = wb
            } catch {
                status = "Auto white balance failed: \(error)"
            }
        default:
            if let wb = preset.fixed { parameters.whiteBalance = wb }
        }
    }

    /// The Kelvin field beside the Temperature slider.
    var temperatureKelvinBinding: Binding<Float> {
        Binding(get: { self.parameters.whiteBalance.temperature },
                set: { kelvin in
                    let range = ColorKit.WhiteBalance.temperatureRange
                    self.parameters.whiteBalance.temperature = min(max(kelvin, range.lowerBound), range.upperBound)
                })
    }

    /// W: arm or disarm the White Balance Selector.
    func toggleWhiteBalanceSelector() {
        toneTool = toneTool == .whiteBalance ? .none : .whiteBalance
    }

    private func pickWhiteBalance(at screen: CGPoint) {
        guard let session, let pipeline, let gpuContext else { return }
        let canvas = viewport.sensorPoint(forScreenPoint: screen, drawableSize: drawableSize)
        let size = frame.canvasSize
        guard canvas.x >= 0, canvas.y >= 0, canvas.x < size.width, canvas.y < size.height else { return }
        // The camera-space render is before the lens stage; the click is
        // on the corrected picture.
        let point = rawNormalized(sensorNormalized(screen))
        do {
            switch try WhiteBalancePicker.whiteBalance(at: point, session: session, pipeline: pipeline,
                                                       gpu: gpuContext, parameters: parameters) {
            case .balanced(let wb):
                parameters.whiteBalance = wb
                status = String(format: "White balance set from the picked spot: %.0f K, tint %+.0f.",
                                wb.temperature, wb.tint)
                // Lightroom's default: the selector puts itself away.
                toneTool = .none
            case .clipped:
                status = "That spot is clipped, so its colour can't be trusted. Pick something a little darker."
            case .tooDark:
                status = "That spot is too dark to judge its colour. Pick something lighter."
            case .noProfile:
                status = "This file has no camera colour profile, so white balance can't be picked."
                toneTool = .none
            }
        } catch {
            status = "Couldn't read the picked spot: \(error)"
        }
    }

    // MARK: - Targeted adjustment

    func toneToolBegan(at screen: CGPoint) {
        switch toneTool {
        case .none:
            return
        case .whiteBalance:
            pickWhiteBalance(at: screen)
        case .curve:
            guard let tone = toneBeforeCurve(atScreen: screen) else { return }
            if curveEditorMode == .parametric {
                let region = parameters.parametricCurve.region(containing: tone)
                toneToolDrag = ToneToolDrag(origin: screen,
                                            target: .region(region, start: parameters.parametricCurve.amounts[region.rawValue]))
            } else {
                let (curve, index) = Self.curve(parameters.toneCurve, withPointAt: tone)
                parameters.toneCurve = curve
                toneToolDrag = ToneToolDrag(origin: screen, target: .point(index: index, start: curve.points[index].y))
            }
        case .colour(let component):
            guard let linear = displayedPixel(atScreen: screen) else { return }
            let hue = PixelReadout(linearDisplayP3: linear).gradingCoordinates(headroom: displayOutput.headroom).hue
            let weights = HSLAdjustments.bandWeights(hue: hue)
            toneToolDrag = ToneToolDrag(origin: screen,
                                        target: .bands(component, weights: weights, start: hslValues(component)))
        }
    }

    func toneToolMoved(to screen: CGPoint) {
        guard let drag = toneToolDrag else { return }
        // Up is more, as in Lightroom.
        let amount = Float((drag.origin.y - screen.y) / Self.targetedDragSpan) * 2
        switch drag.target {
        case .region(let region, let start):
            var curve = parameters.parametricCurve
            var amounts = curve.amounts
            amounts[region.rawValue] = min(max(start + amount, -1), 1)
            curve.amounts = amounts
            parameters.parametricCurve = curve
        case .point(let index, let start):
            guard parameters.toneCurve.points.indices.contains(index) else { return }
            parameters.toneCurve.points[index].y = min(max(start + amount / 4, 0), 1)
        case .bands(let component, let weights, let start):
            var values = start
            for i in values.indices { values[i] = min(max(start[i] + weights[i] * amount, -1), 1) }
            setHSLValues(values, component)
        }
    }

    func toneToolEnded() {
        toneToolDrag = nil
    }

    /// The tone the master curve took as input at a screen point: the
    /// displayed tone traced back through the curve as it is now.
    func toneBeforeCurve(atScreen screen: CGPoint) -> Float? {
        guard let linear = displayedPixel(atScreen: screen) else { return nil }
        let shown = PixelReadout(linearDisplayP3: linear).gradingCoordinates(headroom: displayOutput.headroom).luma
        guard parameters.wantsMasterCurve else { return shown }
        let lut = parameters.toneCurve.masterLookupTable(parametric: parameters.parametricCurve)
        return ToneCurve.inverse(lut, at: shown)
    }

    /// The point curve with a point at input `x`: the nearest existing
    /// inner point within reach, or a new one on the curve as drawn.
    static func curve(_ curve: ToneCurve, withPointAt x: Float) -> (ToneCurve, Int) {
        let reach: Float = 0.04
        let inner = curve.points.indices.dropFirst().dropLast()
        if let near = inner.min(by: { abs(curve.points[$0].x - x) < abs(curve.points[$1].x - x) }),
           abs(curve.points[near].x - x) <= reach {
            return (curve, near)
        }
        // Not on top of an end point, which stays pinned.
        let clampedX = min(max(x, 0.02), 0.98)
        let y = ToneCurve.sample(curve.lookupTable(), at: clampedX)
        var result = curve
        let index = result.points.firstIndex { $0.x > clampedX } ?? result.points.count
        result.points.insert(SIMD2(clampedX, y), at: index)
        return (result, index)
    }

    private func hslValues(_ component: HSLComponent) -> [Float] {
        switch component {
        case .hue: return parameters.hsl.hue
        case .saturation: return parameters.hsl.saturation
        case .luminance: return parameters.hsl.luminance
        }
    }

    private func setHSLValues(_ values: [Float], _ component: HSLComponent) {
        switch component {
        case .hue: parameters.hsl.hue = values
        case .saturation: parameters.hsl.saturation = values
        case .luminance: parameters.hsl.luminance = values
        }
    }
}
