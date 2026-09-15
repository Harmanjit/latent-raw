import Foundation
import simd

// The geometry frame alignment shares: 3 x 3 homographies and the pixel
// convention they are written in.

/// Helpers for homographies: 3 x 3 matrices that map points in one flat
/// image to another.
///
/// **What a homography covers.** Shift, rotation, scale, shear and
/// perspective: everything a camera turning about its lens produces
/// between two photos of the same scene. A handheld bracket moves the
/// camera a little between frames; a homography describes that exactly as
/// long as the subject is far enough away that the lens's own movement
/// (parallax) doesn't show.
///
/// **Coordinates.** Full-resolution pixel coordinates with a top-left
/// origin: (0, 0) is the image's top-left corner, x grows right, y grows
/// down, and the centre of pixel (i, j) is at (i + 0.5, j + 0.5). A
/// homography `h` maps a point p = (x, y) by multiplying the column vector
/// (x, y, 1) and dividing by the third component, so `h` and `2 * h` are
/// the same map.
///
/// simd matrices are indexed column first (`h[column][row]`); `rows:`
/// builds one the way it is written on paper.
public enum Homography {
    public static let identity = matrix_identity_double3x3

    public static func translation(_ dx: Double, _ dy: Double) -> simd_double3x3 {
        simd_double3x3(rows: [SIMD3(1, 0, dx), SIMD3(0, 1, dy), SIMD3(0, 0, 1)])
    }

    public static func scale(_ sx: Double, _ sy: Double) -> simd_double3x3 {
        simd_double3x3(rows: [SIMD3(sx, 0, 0), SIMD3(0, sy, 0), SIMD3(0, 0, 1)])
    }

    /// A rotation by `degrees` (clockwise on screen, since y grows down)
    /// and a uniform `scale`, both about `centre`.
    public static func rotation(degrees: Double, scale: Double = 1, about centre: SIMD2<Double>) -> simd_double3x3 {
        let a = degrees * .pi / 180
        let r = simd_double3x3(rows: [SIMD3(scale * cos(a), -scale * sin(a), 0),
                                      SIMD3(scale * sin(a), scale * cos(a), 0),
                                      SIMD3(0, 0, 1)])
        return translation(centre.x, centre.y) * r * translation(-centre.x, -centre.y)
    }

    /// The map between two photos taken by a camera that turned about its
    /// lens: K R K⁻¹, where K is the camera's focal length (in pixels) and
    /// principal point, and R rotates by `yaw` (about the vertical axis),
    /// `pitch` (about the horizontal axis) and `roll` (about the lens axis),
    /// all in degrees. Nearly a shift for small angles, with the slight
    /// keystone a real turn gives.
    public static func cameraRotation(yaw: Double, pitch: Double, roll: Double, focalLength: Double,
                                      principalPoint: SIMD2<Double>) -> simd_double3x3 {
        let d = Double.pi / 180
        let (y, p, r) = (yaw * d, pitch * d, roll * d)
        let rotX = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(p), -sin(p)), SIMD3(0, sin(p), cos(p))])
        let rotY = simd_double3x3(rows: [SIMD3(cos(y), 0, sin(y)), SIMD3(0, 1, 0), SIMD3(-sin(y), 0, cos(y))])
        let rotZ = simd_double3x3(rows: [SIMD3(cos(r), -sin(r), 0), SIMD3(sin(r), cos(r), 0), SIMD3(0, 0, 1)])
        let k = simd_double3x3(rows: [SIMD3(focalLength, 0, principalPoint.x),
                                      SIMD3(0, focalLength, principalPoint.y), SIMD3(0, 0, 1)])
        return normalised(k * rotZ * rotX * rotY * k.inverse)
    }

    /// Where `h` sends `point`.
    @inline(__always)
    public static func apply(_ h: simd_double3x3, _ point: SIMD2<Double>) -> SIMD2<Double> {
        let v = h * SIMD3(point.x, point.y, 1)
        return SIMD2(v.x / v.z, v.y / v.z)
    }

    /// `h` scaled so its bottom-right entry is 1 (the same map).
    public static func normalised(_ h: simd_double3x3) -> simd_double3x3 {
        let s = h[2][2]
        return s != 0 && s.isFinite ? h * (1 / s) : h
    }

    /// Whether `h` is exactly the identity map (the same test
    /// `MergeWarpKernels.isIdentity` uses to skip resampling).
    public static func isIdentity(_ h: simd_double3x3) -> Bool {
        normalised(h) == identity
    }

    /// Whether every entry is a finite number and the map can be inverted.
    public static func isUsable(_ h: simd_double3x3) -> Bool {
        let entries = [h[0], h[1], h[2]].flatMap { [$0.x, $0.y, $0.z] }
        guard entries.allSatisfy(\.isFinite) else { return false }
        let det = h.determinant
        return det.isFinite && abs(det) > 1e-12
    }

    /// The four corners of a `width x height` image.
    static func corners(width: Double, height: Double) -> [SIMD2<Double>] {
        [SIMD2(0, 0), SIMD2(width, 0), SIMD2(0, height), SIMD2(width, height)]
    }

    /// How far `h` moves the corners of a `width x height` image, at most:
    /// the frame's largest displacement, in pixels.
    public static func maxCornerShift(_ h: simd_double3x3, width: Int, height: Int) -> Double {
        corners(width: Double(width), height: Double(height)).map { simd_distance(apply(h, $0), $0) }.max() ?? 0
    }

    /// How far apart `a` and `b` put the corners of a `width x height`
    /// image, at most: the usual way to compare an estimated homography
    /// with the true one.
    public static func maxCornerDistance(_ a: simd_double3x3, _ b: simd_double3x3, width: Int, height: Int) -> Double {
        corners(width: Double(width), height: Double(height)).map { simd_distance(apply(a, $0), apply(b, $0)) }.max() ?? 0
    }

    /// How much `h` enlarges (or shrinks) areas around `point`, as a
    /// fraction of length: 0.02 means 2% bigger. The square root of the
    /// local Jacobian's determinant, minus 1.
    public static func scaleChange(_ h: simd_double3x3, at point: SIMD2<Double>) -> Double {
        let e = 1.0
        let p0 = apply(h, point), px = apply(h, point + SIMD2(e, 0)), py = apply(h, point + SIMD2(0, e))
        let dx = px - p0, dy = py - p0
        return abs(dx.x * dy.y - dx.y * dy.x).squareRoot() - 1
    }

    /// The rotation `h` gives around `point`, in degrees (clockwise on
    /// screen): the angle a short horizontal segment there turns through.
    public static func rotationDegrees(_ h: simd_double3x3, at point: SIMD2<Double>) -> Double {
        let d = apply(h, point + SIMD2(1, 0)) - apply(h, point)
        return atan2(d.y, d.x) * 180 / .pi
    }
}
