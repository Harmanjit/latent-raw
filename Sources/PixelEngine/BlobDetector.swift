import Foundation
import simd

/// The classical blob detector shared by sensor dust and blemishes
/// (docs/Retouch.md contract C): dark (or reddish) round dips in a
/// Float32 map, found as difference-of-Gaussian peaks and checked for
/// size, roundness, contrast against the local noise and a smooth
/// surround. Swift and Accelerate only, so PixelEngineTests can drive it
/// on synthetic scenes without a GPU.
///
/// Wave 0: the contract with stub bodies. Wave 1 (dust-core) fills them
/// in; until then `detect` finds nothing and the maps come back flat.
public enum BlobDetector {
    public enum Polarity: Sendable, Equatable {
        /// A dip in luminance: dust shadows, dark blemishes.
        case dark
        /// A rise in a*: a red blemish on skin.
        case reddish
    }

    public struct Parameters: Sendable, Equatable {
        /// Pixels of the map.
        public var radiusRange: ClosedRange<Float>
        public var polarity: Polarity
        /// A peak counts when it is at least this many local noise sigmas.
        public var contrastSigma: Float
        /// A floor under the noise test, in map units (log2 stops, or a*).
        public var minimumContrast: Float
        /// 4πA/P², 0…1.
        public var minimumCircularity: Float
        /// The annulus residual's standard deviation may be at most this
        /// many local noise sigmas; nil doesn't require it.
        public var smoothSurround: Float?
        /// Mean |∇(G_2r∗D)| over the annulus, map units per pixel.
        public var maximumSurroundGradient: Float?
        public var maximumCount: Int

        public init(radiusRange: ClosedRange<Float>, polarity: Polarity, contrastSigma: Float, minimumContrast: Float,
                    minimumCircularity: Float, smoothSurround: Float?, maximumSurroundGradient: Float?, maximumCount: Int) {
            self.radiusRange = radiusRange
            self.polarity = polarity
            self.contrastSigma = contrastSigma
            self.minimumContrast = minimumContrast
            self.minimumCircularity = minimumCircularity
            self.smoothSurround = smoothSurround
            self.maximumSurroundGradient = maximumSurroundGradient
            self.maximumCount = maximumCount
        }
    }

    public struct Blob: Sendable, Equatable {
        /// Map pixels, pixel centres.
        public var centre: SIMD2<Float>
        /// Map pixels (r_eq = √(A/π)).
        public var radius: Float
        /// Map units.
        public var contrast: Float
        public var score: Float

        public init(centre: SIMD2<Float>, radius: Float, contrast: Float, score: Float) {
            self.centre = centre
            self.radius = radius
            self.contrast = contrast
            self.score = score
        }
    }

    public struct Map: Sendable {
        /// Row-major, width × height.
        public var values: [Float]
        public var width: Int
        public var height: Int
        /// Optional per-pixel weight 0…1 (a skin mask): a blob whose centre
        /// weight is under 0.5 is rejected, and the score is multiplied by it.
        public var weight: [Float]?

        public init(values: [Float], width: Int, height: Int, weight: [Float]? = nil) {
            self.values = values
            self.width = width
            self.height = height
            self.weight = weight
        }
    }

    /// Best first, capped at `p.maximumCount`.
    public static func detect(_ map: Map, _ p: Parameters) -> [Blob] {
        // Wave 1 (dust-core) writes the detector; nothing is found until then.
        []
    }

    /// 1.4826 × MAD of (D − G₁∗D) per `tile`² tile, bilinearly interpolated
    /// back to the map's size.
    public static func localNoise(_ map: Map, tile: Int = 64) -> [Float] {
        // Wave 1 (dust-core) writes the estimator; a flat zero map until then.
        [Float](repeating: 0, count: map.width * map.height)
    }

    /// G_{3σ}∗D − G_σ∗D through a pyramid (σ ≤ 4 px per level), upsampled
    /// to the map's size.
    public static func differenceOfGaussians(_ map: Map, sigma: Float) -> [Float] {
        // Wave 1 (dust-core) writes the pyramid; a flat zero map until then.
        [Float](repeating: 0, count: map.width * map.height)
    }
}
