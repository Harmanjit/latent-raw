import SwiftUI
import PixelEngine

/// The crop tool's on-image UI: the rectangle, its eight handles, a
/// rule-of-thirds grid and a dimmed surround — the darktable/Lightroom
/// idiom. It works in SwiftUI points and converts to the model's canvas
/// pixels through the viewport, so it stays aligned at any zoom.
///
/// Drags inside the rectangle move it; on an edge or corner they resize
/// it (keeping the aspect lock if one is set); outside they do nothing,
/// so the Metal view underneath still gets scroll and pinch.
struct CropOverlay: View {
    @ObservedObject var model: EditorModel

    private enum Handle { case move, n, s, e, w, ne, nw, se, sw }
    @State private var drag: (handle: Handle, startRect: CGRect, startPoint: CGPoint)?

    private static let handleHit: CGFloat = 12
    private static let minimumSide: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let scale = pointsToPixels(geo.size)
            let rect = screenRect(model.cropCanvasRect, scale: scale)
            ZStack {
                Canvas { context, size in
                    // Dim everything but the crop.
                    var outside = Path(CGRect(origin: .zero, size: size))
                    outside.addRect(rect)
                    context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

                    // Thirds.
                    var grid = Path()
                    for i in 1...2 {
                        let x = rect.minX + rect.width * CGFloat(i) / 3
                        let y = rect.minY + rect.height * CGFloat(i) / 3
                        grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                        grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                    context.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 1)
                    context.stroke(Path(rect), with: .color(.white.opacity(0.9)), lineWidth: 1)

                    // Handles: corner brackets and edge ticks.
                    let h: CGFloat = 14, t: CGFloat = 3
                    var handles = Path()
                    for (x, y) in [(rect.minX, rect.minY), (rect.maxX, rect.minY),
                                   (rect.minX, rect.maxY), (rect.maxX, rect.maxY)] {
                        let sx: CGFloat = x == rect.minX ? 1 : -1, sy: CGFloat = y == rect.minY ? 1 : -1
                        handles.addRect(CGRect(x: min(x, x + sx * h), y: min(y, y + sy * t), width: h, height: t))
                        handles.addRect(CGRect(x: min(x, x + sx * t), y: min(y, y + sy * h), width: t, height: h))
                    }
                    for (x, y) in [(rect.midX, rect.minY), (rect.midX, rect.maxY)] {
                        handles.addRect(CGRect(x: x - h / 2, y: y - t / 2, width: h, height: t))
                    }
                    for (x, y) in [(rect.minX, rect.midY), (rect.maxX, rect.midY)] {
                        handles.addRect(CGRect(x: x - t / 2, y: y - h / 2, width: t, height: h))
                    }
                    context.fill(handles, with: .color(.white))
                }
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(scale: scale))
            }
            // The rectangle is dragged with the mouse; VoiceOver reads its
            // size, aspect and angle, and can reset it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Crop rectangle")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Drag inside the rectangle to move it, or its edges and corners to resize it")
            .accessibilityAction(named: "Reset crop") { model.resetCrop() }
        }
    }

    private var accessibilityValue: String {
        let size = model.croppedPixelSize
        let aspect = CropAspectOption.matching(model.cropAspectDisplayRatio, original: model.originalDisplayRatio)
        return SpokenText.crop(width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                               aspect: aspect.title, angle: model.parameters.crop.angle)
    }

    // MARK: - Coordinate conversion

    /// Device pixels per point for this view; the model measures in pixels.
    private func pointsToPixels(_ size: CGSize) -> CGFloat {
        size.width > 0 ? model.drawableSize.width / size.width : 2
    }

    private func screenRect(_ canvas: CGRect, scale: CGFloat) -> CGRect {
        let px = model.viewport.screenRect(forSensorRect: canvas, drawableSize: model.drawableSize)
        return CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale)
    }

    /// Points -> canvas pixels.
    private func canvasPoint(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        model.viewport.sensorPoint(forScreenPoint: CGPoint(x: p.x * scale, y: p.y * scale),
                                   drawableSize: model.drawableSize)
    }

    // MARK: - Dragging

    private func dragGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil {
                    let rect = screenRect(model.cropCanvasRect, scale: scale)
                    guard let handle = hitTest(value.startLocation, in: rect) else { return }
                    drag = (handle, model.cropCanvasRect, canvasPoint(value.startLocation, scale: scale))
                }
                guard let drag else { return }
                let now = canvasPoint(value.location, scale: scale)
                let delta = CGSize(width: now.x - drag.startPoint.x, height: now.y - drag.startPoint.y)
                model.cropCanvasRect = resized(drag.startRect, handle: drag.handle, by: delta)
            }
            .onEnded { _ in drag = nil }
    }

    private func hitTest(_ p: CGPoint, in rect: CGRect) -> Handle? {
        let d = Self.handleHit
        let nearLeft = abs(p.x - rect.minX) <= d, nearRight = abs(p.x - rect.maxX) <= d
        let nearTop = abs(p.y - rect.minY) <= d, nearBottom = abs(p.y - rect.maxY) <= d
        let withinX = p.x >= rect.minX - d && p.x <= rect.maxX + d
        let withinY = p.y >= rect.minY - d && p.y <= rect.maxY + d
        guard withinX, withinY else { return nil }
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .nw
        case (_, true, true, _): return .ne
        case (true, _, _, true): return .sw
        case (_, true, _, true): return .se
        case (true, _, _, _): return .w
        case (_, true, _, _): return .e
        case (_, _, true, _): return .n
        case (_, _, _, true): return .s
        default: return rect.contains(p) ? .move : nil
        }
    }

    /// Applies a drag to the starting rectangle: move, or grow/shrink the
    /// dragged side(s). With an aspect lock, corners follow the larger
    /// change and edges adjust the other dimension about the centre. The
    /// result is kept inside the canvas and above a minimum size.
    private func resized(_ start: CGRect, handle: Handle, by d: CGSize) -> CGRect {
        let bounds = model.cropCanvasBounds
        let minSide = Self.minimumSide
        var r = start

        if handle == .move {
            r.origin.x = min(max(start.minX + d.width, bounds.minX), bounds.maxX - start.width)
            r.origin.y = min(max(start.minY + d.height, bounds.minY), bounds.maxY - start.height)
            return r
        }

        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch handle {
        case .n, .ne, .nw: minY = start.minY + d.height
        case .s, .se, .sw: maxY = start.maxY + d.height
        default: break
        }
        switch handle {
        case .w, .nw, .sw: minX = start.minX + d.width
        case .e, .ne, .se: maxX = start.maxX + d.width
        default: break
        }
        // Keep the dragged side on the canvas and the rect at least minSide.
        minX = max(bounds.minX, min(minX, maxX - minSide))
        maxX = min(bounds.maxX, max(maxX, minX + minSide))
        minY = max(bounds.minY, min(minY, maxY - minSide))
        maxY = min(bounds.maxY, max(maxY, minY + minSide))
        r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        if let ratio = model.cropAspectDisplayRatio, ratio > 0 {
            r = constrainAspect(r, ratio: CGFloat(ratio), handle: handle, anchor: start, bounds: bounds)
        }
        return r
    }

    /// Re-derives one dimension from the other so the rect keeps `ratio`,
    /// anchored on the side opposite the handle (or the centre for edges).
    private func constrainAspect(_ r: CGRect, ratio: CGFloat, handle: Handle,
                                 anchor: CGRect, bounds: CGRect) -> CGRect {
        var out = r
        switch handle {
        case .n, .s:
            // Height is what the user set; width follows, centred.
            let w = min(r.height * ratio, bounds.width)
            out.origin.x = min(max(anchor.midX - w / 2, bounds.minX), bounds.maxX - w)
            out.size.width = w
            out.size.height = w / ratio
            if handle == .n { out.origin.y = anchor.maxY - out.height }
        case .e, .w:
            let h = min(r.width / ratio, bounds.height)
            out.origin.y = min(max(anchor.midY - h / 2, bounds.minY), bounds.maxY - h)
            out.size.height = h
            out.size.width = h * ratio
            if handle == .w { out.origin.x = anchor.maxX - out.width }
        default:
            // Corners: honour whichever dimension changed more.
            let dw = abs(r.width - anchor.width), dh = abs(r.height - anchor.height)
            var w = r.width, h = r.height
            if dw >= dh { h = w / ratio } else { w = h * ratio }
            // Fit inside the canvas from the anchored corner.
            let anchorX = (handle == .ne || handle == .se) ? anchor.minX : anchor.maxX
            let anchorY = (handle == .se || handle == .sw) ? anchor.minY : anchor.maxY
            let roomW = (handle == .ne || handle == .se) ? bounds.maxX - anchorX : anchorX - bounds.minX
            let roomH = (handle == .se || handle == .sw) ? bounds.maxY - anchorY : anchorY - bounds.minY
            let s = min(1, roomW / w, roomH / h)
            w *= s; h *= s
            out.size = CGSize(width: w, height: h)
            out.origin.x = (handle == .ne || handle == .se) ? anchorX : anchorX - w
            out.origin.y = (handle == .se || handle == .sw) ? anchorY : anchorY - h
        }
        return out
    }
}
