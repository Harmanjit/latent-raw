import SwiftUI
import PixelEngine

/// Shows the red-eye spots: a circle around each pupil, with a dot at the
/// centre. Purely visual, like HealOverlay: the Metal view owns the mouse
/// and the model hit tests (inside moves a spot, the rim resizes it). A
/// spot is stored on the raw grid and the view shows the corrected image,
/// so its circle is placed through the lens map (`outputNormalized`).
struct RedEyeOverlay: View {
    @ObservedObject var model: EditorModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width > 0 ? model.drawableSize.width / geo.size.width : 2
            Canvas { context, _ in
                let short = min(model.sensorSize.width, model.sensorSize.height)
                for (i, spot) in model.parameters.redEyes.enumerated() {
                    let selected = i == model.selectedRedEyeIndex
                    let r = CGFloat(spot.radius) * short * model.viewport.zoom / scale
                    let c = point(spot.centre, scale: scale)
                    let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    context.stroke(circle, with: .color(.black.opacity(0.5)), lineWidth: 3)
                    context.stroke(circle, with: .color(selected ? .accentColor : .white), lineWidth: selected ? 2 : 1.5)
                    let dot = Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
                    context.fill(dot, with: .color(selected ? .accentColor : .white))

                    let ring = Contrast.selectionOutlineWidth(selected: selected, increased: contrast == .increased)
                    if ring > 0 {
                        let outer = r + 3 + ring
                        let halo = Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer))
                        context.stroke(halo, with: .color(.black), lineWidth: ring + 2)
                        context.stroke(halo, with: .color(.accentColor), lineWidth: ring)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Red-eye spots")
            .accessibilityValue(SpokenText.redEyeSpots(count: model.parameters.redEyes.count,
                                                       selected: model.selectedRedEyeIndex))
            .accessibilityHint("Click a red pupil to fix it, or use Auto in the Spot Removal panel")
            .accessibilityAdjustableAction { direction in
                let count = model.parameters.redEyes.count
                guard count > 0 else { return }
                let step = direction == .increment ? 1 : direction == .decrement ? -1 : 0
                let current = model.selectedRedEyeIndex ?? (step > 0 ? -1 : count)
                model.selectedRedEyeIndex = min(max(current + step, 0), count - 1)
            }
            .accessibilityAction(named: "Delete selected spot") { model.deleteSelectedRedEye() }
        }
    }

    /// A stored spot centre (raw grid) -> view points, through the lens
    /// map, the crop frame and the viewport.
    private func point(_ raw: SIMD2<Float>, scale: CGFloat) -> CGPoint {
        let n = model.outputNormalized(raw)
        let sensor = CGPoint(x: CGFloat(n.x) * model.sensorSize.width, y: CGFloat(n.y) * model.sensorSize.height)
        let canvas = model.frame.canvasPoint(fromSensorPoint: sensor)
        let px = model.viewport.screenPoint(forSensorPoint: canvas, drawableSize: model.drawableSize)
        return CGPoint(x: px.x / scale, y: px.y / scale)
    }
}

extension SpokenText {
    /// "No spots", "2 spots, spot 1 selected".
    static func redEyeSpots(count: Int, selected: Int?) -> String {
        guard count > 0 else { return "No spots" }
        var text = count == 1 ? "1 spot" : "\(count) spots"
        if let selected, selected >= 0, selected < count { text += ", spot \(selected + 1) selected" }
        return text
    }

    /// What Auto found, for the status bar and VoiceOver.
    static func redEyesFound(added: Int, detected: Int) -> String {
        switch (added, detected) {
        case (0, 0): "No red eyes found"
        case (0, _): "Red eyes found already have spots"
        case (1, _): "Fixed 1 red eye"
        default: "Fixed \(added) red eyes"
        }
    }
}
