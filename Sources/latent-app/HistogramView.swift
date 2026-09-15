import SwiftUI
import PixelEngine

/// The histogram display.
///
/// Drawn with Canvas rather than stacked Shape views: 1024 data points as
/// individual views would be absurd, and Canvas draws the whole thing in one
/// pass with no view-tree overhead.
///
/// The three channels are drawn additively (`plusLighter`), so overlapping
/// regions brighten toward white — the convention every photo editor uses,
/// and it means neutral areas of the image read as grey peaks rather than
/// three separate coloured humps.
///
/// No vertical axis: the counts are square-root scaled to keep the tail
/// readable, so any number printed against that axis would imply a
/// precision the scaling doesn't have. The shape is what's useful.
struct HistogramView: View {
    let histogram: Histogram?

    /// Tick positions along the tonal axis, as fractions of full scale.
    private let xTicks: [(position: Double, label: String)] = [
        (0.0,  "0"),
        (0.25, "64"),
        (0.5,  "128"),
        (0.75, "192"),
        (1.0,  "255"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            plotArea
            xAxisLabels
        }
    }

    private var plotArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.08))

            if let histogram, histogram.peak > 0 {
                Canvas { context, size in
                    drawGrid(in: &context, size: size)
                    draw(histogram: histogram, in: &context, size: size)
                }
                .padding(1)
            } else {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 90)
    }

    private var xAxisLabels: some View {
        GeometryReader { geometry in
            ForEach(Array(xTicks.enumerated()), id: \.offset) { _, tick in
                Text(tick.label)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: geometry.size.width * tick.position, y: 5)
            }
        }
        .frame(height: 12)
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        for tick in xTicks where tick.position > 0 && tick.position < 1 {
            var line = Path()
            let x = size.width * tick.position
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Color(white: 0.22)), lineWidth: 0.5)
        }
    }

    private func draw(histogram: Histogram, in context: inout GraphicsContext, size: CGSize) {
        let channels: [(counts: [UInt32], color: Color)] = [
            (histogram.red, .red),
            (histogram.green, .green),
            (histogram.blue, .blue),
        ]

        // Square-root scaling rather than linear. A typical photo has a few
        // enormous midtone bins and a long tail of small ones; drawn
        // linearly, everything except the peak is invisible. sqrt keeps the
        // shape honest while making the tail readable — the same compromise
        // most editors make.
        let peak = Double(histogram.peak)
        let scale = peak > 0 ? 1.0 / sqrt(peak) : 0

        for channel in channels {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))

            let binCount = channel.counts.count
            for (index, count) in channel.counts.enumerated() {
                let x = size.width * Double(index) / Double(binCount - 1)
                let normalized = sqrt(Double(count)) * scale
                let y = size.height * (1.0 - min(normalized, 1.0))
                path.addLine(to: CGPoint(x: x, y: y))
            }

            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()

            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.fill(path, with: .color(channel.color.opacity(0.55)))
            }
        }

        // Luminance as a thin outline over the fills: where the light and
        // dark pixels are regardless of hue, which the three overlapping
        // channels only suggest. Same scale as the channels, clipped at
        // the top if its peak is taller.
        var outline = Path()
        let bins = histogram.luminance.count
        for (index, count) in histogram.luminance.enumerated() {
            let x = size.width * Double(index) / Double(bins - 1)
            let y = size.height * (1.0 - min(sqrt(Double(count)) * scale, 1.0))
            if index == 0 {
                outline.move(to: CGPoint(x: x, y: y))
            } else {
                outline.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(outline, with: .color(.white.opacity(0.6)), lineWidth: 1)
    }
}

/// A compact readout of how much of each channel is sitting in the top and
/// bottom bins, and, while the view shows HDR, how much of the image is
/// brighter than SDR white.
///
/// Worth being precise about what this means: it's clipping in the
/// *rendered output*, after tone mapping, not clipping in the sensor data.
/// The tone curve can pull a genuinely blown highlight back below the top
/// bin, so a clean reading here doesn't prove the raw data survived.
///
/// "Above SDR white" counts the highlights an SDR screen or file can't
/// show as bright as this view does. They land in the top bin too, since
/// the bins describe the SDR view; an SDR export renders them again with
/// no headroom, which compresses them below white rather than clipping.
struct ClippingReadout: View {
    let histogram: Histogram?
    /// Only meaningful while the viewport renders with headroom; with HDR
    /// display off, proofing, or on an SDR screen it would always read 0.
    var showsAboveSDRWhite = false

    var body: some View {
        if let histogram {
            VStack(alignment: .leading, spacing: 2) {
                row("clipped:", histogram.clippedFraction)
                row("shadows:", histogram.shadowClippedFraction)
                if showsAboveSDRWhite {
                    let percent = histogram.aboveSDRWhiteFraction * 100
                    HStack(spacing: 3) {
                        Text("above SDR white:").foregroundStyle(.tertiary)
                        Text(percentText(percent)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .help("Pixels shown brighter than SDR white. An SDR screen or file can't reach them; an SDR export compresses them below white.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Above SDR white")
                    .accessibilityValue(spokenPercent(histogram.aboveSDRWhiteFraction))
                }
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }

    private func row(_ title: String, _ fractions: (red: Float, green: Float, blue: Float)) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.tertiary)
            label("R", fractions.red, .red)
            label("G", fractions.green, .green)
            label("B", fractions.blue, .blue)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title == "shadows:" ? "Shadow clipping" : "Highlight clipping")
        .accessibilityValue("red \(spokenPercent(fractions.red)), green \(spokenPercent(fractions.green)), "
                            + "blue \(spokenPercent(fractions.blue))")
    }

    private func label(_ name: String, _ fraction: Float, _ color: Color) -> some View {
        let percent = fraction * 100
        return HStack(spacing: 3) {
            Text(name).foregroundStyle(color)
            Text(percentText(percent))
                .foregroundStyle(percent > 1 ? Color.orange : Color.secondary)
        }
    }

    private func percentText(_ percent: Float) -> String {
        percent < 0.01 ? "—" : String(format: "%.1f%%", percent)
    }

    private func spokenPercent(_ fraction: Float) -> String {
        let percent = fraction * 100
        return percent < 0.01 ? "none" : String(format: "%.1f percent", percent)
    }
}
