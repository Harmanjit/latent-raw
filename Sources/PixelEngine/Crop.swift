import Foundation
import CoreGraphics
import simd

/// Crop and straighten, stored in normalized *sensor* coordinates like
/// the masks are, so quarter-turn rotations and local adjustments never
/// need to know about it.
///
/// The crop is an axis-aligned rectangle in a frame that is the sensor
/// rotated by `angle` about the crop's centre. Its `centre` is a
/// normalized sensor point; `size` is a fraction of the sensor's width
/// and height (so `size == [1, 1]` at `angle == 0` is the whole sensor).
/// `angle` is degrees; positive turns the picture clockwise on screen,
/// matching the ↻ button.
public struct CropParameters: Equatable, Sendable, Codable {
    public var centre: SIMD2<Float>
    public var size: SIMD2<Float>
    public var angle: Float
    /// Locked width:height of the crop in sensor orientation, or nil for
    /// free. Stored so reopening the image keeps the lock.
    public var aspect: Float?

    public init(centre: SIMD2<Float> = [0.5, 0.5], size: SIMD2<Float> = [1, 1],
                angle: Float = 0, aspect: Float? = nil) {
        self.centre = centre
        self.size = size
        self.angle = angle
        self.aspect = aspect
    }

    /// No crop, no straighten.
    public static let none = CropParameters()

    /// True when applying this changes nothing (the aspect lock alone
    /// doesn't count; it's a tool setting, not a change to the picture).
    public var isIdentity: Bool {
        angle == 0 && size == [1, 1] && centre == [0.5, 0.5]
    }

    var radians: Double { Double(angle) * .pi / 180 }

    /// Size of the crop in sensor pixels.
    public func pixelSize(sensorSize s: CGSize) -> CGSize {
        CGSize(width: Double(size.x) * s.width, height: Double(size.y) * s.height)
    }

    /// Half-extents of the crop's axis-aligned bounding box in sensor
    /// pixels, after rotation by `angle`.
    func boundingHalfExtents(sensorSize s: CGSize) -> (x: Double, y: Double) {
        let p = pixelSize(sensorSize: s)
        let a = abs(cos(radians)), b = abs(sin(radians))
        return (p.width / 2 * a + p.height / 2 * b, p.width / 2 * b + p.height / 2 * a)
    }

    /// Whether the crop lies wholly inside the sensor. A rotated rectangle
    /// fits inside an axis-aligned one exactly when its bounding box does,
    /// because the sensor is convex and axis-aligned.
    public func fitsInside(sensorSize s: CGSize, tolerance: Double = 0.5) -> Bool {
        let e = boundingHalfExtents(sensorSize: s)
        let c = CGPoint(x: Double(centre.x) * s.width, y: Double(centre.y) * s.height)
        return c.x - e.x >= -tolerance && c.x + e.x <= s.width + tolerance
            && c.y - e.y >= -tolerance && c.y + e.y <= s.height + tolerance
    }

    /// The same crop shrunk about its centre until it fits the sensor, so
    /// a straighten never shows grey corners. Keeps the aspect. This is
    /// also how "largest crop for this angle" is computed: constrain the
    /// full frame.
    public func constrained(sensorSize s: CGSize) -> CropParameters {
        var result = self
        // Keep the centre on the sensor first.
        result.centre = simd_clamp(centre, SIMD2(0, 0), SIMD2(1, 1))
        let e = result.boundingHalfExtents(sensorSize: s)
        guard e.x > 0, e.y > 0 else { return result }
        let c = CGPoint(x: Double(result.centre.x) * s.width, y: Double(result.centre.y) * s.height)
        let roomX = min(c.x, s.width - c.x), roomY = min(c.y, s.height - c.y)
        let scale = min(1, roomX / e.x, roomY / e.y)
        if scale < 1 {
            result.size = result.size * Float(scale)
        }
        return result
    }

    /// Ratio of the crop's width to height in sensor pixels.
    public func ratio(sensorSize s: CGSize) -> Float {
        let p = pixelSize(sensorSize: s)
        return p.height > 0 ? Float(p.width / p.height) : 1
    }

    /// The crop resized about its centre to `aspect` (width:height in
    /// sensor pixels), keeping the longer side where possible, then
    /// constrained to the sensor.
    public func withAspect(_ aspect: Float, sensorSize s: CGSize) -> CropParameters {
        guard aspect > 0 else { return self }
        var result = self
        result.aspect = aspect
        let p = pixelSize(sensorSize: s)
        // Keep the current area roughly: fit a rect of the new ratio in it.
        let current = Float(p.width / p.height)
        var w = p.width, h = p.height
        if aspect > current {
            h = p.width / Double(aspect)         // wider than now: shorten
        } else {
            w = p.height * Double(aspect)        // taller than now: narrow
        }
        result.size = SIMD2(Float(w / s.width), Float(h / s.height))
        return result.constrained(sensorSize: s)
    }
}

/// The geometry that places a cropped, straightened, quarter-turned image
/// on a canvas. Every coordinate the user sees ("canvas space") passes
/// through here to reach sensor pixels, and the presenter and exporter
/// both sample the rendered sensor texture through this mapping, so crop
/// and straighten cost no pipeline work at all.
///
/// Canvas space: the crop rectangle's own pixels, turned by `rotation`.
/// `canvasSize` is what the viewport fits to and what an export measures.
public struct CropFrame: Equatable, Sendable {
    public let sensorSize: CGSize
    public let crop: CropParameters
    public let rotation: ImageRotation

    public init(sensorSize: CGSize, crop: CropParameters = .none, rotation: ImageRotation = .none) {
        self.sensorSize = sensorSize
        self.crop = crop
        self.rotation = rotation
    }

    /// The crop in sensor pixels, before quarter turns.
    public var cropSize: CGSize { crop.pixelSize(sensorSize: sensorSize) }
    public var canvasSize: CGSize { rotation.imageSize(forSensorSize: cropSize) }

    private var cropCentre: CGPoint {
        CGPoint(x: Double(crop.centre.x) * sensorSize.width, y: Double(crop.centre.y) * sensorSize.height)
    }

    /// Canvas pixel -> sensor pixel. Undo the quarter turns to get a point
    /// in the crop's own frame, offset from its centre, then rotate that
    /// offset by the straighten angle and add the centre. Positive angle
    /// shows the picture turned clockwise, so the sampling axes turn the
    /// other way.
    public func sensorPoint(fromCanvasPoint p: CGPoint) -> CGPoint {
        let f = rotation.sensorPoint(fromImagePoint: p, sensorSize: cropSize)
        let d = CGPoint(x: f.x - cropSize.width / 2, y: f.y - cropSize.height / 2)
        let a = -crop.radians
        let c = cropCentre
        return CGPoint(x: c.x + cos(a) * d.x - sin(a) * d.y,
                       y: c.y + sin(a) * d.x + cos(a) * d.y)
    }

    /// Sensor pixel -> canvas pixel (the inverse).
    public func canvasPoint(fromSensorPoint s: CGPoint) -> CGPoint {
        let c = cropCentre
        let d = CGPoint(x: s.x - c.x, y: s.y - c.y)
        let a = crop.radians
        let f = CGPoint(x: cropSize.width / 2 + cos(a) * d.x - sin(a) * d.y,
                        y: cropSize.height / 2 + sin(a) * d.x + cos(a) * d.y)
        return rotation.imagePoint(fromSensorPoint: f, sensorSize: cropSize)
    }

    /// Bounding box in sensor space of a canvas rectangle. With a
    /// straighten angle the box is larger than the rectangle; tiles are
    /// requested from it, so they always cover what's on screen.
    public func sensorRect(fromCanvasRect r: CGRect) -> CGRect {
        bounds(of: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            .map(sensorPoint(fromCanvasPoint:)))
    }

    public func canvasRect(fromSensorRect r: CGRect) -> CGRect {
        bounds(of: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            .map(canvasPoint(fromSensorPoint:)))
    }

    private func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// The frame the crop tool works in: the same angle, but a canvas big
    /// enough to show the whole sensor so the user can drag the crop
    /// anywhere on it. The crop itself is then an axis-aligned rectangle
    /// on this canvas (`toolCanvasRect`).
    public var toolFrame: CropFrame {
        let e = CropParameters(centre: [0.5, 0.5], size: [1, 1], angle: crop.angle)
            .boundingHalfExtents(sensorSize: sensorSize)
        let whole = CropParameters(centre: [0.5, 0.5],
                                   size: SIMD2(Float(2 * e.x / sensorSize.width),
                                               Float(2 * e.y / sensorSize.height)),
                                   angle: crop.angle)
        return CropFrame(sensorSize: sensorSize, crop: whole, rotation: rotation)
    }

    /// Where the crop rectangle sits on the tool frame's canvas.
    public var toolCanvasRect: CGRect {
        let tool = toolFrame
        let s = cropSize
        let corners = [CGPoint(x: -s.width / 2, y: -s.height / 2), CGPoint(x: s.width / 2, y: s.height / 2)]
            .map { d -> CGPoint in
                // Offsets in the crop frame -> sensor -> tool canvas.
                let a = -crop.radians
                let c = cropCentre
                let sensor = CGPoint(x: c.x + cos(a) * d.x - sin(a) * d.y,
                                     y: c.y + sin(a) * d.x + cos(a) * d.y)
                return tool.canvasPoint(fromSensorPoint: sensor)
            }
        return bounds(of: corners)
    }

    /// The crop whose rectangle is `rect` on the tool frame's canvas:
    /// the inverse of `toolCanvasRect`. Size comes straight from the
    /// rectangle (un-swapping the quarter turn); the centre goes through
    /// the tool canvas to the sensor.
    public func cropForToolCanvasRect(_ rect: CGRect) -> CropParameters {
        let tool = toolFrame
        let centre = tool.sensorPoint(fromCanvasPoint: CGPoint(x: rect.midX, y: rect.midY))
        var w = rect.width, h = rect.height
        if rotation.swapsAxes { swap(&w, &h) }
        return CropParameters(centre: SIMD2(Float(centre.x / sensorSize.width), Float(centre.y / sensorSize.height)),
                              size: SIMD2(Float(w / sensorSize.width), Float(h / sensorSize.height)),
                              angle: crop.angle, aspect: crop.aspect)
    }

    /// Affine map from normalized destination coordinates (0...1 over the
    /// canvas) to normalized sensor texture coordinates. Exact for any
    /// composition of the rotations and translations above, so sampling
    /// three points and differencing is enough.
    public func normalizedSamplingMap() -> simd_float3x2 {
        let canvas = canvasSize
        func uv(_ p: CGPoint) -> SIMD2<Float> {
            let s = sensorPoint(fromCanvasPoint: CGPoint(x: p.x * canvas.width, y: p.y * canvas.height))
            return SIMD2(Float(s.x / sensorSize.width), Float(s.y / sensorSize.height))
        }
        let origin = uv(.zero)
        let dx = uv(CGPoint(x: 1, y: 0)) - origin
        let dy = uv(CGPoint(x: 0, y: 1)) - origin
        return simd_float3x2(columns: (dx, dy, origin))
    }
}

extension ViewportTransform {
    /// The present kernel's map for a texture covering `coverage` in
    /// sensor space, shown through `frame`. Generalises the rotation-only
    /// version: with no crop the two agree exactly.
    public func screenToTextureMap(coverage: CGRect, frame: CropFrame,
                                   drawableSize: CGSize) -> simd_float3x2 {
        func uv(_ screen: CGPoint) -> SIMD2<Float> {
            let canvas = sensorPoint(forScreenPoint: screen, drawableSize: drawableSize)
            let sensor = frame.sensorPoint(fromCanvasPoint: canvas)
            return SIMD2<Float>(Float((sensor.x - coverage.minX) / coverage.width),
                                Float((sensor.y - coverage.minY) / coverage.height))
        }
        let origin = uv(.zero)
        let dx = uv(CGPoint(x: 1, y: 0)) - origin
        let dy = uv(CGPoint(x: 0, y: 1)) - origin
        return simd_float3x2(columns: (dx, dy, origin))
    }
}
