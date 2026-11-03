import Foundation
import simd

/// The colour algebra a camera profile needs: chromatic adaptation, the
/// ProFoto RGB space DNG tables are defined in, and the DNG
/// specification's recipe for turning a dual-illuminant profile into one
/// matrix for the white balance in use.
extension ColorKit {

    // MARK: - White points and adaptation

    /// CIE XYZ of D50 and D65, Y = 1.
    public static let d50XYZ = SIMD3<Float>(0.96422, 1.0, 0.82521)
    public static let d65XYZ = SIMD3<Float>(0.95047, 1.0, 1.08883)

    /// Bradford cone response matrix.
    static let bradford = matrix(rows: [
        [ 0.8951,  0.2664, -0.1614],
        [-0.7502,  1.7135,  0.0367],
        [ 0.0389, -0.0685,  1.0296],
    ])

    /// XYZ under `source` white -> XYZ under `destination` white, by the
    /// Bradford transform (what the DNG SDK and ICC use).
    public static func bradfordAdaptation(from source: SIMD3<Float>, to destination: SIMD3<Float>) -> simd_float3x3 {
        let s = bradford * source, d = bradford * destination
        let scale = simd_float3x3(diagonal: SIMD3(d.x / max(s.x, 1e-9), d.y / max(s.y, 1e-9), d.z / max(s.z, 1e-9)))
        return bradford.inverse * scale * bradford
    }

    /// Linear ProPhoto (ROMM) RGB -> XYZ D50.
    public static let proPhotoToXYZD50 = matrix(rows: [
        [0.7976749, 0.1351917, 0.0313534],
        [0.2880402, 0.7118741, 0.0000857],
        [0.0000000, 0.0000000, 0.8252100],
    ])

    /// Latent's working space (linear Rec.2020, D65) -> linear ProPhoto
    /// (D50), the space DNG's hue/saturation tables are defined in. Rows
    /// are scaled so white maps to exactly (1, 1, 1): the published
    /// matrices agree to about 1e-4, and a table lookup on a neutral must
    /// see saturation 0, not a faint tint.
    public static let workingToProPhoto: simd_float3x3 = {
        let m = proPhotoToXYZD50.inverse * bradfordAdaptation(from: d65XYZ, to: d50XYZ) * rec2020ToXYZ
        return normalizingRows(m)
    }()

    public static let proPhotoToWorking: simd_float3x3 = workingToProPhoto.inverse

    /// `m` with each row divided by its sum, so (1, 1, 1) maps to itself.
    static func normalizingRows(_ m: simd_float3x3) -> simd_float3x3 {
        var out = m
        for row in 0..<3 {
            let sum = m[0][row] + m[1][row] + m[2][row]
            guard abs(sum) > 1e-9 else { continue }
            for col in 0..<3 { out[col][row] = m[col][row] / sum }
        }
        return out
    }

    // MARK: - Illuminants

    /// The correlated colour temperature of an EXIF LightSource code, as
    /// the DNG SDK assigns them for profile interpolation. 0 for codes it
    /// can't place (Other, Unknown), which then count as D65.
    public static func temperature(ofIlluminant code: Int) -> Float {
        switch code {
        case 17, 3: return 2850                   // Standard light A, Tungsten
        case 24: return 3200                      // ISO studio tungsten
        case 23: return 5000                      // D50
        case 1, 4, 9, 18, 20: return 5500         // Daylight, Flash, Fine weather, B, D55
        case 21, 19, 10: return 6500              // D65, C, Cloudy
        case 22, 11: return 7500                  // D75, Shade
        case 12: return 6400                      // Daylight fluorescent (5700-7100K)
        case 13: return 5050                      // Day white fluorescent (4600-5500K)
        case 14, 2: return 4150                   // Cool white fluorescent, Fluorescent
        case 15: return 3525                      // White fluorescent (3250-3800K)
        case 16: return 2925                      // Warm white fluorescent (2600-3250K)
        default: return 0
        }
    }

    /// Correlated colour temperature of a chromaticity, by McCamy's cubic.
    /// Good to a few kelvin between 2000K and 12500K, which is all a
    /// profile's interpolation weight needs.
    public static func correlatedTemperature(ofChromaticity xy: SIMD2<Float>) -> Float {
        let n = (xy.x - 0.3320) / (0.1858 - xy.y)
        let t = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
        return min(max(t, 1500), 50000)
    }
}

/// How a DNG camera profile renders one image: the camera matrix for its
/// white balance, and the tables for that white.
///
/// Follows the DNG specification (chapter 6, "Mapping Camera Color Space
/// to CIE XYZ Space"): the two calibrations are mixed by inverse colour
/// temperature of the white being rendered, found by iterating between
/// the camera neutral and the interpolated ColorMatrix.
public struct CameraProfileMath {
    public let profile: DCPProfile

    public init(profile: DCPProfile) {
        self.profile = profile
    }

    /// How much of calibration 1 to use for a white at `temperature`,
    /// linear in inverse temperature and clamped at both ends.
    public func weight1(forTemperature temperature: Float) -> Float {
        guard let c2 = profile.calibration2 else { return 1 }
        let t1 = ColorKit.temperature(ofIlluminant: profile.calibration1.illuminant)
        let t2 = ColorKit.temperature(ofIlluminant: c2.illuminant)
        guard t1 > 0, t2 > 0, abs(t1 - t2) > 1 else { return 1 }
        let inv = 1 / max(temperature, 1), inv1 = 1 / t1, inv2 = 1 / t2
        let g = (inv - inv2) / (inv1 - inv2)
        return min(max(g, 0), 1)
    }

    func mix(_ a: simd_float3x3?, _ b: simd_float3x3?, _ w: Float) -> simd_float3x3? {
        guard let a else { return b }
        guard let b else { return a }
        return a * w + b * (1 - w)
    }

    func colorMatrix(weight: Float) -> simd_float3x3 {
        mix(profile.calibration1.colorMatrix, profile.calibration2?.colorMatrix, weight)
            ?? matrix_identity_float3x3
    }

    /// The white's chromaticity for a camera neutral (the camera's RGB
    /// response to the white, any scale), and the calibration-1 weight
    /// that goes with it. Iterates: guess a white, interpolate the matrix
    /// for its temperature, convert the neutral, repeat until it settles.
    public func white(forCameraNeutral neutral: SIMD3<Float>) -> (xy: SIMD2<Float>, weight1: Float) {
        var xy = ColorKit.chromaticityFromXYZ(ColorKit.d50XYZ)
        var weight: Float = 1
        for _ in 0..<30 {
            weight = weight1(forTemperature: ColorKit.correlatedTemperature(ofChromaticity: xy))
            let cm = colorMatrix(weight: weight)
            guard abs(cm.determinant) > 1e-12 else { break }
            let xyz = cm.inverse * neutral
            guard xyz.y > 0 else { break }
            let next = ColorKit.chromaticityFromXYZ(xyz)
            guard next.x.isFinite, next.y.isFinite, next.y > 0.05 else { break }
            let settled = simd_length(next - xy) < 1e-7
            xy = next
            if settled { break }
        }
        weight = weight1(forTemperature: ColorKit.correlatedTemperature(ofChromaticity: xy))
        return (xy, weight)
    }

    /// Camera RGB at Latent's seam -> linear Rec.2020, for an image whose
    /// seam was white balanced with `multipliers` (green-normalized, the
    /// reciprocal of the camera neutral).
    ///
    /// The seam already holds white-balanced camera values, which is what
    /// a ForwardMatrix expects: it maps them to XYZ D50 so that white lands
    /// on D50 white. Without one, the ColorMatrix is inverted and the white
    /// it finds is adapted to D65. Either way the result's rows are scaled
    /// so camera white maps to exactly (1, 1, 1), as Latent's own matrix
    /// does, which keeps exposure and neutrals where they were.
    public func cameraToWorking(multipliers: SIMD4<Float>) -> simd_float3x3? {
        let neutral = SIMD3<Float>(1 / max(multipliers.x, 1e-6), 1 / max(multipliers.y, 1e-6),
                                   1 / max(multipliers.z, 1e-6))
        let (xy, w) = white(forCameraNeutral: neutral)
        let xyzD65ToWorking = ColorKit.rec2020ToXYZ.inverse
        let m: simd_float3x3
        if let fm = mix(profile.calibration1.forwardMatrix, profile.calibration2?.forwardMatrix, w) {
            // DNG: normalise the forward matrix so camera white maps to D50.
            let white = fm * SIMD3<Float>(1, 1, 1)
            guard white.x > 0, white.y > 0, white.z > 0 else { return nil }
            let scale = simd_float3x3(diagonal: ColorKit.d50XYZ / white)
            m = xyzD65ToWorking * ColorKit.bradfordAdaptation(from: ColorKit.d50XYZ, to: ColorKit.d65XYZ)
                * scale * fm
        } else {
            let cm = colorMatrix(weight: w)
            guard abs(cm.determinant) > 1e-12 else { return nil }
            // Seam values are raw x multipliers, so raw = seam * neutral.
            let cameraToXYZ = cm.inverse * simd_float3x3(diagonal: neutral)
            let whiteXYZ = ColorKit.xyzFromChromaticity(xy)
            m = xyzD65ToWorking * ColorKit.bradfordAdaptation(from: whiteXYZ, to: ColorKit.d65XYZ) * cameraToXYZ
        }
        let normalised = ColorKit.normalizingRows(m)
        guard abs(normalised.determinant) > 1e-9,
              (0..<3).allSatisfy({ c in (0..<3).allSatisfy { normalised[c][$0].isFinite } }) else { return nil }
        return normalised
    }

    /// The HueSatMap for this white: the two calibrations' tables mixed
    /// with the matrices' weight, or the one there is.
    public func hueSatMap(multipliers: SIMD4<Float>) -> HueSatTable? {
        let t1 = profile.calibration1.hueSatMap, t2 = profile.calibration2?.hueSatMap
        guard let t1 else { return t2 }
        guard let t2 else { return t1 }
        let neutral = SIMD3<Float>(1 / max(multipliers.x, 1e-6), 1 / max(multipliers.y, 1e-6),
                                   1 / max(multipliers.z, 1e-6))
        return t1.blended(with: t2, weight: white(forCameraNeutral: neutral).weight1)
    }
}
