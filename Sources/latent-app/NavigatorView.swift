import SwiftUI
import PixelEngine

/// Whether the Navigator shows, one setting for every view: Develop's panel
/// section open or closed, and the floating card over Loupe, Compare and
/// Survey. View › Show Navigator toggles it. Kept under the key Develop's
/// section has always used, so an existing choice carries over.
@MainActor
final class NavigatorSettings: ObservableObject {
    static let shared = NavigatorSettings()
    static let shownKey = "latent.navigatorExpanded"

    private let defaults: UserDefaults

    @Published var isShown: Bool { didSet { defaults.set(isShown, forKey: Self.shownKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isShown = defaults.bool(forKey: Self.shownKey)
    }
}

/// The Navigator at the top of Develop's panel, as Lightroom and darktable
/// have it: the whole picture small, with the part the viewport shows
/// outlined. Click or drag in it to move the view there. Collapsed until
/// opened, and remembered either way.
struct NavigatorSection: View {
    @Bindable var model: EditorModel
    @ObservedObject private var settings = NavigatorSettings.shared

    var body: some View {
        DisclosureGroup(isExpanded: $settings.isShown) {
            VStack(spacing: 6) {
                NavigatorView(model: model)
                NavigatorZoomPresets(model: model)
            }
            .padding(.top, 6)
        } label: {
            Text("Navigator")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The picture fitted into the panel's width, drawn by the editor's own
/// presenter from its preview (no render of its own), and the viewport's
/// visible rectangle over it.
struct NavigatorView: View {
    @Bindable var model: EditorModel
    @ObservedObject private var prefs = AppPreferences.shared
    /// The navigator's drawable, in pixels, for the fit.
    @State private var drawableSize: CGSize = .zero
    /// The thumbnail's height; the floating card's is smaller than the panel's.
    var height: CGFloat = NavigatorView.height

    static let height: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                prefs.surroundColor
                if let device = model.device, let presenter = model.presenter, let preview = model.preview, model.hasImage {
                    MetalImageView(preview: preview, tile: nil,
                                   transform: .fit(imageSize: model.imageSize, drawableSize: drawableSize),
                                   frame: model.frame, presenter: presenter, device: device,
                                   onResize: { drawableSize = $0 }, onHeadroomChange: { _ in },
                                   backgroundLevel: prefs.surroundLinear,
                                   onZoom: { _, _ in }, onPan: { _ in }, onDoubleClick: { _ in },
                                   atFit: true, onStep: nil, allowsMagnifier: false, magnifierTile: nil,
                                   onMagnifier: { _ in }, toolActive: false,
                                   onToolBegan: { _, _ in }, onToolMoved: { _ in }, onToolEnded: {})
                        .accessibilityHidden(true)
                    if let rect = visibleRect(in: geo.size) {
                        Rectangle()
                            .stroke(Color.white, lineWidth: 1.5)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                    // Over the Metal view, which would otherwise take the
                    // clicks: a click or drag moves the view there.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            centre(at: value.location, in: geo.size)
                        })
                } else {
                    Text("No image open").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Navigator")
        .accessibilityValue(model.fitMode ? "The whole image is in view" : "Zoomed to \(model.zoomLabel)")
        .help("Click or drag to move the view (when zoomed in)")
    }

    private func visibleRect(in size: CGSize) -> CGRect? {
        guard !model.fitMode, model.drawableSize.width > 0 else { return nil }
        return NavigatorGeometry.visibleRect(model.viewport.visibleSensorRect(drawableSize: model.drawableSize),
                                             imageSize: model.imageSize, in: size)
    }

    private func centre(at location: CGPoint, in size: CGSize) {
        guard let point = NavigatorGeometry.canvasPoint(at: location, imageSize: model.imageSize, in: size) else { return }
        model.centreView(on: point)
    }
}

/// The Navigator's arithmetic, apart from the view so it can be tested:
/// the picture fitted and centred in the navigator.
enum NavigatorGeometry {
    static func placement(imageSize: CGSize, in size: CGSize) -> (scale: CGFloat, origin: CGPoint)? {
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else { return nil }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        return (scale, CGPoint(x: (size.width - imageSize.width * scale) / 2,
                               y: (size.height - imageSize.height * scale) / 2))
    }

    /// The viewport's visible canvas rectangle, in navigator points,
    /// clipped to the picture.
    static func visibleRect(_ visible: CGRect, imageSize: CGSize, in size: CGSize) -> CGRect? {
        guard let p = placement(imageSize: imageSize, in: size) else { return nil }
        let (scale, origin) = (p.scale, p.origin)
        let clipped = visible.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return CGRect(x: origin.x + clipped.minX * scale, y: origin.y + clipped.minY * scale,
                      width: clipped.width * scale, height: clipped.height * scale)
    }

    /// The canvas point under a navigator point, held to the picture.
    static func canvasPoint(at location: CGPoint, imageSize: CGSize, in size: CGSize) -> CGPoint? {
        guard let p = placement(imageSize: imageSize, in: size) else { return nil }
        let (scale, origin) = (p.scale, p.origin)
        let x = (location.x - origin.x) / scale, y = (location.y - origin.y) / scale
        return CGPoint(x: min(max(x, 0), imageSize.width), y: min(max(y, 0), imageSize.height))
    }
}

/// The Navigator's zoom presets, a row of small buttons under the picture:
/// the status bar's zoom levels that fit the width. They act on `model`
/// alone; in Compare and Survey a linked view carries the change to the
/// other panes, as any zoom there does, so Sync off leaves them alone.
struct NavigatorZoomPresets: View {
    @Bindable var model: EditorModel

    /// The presets shown, a subset of the status bar's menu.
    static let levels: [ZoomLevel] = [.fit, .fill, .percent(50), .percent(100), .percent(200)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.levels) { level in
                Button(level.title) { model.setZoomLevel(level) }
                    .buttonStyle(.borderless)
                    .font(.caption2.monospacedDigit())
                    .fontWeight(Self.isCurrent(level, label: model.zoomLabel) ? .bold : .regular)
                    .frame(maxWidth: .infinity)
                    .help("Zoom to \(level.title)")
            }
        }
        .disabled(!model.hasImage)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom presets")
    }

    /// Whether `level` is what the view shows now, read from the status
    /// bar's label ("Fit" or "100%"). Fill has no label of its own.
    static func isCurrent(_ level: ZoomLevel, label: String) -> Bool {
        switch level {
        case .fit: label == "Fit"
        case .fill: false
        case .percent(let p): label == "\(p)%"
        }
    }
}

/// The Navigator floating over an image in Loupe, Compare and Survey,
/// which have no side panel for it: the same `NavigatorView` and zoom
/// presets in a small card in the image's lower right corner (the upper
/// right is the loupe overlay's controls and Survey's ✕). It follows
/// `NavigatorSettings`, so View › Show Navigator shows or hides it, as its
/// own ✕ hides it. In Compare and Survey the caller puts it on the active
/// pane only, so it always shows the pane the keys act on.
struct FloatingNavigator: View {
    @Bindable var model: EditorModel
    @ObservedObject private var settings = NavigatorSettings.shared

    static let width: CGFloat = 200
    static let thumbnailHeight: CGFloat = 120

    var body: some View {
        if settings.isShown && model.hasImage {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Navigator")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(model.zoomLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        settings.isShown = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Hide Navigator")
                    .help("Hide the Navigator (View › Show Navigator)")
                }
                NavigatorView(model: model, height: Self.thumbnailHeight)
                NavigatorZoomPresets(model: model)
            }
            .padding(8)
            .frame(width: Self.width)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.25), radius: 4)
            .padding(12)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Which of Compare's two panes the Navigator follows: the one last
/// clicked, the Candidate until then.
enum ComparePane: Equatable {
    case select, candidate

    /// The pane's model, the Candidate's while the Select pane has none.
    @MainActor
    func model(select: EditorModel?, candidate: EditorModel) -> EditorModel {
        switch self {
        case .select: select ?? candidate
        case .candidate: candidate
        }
    }
}

/// The zoom-level menu in the status bar: Fit, Fill and fixed
/// percentages, beside the − + Fit 100% buttons. In Compare it zooms both
/// panes, as those buttons do.
struct ZoomLevelMenu: View {
    @Bindable var model: EditorModel
    var mirror: EditorModel?

    var body: some View {
        Menu {
            ForEach(ZoomLevel.menu) { level in
                Button(level.title) {
                    model.setZoomLevel(level)
                    mirror?.setZoomLevel(level)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Zoom level")
        .help("Zoom to Fit, Fill, or a set percentage")
    }
}
