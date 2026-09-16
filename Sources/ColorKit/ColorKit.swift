import Foundation
import simd

/// Colour management for Latent (DESIGN.md §8.1, stages 1, 9 and 15).
///
/// Everything here runs on the CPU, once per image or per parameter change,
/// and produces small matrices and vectors the GPU kernels apply per pixel.
/// Doing this algebra per pixel would be pure waste — it's identical for
/// every pixel in the frame.
///
/// The working and output spaces are built from their published
/// primaries, which is exact and dependency-free.
/// ICC profiles (soft proofing, `PixelEngine/SoftProof.swift`) go through
/// ColorSync; LittleCMS was not adopted (DESIGN.md §3).
public enum ColorKit {

    // MARK: - Colour space primaries

    /// Linear Rec.2020 RGB -> CIE XYZ (D65). Rows are X, Y, Z.
    ///
    /// Rec.2020 is Latent's working space: wide enough to hold essentially
    /// any camera's gamut without clipping, which matters because clipping
    /// in the working space is unrecoverable later in the pipeline.
    public static let rec2020ToXYZ = matrix(rows: [
        [0.6369580, 0.1446169, 0.1688810],
        [0.2627002, 0.6779981, 0.0593017],
        [0.0000000, 0.0280727, 1.0609851],
    ])

    /// Linear sRGB / Rec.709 RGB -> CIE XYZ (D65). Rows are X, Y, Z.
    public static let sRGBToXYZ = matrix(rows: [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ])

    /// Linear Display P3 RGB -> CIE XYZ (D65). Rows are X, Y, Z.
    public static let displayP3ToXYZ = matrix(rows: [
        [0.4865709, 0.2656677, 0.1982173],
        [0.2289746, 0.6917385, 0.0792869],
        [0.0000000, 0.0451134, 1.0439444],
    ])

    /// Which space rendered output is encoded into.
    public enum OutputSpace: Sendable {
        case sRGB
        case displayP3
        /// The working space itself — for analysis renders that want the
        /// pipeline's own linear values, untransformed.
        case rec2020

        var toXYZ: simd_float3x3 {
            switch self {
            case .sRGB:      return ColorKit.sRGBToXYZ
            case .displayP3: return ColorKit.displayP3ToXYZ
            case .rec2020:   return ColorKit.rec2020ToXYZ
            }
        }
    }

    /// Working space -> output space, for the final display transform.
    public static func workingToOutput(_ space: OutputSpace) -> simd_float3x3 {
        space.toXYZ.inverse * rec2020ToXYZ
    }

    // MARK: - White balance

    /// A white balance setting, expressed the way photographers think about
    /// it rather than as raw channel multipliers.
    ///
    /// `temperature` is the colour temperature in Kelvin of the illuminant
    /// being declared neutral — lower is warmer light (tungsten ~3200K),
    /// higher is cooler (shade ~7500K). Counter-intuitively, *lowering* the
    /// temperature makes the rendered image look cooler, because you're
    /// telling the renderer the light was warmer than it assumed.
    ///
    /// `tint` shifts perpendicular to the temperature axis, correcting the
    /// green-magenta cast that fluorescent and mixed lighting produce.
    /// Negative is greener, positive is more magenta. Units are Latent's
    /// own and are not numerically comparable to Lightroom's tint scale.
    public struct WhiteBalance: Sendable, Equatable {
        public var temperature: Float
        public var tint: Float

        public init(temperature: Float = 5500, tint: Float = 0) {
            self.temperature = temperature
            self.tint = tint
        }

        /// Sentinel meaning "use the camera's as-shot multipliers untouched",
        /// which avoids a round trip through the temperature conversion and
        /// its approximation error.
        public static let asShot = WhiteBalance(temperature: 0, tint: 0)
        public var isAsShot: Bool { temperature <= 0 }

        public static let temperatureRange: ClosedRange<Float> = 2000...12000
        public static let tintRange: ClosedRange<Float> = -100...100
    }

    // MARK: - Mired scaling for the temperature control

    /// Colour temperature's perceptual effect scales with the *reciprocal*
    /// of Kelvin, not with Kelvin. The standard unit is the mired
    /// (micro-reciprocal degree): 1,000,000 / K.
    ///
    /// Why this matters for a slider: 2000K is 500 mired, 5500K is 182, and
    /// 12000K is 83. A slider linear in Kelvin spends three quarters of its
    /// travel where almost nothing visible happens, and crams the dramatic
    /// end into the first sliver.
    ///
    /// The slider value is *negated* mired so that dragging right still
    /// raises the Kelvin reading, matching every other editor.
    public static func sliderValue(forTemperature temperature: Float) -> Float {
        -1_000_000 / max(temperature, 1)
    }

    public static func temperature(forSliderValue value: Float) -> Float {
        -1_000_000 / min(value, -1)
    }

    /// Hard limits on the slider, in mired. 20 mired is 50000K (deep shade
    /// pushed to an extreme), 500 is 2000K (candlelight).
    private static let miredLimits: ClosedRange<Float> = 20...500

    /// How far the slider reaches either side of as-shot, in mired, when
    /// nothing is clamping it.
    private static let preferredMiredSpan: Float = 150

    /// The slider's range for a given image, centred on its as-shot value.
    ///
    /// A fixed Kelvin range can't work here: where as-shot falls inside it
    /// depends entirely on the photo. A 5500K daylight shot sits at 76% of a
    /// 2000-12000K slider, so one direction has three times the travel of
    /// the other and the two ends feel wildly unequal. A tungsten shot has
    /// the opposite problem.
    ///
    /// Centring on as-shot fixes both: the starting point is always the
    /// middle, and equal drags either way shift by equal mireds, which is
    /// equal perceptual change. Near the limits the span shrinks
    /// symmetrically rather than clamping one side, so the centring holds.
    ///
    /// Trade-off: the reachable range now depends on the photo. A daylight
    /// shot won't reach 2000K. That's a deliberate choice — for a daylight
    /// photo 2000K isn't a correction, it's an effect, and a numeric entry
    /// field is the right way to reach it rather than distorting the slider
    /// for every normal edit.
    public static func temperatureSliderRange(
        asShotTemperature: Float
    ) -> ClosedRange<Float> {
        let centreMired = min(max(1_000_000 / max(asShotTemperature, 1),
                                    miredLimits.lowerBound), miredLimits.upperBound)
        let span = max(50, min(preferredMiredSpan,
                                min(centreMired - miredLimits.lowerBound,
                                     miredLimits.upperBound - centreMired)))
        // Negated, so lower slider value = higher Kelvin = further right.
        return (-(centreMired + span))...(-(centreMired - span))
    }

    /// Chromaticity (x, y) of a blackbody radiator at `temperature` Kelvin.
    ///
    /// Kang et al. (2002) cubic approximation of the Planckian locus, the
    /// standard closed-form fit. Valid from 1667K to 25000K; inputs outside
    /// that are clamped.
    public static func planckianChromaticity(temperature: Float) -> SIMD2<Float> {
        let t = min(max(temperature, 1667), 25000)
        let invT = 1000.0 / t          // scaled to keep the cubics well-conditioned
        let invT2 = invT * invT
        let invT3 = invT2 * invT

        let x: Float
        if t < 4000 {
            x = -0.2661239 * invT3 - 0.2343589 * invT2 + 0.8776956 * invT + 0.179910
        } else {
            x = -3.0258469 * invT3 + 2.1070379 * invT2 + 0.2226347 * invT + 0.240390
        }

        let x2 = x * x, x3 = x2 * x
        let y: Float
        if t < 2222 {
            y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        } else if t < 4000 {
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }

        return SIMD2<Float>(x, y)
    }

    /// CIE 1931 xy -> CIE 1960 uv. Tint is applied in uv space because
    /// that's where a perpendicular offset from the Planckian locus
    /// corresponds to a perceptually sensible green-magenta shift.
    public static func uvFromXY(_ xy: SIMD2<Float>) -> SIMD2<Float> {
        let denominator = -2 * xy.x + 12 * xy.y + 3
        guard abs(denominator) > 1e-9 else { return SIMD2<Float>(0, 0) }
        return SIMD2<Float>(4 * xy.x / denominator, 6 * xy.y / denominator)
    }

    /// CIE 1960 uv -> CIE 1931 xy.
    public static func xyFromUV(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        let denominator = 2 * uv.x - 8 * uv.y + 4
        guard abs(denominator) > 1e-9 else { return SIMD2<Float>(0.3127, 0.3290) }
        return SIMD2<Float>(3 * uv.x / denominator, 2 * uv.y / denominator)
    }

    /// Scales Latent's tint units into uv-space offsets. Chosen so the
    /// ±100 slider range covers roughly the useful correction range for
    /// fluorescent and mixed lighting.
    private static let tintToUV: Float = 0.0008

    /// Unit vector perpendicular to the Planckian locus at `temperature`,
    /// in uv space. Found by finite difference along the locus, then
    /// rotated 90°.
    private static func locusPerpendicular(temperature: Float) -> SIMD2<Float> {
        let delta = max(temperature * 0.01, 10)
        let before = uvFromXY(planckianChromaticity(temperature: temperature - delta))
        let after = uvFromXY(planckianChromaticity(temperature: temperature + delta))
        let tangent = after - before
        let length = simd_length(tangent)
        guard length > 1e-9 else { return SIMD2<Float>(0, 1) }
        let unit = tangent / length
        return SIMD2<Float>(-unit.y, unit.x)
    }

    /// Chromaticity of the illuminant described by a temperature and tint.
    public static func chromaticity(_ wb: WhiteBalance) -> SIMD2<Float> {
        let locusUV = uvFromXY(planckianChromaticity(temperature: wb.temperature))
        let offsetUV = locusUV + locusPerpendicular(temperature: wb.temperature)
            * (wb.tint * tintToUV)
        return xyFromUV(offsetUV)
    }

    /// XYZ of a chromaticity, normalized to Y = 1.
    public static func xyzFromChromaticity(_ xy: SIMD2<Float>) -> SIMD3<Float> {
        guard xy.y > 1e-6 else { return SIMD3<Float>(0.9505, 1.0, 1.0890) }
        return SIMD3<Float>(xy.x / xy.y, 1.0, (1 - xy.x - xy.y) / xy.y)
    }

    /// Chromaticity of an XYZ colour.
    public static func chromaticityFromXYZ(_ xyz: SIMD3<Float>) -> SIMD2<Float> {
        let sum = xyz.x + xyz.y + xyz.z
        guard abs(sum) > 1e-9 else { return SIMD2<Float>(0.3127, 0.3290) }
        return SIMD2<Float>(xyz.x / sum, xyz.y / sum)
    }

    /// Normalizes LibRaw's as-shot white balance multipliers against green.
    ///
    /// Cameras report multipliers in arbitrary scale. Dividing through by
    /// green keeps overall image brightness stable across cameras, so the
    /// exposure slider means the same thing everywhere.
    public static func normalizedWhiteBalance(
        _ multipliers: (Float, Float, Float, Float)
    ) -> SIMD4<Float> {
        let green = multipliers.1
        guard green > 0 else { return SIMD4<Float>(1, 1, 1, 1) }
        return SIMD4<Float>(multipliers.0 / green, 1.0,
                             multipliers.2 / green, multipliers.3 / green)
    }

    // MARK: - Camera profile

    /// A camera's colour characterization, plus the conversions that depend
    /// on it.
    ///
    /// Built once per image. Everything here needs the camera matrix, which
    /// is why temperature/tint conversion lives on this type rather than as
    /// free functions — the same temperature produces different multipliers
    /// on different cameras.
    public struct CameraColorProfile: Sendable {
        /// CIE XYZ -> camera native RGB (Adobe ColorMatrix convention).
        public let xyzToCamera: simd_float3x3
        /// Camera native RGB -> linear Rec.2020 working space.
        public let cameraToWorking: simd_float3x3

        /// Builds the profile from LibRaw's row-major 3x3 characterization.
        ///
        /// Three steps, following dcraw's `cam_xyz_coeff`:
        ///
        /// 1. Compose XYZ->camera with Rec.2020->XYZ, giving Rec.2020->camera.
        /// 2. **Normalize each row to sum to 1.** Easy to skip and impossible
        ///    to miss the absence of: without it, neutral camera values don't
        ///    map to neutral output and the whole image carries a cast.
        /// 3. Invert, giving camera->Rec.2020.
        ///
        /// Returns nil if the matrix is singular (a malformed profile).
        ///
        /// Known approximation: LibRaw's cam_xyz follows Adobe's ColorMatrix
        /// convention, defined against a D50 white point, while the space
        /// primaries above are D65. dcraw and LibRaw both compose them
        /// directly without chromatic adaptation, and the row normalization
        /// absorbs most of the discrepancy. Proper Bradford adaptation
        /// belongs here when DCP profile support lands.
        public init?(cameraToXYZRowMajor m: [Float]) {
            guard m.count >= 9 else { return nil }

            let xyzToCam = ColorKit.matrix(rows: [
                [m[0], m[1], m[2]],
                [m[3], m[4], m[5]],
                [m[6], m[7], m[8]],
            ])

            var workingToCamera = xyzToCam * ColorKit.rec2020ToXYZ
            for row in 0..<3 {
                let sum = workingToCamera[0][row] + workingToCamera[1][row] + workingToCamera[2][row]
                guard abs(sum) > 1e-6 else { return nil }
                for col in 0..<3 {
                    workingToCamera[col][row] /= sum
                }
            }
            guard abs(workingToCamera.determinant) > 1e-9 else { return nil }

            self.xyzToCamera = xyzToCam
            self.cameraToWorking = workingToCamera.inverse
        }

        /// Channel multipliers that make the illuminant described by `wb`
        /// render as neutral. Normalized so green is 1.
        public func multipliers(for wb: WhiteBalance) -> SIMD4<Float> {
            let xyz = ColorKit.xyzFromChromaticity(ColorKit.chromaticity(wb))
            let cameraResponse = xyzToCamera * xyz
            let safe = SIMD3<Float>(max(cameraResponse.x, 1e-6),
                                     max(cameraResponse.y, 1e-6),
                                     max(cameraResponse.z, 1e-6))
            var mul = SIMD3<Float>(1, 1, 1) / safe
            mul /= mul.y
            return SIMD4<Float>(mul.x, mul.y, mul.z, mul.y)
        }

        /// The inverse: recovers an approximate temperature and tint from
        /// channel multipliers, so the UI can show what the camera chose.
        ///
        /// There's no closed form, so this searches the Planckian locus for
        /// the nearest point in uv space and measures the perpendicular
        /// offset. Coarse log-spaced sweep, then a local refinement.
        public func whiteBalance(fromMultipliers mul: SIMD4<Float>) -> WhiteBalance {
            let response = SIMD3<Float>(1.0 / max(mul.x, 1e-6),
                                         1.0 / max(mul.y, 1e-6),
                                         1.0 / max(mul.z, 1e-6))
            let xyz = xyzToCamera.inverse * response
            let targetUV = ColorKit.uvFromXY(ColorKit.chromaticityFromXYZ(xyz))

            func distance(at temperature: Float) -> Float {
                let locusUV = ColorKit.uvFromXY(
                    ColorKit.planckianChromaticity(temperature: temperature))
                return simd_length(locusUV - targetUV)
            }

            var bestTemperature: Float = 5500
            var bestDistance = Float.greatestFiniteMagnitude
            var temperature: Float = 1667
            while temperature <= 25000 {
                let d = distance(at: temperature)
                if d < bestDistance {
                    bestDistance = d
                    bestTemperature = temperature
                }
                temperature *= 1.02
            }

            var step = bestTemperature * 0.01
            for _ in 0..<40 {
                let lower = distance(at: bestTemperature - step)
                let upper = distance(at: bestTemperature + step)
                if lower < bestDistance {
                    bestDistance = lower
                    bestTemperature -= step
                } else if upper < bestDistance {
                    bestDistance = upper
                    bestTemperature += step
                } else {
                    step *= 0.5
                }
            }

            let locusUV = ColorKit.uvFromXY(
                ColorKit.planckianChromaticity(temperature: bestTemperature))
            let perpendicular = ColorKit.locusPerpendicular(temperature: bestTemperature)
            let offset = simd_dot(targetUV - locusUV, perpendicular)

            return WhiteBalance(
                temperature: min(max(bestTemperature, WhiteBalance.temperatureRange.lowerBound),
                                  WhiteBalance.temperatureRange.upperBound),
                tint: min(max(offset / ColorKit.tintToUV, WhiteBalance.tintRange.lowerBound),
                           WhiteBalance.tintRange.upperBound))
        }
    }

    // MARK: - Helpers

    /// Builds a simd_float3x3 from row-major input.
    ///
    /// simd's initializer takes *columns*, and its subscript is
    /// `[column][row]` — the opposite of how colour matrices are written in
    /// every reference. This helper exists so the tables above can be
    /// written the way they appear in the literature and checked by eye.
    public static func matrix(rows: [[Float]]) -> simd_float3x3 {
        precondition(rows.count == 3 && rows.allSatisfy { $0.count == 3 })
        return simd_float3x3(columns: (
            SIMD3<Float>(rows[0][0], rows[1][0], rows[2][0]),
            SIMD3<Float>(rows[0][1], rows[1][1], rows[2][1]),
            SIMD3<Float>(rows[0][2], rows[1][2], rows[2][2])
        ))
    }

    /// Retained for compatibility with earlier call sites.
    public static func cameraToWorking(cameraToXYZRowMajor m: [Float]) -> simd_float3x3? {
        CameraColorProfile(cameraToXYZRowMajor: m)?.cameraToWorking
    }
}
