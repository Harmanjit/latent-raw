import SwiftUI
import PixelEngine

/// Shows the spot-removal patches: a solid circle on the target, a
/// dashed one on the source, a line between them. Purely visual; the
/// Metal view underneath owns the mouse and the model does the hit
/// testing, so this can never disagree with what a drag actually grabs.
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
            }
            .allowsHitTesting(false)
            // Patches are placed with the mouse; VoiceOver can count them,
            // step the selection through them and delete the selected one.
            .accessibilityElement()
            .accessibilityLabel("Spot removal patches")
            .accessibilityValue(SpokenText.healPatches(count: model.parameters.heals.count,
                                                       selected: model.selectedHealIndex))
            .accessibilityHint("Click a spot on the image to remove it")
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

    /// Normalized sensor -> view points, through the crop frame and viewport.
    private func point(_ n: SIMD2<Float>, scale: CGFloat) -> CGPoint {
        let sensor = CGPoint(x: CGFloat(n.x) * model.sensorSize.width, y: CGFloat(n.y) * model.sensorSize.height)
        let canvas = model.frame.canvasPoint(fromSensorPoint: sensor)
        let px = model.viewport.screenPoint(forSensorPoint: canvas, drawableSize: model.drawableSize)
        return CGPoint(x: px.x / scale, y: px.y / scale)
    }
}
