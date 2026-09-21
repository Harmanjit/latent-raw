import SwiftUI
import PixelEngine

/// Shows the dust spots while the dust tool is armed: a thin ring round
/// each, 1 pt white over a 2 pt black halo so it reads on any sky, the
/// accent colour on the selected one. Purely visual, like HealOverlay:
/// the Metal view owns the mouse and the model hit tests (a ring removes
/// its spot, the image adds one). The rings follow the render, so Before
/// shows none.
struct DustOverlay: View {
    @ObservedObject var model: EditorModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width > 0 ? model.drawableSize.width / geo.size.width : 2
            Canvas { context, _ in
                let short = min(model.sensorSize.width, model.sensorSize.height)
                for (i, spot) in model.renderParameters.dust.enumerated() {
                    let selected = i == model.selectedDustIndex
                    // Never thinner than the halo, however far out the view is.
                    let r = max(CGFloat(spot.radius) * short * model.viewport.zoom / scale, 2)
                    let c = point(spot.target, scale: scale)
                    let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    context.stroke(ring, with: .color(.black.opacity(0.6)), lineWidth: 2)
                    context.stroke(ring, with: .color(selected ? .accentColor : .white), lineWidth: selected ? 1.5 : 1)

                    let outline = Contrast.selectionOutlineWidth(selected: selected, increased: contrast == .increased)
                    if outline > 0 {
                        let outer = r + 3 + outline
                        let halo = Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer))
                        context.stroke(halo, with: .color(.black), lineWidth: outline + 2)
                        context.stroke(halo, with: .color(.accentColor), lineWidth: outline)
                    }
                }
            }
            .allowsHitTesting(false)
            // Spots are found or clicked with the mouse; VoiceOver can count
            // them, step the selection through them and delete the selected one.
            .accessibilityElement()
            .accessibilityLabel("Dust spots")
            .accessibilityValue(SpokenText.dustSpots(count: model.renderParameters.dust.count,
                                                     selected: model.selectedDustIndex))
            .accessibilityHint("Click a ring to remove a false spot, or click the image to add one")
            .accessibilityAdjustableAction { direction in
                let count = model.parameters.dust.count
                guard count > 0 else { return }
                let step = direction == .increment ? 1 : direction == .decrement ? -1 : 0
                let current = model.selectedDustIndex ?? (step > 0 ? -1 : count)
                model.selectedDustIndex = min(max(current + step, 0), count - 1)
            }
            .accessibilityAction(named: "Delete selected spot") { model.deleteSelectedDust() }
        }
    }

    /// Normalised sensor -> view points, through the crop frame and viewport.
    private func point(_ n: SIMD2<Float>, scale: CGFloat) -> CGPoint {
        let sensor = CGPoint(x: CGFloat(n.x) * model.sensorSize.width, y: CGFloat(n.y) * model.sensorSize.height)
        let canvas = model.frame.canvasPoint(fromSensorPoint: sensor)
        let px = model.viewport.screenPoint(forSensorPoint: canvas, drawableSize: model.drawableSize)
        return CGPoint(x: px.x / scale, y: px.y / scale)
    }
}

extension SpokenText {
    /// "No dust spots", "1 dust spot", "37 dust spots, spot 3 selected".
    static func dustSpots(count: Int, selected: Int?) -> String {
        guard count > 0 else { return "No dust spots" }
        var text = count == 1 ? "1 dust spot" : "\(count) dust spots"
        if let selected, selected >= 0, selected < count { text += ", spot \(selected + 1) selected" }
        return text
    }

    /// What Find Spots (or a dust map) found, for the status bar and
    /// VoiceOver: `added` spots were healed of `detected` seen; the
    /// rest were already under a patch.
    static func dustFound(added: Int, detected: Int) -> String {
        switch (added, detected) {
        case (0, 0): "No dust spots found"
        case (0, _): "Dust spots found already have patches"
        case (1, _): "Found 1 dust spot"
        default: "Found \(added) dust spots"
        }
    }
}
