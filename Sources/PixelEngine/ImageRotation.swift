import Foundation
import CoreGraphics
import simd

/// Whole-image rotation in quarter turns clockwise.
///
/// Two coordinate systems meet here. **Sensor space** is the raw grid as
/// recorded, which the pipeline and its caches always use. **Image space**
/// is what the user sees: the sensor turned by this rotation, so a
/// portrait shot is tall. The viewport transform works in image space;
/// this type converts between the two so the presenter can sample the
/// unrotated textures and tiles can be requested in sensor coordinates.
public enum ImageRotation: Int, Sendable, CaseIterable, Equatable {
    case none = 0
    case cw90 = 1
    case cw180 = 2
    case cw270 = 3

    /// From LibRaw's `flip` (dcraw's convention): 0 upright, 3 = 180°,
    /// 5 = 90° counter-clockwise, 6 = 90° clockwise.
    public init(libRawFlip flip: Int) {
        switch flip {
        case 3: self = .cw180
        case 5: self = .cw270
        case 6: self = .cw90
        default: self = .none
        }
    }

    public func rotated(by quarterTurns: Int) -> ImageRotation {
        ImageRotation(rawValue: (((rawValue + quarterTurns) % 4) + 4) % 4)!
    }

    public var swapsAxes: Bool { rawValue % 2 == 1 }

    public func imageSize(forSensorSize s: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: s.height, height: s.width) : s
    }

    /// Sensor point -> image point.
    public func imagePoint(fromSensorPoint p: CGPoint, sensorSize s: CGSize) -> CGPoint {
        switch self {
        case .none:  return p
        case .cw90:  return CGPoint(x: s.height - p.y, y: p.x)
        case .cw180: return CGPoint(x: s.width - p.x, y: s.height - p.y)
        case .cw270: return CGPoint(x: p.y, y: s.width - p.x)
        }
    }

    /// Image point -> sensor point (the inverse).
    public func sensorPoint(fromImagePoint p: CGPoint, sensorSize s: CGSize) -> CGPoint {
        switch self {
        case .none:  return p
        case .cw90:  return CGPoint(x: p.y, y: s.height - p.x)
        case .cw180: return CGPoint(x: s.width - p.x, y: s.height - p.y)
        case .cw270: return CGPoint(x: s.width - p.y, y: p.x)
        }
    }

    /// Bounding box of an image-space rectangle in sensor space.
    public func sensorRect(fromImageRect r: CGRect, sensorSize s: CGSize) -> CGRect {
        let a = sensorPoint(fromImagePoint: CGPoint(x: r.minX, y: r.minY), sensorSize: s)
        let b = sensorPoint(fromImagePoint: CGPoint(x: r.maxX, y: r.maxY), sensorSize: s)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Bounding box of a sensor-space rectangle in image space.
    public func imageRect(fromSensorRect r: CGRect, sensorSize s: CGSize) -> CGRect {
        let a = imagePoint(fromSensorPoint: CGPoint(x: r.minX, y: r.minY), sensorSize: s)
        let b = imagePoint(fromSensorPoint: CGPoint(x: r.maxX, y: r.maxY), sensorSize: s)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension ViewportTransform {
    /// Builds the affine map from drawable pixels to a texture's normalized
    /// coordinates, for a texture covering `coverage` in sensor space,
    /// shown with `rotation`. Evaluating the composed function at three
    /// points and differencing is exact because every step is affine.
    public func screenToTextureMap(coverage: CGRect,
                                   rotation: ImageRotation,
                                   sensorSize: CGSize,
                                   drawableSize: CGSize) -> simd_float3x2 {
        func uv(_ screen: CGPoint) -> SIMD2<Float> {
            let image = sensorPoint(forScreenPoint: screen, drawableSize: drawableSize)
            let sensor = rotation.sensorPoint(fromImagePoint: image, sensorSize: sensorSize)
            return SIMD2<Float>(Float((sensor.x - coverage.minX) / coverage.width),
                                Float((sensor.y - coverage.minY) / coverage.height))
        }
        let origin = uv(.zero)
        let dx = uv(CGPoint(x: 1, y: 0)) - origin
        let dy = uv(CGPoint(x: 0, y: 1)) - origin
        return simd_float3x2(columns: (dx, dy, origin))
    }
}
