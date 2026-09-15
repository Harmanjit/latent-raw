import Foundation

/// The calibration models from the Lensfun database (DESIGN.md §9.2),
/// in the database's own "hugin" units.
///
/// Radii for distortion and TCA are normalized so that r = 1 is half the
/// image's *short* side; for vignetting, half the *diagonal*. Both are
/// relative to the camera the lens was calibrated on, so a lens measured
/// on a crop body and used on full frame needs its radii scaled by the
/// ratio of crop factors — see `LensCorrection.cropRatio`.
///
/// All models map the *undistorted* radius to the *distorted* one. That's
/// the direction a corrector wants: for each clean output pixel, where
/// in the crooked source do I sample?
public enum DistortionModel: Equatable, Sendable {
    /// r_d = r_u · (a·r_u³ + b·r_u² + c·r_u + 1 − a − b − c)
    case ptlens(a: Float, b: Float, c: Float)
    /// r_d = r_u · (1 − k1 + k1·r_u²)
    case poly3(k1: Float)
    /// r_d = r_u · (1 + k1·r_u² + k2·r_u⁴)
    case poly5(k1: Float, k2: Float)

    /// The radial multiplier r_d / r_u at undistorted radius `ru`.
    public func factor(atUndistortedRadius ru: Float) -> Float {
        switch self {
        case .ptlens(let a, let b, let c):
            return a * ru * ru * ru + b * ru * ru + c * ru + (1 - a - b - c)
        case .poly3(let k1):
            return 1 - k1 + k1 * ru * ru
        case .poly5(let k1, let k2):
            return 1 + k1 * ru * ru + k2 * ru * ru * ru * ru
        }
    }

    /// Packed for the GPU: type, then up to three terms.
    public var packed: (type: Int32, terms: SIMD3<Float>) {
        switch self {
        case .ptlens(let a, let b, let c): return (1, SIMD3(a, b, c))
        case .poly3(let k1):               return (2, SIMD3(k1, 0, 0))
        case .poly5(let k1, let k2):       return (3, SIMD3(k1, k2, 0))
        }
    }
}

/// Transverse chromatic aberration: red and blue radii relative to green.
/// r_d = r_u · (b·r_u² + c·r_u + v). Linear model is the case b = c = 0.
public struct TCAModel: Equatable, Sendable {
    public var red: SIMD3<Float>    // b, c, v
    public var blue: SIMD3<Float>
    public static let identity = TCAModel(red: SIMD3(0, 0, 1), blue: SIMD3(0, 0, 1))
    public init(red: SIMD3<Float>, blue: SIMD3<Float>) { self.red = red; self.blue = blue }
}

/// Vignetting (Lensfun "pa"): C_corrected = C_source / (1 + k1 r² + k2 r⁴ + k3 r⁶),
/// r normalized to half the diagonal.
public struct VignettingModel: Equatable, Sendable {
    public var k1: Float, k2: Float, k3: Float
    public init(k1: Float, k2: Float, k3: Float) { self.k1 = k1; self.k2 = k2; self.k3 = k3 }
}

/// A camera body as the database knows it.
public struct LensfunCamera: Sendable, Equatable {
    public var maker: String
    public var model: String
    /// All spellings the database lists (including language variants).
    public var modelNames: [String]
    public var mount: String
    public var cropFactor: Float
}

/// One lens with all its calibration points.
public struct LensfunLens: Sendable, Equatable {
    public struct DistortionPoint: Sendable, Equatable {
        public var focal: Float
        public var model: DistortionModel
    }
    public struct TCAPoint: Sendable, Equatable {
        public var focal: Float
        public var model: TCAModel
    }
    public struct VignettingPoint: Sendable, Equatable {
        public var focal: Float
        public var aperture: Float
        public var distance: Float
        public var model: VignettingModel
    }

    public var maker: String
    public var model: String
    public var modelNames: [String]
    public var mounts: [String]
    /// Crop factor of the camera the calibration was made on.
    public var cropFactor: Float
    public var aspectRatio: Float
    public var distortion: [DistortionPoint]
    public var tca: [TCAPoint]
    public var vignetting: [VignettingPoint]
    /// What the lens is sold as ("17-55mm f/2.8"): read from the model
    /// names, or from the database's `<focal>`/`<aperture>` elements where
    /// a name doesn't say. See `LensSpec`.
    public var spec = LensSpec()

    /// Nikon's lens ID, when the database encodes it as a trailing number
    /// on the model name ("... 50mm f/1.4G 160"). A Lensfun convention
    /// for lenses that only identify themselves numerically.
    public var trailingNumericID: Int? {
        let parts = model.split(separator: " ")
        guard let last = parts.last, parts.count > 1, let n = Int(last), n >= 0, n < 256 else { return nil }
        return n
    }

    /// Focal range covered by the calibration data.
    public var focalRange: ClosedRange<Float>? {
        let focals = distortion.map(\.focal) + tca.map(\.focal) + vignetting.map(\.focal)
        guard let lo = focals.min(), let hi = focals.max() else { return nil }
        return lo...hi
    }
}
