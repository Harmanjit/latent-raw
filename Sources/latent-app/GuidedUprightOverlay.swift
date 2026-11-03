import SwiftUI
import AppKit
import PixelEngine

/// Guided Upright's on-image UI: drag along an edge that should be
/// upright or level to lay a guide; drag a guide's end to move it;
/// ⌥-click a guide to remove it. Two to four guides, as in Lightroom: two
/// uprights straighten converging verticals, two levels straighten
/// horizontals, and one alone just levels the picture.
///
/// The picture is corrected when a drag ends, not during it (the guide
/// would otherwise run away from the pointer as the picture moved under
/// it); the guide is then drawn where its feature now sits, straight.
/// Drags start only on the image, so scroll and pinch still reach the
/// Metal view underneath, as with the crop tool.
struct GuidedUprightOverlay: View {
    @ObservedObject var model: EditorModel
    @Environment(\.colorSchemeContrast) private var contrast

    private enum Drag {
        case drawing(start: CGPoint, end: CGPoint)
        case moving(index: Int, end: Bool, at: CGPoint, start: PerspectiveCorrection)
    }
    @State private var drag: Drag?
    private static let endHit: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width > 0 ? model.drawableSize.width / geo.size.width : 2
            let lines = screenLines(scale: scale)
            ZStack {
                Canvas { context, _ in
                    for (i, line) in lines.enumerated() {
                        var shown = line
                        if case .moving(let index, let end, let at, _) = drag, index == i {
                            if end { shown.1 = at } else { shown.0 = at }
                        }
                        stroke(&context, shown)
                    }
                    if case .drawing(let a, let b) = drag { stroke(&context, (a, b)) }
                }
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(scale: scale, lines: lines))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Guided Upright")
            .accessibilityValue(SpokenText.guides(count: lines.count))
            .accessibilityHint("Drag along an edge that should be upright or level to add a guide; up to four")
            .accessibilityAction(named: "Remove all guides") { model.clearGuides() }
        }
    }

    private func stroke(_ context: inout GraphicsContext, _ line: (CGPoint, CGPoint)) {
        var path = Path()
        path.move(to: line.0); path.addLine(to: line.1)
        let wide = contrast == .increased
        context.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: wide ? 4 : 3)
        context.stroke(path, with: .color(.yellow), lineWidth: wide ? 2 : 1.5)
        for p in [line.0, line.1] {
            let dot = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(.yellow))
            context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    // MARK: - Coordinates

    private func screenLines(scale: CGFloat) -> [(CGPoint, CGPoint)] {
        model.guideCanvasLines.map { (screenPoint($0.0, scale: scale), screenPoint($0.1, scale: scale)) }
    }

    private func screenPoint(_ canvas: CGPoint, scale: CGFloat) -> CGPoint {
        let px = model.viewport.screenPoint(forSensorPoint: canvas, drawableSize: model.drawableSize)
        return CGPoint(x: px.x / scale, y: px.y / scale)
    }

    private func canvasPoint(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        model.viewport.sensorPoint(forScreenPoint: CGPoint(x: p.x * scale, y: p.y * scale),
                                   drawableSize: model.drawableSize)
    }

    /// The guide whose line passes within a few points of `p`.
    private func guide(near p: CGPoint, in lines: [(CGPoint, CGPoint)]) -> Int? {
        lines.indices.first { i in
            let (a, b) = lines[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 1e-9)))
            return hypot(a.x + t * dx - p.x, a.y + t * dy - p.y) <= Self.endHit
        }
    }

    // MARK: - Dragging

    private func dragGesture(scale: CGFloat, lines: [(CGPoint, CGPoint)]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil {
                    let p = value.startLocation
                    if NSEvent.modifierFlags.contains(.option) {
                        if let i = guide(near: p, in: lines) { model.removeGuide(i) }
                        drag = .drawing(start: p, end: p)   // swallow the rest of this drag
                        return
                    }
                    for (i, line) in lines.enumerated() {
                        if hypot(line.0.x - p.x, line.0.y - p.y) <= Self.endHit {
                            drag = .moving(index: i, end: false, at: p, start: model.parameters.perspective); break
                        }
                        if hypot(line.1.x - p.x, line.1.y - p.y) <= Self.endHit {
                            drag = .moving(index: i, end: true, at: p, start: model.parameters.perspective); break
                        }
                    }
                    if drag == nil { drag = .drawing(start: p, end: p) }
                }
                switch drag {
                case .drawing(let a, _): drag = .drawing(start: a, end: value.location)
                case .moving(let i, let end, _, let start): drag = .moving(index: i, end: end, at: value.location, start: start)
                case nil: break
                }
            }
            .onEnded { _ in
                defer { drag = nil }
                guard !NSEvent.modifierFlags.contains(.option) else { return }
                switch drag {
                case .drawing(let a, let b):
                    guard hypot(b.x - a.x, b.y - a.y) > 12 else { return }
                    model.addGuide(fromCanvas: canvasPoint(a, scale: scale), to: canvasPoint(b, scale: scale))
                case .moving(let i, let end, let at, let start):
                    model.moveGuide(i, end: end, toCanvas: canvasPoint(at, scale: scale), from: start)
                case nil:
                    break
                }
            }
    }
}

extension SpokenText {
    static func guides(count: Int) -> String {
        switch count {
        case 0: "No guides"
        case 1: "1 guide"
        default: "\(count) guides"
        }
    }
}
