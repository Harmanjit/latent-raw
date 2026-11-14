import Foundation
import simd

// The geometry of gradients and radials for editing them on the image:
// the rotated ellipse (its weight, as the colour kernel computes it, and
// its outline), where each shape's handles sit, and what dragging one
// does. Points are normalised sensor coordinates; `sensorSize` is in
// pixels, so circles are round whatever the aspect ratio.

/// A handle on a placed gradient or radial (MaskShapeOverlay draws them).
public enum MaskShapeHandle: String, CaseIterable, Sendable {
    /// Linear gradient: where the effect is full, where it ends, and the
    /// middle, which moves both.
    case linearStart, linearEnd, linearMiddle
    /// Radial: the centre (moves it), the edge on each of its axes, the
    /// inner ring where the feather begins, and the rotate handle above it.
    case radialCentre, radialEdgeX, radialEdgeY, radialFeather, radialRotate
}

extension MaskShape {
    /// A radial's turn in degrees; 0 for anything else.
    public var radialAngle: Float {
        if case .radial(_, _, _, let angle) = self { return angle ?? 0 }
        return 0
    }

    /// The same radial turned to `degrees` (wrapped to −180…180), stored
    /// as nil at 0 so an unturned ellipse is written as it always was.
    public func withRadialAngle(_ degrees: Float) -> MaskShape {
        guard case .radial(let c, let r, let f, _) = self else { return self }
        var a = fmodf(degrees, 360)
        if a > 180 { a -= 360 } else if a <= -180 { a += 360 }
        return .radial(centre: c, radii: r, feather: f, angle: abs(a) < 1e-4 ? nil : a)
    }

    /// The radial with another feather (0…1), keeping its turn.
    public func withRadialFeather(_ feather: Float) -> MaskShape {
        guard case .radial(let c, let r, _, let a) = self else { return self }
        return .radial(centre: c, radii: r, feather: min(max(feather, 0), 1), angle: a)
    }

    /// The radial's weight at a point, as `shapeMask` case 2 computes it;
    /// nil for any other shape.
    public func radialWeight(at p: SIMD2<Float>, sensorSize: SIMD2<Float>) -> Float? {
        guard case .radial(let centre, let radii, let feather, _) = self else { return nil }
        let e = Self.ellipseNorm(p, centre: centre, radii: radii, angle: radialAngle, sensorSize: sensorSize)
        let inner = 1 - min(max(feather, 0), 0.999)
        return 1 - MaskRangeMath.smoothstep(inner, 1, e)
    }

    /// How far a point is out from the centre in the ellipse's own units:
    /// 1 on its outline.
    static func ellipseNorm(_ p: SIMD2<Float>, centre: SIMD2<Float>, radii: SIMD2<Float>, angle: Float,
                            sensorSize: SIMD2<Float>) -> Float {
        let short = min(sensorSize.x, sensorSize.y)
        let r = simd_max(radii * short, SIMD2(repeating: 1))
        let d = rotate((p - centre) * sensorSize, by: -angle)
        return simd_length(d / r)
    }

    /// A point on a radial's outline (fraction 1) or a ring inside it, at
    /// parameter `t` (radians, 0 on its x axis, π/2 on its y axis).
    public static func radialPoint(centre: SIMD2<Float>, radii: SIMD2<Float>, angle: Float, t: Float,
                                   fraction: Float = 1, sensorSize: SIMD2<Float>) -> SIMD2<Float> {
        let short = min(sensorSize.x, sensorSize.y)
        let local = SIMD2(cos(t) * radii.x, sin(t) * radii.y) * short * fraction
        return centre + rotate(local, by: angle) / simd_max(sensorSize, SIMD2(repeating: 1))
    }

    /// Turns a pixel offset by `degrees`, clockwise with y down.
    static func rotate(_ v: SIMD2<Float>, by degrees: Float) -> SIMD2<Float> {
        guard degrees != 0 else { return v }
        let a = degrees * .pi / 180
        let cs = cos(a), sn = sin(a)
        return SIMD2(v.x * cs - v.y * sn, v.x * sn + v.y * cs)
    }

    /// Where each handle of a gradient or radial sits; empty for other shapes.
    public func handlePositions(sensorSize: SIMD2<Float>) -> [(handle: MaskShapeHandle, point: SIMD2<Float>)] {
        switch self {
        case .linear(let s, let e):
            return [(.linearStart, s), (.linearEnd, e), (.linearMiddle, (s + e) / 2)]
        case .radial(let c, let r, let feather, _):
            let a = radialAngle
            let inner = 1 - min(max(feather, 0), 0.999)
            func at(_ t: Float, _ fraction: Float) -> SIMD2<Float> {
                Self.radialPoint(centre: c, radii: r, angle: a, t: t, fraction: fraction, sensorSize: sensorSize)
            }
            return [(.radialCentre, c), (.radialEdgeX, at(0, 1)), (.radialEdgeY, at(.pi / 2, 1)),
                    (.radialFeather, at(.pi, inner)), (.radialRotate, at(-.pi / 2, 1.3))]
        default:
            return []
        }
    }

    /// The shape after dragging `handle` from `pressed` (where the drag
    /// began) to `p`; `self` is the shape as it was at the press.
    public func dragging(_ handle: MaskShapeHandle, from pressed: SIMD2<Float>, to p: SIMD2<Float>,
                         sensorSize: SIMD2<Float>) -> MaskShape {
        let short = max(min(sensorSize.x, sensorSize.y), 1)
        switch (self, handle) {
        case (.linear(_, let e), .linearStart):
            return .linear(start: p, end: e)
        case (.linear(let s, _), .linearEnd):
            return .linear(start: s, end: p)
        case (.linear(let s, let e), .linearMiddle):
            return .linear(start: s + (p - pressed), end: e + (p - pressed))
        case (.radial(let c, let r, let f, let a), .radialCentre):
            return .radial(centre: c + (p - pressed), radii: r, feather: f, angle: a)
        case (.radial(let c, let r, let f, let a), .radialEdgeX), (.radial(let c, let r, let f, let a), .radialEdgeY):
            // The pointer's distance along the axis, in the ellipse's frame.
            let d = Self.rotate((p - c) * sensorSize, by: -(a ?? 0))
            if handle == .radialEdgeX {
                return .radial(centre: c, radii: SIMD2(max(abs(d.x) / short, 0.005), r.y), feather: f, angle: a)
            }
            return .radial(centre: c, radii: SIMD2(r.x, max(abs(d.y) / short, 0.005)), feather: f, angle: a)
        case (.radial(let c, let r, _, _), .radialFeather):
            let e = Self.ellipseNorm(p, centre: c, radii: r, angle: radialAngle, sensorSize: sensorSize)
            return withRadialFeather(1 - min(e, 1))
        case (.radial(let c, _, _, _), .radialRotate):
            // The handle sits on the ellipse's −y axis, a quarter turn
            // anticlockwise of its x axis.
            let d = (p - c) * sensorSize
            guard simd_length(d) > 1 else { return self }
            return withRadialAngle(atan2(d.y, d.x) * 180 / .pi + 90)
        default:
            return self
        }
    }

    /// What the scroll wheel does over a selected shape: a radial's
    /// feather moves by `step` (0…1); a gradient's fade, the distance from
    /// start to end, grows or shrinks by that fraction about its middle.
    public func scrollingFeather(by step: Float) -> MaskShape {
        switch self {
        case .radial(_, _, let f, _):
            return withRadialFeather(f + step)
        case .linear(let s, let e):
            let mid = (s + e) / 2
            let scale = max(1 + step * 2, 0.05)
            let half = (e - s) / 2 * scale
            guard simd_length(half) > 1e-4 else { return self }
            return .linear(start: mid - half, end: mid + half)
        default:
            return self
        }
    }

    /// Whether a point is over the shape, for the scroll wheel: inside a
    /// radial's outline, or within a gradient's band (a little either side
    /// of its start and end lines).
    public func contains(_ p: SIMD2<Float>, sensorSize: SIMD2<Float>) -> Bool {
        switch self {
        case .radial(let c, let r, _, _):
            return Self.ellipseNorm(p, centre: c, radii: r, angle: radialAngle, sensorSize: sensorSize) <= 1
        case .linear(let s, let e):
            let a = s * sensorSize, d = (e - s) * sensorSize
            let len2 = simd_dot(d, d)
            guard len2 > 1e-6 else { return false }
            let t = simd_dot(p * sensorSize - a, d) / len2
            return t >= -0.25 && t <= 1.25
        default:
            return false
        }
    }
}
