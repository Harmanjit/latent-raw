import SwiftUI
import PixelEngine

/// View › Colour Assessment, darktable's ISO 12646 mode: the image shrunk
/// inside a wide border of 18% grey, with a thin white frame around it as
/// a reference white, so colours are judged against a neutral surround
/// rather than whatever the image happens to sit on. A view only, in
/// SwiftUI around the Metal view: the pipeline and the edit never see it,
/// and the user's own surround (Settings › Appearance) comes back as soon
/// as it is off, since it was never changed.
@MainActor
enum ColourAssessment {
    /// 18% reflectance, the photographic mid-grey: 0.18 linear, about 0.46
    /// in sRGB.
    static let greyLinear: Float = 0.18
    static let greyEncoded: Double = 0.4613

    /// The surround behind the image: the forced grey while assessing,
    /// else the user's.
    static func surroundColor(_ settings: ViewingSettings, _ prefs: AppPreferences) -> Color {
        settings.colourAssessment ? Color(.sRGB, white: greyEncoded, opacity: 1) : prefs.surroundColor
    }

    /// The same, in the drawable's linear encoding, for the Metal view's
    /// own surround inside the image's frame.
    static func surroundLinear(_ settings: ViewingSettings, _ prefs: AppPreferences) -> Float {
        settings.colourAssessment ? greyLinear : prefs.surroundLinear
    }

    /// The border on each side, in points: a share of the shorter side.
    static func inset(share: Double, size: CGSize) -> CGFloat {
        CGFloat(ViewingSettings.clampedInset(share)) * min(size.width, size.height)
    }

    /// Where the image lies in the inset view of `innerSize` points, from
    /// the editor's own zoom and pan; the visible part of it when zoomed in.
    static func imageRect(model: EditorModel, innerSize: CGSize) -> CGRect? {
        guard model.hasImage, model.drawableSize.width > 0, innerSize.width > 0 else { return nil }
        let pixelsPerPoint = model.drawableSize.width / innerSize.width
        let shown = model.viewport.screenRect(forSensorRect: CGRect(origin: .zero, size: model.imageSize),
                                              drawableSize: model.drawableSize)
        let points = CGRect(x: shown.minX / pixelsPerPoint, y: shown.minY / pixelsPerPoint,
                            width: shown.width / pixelsPerPoint, height: shown.height / pixelsPerPoint)
        let visible = points.intersection(CGRect(origin: .zero, size: innerSize))
        return visible.isNull || visible.isEmpty ? nil : visible
    }
}

/// Insets the image view while Colour Assessment is on and draws the
/// white frame around the picture. The view keeps its identity either
/// way (only the padding changes), so turning it on or off never makes a
/// new Metal view.
struct ColourAssessmentInset: ViewModifier {
    @ObservedObject var settings: ViewingSettings
    /// The picture's rectangle within the inset area, given that area's
    /// size in points; nil when there is no picture.
    let imageRect: (CGSize) -> CGRect?

    /// The reference frame's width in points, and its gap from the picture.
    static let frameWidth: CGFloat = 1.5
    static let frameGap: CGFloat = 2

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let on = settings.colourAssessment
            let inset = on ? ColourAssessment.inset(share: settings.assessmentInset, size: geo.size) : 0
            let inner = CGSize(width: max(0, geo.size.width - 2 * inset), height: max(0, geo.size.height - 2 * inset))
            content
                .padding(inset)
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay {
                    if on, let rect = imageRect(inner) {
                        Path { path in
                            path.addRect(rect.offsetBy(dx: inset, dy: inset)
                                .insetBy(dx: -(Self.frameGap + Self.frameWidth / 2), dy: -(Self.frameGap + Self.frameWidth / 2)))
                        }
                        .stroke(Color.white, lineWidth: Self.frameWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
        }
    }
}
