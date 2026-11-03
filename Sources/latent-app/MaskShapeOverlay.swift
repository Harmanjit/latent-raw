import SwiftUI
import PixelEngine

/// Outlines for the selected mask's gradient or radial, and the Select
/// Objects box while it is dragged. Purely visual, like RedEyeOverlay:
/// the Metal view owns the mouse and the model reshapes the mask. A
/// radial shows its ellipse and centre (drag inside it to move it); a
/// linear gradient shows where the effect is full and where it ends.
struct MaskShapeOverlay: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width > 0 ? model.drawableSize.width / geo.size.width : 2
            Canvas { context, _ in
                func stroke(_ path: Path, dashed: Bool = false) {
                    let style = StrokeStyle(lineWidth: 1.5, dash: dashed ? [5, 4] : [])
                    context.stroke(path, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 3, dash: style.dash))
                    context.stroke(path, with: .color(.white), style: style)
                }
                if let box = model.maskDragBox {
                    let a = point(SIMD2(Float(box.minX), Float(box.minY)), scale: scale)
                    let b = point(SIMD2(Float(box.maxX), Float(box.maxY)), scale: scale)
                    stroke(Path(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))),
                           dashed: true)
                    return
                }
                guard let element = model.activeMaskElement else { return }
                switch element.shape {
                case .radial(let centre, let radii, let feather):
                    let short = Float(min(model.sensorSize.width, model.sensorSize.height))
                    let w = Float(max(model.sensorSize.width, 1)), h = Float(max(model.sensorSize.height, 1))
                    // Sample the ellipse in sensor space so rotation and
                    // crop carry it correctly to the screen.
                    for (fraction, dashed) in [(Float(1), false), (1 - min(max(feather, 0), 0.999), true)] {
                        var path = Path()
                        for k in 0...48 {
                            let t = Float(k) / 48 * 2 * .pi
                            let p = centre + SIMD2(cos(t) * radii.x * short / w, sin(t) * radii.y * short / h) * fraction
                            let s = point(p, scale: scale)
                            if k == 0 { path.move(to: s) } else { path.addLine(to: s) }
                        }
                        stroke(path, dashed: dashed)
                    }
                    let c = point(centre, scale: scale)
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.white))
                case .linear(let start, let end):
                    let d = end - start
                    // Lines across the frame at the start and the end,
                    // perpendicular to the gradient's direction.
                    let normal = SIMD2(-d.y * Float(model.sensorSize.height), d.x * Float(model.sensorSize.width))
                    let length = (normal.x * normal.x + normal.y * normal.y).squareRoot()
                    guard length > 0 else { return }
                    let across = SIMD2(normal.x / Float(max(model.sensorSize.width, 1)),
                                       normal.y / Float(max(model.sensorSize.height, 1))) / length * 2
                    for (p, dashed) in [(start, false), (end, true)] {
                        var path = Path()
                        path.move(to: point(p - across, scale: scale))
                        path.addLine(to: point(p + across, scale: scale))
                        stroke(path, dashed: dashed)
                    }
                default:
                    break
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// A normalised output-grid point -> view points, through the crop
    /// frame and the viewport (masks live on the output grid).
    private func point(_ n: SIMD2<Float>, scale: CGFloat) -> CGPoint {
        let sensor = CGPoint(x: CGFloat(n.x) * model.sensorSize.width, y: CGFloat(n.y) * model.sensorSize.height)
        let canvas = model.frame.canvasPoint(fromSensorPoint: sensor)
        let px = model.viewport.screenPoint(forSensorPoint: canvas, drawableSize: model.drawableSize)
        return CGPoint(x: px.x / scale, y: px.y / scale)
    }
}

extension EditorModel {
    /// Whether the outline overlay has anything to draw: a radial or
    /// gradient is selected with its tool armed or the overlay on, or a
    /// box is being dragged.
    var showsMaskShapeOverlay: Bool {
        if maskDragBox != nil { return true }
        guard let element = activeMaskElement, !cropToolActive else { return false }
        switch element.shape {
        case .radial, .linear: return maskToolActive || showMaskOverlay
        default: return false
        }
    }
}
