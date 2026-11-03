import SwiftUI
import PixelEngine
import MLKit

/// Lens Blur (docs/wiki/Develop.md, "Lens Blur"), the content of
/// `DisclosureGroup("Lens Blur")`: Amount, the bokeh's shape, Boost
/// Highlights, the Focus Range over the depth map's histogram, Pick Focus
/// and Show Depth, and where the depth came from. Everything runs on this
/// Mac; the footnote says so.
struct LensBlurSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state: LensBlurState

    init(model: EditorModel) {
        self.model = model
        self.state = model.lensBlurState
    }

    private var blur: LensBlur { model.parameters.lensBlur }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Amount", value: Binding(get: { blur.amount }, set: { model.setLensBlurAmount($0) }),
                hint: "How strongly everything outside the focus range is blurred; 0 turns Lens Blur off")

            HStack {
                Text("Bokeh").font(.subheadline).accessibilityHidden(true)
                Spacer()
                Picker("Bokeh", selection: Binding(get: { blur.bokeh }, set: { model.parameters.lensBlur.bokeh = $0 })) {
                    ForEach(LensBlur.Bokeh.allCases) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("The shape out-of-focus highlights take: an even circle, a bright-rimmed bubble, or the pentagon of a five-blade aperture")
                .accessibilityLabel("Bokeh shape")
            }
            .controlSize(.small)
            .disabled(!blur.isActive)

            row("Boost Highlights", value: $model.parameters.lensBlur.boost,
                hint: "Brightens highlights in the blur so points of light open into visible discs")
                .disabled(!blur.isActive)

            focusRange

            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { state.pickingFocus }, set: { model.setPickingFocus($0) })) {
                    Text(state.pickingFocus ? "Click the photo…" : "Pick Focus")
                }
                .toggleStyle(.button)
                .help("Then click the part of the photo to keep sharp: the focus range centres on its depth")
                .accessibilityLabel("Pick focus")
                .accessibilityHint("The next click on the photo sets the focus range around what was clicked")
                Toggle("Show Depth", isOn: Binding(get: { state.showDepth }, set: { model.setShowDepth($0) }))
                    .toggleStyle(.button)
                    .help("Show the depth map in colour, amber near to blue far, the focus range washed light; the photo is not changed")
                    .accessibilityHint("Shows the depth map in place of the photo")
                Spacer()
                if state.building { ProgressView().controlSize(.mini).accessibilityLabel("Making the depth map") }
            }
            .controlSize(.small)

            if !state.status.isEmpty {
                Text(state.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            depthSourceRow

            Text("The depth map is made on this Mac. Nothing is sent anywhere.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.hasImage)
    }

    // MARK: - Focus Range

    private var focusRange: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Focus Range").font(.subheadline).accessibilityHidden(true)
                Spacer()
                Text(String(format: "%.0f–%.0f", blur.focusFar * 100, blur.focusNear * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            FocusRangeBar(range: Binding(get: { SIMD2(blur.focusFar, blur.focusNear) },
                                         set: { range in
                                             var b = model.parameters.lensBlur
                                             b.focusFar = range.x
                                             b.focusNear = range.y
                                             model.parameters.lensBlur = b
                                         }),
                          histogram: state.histogram)
                .frame(height: 34)
                .help("Drag either edge: the part of the scene between them stays sharp. Far is on the left, near on the right")
            HStack {
                Text("Far").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Near").font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: - Depth source

    @ViewBuilder
    private var depthSourceRow: some View {
        let models = ModelRegistry.shared.entries(kind: .depth).filter(\.isInstalled)
        HStack(spacing: 6) {
            Text("Depth:").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            Menu(LensBlurDepth.displayName(of: blur.depthModel ?? state.source ?? LensBlurDepth.defaultSource())) {
                ForEach(models) { entry in
                    Button(entry.manifest.displayName) { model.remakeDepthMap(with: entry.modelVersion) }
                }
                Button("Subject (two planes)") { model.remakeDepthMap(with: LensBlur.subjectDepthVersion) }
                if models.isEmpty {
                    Divider()
                    Text("No depth model installed: add one in Settings › AI › Models")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.mini)
            .help("What the depth map is made with. A depth model (Settings › AI › Models) knows the whole scene; the subject's two planes keep the subject sharp and blur the rest evenly")
            .accessibilityLabel("Depth source")
            Spacer()
        }
    }

    /// A 0…100 slider with a typed value, as the other panels' rows.
    private func row(_ title: String, value: Binding<Float>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: value, in: 0...100, format: SliderValueFormat(printf: "%.0f"), label: title)
            }
            ResettableSlider(value: value, in: 0...100, label: title,
                             format: SliderValueFormat(printf: "%.0f")) { value.wrappedValue = 0 }
                .help("Double-click to reset")
                .accessibilityHint(hint)
        }
    }
}

/// The Focus Range: a strip from far (left) to near (right) in Show
/// Depth's colours, the depth map's histogram drawn over it, and the range
/// that stays sharp as a light band with a handle at each edge. A drag
/// moves the nearer handle; dragging inside the band moves both. VoiceOver
/// reads it as two adjustable values.
struct FocusRangeBar: View {
    /// x the far edge, y the near edge, both 0…1, x ≤ y. One binding so a
    /// drag of the whole band is one change, never a crossed pair.
    @Binding var range: SIMD2<Float>
    let histogram: [Float]

    private var far: Float { range.x }
    private var near: Float { range.y }

    private enum Grab { case far, near, both(start: Float, far: Float, near: Float) }
    @State private var grab: Grab?

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1), h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.50),
                                                  Color(red: 0.10, green: 0.62, blue: 0.60),
                                                  Color(red: 1.00, green: 0.72, blue: 0.18)],
                                         startPoint: .leading, endPoint: .trailing))
                    .opacity(0.55)
                Canvas { context, size in
                    guard let peak = histogram.max(), peak > 0 else { return }
                    let step = size.width / CGFloat(histogram.count)
                    for (i, v) in histogram.enumerated() {
                        let barHeight = CGFloat(sqrt(v / peak)) * (size.height - 4)
                        context.fill(Path(CGRect(x: CGFloat(i) * step, y: size.height - barHeight,
                                                 width: max(step - 0.5, 0.5), height: barHeight)),
                                     with: .color(.white.opacity(0.55)))
                    }
                }
                Rectangle()
                    .fill(Color.white.opacity(0.28))
                    .overlay(Rectangle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                    .frame(width: max(CGFloat(near - far) * w, 2), height: h)
                    .offset(x: CGFloat(far) * w)
                handle.offset(x: CGFloat(far) * w - 3)
                handle.offset(x: CGFloat(near) * w - 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in dragged(to: Float(drag.location.x / w), from: Float(drag.startLocation.x / w)) }
                .onEnded { _ in grab = nil })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation {
            VStack {
                Slider(value: Binding(get: { Double(far) }, set: { range.x = min(Float($0), near) }), in: 0...1)
                    .accessibilityLabel("Focus range, far edge")
                    .accessibilityValue(String(format: "%.0f percent", far * 100))
                Slider(value: Binding(get: { Double(near) }, set: { range.y = max(Float($0), far) }), in: 0...1)
                    .accessibilityLabel("Focus range, near edge")
                    .accessibilityValue(String(format: "%.0f percent", near * 100))
            }
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 6)
            .shadow(radius: 1)
    }

    /// The first touch picks what moves: inside the band (clear of its
    /// edges) both edges, else the nearer edge. Edges never cross.
    private func dragged(to x: Float, from start: Float) {
        let x = min(max(x, 0), 1)
        if grab == nil {
            let edge: Float = 0.03
            if start > far + edge, start < near - edge {
                grab = .both(start: start, far: far, near: near)
            } else {
                grab = abs(start - far) <= abs(start - near) ? .far : .near
            }
        }
        switch grab {
        case .far: range.x = min(x, near)
        case .near: range.y = max(x, far)
        case .both(let s, let f, let n):
            let delta = min(max(x - s, -f), 1 - n)
            range = SIMD2(f + delta, n + delta)
        case nil: break
        }
    }
}
