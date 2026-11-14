import SwiftUI
import AppKit
import PixelEngine

/// One pinned colour sample: where it is on the picture and what it last
/// read. Per session, never stored in the edit.
struct ColourSample: Identifiable, Equatable {
    let id: Int
    /// Sensor pixels, before crop and rotation, so the sample stays on
    /// the same part of the picture through pan, zoom and crop.
    let sensorPoint: CGPoint
    let size: PixelSampleSize
    var value: PixelAreaStatistics?
}

/// The pinned samples of the image open in one editor (darktable's
/// "live samples"). Up to eight; a new image starts with none.
@MainActor
final class ColourSamples: ObservableObject {
    static let limit = 8

    @Published private(set) var samples: [ColourSample] = []
    /// The image the samples were pinned on.
    private(set) var imageURL: URL?
    private var nextID = 1

    /// The samples, if they belong to `url`.
    func samples(for url: URL?) -> [ColourSample] {
        url != nil && url == imageURL ? samples : []
    }

    /// Pins a sample; false when eight are already pinned. A different
    /// image starts a fresh list.
    @discardableResult
    func pin(at sensorPoint: CGPoint, size: PixelSampleSize, value: PixelAreaStatistics?, url: URL?) -> Bool {
        if url != imageURL { samples = []; imageURL = url; nextID = 1 }
        guard samples.count < Self.limit else { return false }
        samples.append(ColourSample(id: nextID, sensorPoint: sensorPoint, size: size, value: value))
        nextID += 1
        return true
    }

    func remove(id: Int) {
        samples.removeAll { $0.id == id }
        if samples.isEmpty { nextID = 1 }
    }

    func removeAll() { samples = []; nextID = 1 }

    /// New readings, in the samples' order; unchanged ones aren't
    /// republished.
    func update(values: [Int: PixelAreaStatistics?]) {
        var changed = samples
        for i in changed.indices {
            if let v = values[changed[i].id], changed[i].value != v { changed[i].value = v }
        }
        if changed != samples { samples = changed }
    }
}

extension EditorModel {
    /// The layer showing `sensor`: the full-resolution tile where it
    /// covers, the preview elsewhere (as `displayedPixel` chooses).
    private func layer(showing sensor: CGPoint) -> PresentLayer? {
        guard let preview else { return nil }
        if let tile, tile.coverage.insetBy(dx: tile.inset, dy: tile.inset).contains(sensor) { return tile }
        return preview.coverage.contains(sensor) ? preview : nil
    }

    /// The displayed colours (linear Display P3) of a square `size` image
    /// pixels across centred on `sensor`, read from the layer showing it.
    /// The square is scaled to that layer's resolution, so it covers the
    /// same part of the picture on the preview as on a tile.
    func displayedArea(atSensor sensor: CGPoint, size: PixelSampleSize) -> PixelAreaStatistics? {
        guard hasImage, let gpu = gpuContext, let layer = layer(showing: sensor) else { return nil }
        let c = layer.coverage, tex = layer.texture
        guard c.width > 0, tex.width > 0, tex.height > 0 else { return nil }
        let cx = Int((sensor.x - c.minX) / c.width * CGFloat(tex.width))
        let cy = Int((sensor.y - c.minY) / c.height * CGFloat(tex.height))
        let r = size == .point ? 0 : Int((Double(size.radius) * Double(tex.width) / Double(c.width)).rounded())
        let x0 = min(max(cx - r, 0), tex.width - 1), y0 = min(max(cy - r, 0), tex.height - 1)
        let x1 = min(max(cx + r, 0), tex.width - 1), y1 = min(max(cy + r, 0), tex.height - 1)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        guard let px = try? TextureReadback.float16Pixels(of: tex, x: x0, y: y0, width: w, height: h, gpu: gpu),
              px.count >= w * h * 4 else { return nil }
        var colours: [SIMD3<Float>] = []
        colours.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            colours.append(SIMD3(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])))
        }
        return PixelAreaStatistics(pixels: colours)
    }

    /// The sensor point under a screen point (drawable pixels); nil off
    /// the picture.
    func sensorPointOnPicture(atScreen screen: CGPoint) -> CGPoint? {
        guard hasImage, drawableSize.width > 0 else { return nil }
        let canvas = viewport.sensorPoint(forScreenPoint: screen, drawableSize: drawableSize)
        let size = frame.canvasSize
        guard canvas.x >= 0, canvas.y >= 0, canvas.x < size.width, canvas.y < size.height else { return nil }
        return frame.sensorPoint(fromCanvasPoint: canvas)
    }

    /// The area readout for the colour picker, when its sample size is
    /// larger than a point: called with each pointer move.
    func updateAreaReadout(atScreen screen: CGPoint?) {
        let size = ScopeSettings.shared.sampleSize
        var area: PixelAreaStatistics?
        if size != .point, let screen, let sensor = sensorPointOnPicture(atScreen: screen) {
            area = displayedArea(atSensor: sensor, size: size)
        }
        if pixelProbe.area != area { pixelProbe.area = area }
        if screen != nil, let readout = pixelProbe.readout {
            pixelProbe.lastReadout = readout
            pixelProbe.lastArea = area
        }
    }

    /// Option-click in Develop: pins a colour sample under the pointer.
    func pinColourSample(atScreen screen: CGPoint) {
        guard let sensor = sensorPointOnPicture(atScreen: screen) else { return }
        let size = ScopeSettings.shared.sampleSize
        if !colourSamples.pin(at: sensor, size: size, value: displayedArea(atSensor: sensor, size: size),
                              url: sourceURL) {
            status = "Eight colour samples are pinned; remove one to pin another"
        }
    }

    /// Reads every pinned sample again, after a render.
    func refreshColourSamples() {
        let pinned = colourSamples.samples(for: sourceURL)
        guard !pinned.isEmpty else { return }
        var values: [Int: PixelAreaStatistics?] = [:]
        for s in pinned { values[s.id] = displayedArea(atSensor: s.sensorPoint, size: s.size) }
        colourSamples.update(values: values)
    }

    /// A sensor point in view points, through the crop frame and viewport.
    func viewPoint(forSensor sensor: CGPoint, scale: CGFloat) -> CGPoint {
        let canvas = frame.canvasPoint(fromSensorPoint: sensor)
        let px = viewport.screenPoint(forSensorPoint: canvas, drawableSize: drawableSize)
        return CGPoint(x: px.x / scale, y: px.y / scale)
    }
}

/// Under the colour readout: the pinned samples with their live values,
/// each with a remove button. Shown only while there are some.
struct ColourSamplesPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var samples: ColourSamples
    @ObservedObject var settings = ScopeSettings.shared

    var body: some View {
        let pinned = samples.samples(for: model.sourceURL)
        if !pinned.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Samples").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear") { samples.removeAll() }
                        .buttonStyle(.borderless).controlSize(.mini)
                        .help("Remove every pinned sample")
                }
                ForEach(pinned) { sample in
                    row(sample)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .onReceive(model.$preview) { _ in refreshSoon() }
            .onReceive(model.$tile) { _ in refreshSoon() }
            .onAppear { model.refreshColourSamples() }
        }
    }

    private func row(_ sample: ColourSample) -> some View {
        let text = sample.value.map { $0.mean.text(in: settings.readoutSpace) } ?? "off the picture"
        return HStack(spacing: 4) {
            Text("\(sample.id)").foregroundStyle(.secondary).frame(width: 12, alignment: .trailing)
            Circle()
                .fill(swatch(sample.value?.mean))
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5))
            Text(text).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Button {
                samples.remove(id: sample.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless).controlSize(.mini)
            .help("Remove sample \(sample.id)")
            .accessibilityLabel("Remove sample \(sample.id)")
        }
        .contextMenu {
            Button("Copy Value") { copy(text) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sample \(sample.id): \(text)")
    }

    private func swatch(_ readout: PixelReadout?) -> Color {
        guard let p = readout?.percent else { return .clear }
        return Color(.displayP3, red: Double(p.x / 100), green: Double(p.y / 100), blue: Double(p.z / 100))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// `@Published` announces a change before it lands, so the read waits
    /// for the next turn of the main loop.
    private func refreshSoon() {
        Task { @MainActor in model.refreshColourSamples() }
    }
}

/// Numbered markers over the viewport at each pinned sample. Display
/// only: it never takes a click.
struct ColourSampleMarkers: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var samples: ColourSamples

    var body: some View {
        GeometryReader { geo in
            let scale = model.drawableSize.width / max(geo.size.width, 1)
            ForEach(samples.samples(for: model.sourceURL)) { sample in
                let p = model.viewPoint(forSensor: sample.sensorPoint, scale: scale)
                marker(sample).position(p)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func marker(_ sample: ColourSample) -> some View {
        ZStack {
            Rectangle()
                .stroke(Color.white, lineWidth: 1)
                .background(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 3))
                .frame(width: 9, height: 9)
            Text("\(sample.id)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
                .offset(x: 10, y: -9)
        }
    }
}

// MARK: - Picker sizes and spaces

/// The readout in a chosen space, and for an area its mean with the
/// least and greatest values on a second line.
struct PixelReadoutLines: View {
    let readout: PixelReadout?
    let area: PixelAreaStatistics?
    @ObservedObject var settings: ScopeSettings

    var body: some View {
        if let text = Self.text(readout: readout, area: area, settings: settings) {
            Text(text)
        } else {
            Text("Point at the photo for its colour")
        }
    }

    /// What Copy Value copies: the readout's lines as shown.
    @MainActor
    static func text(readout: PixelReadout?, area: PixelAreaStatistics?, settings: ScopeSettings) -> String? {
        let space = settings.readoutSpace
        if settings.sampleSize != .point, let area {
            let range = area.range(in: space == .standard ? .rgbPercent : space)
            let rangeSpace: PixelReadoutSpace = space == .standard ? .rgbPercent : space
            return "x̄ " + area.mean.text(in: space) + "\n"
                + "min " + PixelReadout.text(range.min, space: rangeSpace)
                + "  max " + PixelReadout.text(range.max, space: rangeSpace)
        }
        guard let readout else { return nil }
        let hdr = readout.stopsAboveSDRWhite.map { String(format: "   +%.1f stops", $0) } ?? ""
        return readout.text(in: space) + hdr
    }
}

/// Beside the readout: the sample size, the space, and Copy Value.
struct PixelReadoutMenu: View {
    @ObservedObject var probe: PixelProbe
    @ObservedObject private var settings = ScopeSettings.shared

    var body: some View {
        Menu {
            Picker("Sample Size", selection: $settings.sampleSize) {
                ForEach(PixelSampleSize.allCases) { Text($0.title).tag($0) }
            }
            Picker("Show As", selection: $settings.readoutSpace) {
                ForEach(PixelReadoutSpace.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Copy Value") {
                guard let text = PixelReadoutLines.text(readout: probe.lastReadout, area: probe.lastArea,
                                                        settings: settings) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .help("Copies the last colour read over the photo")
            Text("Option-click the photo to pin a sample")
        } label: {
            Image(systemName: "eyedropper")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.mini)
        .help("Colour picker: sample size, colour space, copy the value")
        .accessibilityLabel("Colour picker options")
    }
}
