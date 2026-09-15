import Foundation
import simd

// The panorama's shared contract: where each photo sits on the panorama,
// how panorama pixels map to directions and back, and how big the result
// is. The geometry solver (Phase 8a) produces these values and the GPU
// stitcher (Phase 8b) consumes them; they were built in parallel against
// this file, so change it only with both sides in view.
// docs/PhotoMerge.md section 4 describes the pipeline.
//
// Conventions, used everywhere below and mirrored exactly in the Metal
// kernels:
// - A camera looks down +z, with +x to the right and +y DOWN, like image
//   rows. A pixel (u, v) of a photo, measured in the photo's full-resolution
//   pixels with (0, 0) at the top-left corner of the top-left pixel, sees
//   the ray ((u - cx) / f, (v - cy) / f, 1), where (cx, cy) is the principal
//   point and f the focal length, both in pixels. Photos are lens-corrected
//   first, so this pinhole model holds.
// - The world ("panorama") frame uses the same axes: +z is the panorama's
//   centre direction, +y is down, so the horizon is y = 0.
// - Longitude θ = atan2(x, z) grows to the right; latitude φ = atan2(-y,
//   sqrt(x² + z²)) grows upwards.

/// How directions are flattened onto the panorama.
public enum PanoramaProjection: String, Codable, Sendable, CaseIterable {
    /// Chosen by the solver: Perspective up to about 70° across, else Cylindrical.
    case automatic
    /// Straight lines stay straight; only for narrow panoramas.
    case perspective
    /// Wraps around horizontally like a label on a can; verticals stay vertical.
    case cylindrical
    /// Longitude and latitude both linear; for very tall or 360° panoramas.
    case spherical
}

/// One photo placed on the panorama.
public struct PanoramaCamera: Sendable, Equatable, Codable {
    /// Index into the photos the panorama was made from, in capture order.
    public let frameIndex: Int
    /// Camera-to-world rotation, row-major 3 x 3 (9 values): world = R · camera.
    public let rotation: [Double]
    /// Focal length in the photo's full-resolution pixels.
    public let focalLengthPixels: Double
    /// Principal point in full-resolution pixels (usually the photo's centre).
    public let principalPoint: SIMD2<Double>
    /// The photo's full-resolution size as it is sampled (after orientation).
    public let width: Int
    public let height: Int
    /// Multiply the photo's linear pixels by this so its brightness matches
    /// the panorama's (exposure differences and gain compensation together).
    public let exposureGain: Double

    public init(frameIndex: Int, rotation: [Double], focalLengthPixels: Double, principalPoint: SIMD2<Double>,
                width: Int, height: Int, exposureGain: Double) {
        precondition(rotation.count == 9, "rotation must be a 3 x 3 matrix")
        self.frameIndex = frameIndex; self.rotation = rotation; self.focalLengthPixels = focalLengthPixels
        self.principalPoint = principalPoint; self.width = width; self.height = height
        self.exposureGain = exposureGain
    }

    public var rotationMatrix: simd_double3x3 {
        // simd matrices are column-major; `rotation` is row-major.
        simd_double3x3(rows: [SIMD3(rotation[0], rotation[1], rotation[2]),
                              SIMD3(rotation[3], rotation[4], rotation[5]),
                              SIMD3(rotation[6], rotation[7], rotation[8])])
    }
}

/// The panorama's surface at full resolution (scale 1).
public struct PanoramaCanvas: Sendable, Equatable, Codable {
    /// Never `.automatic`.
    public let projection: PanoramaProjection
    /// Canvas pixels per radian at the canvas centre: for Cylindrical and
    /// Spherical the scale of both axes, for Perspective the focal length of
    /// the virtual camera. Scale 1 matches the source photos' resolution.
    public let pixelsPerRadian: Double
    /// The projected coordinates (in pixels at scale 1) of the canvas's
    /// top-left corner: canvas pixel (0, 0) is projected point `origin`.
    public let origin: SIMD2<Double>
    /// Canvas size in pixels at scale 1, trimmed to the area any photo covers.
    public let width: Int
    public let height: Int

    public init(projection: PanoramaProjection, pixelsPerRadian: Double, origin: SIMD2<Double>,
                width: Int, height: Int) {
        precondition(projection != .automatic, "a canvas has a resolved projection")
        self.projection = projection; self.pixelsPerRadian = pixelsPerRadian; self.origin = origin
        self.width = width; self.height = height
    }
}

/// Everything the stitcher needs to know about the panorama's shape.
public struct PanoramaLayout: Sendable, Equatable, Codable {
    public let cameras: [PanoramaCamera]
    public let canvas: PanoramaCanvas
    /// The largest rectangle inside the covered area, in canvas pixels at
    /// scale 1, for Auto Crop (saved as an undoable crop edit, not cut off).
    public let autoCropRect: CGRect

    public init(cameras: [PanoramaCamera], canvas: PanoramaCanvas, autoCropRect: CGRect) {
        self.cameras = cameras; self.canvas = canvas; self.autoCropRect = autoCropRect
    }
}

/// How big the panorama will be made, after the downsampling rule
/// (docs/PhotoMerge.md section 4): never refused for size; scaled down,
/// with the user's agreement, to the largest size this Mac can edit.
public struct PanoramaOutputSize: Sendable, Equatable, Codable {
    public enum Limit: String, Codable, Sendable {
        /// Full resolution fits.
        case none
        /// The GPU's largest texture side decided the scale.
        case textureSide
        /// The editing memory budget decided the scale.
        case memory
    }

    /// Canvas size at full resolution.
    public let fullWidth: Int
    public let fullHeight: Int
    /// 0 < scale <= 1.
    public let scale: Double
    /// The output: floor(full x scale).
    public let width: Int
    public let height: Int
    public let limit: Limit
    /// Binned demosaic span to decode frames with (1 = full resolution): the
    /// largest k with 1/k >= scale, so frames are never decoded smaller than
    /// the output needs.
    public let decodeSpan: Int

    public init(fullWidth: Int, fullHeight: Int, scale: Double, width: Int, height: Int, limit: Limit, decodeSpan: Int) {
        self.fullWidth = fullWidth; self.fullHeight = fullHeight; self.scale = scale
        self.width = width; self.height = height; self.limit = limit; self.decodeSpan = decodeSpan
    }

    public var needsDownsampling: Bool { scale < 1 }
}

/// The projection maths, shared by the solver (CPU) and mirrored by the
/// stitcher's Metal kernels. All canvas coordinates are pixels at scale 1;
/// multiply by the output scale for the output image.
public enum PanoramaMath {
    /// The world direction (unit vector) a canvas pixel shows, or nil where
    /// the projection has no direction (never for Cylindrical and Spherical).
    public static func direction(canvasPixel p: SIMD2<Double>, canvas: PanoramaCanvas) -> SIMD3<Double>? {
        let s = canvas.pixelsPerRadian
        let projected = p + canvas.origin
        switch canvas.projection {
        case .perspective, .automatic:
            return simd_normalize(SIMD3(projected.x / s, projected.y / s, 1))
        case .cylindrical:
            let theta = projected.x / s
            return simd_normalize(SIMD3(sin(theta), projected.y / s, cos(theta)))
        case .spherical:
            let theta = projected.x / s, phi = -projected.y / s
            return SIMD3(cos(phi) * sin(theta), -sin(phi), cos(phi) * cos(theta))
        }
    }

    /// The canvas pixel showing a world direction, or nil if the projection
    /// can't show it (behind a Perspective canvas).
    public static func canvasPixel(direction d: SIMD3<Double>, canvas: PanoramaCanvas) -> SIMD2<Double>? {
        let s = canvas.pixelsPerRadian
        let projected: SIMD2<Double>
        switch canvas.projection {
        case .perspective, .automatic:
            guard d.z > 1e-9 else { return nil }
            projected = SIMD2(s * d.x / d.z, s * d.y / d.z)
        case .cylindrical:
            let horizontal = (d.x * d.x + d.z * d.z).squareRoot()
            guard horizontal > 1e-9 else { return nil }
            projected = SIMD2(s * atan2(d.x, d.z), s * d.y / horizontal)
        case .spherical:
            let horizontal = (d.x * d.x + d.z * d.z).squareRoot()
            projected = SIMD2(s * atan2(d.x, d.z), -s * atan2(-d.y, horizontal))
        }
        return projected - canvas.origin
    }

    /// The pixel of `camera`'s photo that sees a world direction, or nil if
    /// the direction is behind the camera. The pixel may lie outside the photo.
    public static func framePixel(direction d: SIMD3<Double>, camera: PanoramaCamera) -> SIMD2<Double>? {
        let ray = camera.rotationMatrix.transpose * d
        guard ray.z > 1e-9 else { return nil }
        let f = camera.focalLengthPixels
        return SIMD2(f * ray.x / ray.z, f * ray.y / ray.z) + camera.principalPoint
    }

    /// The world direction a photo pixel sees.
    public static func direction(framePixel p: SIMD2<Double>, camera: PanoramaCamera) -> SIMD3<Double> {
        let f = camera.focalLengthPixels
        let local = (p - camera.principalPoint) / f
        return simd_normalize(camera.rotationMatrix * SIMD3(local.x, local.y, 1))
    }
}
