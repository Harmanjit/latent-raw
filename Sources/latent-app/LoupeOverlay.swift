import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixelEngine

/// View › Loupe Overlay, after Lightroom's: a grid, two guides you drag
/// into place, and a layout image (a PNG with transparency, say a
/// magazine cover's masthead and type) laid over the photo, in Loupe and
/// in Develop. Display only: nothing here reaches the edit or an export.
///
/// The settings are the app's, not a photo's, and are remembered between
/// launches. The layout image is copied into Application Support when it
/// is chosen, so it needs no lasting permission to the file it came from.
@MainActor
final class LoupeOverlaySettings: ObservableObject {
    static let shared = LoupeOverlaySettings()

    private let defaults: UserDefaults
    private let directory: URL

    /// Show Overlay (⌥⌘O): the overlays switched on below, or none.
    @Published var isShown: Bool { didSet { defaults.set(isShown, forKey: Key.shown) } }
    @Published var showsGrid: Bool { didSet { defaults.set(showsGrid, forKey: Key.grid) } }
    @Published var showsGuides: Bool { didSet { defaults.set(showsGuides, forKey: Key.guides) } }
    @Published var showsLayoutImage: Bool { didSet { defaults.set(showsLayoutImage, forKey: Key.layout) } }
    /// A grid square's side, in points on screen.
    @Published var gridSize: Double { didSet { defaults.set(gridSize, forKey: Key.gridSize) } }
    @Published var gridOpacity: Double { didSet { defaults.set(gridOpacity, forKey: Key.gridOpacity) } }
    /// Where the vertical and the horizontal guide sit, 0...1 across and
    /// down the picture, so they stay put through zoom and resizing.
    @Published var guideX: Double { didSet { defaults.set(guideX, forKey: Key.guideX) } }
    @Published var guideY: Double { didSet { defaults.set(guideY, forKey: Key.guideY) } }
    @Published var layoutOpacity: Double { didSet { defaults.set(layoutOpacity, forKey: Key.layoutOpacity) } }
    /// 1 fits the layout image inside the picture; the offsets move it by
    /// a fraction of the picture's width and height.
    @Published var layoutScale: Double { didSet { defaults.set(layoutScale, forKey: Key.layoutScale) } }
    @Published var layoutOffsetX: Double { didSet { defaults.set(layoutOffsetX, forKey: Key.layoutOffsetX) } }
    @Published var layoutOffsetY: Double { didSet { defaults.set(layoutOffsetY, forKey: Key.layoutOffsetY) } }
    @Published private(set) var layoutImage: NSImage?

    static let gridSizes: ClosedRange<Double> = 8...240
    static let layoutScales: ClosedRange<Double> = 0.1...3

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("latent/loupe-overlay", isDirectory: true)
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        isShown = bool(Key.shown, false)
        showsGrid = bool(Key.grid, true)
        showsGuides = bool(Key.guides, false)
        showsLayoutImage = bool(Key.layout, false)
        gridSize = double(Key.gridSize, 48)
        gridOpacity = double(Key.gridOpacity, 0.5)
        guideX = double(Key.guideX, 0.5)
        guideY = double(Key.guideY, 0.5)
        layoutOpacity = double(Key.layoutOpacity, 1)
        layoutScale = double(Key.layoutScale, 1)
        layoutOffsetX = double(Key.layoutOffsetX, 0)
        layoutOffsetY = double(Key.layoutOffsetY, 0)
        layoutImage = NSImage(contentsOf: layoutFileURL)
    }

    var layoutFileURL: URL { directory.appendingPathComponent("layout.png") }

    /// Something would be drawn with the overlay shown.
    var hasAnythingToShow: Bool { showsGrid || showsGuides || (showsLayoutImage && layoutImage != nil) }

    /// The guides back across the middle of the picture.
    func resetGuides() {
        guideX = 0.5
        guideY = 0.5
    }

    /// The layout image's size and place back to fitting the picture.
    func resetLayoutPlacement() {
        layoutScale = 1
        layoutOffsetX = 0
        layoutOffsetY = 0
    }

    /// View › Loupe Overlay › Choose Layout Image…: a PNG, copied in.
    func chooseLayoutImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Layout Image"
        panel.message = "A PNG with transparency, shown over the photo"
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try adoptLayoutImage(from: url)
        } catch {
            NSSound.beep()
            Log.editor.error("Layout image: \(String(describing: error), privacy: .private)")
        }
    }

    /// Copies `url` in as the layout image and shows it.
    func adoptLayoutImage(from url: URL) throws {
        guard let image = NSImage(contentsOf: url), image.isValid else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent("layout-new.png")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: url, to: staged)
        if fm.fileExists(atPath: layoutFileURL.path) {
            _ = try fm.replaceItemAt(layoutFileURL, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: layoutFileURL)
        }
        layoutImage = image
        resetLayoutPlacement()
        showsLayoutImage = true
        isShown = true
    }

    private enum Key {
        static let shown = "latent.loupeOverlay.shown"
        static let grid = "latent.loupeOverlay.grid"
        static let guides = "latent.loupeOverlay.guides"
        static let layout = "latent.loupeOverlay.layout"
        static let gridSize = "latent.loupeOverlay.gridSize"
        static let gridOpacity = "latent.loupeOverlay.gridOpacity"
        static let guideX = "latent.loupeOverlay.guideX"
        static let guideY = "latent.loupeOverlay.guideY"
        static let layoutOpacity = "latent.loupeOverlay.layoutOpacity"
        static let layoutScale = "latent.loupeOverlay.layoutScale"
        static let layoutOffsetX = "latent.loupeOverlay.layoutOffsetX"
        static let layoutOffsetY = "latent.loupeOverlay.layoutOffsetY"
    }
}

/// Where the overlays land, in the view's points. Pure, so it is tested.
enum LoupeOverlayGeometry {
    /// The picture's rectangle on screen: the canvas through the viewport,
    /// from drawable pixels to points.
    static func imageRect(imageSize: CGSize, viewport: ViewportTransform, drawableSize: CGSize,
                          viewSize: CGSize) -> CGRect {
        guard viewSize.width > 0, drawableSize.width > 0 else { return .zero }
        let scale = drawableSize.width / viewSize.width
        let px = viewport.screenRect(forSensorRect: CGRect(origin: .zero, size: imageSize), drawableSize: drawableSize)
        return CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale)
    }

    /// The grid's lines: squares of `cell` points from the picture's top
    /// left corner, the edges themselves left out.
    static func gridLines(in rect: CGRect, cell: CGFloat) -> (xs: [CGFloat], ys: [CGFloat]) {
        guard rect.width > 0, rect.height > 0, cell >= 1 else { return ([], []) }
        func lines(from start: CGFloat, to end: CGFloat) -> [CGFloat] {
            var result: [CGFloat] = []
            var value = start + cell
            while value < end - 0.5 && result.count < 2000 {
                result.append(value)
                value += cell
            }
            return result
        }
        return (lines(from: rect.minX, to: rect.maxX), lines(from: rect.minY, to: rect.maxY))
    }

    /// The layout image fitted inside the picture, scaled about its centre
    /// and moved by fractions of the picture's size.
    static func layoutRect(imageSize: CGSize, in rect: CGRect, scale: CGFloat, offset: CGPoint) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else { return .zero }
        let fit = min(rect.width / imageSize.width, rect.height / imageSize.height) * max(scale, 0.01)
        let size = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        let centre = CGPoint(x: rect.midX + offset.x * rect.width, y: rect.midY + offset.y * rect.height)
        return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }

    /// A guide dragged to `location`: its fraction of the picture, kept on it.
    static func guideFraction(_ location: CGFloat, from start: CGFloat, length: CGFloat) -> Double {
        guard length > 0 else { return 0.5 }
        return Double(min(max((location - start) / length, 0), 1))
    }
}

/// The overlays themselves, over one viewport. Only the guides take the
/// mouse, along a thin strip each; everything else lets clicks through to
/// the image and its tools.
struct LoupeOverlayView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var settings = LoupeOverlaySettings.shared

    var body: some View {
        GeometryReader { geo in
            let rect = LoupeOverlayGeometry.imageRect(imageSize: model.imageSize, viewport: model.viewport,
                                                      drawableSize: model.drawableSize, viewSize: geo.size)
            ZStack(alignment: .topLeading) {
                if settings.showsLayoutImage, let image = settings.layoutImage {
                    let r = LoupeOverlayGeometry.layoutRect(imageSize: image.size, in: rect, scale: settings.layoutScale,
                                                            offset: CGPoint(x: settings.layoutOffsetX, y: settings.layoutOffsetY))
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .opacity(settings.layoutOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if settings.showsGrid {
                    Canvas { context, _ in
                        let lines = LoupeOverlayGeometry.gridLines(in: rect, cell: settings.gridSize)
                        var path = Path()
                        for x in lines.xs { path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY)) }
                        for y in lines.ys { path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y)) }
                        context.stroke(path, with: .color(.black.opacity(settings.gridOpacity * 0.6)), lineWidth: 2)
                        context.stroke(path, with: .color(.white.opacity(settings.gridOpacity)), lineWidth: 0.75)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                if settings.showsGuides {
                    guides(in: rect, bounds: CGRect(origin: .zero, size: geo.size))
                }
            }
            .coordinateSpace(name: Self.space)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private static let space = "loupeOverlay"

    @ViewBuilder
    private func guides(in rect: CGRect, bounds: CGRect) -> some View {
        let visible = rect.intersection(bounds)
        if !visible.isNull, visible.width > 0 {
            let x = rect.minX + rect.width * settings.guideX
            let y = rect.minY + rect.height * settings.guideY
            Canvas { context, _ in
                var path = Path()
                path.move(to: CGPoint(x: x, y: visible.minY)); path.addLine(to: CGPoint(x: x, y: visible.maxY))
                path.move(to: CGPoint(x: visible.minX, y: y)); path.addLine(to: CGPoint(x: visible.maxX, y: y))
                context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 3)
                context.stroke(path, with: .color(.cyan), lineWidth: 1)
            }
            .allowsHitTesting(false)
            // A strip along each guide to drag it by.
            Color.clear
                .frame(width: 9, height: visible.height)
                .contentShape(Rectangle())
                .position(x: x, y: visible.midY)
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space)).onChanged { drag in
                    settings.guideX = LoupeOverlayGeometry.guideFraction(drag.location.x, from: rect.minX, length: rect.width)
                })
                .accessibilityElement()
                .accessibilityLabel("Vertical guide")
                .accessibilityValue("\(Int((settings.guideX * 100).rounded())) percent across")
                .accessibilityAdjustableAction { direction in
                    settings.guideX = min(max(settings.guideX + (direction == .increment ? 0.01 : -0.01), 0), 1)
                }
            Color.clear
                .frame(width: visible.width, height: 9)
                .contentShape(Rectangle())
                .position(x: visible.midX, y: y)
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space)).onChanged { drag in
                    settings.guideY = LoupeOverlayGeometry.guideFraction(drag.location.y, from: rect.minY, length: rect.height)
                })
                .accessibilityElement()
                .accessibilityLabel("Horizontal guide")
                .accessibilityValue("\(Int((settings.guideY * 100).rounded())) percent down")
                .accessibilityAdjustableAction { direction in
                    settings.guideY = min(max(settings.guideY + (direction == .increment ? 0.01 : -0.01), 0), 1)
                }
        }
    }
}

/// The overlay's controls, in a popover from a small button at the
/// viewport's top right while the overlay shows.
struct LoupeOverlayControls: View {
    @ObservedObject var settings = LoupeOverlaySettings.shared
    @State private var showingOptions = false

    var body: some View {
        Button {
            showingOptions.toggle()
        } label: {
            Label("Overlay", systemImage: "square.grid.3x3")
                .labelStyle(.iconOnly)
                .padding(5)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .help("Loupe overlay options")
        .accessibilityLabel("Loupe overlay options")
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            options.padding(14).frame(width: 260)
        }
        .padding(8)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Grid", isOn: $settings.showsGrid)
            HStack {
                Text("Size").frame(width: 56, alignment: .leading)
                Slider(value: $settings.gridSize, in: LoupeOverlaySettings.gridSizes)
                    .accessibilityLabel("Grid size")
            }
            .disabled(!settings.showsGrid)
            HStack {
                Text("Opacity").frame(width: 56, alignment: .leading)
                Slider(value: $settings.gridOpacity, in: 0.1...1)
                    .accessibilityLabel("Grid opacity")
            }
            .disabled(!settings.showsGrid)
            Divider()
            HStack {
                Toggle("Guides", isOn: $settings.showsGuides)
                Spacer()
                Button("Reset") { settings.resetGuides() }
                    .disabled(!settings.showsGuides)
                    .help("Put the guides back across the middle of the photo")
                    .accessibilityLabel("Reset guides")
            }
            Divider()
            HStack {
                Toggle("Layout Image", isOn: $settings.showsLayoutImage)
                    .disabled(settings.layoutImage == nil)
                Spacer()
                Button("Choose…") { settings.chooseLayoutImage() }
                    .accessibilityLabel("Choose layout image")
            }
            Group {
                HStack {
                    Text("Opacity").frame(width: 56, alignment: .leading)
                    Slider(value: $settings.layoutOpacity, in: 0.05...1)
                        .accessibilityLabel("Layout image opacity")
                }
                HStack {
                    Text("Scale").frame(width: 56, alignment: .leading)
                    Slider(value: $settings.layoutScale, in: LoupeOverlaySettings.layoutScales)
                        .accessibilityLabel("Layout image scale")
                }
                HStack {
                    Text("Across").frame(width: 56, alignment: .leading)
                    Slider(value: $settings.layoutOffsetX, in: -0.5...0.5)
                        .accessibilityLabel("Layout image position across")
                }
                HStack {
                    Text("Down").frame(width: 56, alignment: .leading)
                    Slider(value: $settings.layoutOffsetY, in: -0.5...0.5)
                        .accessibilityLabel("Layout image position down")
                }
                Button("Fit to Photo") { settings.resetLayoutPlacement() }
            }
            .disabled(!settings.showsLayoutImage || settings.layoutImage == nil)
        }
        .controlSize(.small)
    }
}
