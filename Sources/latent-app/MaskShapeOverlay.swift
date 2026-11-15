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
                // The eyedropper's samples while it is armed: a ring with
                // a dot, numbered in the order they were taken.
                for (n, sample) in model.maskSamplePoints.enumerated() {
                    let s = point(sample, scale: scale)
                    let ring = CGRect(x: s.x - 5, y: s.y - 5, width: 10, height: 10)
                    context.stroke(Path(ellipseIn: ring), with: .color(.black.opacity(0.6)), lineWidth: 3.5)
                    context.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 1.5)
                    context.fill(Path(ellipseIn: CGRect(x: s.x - 1.5, y: s.y - 1.5, width: 3, height: 3)), with: .color(.white))
                    context.draw(Text("\(n + 1)").font(.caption2.bold()).foregroundStyle(.white),
                                 at: CGPoint(x: s.x + 9, y: s.y - 9))
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
                case .radial(let centre, let radii, let feather, let angle):
                    let size = model.sensorSizeVector
                    // Sample the ellipse in sensor space so rotation and
                    // crop carry it correctly to the screen; a turned
                    // ellipse is turned there (MaskShapeGeometry.swift).
                    for (fraction, dashed) in [(Float(1), false), (1 - min(max(feather, 0), 0.999), true)] {
                        var path = Path()
                        for k in 0...48 {
                            let t = Float(k) / 48 * 2 * .pi
                            let p = MaskShape.radialPoint(centre: centre, radii: radii, angle: angle ?? 0, t: t,
                                                          fraction: fraction, sensorSize: size)
                            let s = point(p, scale: scale)
                            if k == 0 { path.move(to: s) } else { path.addLine(to: s) }
                        }
                        stroke(path, dashed: dashed)
                    }
                    let c = point(centre, scale: scale)
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.white))
                    if model.maskHandlesActive {
                        drawHandles(element.shape, scale: scale, context: context, stroke: stroke)
                    }
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
                    if model.maskHandlesActive {
                        drawHandles(element.shape, scale: scale, context: context, stroke: stroke)
                    }
                default:
                    break
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The shape's handles (MaskShapeGeometry.swift), while its tool is
    /// armed and they can be dragged: round for the points on the shape,
    /// a ring for a radial's rotate handle, joined to the outline.
    private func drawHandles(_ shape: MaskShape, scale: CGFloat, context: GraphicsContext,
                             stroke: (Path, Bool) -> Void) {
        let handles = shape.handlePositions(sensorSize: model.sensorSizeVector)
        if let rotate = handles.first(where: { $0.handle == .radialRotate }),
           case .radial(let c, let r, _, let a) = shape {
            let top = MaskShape.radialPoint(centre: c, radii: r, angle: a ?? 0, t: -.pi / 2, sensorSize: model.sensorSizeVector)
            var line = Path()
            line.move(to: point(top, scale: scale))
            line.addLine(to: point(rotate.point, scale: scale))
            stroke(line, true)
        }
        for (handle, p) in handles where handle != .radialCentre {
            let s = point(p, scale: scale)
            let rect = CGRect(x: s.x - 4.5, y: s.y - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(.black.opacity(0.5)))
            if handle == .radialRotate || handle == .radialFeather {
                context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(.white))
            }
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
    /// gradient is selected with its tool armed or the overlay on, a box
    /// is being dragged, or an armed eyedropper has sample points to show.
    var showsMaskShapeOverlay: Bool {
        if maskDragBox != nil { return true }
        if !maskSamplePoints.isEmpty, !cropToolActive { return true }
        guard let element = activeMaskElement, !cropToolActive else { return false }
        switch element.shape {
        case .radial, .linear: return maskToolActive || showMaskOverlay
        default: return false
        }
    }
}
