import SwiftUI
import PixelEngine

/// Shows the spot-removal patches: a solid circle on the target, a
/// dashed one on the source, a line between them. A stroke is drawn as
/// its outline, solid on the target and dashed on the source, with a dot
/// on the source to drag it by, and the stroke being painted as a plain
/// outline until the mouse is let go. Purely visual; the
/// Metal view underneath owns the mouse and the model does the hit
/// testing, so this can never disagree with what a drag actually grabs.
/// A patch is healed before the lens stage and so is stored on the raw
/// grid, while the view shows the corrected image: every point is placed
/// through the lens map (`outputNormalized`), as DustOverlay does.
struct HealOverlay: View {
    @ObservedObject var model: EditorModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width > 0 ? model.drawableSize.width / geo.size.width : 2
            Canvas { context, _ in
                let short = min(model.sensorSize.width, model.sensorSize.height)
                for (i, patch) in model.parameters.heals.enumerated() {
                    let selected = i == model.selectedHealIndex
                    let r = CGFloat(patch.radius) * short * model.viewport.zoom / scale
                    let t = point(patch.target, scale: scale)
                    let s = point(patch.source, scale: scale)
                    if patch.isStroke {
                        drawStroke(patch, radius: r, selected: selected, scale: scale, in: &context)
                        continue
                    }

                    var link = Path()
                    link.move(to: t); link.addLine(to: s)
                    context.stroke(link, with: .color(.white.opacity(selected ? 0.9 : 0.5)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    let targetCircle = Path(ellipseIn: CGRect(x: t.x - r, y: t.y - r, width: 2 * r, height: 2 * r))
                    context.stroke(targetCircle, with: .color(.black.opacity(0.5)), lineWidth: 3)
                    context.stroke(targetCircle, with: .color(selected ? .accentColor : .white),
                                   lineWidth: selected ? 2 : 1.5)

                    let sourceCircle = Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r))
                    context.stroke(sourceCircle, with: .color(.black.opacity(0.5)), lineWidth: 3)
                    context.stroke(sourceCircle, with: .color(selected ? .accentColor : .white),
                                   style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: [4, 3]))

                    // Increase Contrast: a solid ring just outside the selected
                    // target, so the selection doesn't rest on colour alone.
                    let ring = Contrast.selectionOutlineWidth(selected: selected, increased: contrast == .increased)
                    if ring > 0 {
                        let outer = r + 3 + ring
                        let halo = Path(ellipseIn: CGRect(x: t.x - outer, y: t.y - outer, width: 2 * outer, height: 2 * outer))
                        context.stroke(halo, with: .color(.black), lineWidth: ring + 2)
                        context.stroke(halo, with: .color(.accentColor), lineWidth: ring)
                    }
                }
                if !model.paintingHealStroke.isEmpty {
                    let r = CGFloat(model.healRadius) * short * model.viewport.zoom / scale
                    // Redrawn on every mouse move: one stroked path, not a union.
                    let outline = outlinePath(model.paintingHealStroke, radius: r, scale: scale, merged: false)
                    context.stroke(outline, with: .color(.black.opacity(0.5)), lineWidth: 3)
                    context.stroke(outline, with: .color(.white), lineWidth: 1.5)
                }
            }
            .allowsHitTesting(false)
            // Patches are placed with the mouse; VoiceOver can count them,
            // step the selection through them and delete the selected one.
            .accessibilityElement()
            .accessibilityLabel("Spot removal patches")
            .accessibilityValue(SpokenText.healPatches(count: model.parameters.heals.count,
                                                       selected: model.selectedHealIndex))
            .accessibilityHint("Click a spot on the image to remove it, or paint along a long blemish with the Brush shape")
            .accessibilityAdjustableAction { direction in
                let count = model.parameters.heals.count
                guard count > 0 else { return }
                let step = direction == .increment ? 1 : direction == .decrement ? -1 : 0
                let current = model.selectedHealIndex ?? (step > 0 ? -1 : count)
                model.selectedHealIndex = min(max(current + step, 0), count - 1)
            }
            .accessibilityAction(named: "Delete selected patch") { model.deleteSelectedHeal() }
        }
    }

    /// A stroke patch: the outline of its path on the target, solid, and on
    /// the source, dashed, with a line and a handle dot between them.
    private func drawStroke(_ patch: HealPatch, radius r: CGFloat, selected: Bool, scale: CGFloat,
                            in context: inout GraphicsContext) {
        let colour: Color = selected ? .accentColor : .white
        let t = point(patch.target, scale: scale), s = point(patch.source, scale: scale)
        var link = Path()
        link.move(to: t); link.addLine(to: s)
        context.stroke(link, with: .color(.white.opacity(selected ? 0.9 : 0.5)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        let target = outlinePath(patch.pathPoints(), radius: r, scale: scale)
        context.stroke(target, with: .color(.black.opacity(0.5)), lineWidth: 3)
        context.stroke(target, with: .color(colour), lineWidth: selected ? 2 : 1.5)
        let source = outlinePath(patch.pathPoints(atSource: true), radius: r, scale: scale)
        context.stroke(source, with: .color(.black.opacity(0.5)), lineWidth: 3)
        context.stroke(source, with: .color(colour), style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: [4, 3]))

        let handle = Path(ellipseIn: CGRect(x: s.x - 4, y: s.y - 4, width: 8, height: 8))
        context.fill(handle, with: .color(colour))
        context.stroke(handle, with: .color(.black.opacity(0.6)), lineWidth: 1)

        let ring = Contrast.selectionOutlineWidth(selected: selected, increased: contrast == .increased)
        if ring > 0 {
            let halo = outlinePath(patch.pathPoints(), radius: r + 3 + ring, scale: scale)
            context.stroke(halo, with: .color(.black), lineWidth: ring + 2)
            context.stroke(halo, with: .color(.accentColor), lineWidth: ring)
        }
    }

    /// The outline of a path `radius` view points wide, round at the ends:
    /// the union of one capsule per segment, since a single stroked path
    /// keeps a fold inside each join that would draw as a notch. Without
    /// `merged`, the quick single stroked path, folds and all.
    private func outlinePath(_ points: [SIMD2<Float>], radius r: CGFloat, scale: CGFloat, merged: Bool = true) -> Path {
        let viewPoints = points.map { point($0, scale: scale) }
        guard let first = viewPoints.first else { return Path() }
        let style = StrokeStyle(lineWidth: max(2 * r, 1), lineCap: .round, lineJoin: .round)
        if !merged {
            var centre = Path()
            centre.move(to: first)
            for p in viewPoints.dropFirst() { centre.addLine(to: p) }
            if viewPoints.count == 1 { centre.addLine(to: first) }
            return centre.strokedPath(style)
        }
        func capsule(_ a: CGPoint, _ b: CGPoint) -> Path {
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            return line.strokedPath(style)
        }
        guard viewPoints.count > 1 else { return capsule(first, first) }
        var shape = capsule(viewPoints[0], viewPoints[1])
        for i in 2..<max(viewPoints.count, 2) {
            shape = shape.union(capsule(viewPoints[i - 1], viewPoints[i]))
        }
        return shape
    }

    /// Normalized sensor -> view points, through the crop frame and viewport.
    /// A stored patch point (raw grid) -> view points, through the lens
    /// map, the crop frame and the viewport. Every point drawn here is a
    /// stored one, so the map belongs in the one place they all pass.
    private func point(_ raw: SIMD2<Float>, scale: CGFloat) -> CGPoint {
        let n = model.outputNormalized(raw)
        let sensor = CGPoint(x: CGFloat(n.x) * model.sensorSize.width, y: CGFloat(n.y) * model.sensorSize.height)
        let canvas = model.frame.canvasPoint(fromSensorPoint: sensor)
        let px = model.viewport.screenPoint(forSensorPoint: canvas, drawableSize: model.drawableSize)
        return CGPoint(x: px.x / scale, y: px.y / scale)
    }
}
