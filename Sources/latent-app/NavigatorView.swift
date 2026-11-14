import SwiftUI
import PixelEngine

/// The Navigator at the top of Develop's panel, as Lightroom and darktable
/// have it: the whole picture small, with the part the viewport shows
/// outlined. Click or drag in it to move the view there. Collapsed until
/// opened, and remembered either way.
struct NavigatorSection: View {
    @ObservedObject var model: EditorModel
    @AppStorage("latent.navigatorExpanded") private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            NavigatorView(model: model)
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
    @ObservedObject var model: EditorModel
    @ObservedObject private var prefs = AppPreferences.shared
    /// The navigator's drawable, in pixels, for the fit.
    @State private var drawableSize: CGSize = .zero

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
        .frame(height: Self.height)
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

/// The zoom-level menu in the status bar: Fit, Fill and fixed
/// percentages, beside the − + Fit 100% buttons. In Compare it zooms both
/// panes, as those buttons do.
struct ZoomLevelMenu: View {
    @ObservedObject var model: EditorModel
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
