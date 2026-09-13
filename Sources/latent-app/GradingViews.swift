import SwiftUI
import PixelEngine

/// The tone curve editor: drag points, click the curve to add one,
/// double-click a point to remove it. Drawn with Canvas; hit-testing is
/// done by hand, which is simpler than a view per point.
struct CurveEditor: View {
    @Binding var curve: ToneCurve
    @State private var dragging: Int?

    private let pointRadius: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let size = geo.size
                Canvas { context, size in
                    drawGrid(&context, size)
                    drawCurve(&context, size)
                    drawPoints(&context, size)
                }
                .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 4))
                .gesture(dragGesture(in: size))
                .onTapGesture(count: 2) { location in
                    if let i = nearestPoint(to: location, in: size), isRemovable(i) {
                        curve.points.remove(at: i)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)

            HStack {
                Text("Drag points · click to add · double-click to remove")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Linear") { curve = .identity }
                    .controlSize(.mini)
                    .disabled(curve.isIdentity)
            }
        }
    }

    // MARK: Geometry

    private func toView(_ p: SIMD2<Float>, _ size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(p.y)) * size.height)
    }
    private func toCurve(_ p: CGPoint, _ size: CGSize) -> SIMD2<Float> {
        SIMD2(Float(min(max(p.x / size.width, 0), 1)), Float(min(max(1 - p.y / size.height, 0), 1)))
    }
    private func nearestPoint(to location: CGPoint, in size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in curve.points.enumerated() {
            let v = toView(p, size)
            let d = hypot(v.x - location.x, v.y - location.y)
            if d < 12, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
    /// Endpoints stay; they can move vertically but never leave.
    private func isRemovable(_ i: Int) -> Bool { i != 0 && i != curve.points.count - 1 }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    if let hit = nearestPoint(to: value.startLocation, in: size) {
                        dragging = hit
                    } else {
                        // Click on empty space: add a point there, sorted by x.
                        let p = toCurve(value.startLocation, size)
                        let index = curve.points.firstIndex { $0.x > p.x } ?? curve.points.count
                        curve.points.insert(p, at: index)
                        dragging = index
                    }
                }
                guard let i = dragging else { return }
                var p = toCurve(value.location, size)
                // Keep order: a point can't pass its neighbours; endpoints
                // keep their x.
                if i == 0 { p.x = 0 } else if i == curve.points.count - 1 { p.x = 1 }
                else {
                    let lo = curve.points[i - 1].x + 0.01, hi = curve.points[i + 1].x - 0.01
                    p.x = min(max(p.x, lo), hi)
                }
                curve.points[i] = p
            }
            .onEnded { _ in dragging = nil }
    }

    // MARK: Drawing

    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        var grid = Path()
        for f in [0.25, 0.5, 0.75] {
            grid.move(to: CGPoint(x: size.width * f, y: 0)); grid.addLine(to: CGPoint(x: size.width * f, y: size.height))
            grid.move(to: CGPoint(x: 0, y: size.height * f)); grid.addLine(to: CGPoint(x: size.width, y: size.height * f))
        }
        context.stroke(grid, with: .color(Color(white: 0.2)), lineWidth: 0.5)
        var diag = Path()
        diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diag, with: .color(Color(white: 0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
    }

    private func drawCurve(_ context: inout GraphicsContext, _ size: CGSize) {
        let lut = curve.lookupTable()
        var path = Path()
        for (i, y) in lut.enumerated() {
            let pt = CGPoint(x: CGFloat(i) / 255 * size.width, y: (1 - CGFloat(y)) * size.height)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
    }

    private func drawPoints(_ context: inout GraphicsContext, _ size: CGSize) {
        for (i, p) in curve.points.enumerated() {
            let v = toView(p, size)
            let rect = CGRect(x: v.x - pointRadius, y: v.y - pointRadius,
                              width: pointRadius * 2, height: pointRadius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(i == dragging ? .accentColor : .white))
            context.stroke(Path(ellipseIn: rect), with: .color(Color(white: 0.1)), lineWidth: 1)
        }
    }
}

/// Eight hue bands, one slider each, for whichever of hue / saturation /
/// luminance is selected. Same layout as Lightroom's HSL panel.
struct HSLPanel: View {
    @Binding var hsl: HSLAdjustments
    @State private var mode = 1   // 0 hue, 1 saturation, 2 luminance

    private static let swatches: [Color] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, Color(red: 1, green: 0, blue: 0.6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                Text("Hue").tag(0); Text("Saturation").tag(1); Text("Luminance").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)

            ForEach(0..<8, id: \.self) { band in
                HStack(spacing: 6) {
                    Circle().fill(Self.swatches[band]).frame(width: 8, height: 8)
                    Text(HSLAdjustments.bandNames[band]).font(.caption).frame(width: 52, alignment: .leading)
                    ResettableSlider(value: binding(band), in: -1...1) { binding(band).wrappedValue = 0 }
                    Text(String(format: "%+.0f", binding(band).wrappedValue * 100))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
            HStack {
                Spacer()
                Button("Reset") { hsl = .neutral }.controlSize(.mini).disabled(hsl.isNeutral)
            }
        }
    }

    private func binding(_ band: Int) -> Binding<Float> {
        Binding(
            get: {
                switch mode { case 0: return hsl.hue[band]; case 1: return hsl.saturation[band]; default: return hsl.luminance[band] }
            },
            set: { v in
                switch mode { case 0: hsl.hue[band] = v; case 1: hsl.saturation[band] = v; default: hsl.luminance[band] = v }
            })
    }
}

/// Shadow and highlight tints with a balance.
struct SplitToningPanel: View {
    @Binding var toning: SplitToning

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Highlights", hue: $toning.highlightHue, saturation: $toning.highlightSaturation)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Balance").font(.subheadline)
                    Spacer()
                    Text(String(format: "%+.0f", toning.balance * 100))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                ResettableSlider(value: $toning.balance, in: -1...1) { toning.balance = 0 }
            }
            group("Shadows", hue: $toning.shadowHue, saturation: $toning.shadowSaturation)
            HStack {
                Spacer()
                Button("Reset") { toning = .neutral }.controlSize(.mini).disabled(toning.isNeutral)
            }
        }
    }

    private func group(_ title: String, hue: Binding<Float>, saturation: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Circle()
                    .fill(Color(hue: Double(hue.wrappedValue) / 360, saturation: 1, brightness: 1))
                    .frame(width: 10, height: 10)
                    .opacity(Double(saturation.wrappedValue) * 0.8 + 0.2)
            }
            HStack {
                Text("Hue").font(.caption).frame(width: 60, alignment: .leading)
                Slider(value: hue, in: 0...360)
                Text(String(format: "%.0f°", hue.wrappedValue))
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            HStack {
                Text("Saturation").font(.caption).frame(width: 60, alignment: .leading)
                ResettableSlider(value: saturation, in: 0...1) { saturation.wrappedValue = 0 }
                Text(String(format: "%.0f", saturation.wrappedValue * 100))
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}
