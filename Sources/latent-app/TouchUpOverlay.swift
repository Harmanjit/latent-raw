import SwiftUI
import PixelEngine

/// Shows the touch-up tool's marks: the enabled faces' boxes, faintly,
/// and a ring around each blemish patch (accent when selected). Purely
/// visual, like HealOverlay: the Metal view owns the mouse and the model
/// hit tests, so a click on a ring is the model's `touchUpToolBegan`.
///
/// The boxes are stored on the raw sensor grid and drawn as sensor
/// positions, as the spot tools take their clicks: with a lens profile
/// on, a box sits a few pixels from the corrected face, which a faint
/// outline is for.
struct TouchUpOverlay: View {
    @ObservedObject var model: EditorModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width > 0 ? model.drawableSize.width / geo.size.width : 2
            Canvas { context, _ in
                let short = min(model.sensorSize.width, model.sensorSize.height)
                for face in model.parameters.touchUp.faces where face.enabled {
                    let b = face.boundingBox
                    let corner = point(SIMD2(b.x, b.y), scale: scale)
                    let far = point(SIMD2(b.x + b.z, b.y + b.w), scale: scale)
                    let box = Path(CGRect(x: corner.x, y: corner.y, width: far.x - corner.x, height: far.y - corner.y))
                    context.stroke(box, with: .color(.black.opacity(0.25)), lineWidth: 3)
                    context.stroke(box, with: .color(.white.opacity(0.45)), lineWidth: 1)
                }
                for (i, patch) in model.parameters.touchUp.blemishes.enumerated() {
                    let selected = i == model.selectedBlemishIndex
                    let r = max(CGFloat(patch.radius) * short * model.viewport.zoom / scale, 3)
                    let c = point(patch.target, scale: scale)
                    let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    context.stroke(ring, with: .color(.black.opacity(0.5)), lineWidth: 3)
                    context.stroke(ring, with: .color(selected ? .accentColor : .white), lineWidth: selected ? 2 : 1)

                    // Increase Contrast: a solid ring outside the selected
                    // one, so the selection doesn't rest on colour alone.
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
            // Rings are removed with the mouse; VoiceOver can count them,
            // step the selection through them and keep the selected spot.
            .accessibilityElement()
            .accessibilityLabel("Touch-up blemishes")
            .accessibilityValue(SpokenText.blemishes(count: model.parameters.touchUp.blemishes.count,
                                                     selected: model.selectedBlemishIndex))
            .accessibilityHint("Click a ring to keep that spot")
            .accessibilityAdjustableAction { direction in
                let count = model.parameters.touchUp.blemishes.count
                guard count > 0 else { return }
                let step = direction == .increment ? 1 : direction == .decrement ? -1 : 0
                let current = model.selectedBlemishIndex ?? (step > 0 ? -1 : count)
                model.selectedBlemishIndex = min(max(current + step, 0), count - 1)
            }
            .accessibilityAction(named: "Keep selected spot") { model.deleteSelectedBlemish() }
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
    /// The blemish rings on the image: "No blemishes", "3 blemishes,
    /// blemish 2 selected".
    static func blemishes(count: Int, selected: Int?) -> String {
        guard count > 0 else { return "No blemishes" }
        var text = count == 1 ? "1 blemish" : "\(count) blemishes"
        if let selected, selected >= 0, selected < count { text += ", blemish \(selected + 1) selected" }
        return text
    }

    /// What Find Faces found, for the status bar, the panel and VoiceOver:
    /// "No faces found", "Found 2 faces", "Found 2 faces, 1 too small to
    /// retouch".
    static func facesFound(found: Int, tooSmall: Int) -> String {
        var text = found == 0 ? "No faces found" : found == 1 ? "Found 1 face" : "Found \(found) faces"
        if tooSmall > 0 { text += ", \(tooSmall) too small to retouch" }
        return text
    }

    /// What Find Blemishes found: "No blemishes found", "Found 1 blemish",
    /// "Found 12 blemishes".
    static func blemishesFound(_ count: Int) -> String {
        count == 0 ? "No blemishes found" : count == 1 ? "Found 1 blemish" : "Found \(count) blemishes"
    }

    /// The panel's count line: "No blemishes", "1 blemish", "12 blemishes".
    static func blemishCount(_ count: Int) -> String {
        blemishes(count: count, selected: nil)
    }
}
