import SwiftUI
import CoreGraphics
import PixelEngine

/// Which scope the panel shows. Only the selected one is computed.
enum ScopeKind: String, CaseIterable, Identifiable {
    case histogram, waveform, vectorscope
    /// The waveform's three channels side by side (an RGB parade).
    case parade
    /// Two scopes stacked, measured from the same analysis render.
    case waveformVectorscope, histogramVectorscope
    var id: String { rawValue }
    var title: String {
        switch self {
        case .histogram:   return "Histogram"
        case .waveform:    return "Waveform"
        case .vectorscope: return "Vectorscope"
        case .parade:      return "RGB Parade"
        case .waveformVectorscope:  return "Waveform + Vectorscope"
        case .histogramVectorscope: return "Histogram + Vectorscope"
        }
    }
    /// The three in the segmented control.
    static let primary: [ScopeKind] = [.histogram, .waveform, .vectorscope]
    /// The rest, in the menu beside it.
    static let more: [ScopeKind] = [.parade, .waveformVectorscope, .histogramVectorscope]
}

/// The scope area at the top of the adjustments panel: a picker and the
/// chosen scope beneath it.
struct ScopePanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Picker("Scope", selection: $model.scope) {
                    ForEach(ScopeKind.primary) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                MoreScopesMenu(model: model)
            }

            switch model.scope {
            case .histogram:
                HistogramView(histogram: model.histogram)
                    .overlay(HistogramAdjustOverlay(model: model))
                ClippingReadout(histogram: model.histogram,
                                showsAboveSDRWhite: model.rendersAboveSDRWhite)
            case .waveform:
                WaveformView(waveform: model.waveform)
            case .vectorscope:
                GuidedVectorscope(model: model, samples: model.colourSamples)
            case .parade:
                ParadeView(waveform: model.waveform)
            case .waveformVectorscope:
                WaveformView(waveform: model.waveform, height: 64)
                GuidedVectorscope(model: model, samples: model.colourSamples)
                    .frame(height: 120)
            case .histogramVectorscope:
                HistogramView(histogram: model.histogram, height: 56)
                    .overlay(HistogramAdjustOverlay(model: model))
                GuidedVectorscope(model: model, samples: model.colourSamples)
                    .frame(height: 120)
            }
            PixelReadoutBar(model: model)
            ColourSamplesPanel(model: model, samples: model.colourSamples)
        }
    }
}

/// Both scope drawings work the same way: turn the count grid into a
/// small bitmap once on the CPU (65K pixels — trivial), then draw that
/// bitmap scaled. Drawing 65K individual rectangles through Canvas would
/// be far slower for no gain.
private enum ScopeBitmap {
    /// Builds an RGBA8 image of `width x height` from a per-pixel colour
    /// callback returning 0...1 components.
    static func make(width: Int, height: Int,
                     pixel: (_ x: Int, _ y: Int) -> (r: Float, g: Float, b: Float)) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i]     = UInt8(min(1, max(0, r)) * 255)
                bytes[i + 1] = UInt8(min(1, max(0, g)) * 255)
                bytes[i + 2] = UInt8(min(1, max(0, b)) * 255)
                bytes[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

struct WaveformView: View {
    let waveform: Waveform?
    /// Less when it shares the panel with another scope.
    var height: CGFloat = 110

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.08))
            if let waveform, waveform.peak > 0, let image = bitmap(waveform) {
                Canvas { context, size in
                    // Horizontal guide lines at quarter stops of the range.
                    for f in [0.25, 0.5, 0.75] {
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: size.height * f))
                        line.addLine(to: CGPoint(x: size.width, y: size.height * f))
                        context.stroke(line, with: .color(Color(white: 0.22)), lineWidth: 0.5)
                    }
                    context.draw(Image(decorative: image, scale: 1),
                                 in: CGRect(origin: .zero, size: size))
                }
                .padding(1)
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("Waveform")
        .accessibilityValue(waveform.map { $0.peak > 0 ? "" : "No data" } ?? "No data")
    }

    /// Row 0 of the data is darkest but bitmaps start at the top, so the
    /// row is flipped. Square-root scaling, as with the histogram, keeps
    /// the sparse tails visible; the three channels add so neutral tones
    /// read as white.
    private func bitmap(_ w: Waveform) -> CGImage? {
        let scale = 1 / sqrt(Float(w.peak))
        let cols = Waveform.columns, rows = Waveform.rows
        return ScopeBitmap.make(width: cols, height: rows) { x, y in
            let i = (rows - 1 - y) * cols + x
            return (sqrt(Float(w.red[i])) * scale * 0.9,
                    sqrt(Float(w.green[i])) * scale * 0.9,
                    sqrt(Float(w.blue[i])) * scale * 0.9)
        }
    }
}

struct VectorscopeView: View {
    let vectorscope: Vectorscope?
    /// Drawn over the plot in its square (guides, sample dots); nil, none.
    var overlay: ((inout GraphicsContext, CGRect) -> Void)? = nil

    var body: some View {
        // Square, like the data: the plot fills its box exactly, with no
        // letterboxed background showing around it.
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.08))
            if let vectorscope, vectorscope.peak > 0, let image = bitmap(vectorscope) {
                Canvas { context, size in
                    let side = min(size.width, size.height)
                    let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                                      width: side, height: side)
                    // Graticule: centre cross and a ring at 50% saturation.
                    var lines = Path()
                    lines.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    lines.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    lines.move(to: CGPoint(x: rect.minX, y: rect.midY))
                    lines.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                    lines.addEllipse(in: rect.insetBy(dx: side * 0.25, dy: side * 0.25))
                    context.stroke(lines, with: .color(Color(white: 0.22)), lineWidth: 0.5)

                    context.draw(Image(decorative: image, scale: 1), in: rect)
                    overlay?(&context, rect)
                }
                .padding(1)
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("Vectorscope")
        .accessibilityValue(vectorscope.map { $0.peak > 0 ? "" : "No data" } ?? "No data")
    }

    /// Each cell is tinted with the hue it represents (from its Cb/Cr
    /// position) and brightened by how many pixels landed there, so the
    /// display reads as "this much of this colour" at a glance.
    private func bitmap(_ v: Vectorscope) -> CGImage? {
        let n = Vectorscope.size
        let scale = 1 / sqrt(Float(v.peak))
        return ScopeBitmap.make(width: n, height: n) { x, y in
            let density = sqrt(Float(v.counts[y * n + x])) * scale
            guard density > 0 else { return (0, 0, 0) }
            // Cb, Cr of this cell, at a fixed mid luma, back to RGB.
            let cb = Float(x) / Float(n - 1) - 0.5
            let cr = 0.5 - Float(y) / Float(n - 1)
            let luma: Float = 0.5
            var r = luma + 1.5748 * cr
            var b = luma + 1.8556 * cb
            var g = (luma - 0.2126 * r - 0.0722 * b) / 0.7152
            r = min(1, max(0.15, r)); g = min(1, max(0.15, g)); b = min(1, max(0.15, b))
            // Lift toward white with density so dense regions stay readable.
            let lift = density * 0.6
            return (r * density + lift, g * density + lift, b * density + lift)
        }
    }
}

/// The waveform's red, green and blue drawn side by side, each in its own
/// third and tinted with its colour, with the waveform's guide lines.
struct ParadeView: View {
    let waveform: Waveform?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.08))
            if let waveform, waveform.peak > 0, let image = bitmap(waveform) {
                Canvas { context, size in
                    for f in [0.25, 0.5, 0.75] {
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: size.height * f))
                        line.addLine(to: CGPoint(x: size.width, y: size.height * f))
                        context.stroke(line, with: .color(Color(white: 0.22)), lineWidth: 0.5)
                    }
                    context.draw(Image(decorative: image, scale: 1),
                                 in: CGRect(origin: .zero, size: size))
                    // Separators between the channels.
                    var gaps = Path()
                    for third in [1.0 / 3, 2.0 / 3] {
                        gaps.move(to: CGPoint(x: size.width * third, y: 0))
                        gaps.addLine(to: CGPoint(x: size.width * third, y: size.height))
                    }
                    context.stroke(gaps, with: .color(Color(white: 0.3)), lineWidth: 0.5)
                }
                .padding(1)
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 110)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("RGB parade")
        .accessibilityValue(waveform.map { $0.peak > 0 ? "" : "No data" } ?? "No data")
    }

    /// Three planes across one bitmap, square-root scaled as the
    /// waveform is; each channel lifted a little toward white so a thin
    /// trace still reads.
    private func bitmap(_ w: Waveform) -> CGImage? {
        ScopeBitmap.parade(w)
    }
}

extension ScopeBitmap {
    static func parade(_ w: Waveform) -> CGImage? {
        let scale = 1 / sqrt(Float(w.peak))
        let cols = Waveform.columns, rows = Waveform.rows
        return make(width: cols * 3, height: rows) { x, y in
            let channel = x / cols
            let i = (rows - 1 - y) * cols + (x % cols)
            let plane = channel == 0 ? w.red : channel == 1 ? w.green : w.blue
            let v = sqrt(Float(plane[i])) * scale
            let lift = v * 0.25
            switch channel {
            case 0: return (v + lift, lift, lift)
            case 1: return (lift, v + lift, lift)
            default: return (lift + v * 0.15, lift + v * 0.3, v + lift)
            }
        }
    }
}

/// The vectorscope with its guides (skin tone line, harmony) and the
/// pinned colour samples as numbered dots. Right-click for the guides;
/// drag on it, while a harmony shows, to turn the harmony.
struct GuidedVectorscope: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var samples: ColourSamples
    @ObservedObject var settings = ScopeSettings.shared

    var body: some View {
        let dots: [(id: Int, at: SIMD2<Float>)] = settings.plotsSamples
            ? samples.samples(for: model.sourceURL).compactMap { s in
                s.value.map { (s.id, Vectorscope.position(ofLinear: $0.mean.linear)) }
            }
            : []
        let skin = settings.skinToneLine, harmony = settings.harmony, angle = settings.harmonyAngle
        VectorscopeView(vectorscope: model.vectorscope) { context, rect in
            VectorscopeGuideDrawing.draw(in: &context, rect: rect, skinToneLine: skin,
                                         harmony: harmony, angle: angle)
            for dot in dots {
                let p = CGPoint(x: rect.minX + CGFloat(dot.at.x) * rect.width,
                                y: rect.minY + CGFloat(dot.at.y) * rect.height)
                let ring = Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                context.fill(ring, with: .color(.white))
                context.stroke(ring, with: .color(.black.opacity(0.7)), lineWidth: 1)
                context.draw(Text("\(dot.id)").font(.system(size: 8, weight: .semibold)).foregroundColor(.white),
                             at: CGPoint(x: p.x + 7, y: p.y - 6))
            }
        }
        .overlay {
            if harmony != .none {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let side = min(geo.size.width, geo.size.height)
                            let rect = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2,
                                              width: side, height: side)
                            settings.harmonyAngle = VectorscopeGeometry.angle(of: value.location, in: rect).rounded()
                        })
                }
                .help("Drag to turn the \(harmony.title.lowercased()) guide")
                .accessibilityHidden(true)
            }
        }
        .contextMenu { VectorscopeGuideMenu(settings: settings) }
    }
}

/// The scopes that aren't in the segmented control: a parade and the
/// two-up views. Choosing one leaves the segments unselected.
struct MoreScopesMenu: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Menu {
            ForEach(ScopeKind.more) { kind in
                Toggle(kind.title, isOn: Binding(get: { model.scope == kind },
                                                 set: { if $0 { model.scope = kind } }))
            }
        } label: {
            Image(systemName: "rectangle.split.1x2")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
        .help("More scopes: RGB parade, Waveform + Vectorscope, Histogram + Vectorscope")
        .accessibilityLabel("More scopes")
    }
}
