import Foundation
import CoreGraphics

/// Where the image sits on screen: how large, and which part is centred.
///
/// Two numbers describe every zoom and pan state:
///
/// - `zoom`: drawable (device) pixels per sensor pixel. 1.0 is a true 100%
///   view — one photosite per screen pixel. Fit-to-window is well below 1
///   for a 24 MP image on any display.
/// - `center`: the sensor-space point shown at the centre of the view.
///
/// "Sensor space" is the full `rawWidth x rawHeight` grid. Every rendered
/// texture reports which sensor rectangle it covers, so the same transform
/// places a whole-image binned preview and a full-resolution crop alike.
/// That's what lets the presenter draw *whatever it currently has* at the
/// new zoom instantly, and lets the pipeline catch up afterwards.
///
/// Screen coordinates here are drawable pixels with the origin top-left,
/// matching the Metal texture the present kernel writes into.
public struct ViewportTransform: Equatable, Sendable {
    public var zoom: CGFloat
    public var center: CGPoint

    /// The most anyone reasonably needs. 8x shows individual photosites as
    /// 8-pixel squares; beyond that nothing new is revealed.
    public static let maximumZoom: CGFloat = 8

    public init(zoom: CGFloat, center: CGPoint) {
        self.zoom = zoom
        self.center = center
    }

    // MARK: - Fit

    /// The zoom that shows the whole image as large as the view allows.
    public static func fitZoom(imageSize: CGSize, drawableSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else { return 1 }
        return min(drawableSize.width / imageSize.width,
                   drawableSize.height / imageSize.height)
    }

    /// Whole image, centred.
    public static func fit(imageSize: CGSize, drawableSize: CGSize) -> ViewportTransform {
        ViewportTransform(zoom: fitZoom(imageSize: imageSize, drawableSize: drawableSize),
                          center: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2))
    }

    // MARK: - Mapping between sensor and screen

    /// screen = (sensor - center) * zoom + drawableCentre
    public func screenPoint(forSensorPoint p: CGPoint, drawableSize: CGSize) -> CGPoint {
        CGPoint(x: (p.x - center.x) * zoom + drawableSize.width / 2,
                y: (p.y - center.y) * zoom + drawableSize.height / 2)
    }

    /// The inverse: which sensor point is under a screen pixel.
    public func sensorPoint(forScreenPoint p: CGPoint, drawableSize: CGSize) -> CGPoint {
        CGPoint(x: (p.x - drawableSize.width / 2) / zoom + center.x,
                y: (p.y - drawableSize.height / 2) / zoom + center.y)
    }

    /// Where a sensor rectangle (say, the area a texture covers) lands on
    /// screen. This is exactly what the present kernel needs.
    public func screenRect(forSensorRect r: CGRect, drawableSize: CGSize) -> CGRect {
        let origin = screenPoint(forSensorPoint: r.origin, drawableSize: drawableSize)
        return CGRect(x: origin.x, y: origin.y,
                      width: r.width * zoom, height: r.height * zoom)
    }

    /// The sensor rectangle currently visible in the view. May extend past
    /// the image edges when zoomed out; callers clamp as they need.
    public func visibleSensorRect(drawableSize: CGSize) -> CGRect {
        let topLeft = sensorPoint(forScreenPoint: .zero, drawableSize: drawableSize)
        return CGRect(x: topLeft.x, y: topLeft.y,
                      width: drawableSize.width / zoom,
                      height: drawableSize.height / zoom)
    }

    // MARK: - Gestures

    /// Zooms by `factor`, keeping the sensor point under `screenPoint`
    /// fixed — so pinching on a face keeps the face under your fingers.
    public func zoomed(by factor: CGFloat, about screenPoint: CGPoint,
                       drawableSize: CGSize) -> ViewportTransform {
        let anchor = sensorPoint(forScreenPoint: screenPoint, drawableSize: drawableSize)
        let newZoom = zoom * factor
        // Solve screenPoint == (anchor - newCenter) * newZoom + drawableCentre
        // for newCenter.
        let newCenter = CGPoint(
            x: anchor.x - (screenPoint.x - drawableSize.width / 2) / newZoom,
            y: anchor.y - (screenPoint.y - drawableSize.height / 2) / newZoom)
        return ViewportTransform(zoom: newZoom, center: newCenter)
    }

    /// Moves the content by a screen-pixel delta (content follows the
    /// finger, so the centre moves the opposite way).
    public func panned(byScreenDelta d: CGSize) -> ViewportTransform {
        ViewportTransform(zoom: zoom,
                          center: CGPoint(x: center.x - d.width / zoom,
                                          y: center.y - d.height / zoom))
    }

    /// Keeps the state sensible: zoom between fit and the maximum, and the
    /// image never panned entirely off screen. When the image is smaller
    /// than the view it's simply centred — there's nothing to pan.
    public func clamped(imageSize: CGSize, drawableSize: CGSize) -> ViewportTransform {
        let fit = Self.fitZoom(imageSize: imageSize, drawableSize: drawableSize)
        let z = min(max(zoom, fit), Self.maximumZoom)

        // Visible extent in sensor pixels at this zoom.
        let halfW = drawableSize.width / z / 2
        let halfH = drawableSize.height / z / 2

        func clampAxis(_ value: CGFloat, half: CGFloat, extent: CGFloat) -> CGFloat {
            // Image narrower than the view on this axis: centre it.
            if half >= extent / 2 { return extent / 2 }
            return min(max(value, half), extent - half)
        }
        let c = CGPoint(x: clampAxis(center.x, half: halfW, extent: imageSize.width),
                        y: clampAxis(center.y, half: halfH, extent: imageSize.height))
        return ViewportTransform(zoom: z, center: c)
    }

    /// True when this transform shows the whole image (zoom at or below fit).
    public func isFit(imageSize: CGSize, drawableSize: CGSize) -> Bool {
        zoom <= Self.fitZoom(imageSize: imageSize, drawableSize: drawableSize) + 1e-6
    }
}

/// One pane's zoom and pan in terms another pane can use, for Compare:
/// zoom as a multiple of fitting the image, and the view's centre as a
/// fraction of the image. Two photos with different pixel sizes, crops or
/// rotations then show the same part of the scene at the same size
/// relative to their panes, which replaying gesture deltas cannot do: a
/// screen-pixel pan moves a small image further than a large one.
///
/// "Image" is whatever the pane's `ViewportTransform` works in (the
/// cropped, straightened and rotated canvas in the editor), so a fraction
/// always means a place in the picture as the user sees it.
public struct RelativeView: Equatable, Sendable {
    /// Fitted, and following the pane as it resizes.
    public var isFit: Bool
    /// Zoom divided by the fitted zoom; 1 when fitted.
    public var zoomFactor: CGFloat
    /// The image point at the view's centre, 0...1 on each axis.
    public var center: CGPoint

    public static let fit = RelativeView(isFit: true, zoomFactor: 1, center: CGPoint(x: 0.5, y: 0.5))

    public init(isFit: Bool, zoomFactor: CGFloat, center: CGPoint) {
        self.isFit = isFit
        self.zoomFactor = zoomFactor
        self.center = center
    }

    /// The relative form of `transform`. `isFit` is the pane's own fit
    /// flag rather than a comparison of zooms, so a pane that follows
    /// window resizes keeps doing so in the other pane.
    public init(transform: ViewportTransform, isFit: Bool, imageSize: CGSize, drawableSize: CGSize) {
        guard !isFit, imageSize.width > 0, imageSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else {
            self = .fit
            return
        }
        let fitted = ViewportTransform.fitZoom(imageSize: imageSize, drawableSize: drawableSize)
        self.init(isFit: false, zoomFactor: transform.zoom / fitted,
                  center: CGPoint(x: transform.center.x / imageSize.width,
                                  y: transform.center.y / imageSize.height))
    }

    /// The same view of an image of `imageSize` in a view of `drawableSize`.
    /// Not clamped: the caller clamps as it does for any gesture, so a
    /// centre near one image's edge stops at the other image's edge.
    public func transform(imageSize: CGSize, drawableSize: CGSize) -> ViewportTransform {
        let fitted = ViewportTransform.fit(imageSize: imageSize, drawableSize: drawableSize)
        guard !isFit else { return fitted }
        return ViewportTransform(zoom: fitted.zoom * zoomFactor,
                                 center: CGPoint(x: center.x * imageSize.width,
                                                 y: center.y * imageSize.height))
    }
}
