import Foundation

/// The corrections to apply to one image: the profile resolved at its
/// focal length and aperture, ready for the GPU.
public struct LensCorrection: Sendable, Equatable {
    public var distortion: DistortionModel?
    public var tca: TCAModel?
    public var vignetting: VignettingModel?
    /// Calibration crop factor / camera crop factor.
    public var cropRatio: Float
    /// Uniform scale applied to the undistorted image so the corrected
    /// frame has no empty corners. 1 when there's no distortion.
    public var autoScale: Float
    public var profileName: String
    public var databaseVersion: String

    public init(distortion: DistortionModel? = nil, tca: TCAModel? = nil,
                vignetting: VignettingModel? = nil, cropRatio: Float = 1,
                autoScale: Float = 1, profileName: String = "", databaseVersion: String = "") {
        self.distortion = distortion
        self.tca = tca
        self.vignetting = vignetting
        self.cropRatio = cropRatio
        self.autoScale = autoScale
        self.profileName = profileName
        self.databaseVersion = databaseVersion
    }

    public var isEmpty: Bool { distortion == nil && tca == nil && vignetting == nil }

    // MARK: - Resolving a profile at a focal length and aperture

    /// Interpolates the profile's calibration points to `focal` and
    /// `aperture` (the way Lensfun does: linearly between the two nearest
    /// focal lengths; vignetting also picks the nearest aperture and the
    /// farthest distance, since focus distance isn't known).
    public static func resolve(_ match: LensProfileMatch, focal: Float, aperture: Float,
                               imageWidth: Int, imageHeight: Int,
                               databaseVersion: String) -> LensCorrection {
        let lens = match.lens
        var correction = LensCorrection(cropRatio: match.cropRatio,
                                        profileName: lens.modelNames.last ?? lens.model,
                                        databaseVersion: databaseVersion)

        correction.distortion = interpolate(lens.distortion.map { ($0.focal, $0.model) }, at: focal,
                                            lerp: lerpDistortion)
        correction.tca = interpolate(lens.tca.map { ($0.focal, $0.model) }, at: focal, lerp: lerpTCA)

        if !lens.vignetting.isEmpty {
            // Nearest focal, then nearest aperture, then farthest distance.
            let focals = Set(lens.vignetting.map(\.focal))
            let f = focals.min { abs($0 - focal) < abs($1 - focal) }!
            let atFocal = lens.vignetting.filter { $0.focal == f }
            let apertures = Set(atFocal.map(\.aperture))
            let a = apertures.min { abs(log2($0 / max(aperture, 0.1))) < abs(log2($1 / max(aperture, 0.1))) }!
            let atAperture = atFocal.filter { $0.aperture == a }
            correction.vignetting = atAperture.max { $0.distance < $1.distance }?.model
        }

        if let d = correction.distortion {
            correction.autoScale = autoScale(for: d, cropRatio: match.cropRatio,
                                             width: imageWidth, height: imageHeight)
        }
        return correction
    }

    static func interpolate<M>(_ points: [(Float, M)], at focal: Float,
                               lerp: (M, M, Float) -> M?) -> M? {
        let sorted = points.sorted { $0.0 < $1.0 }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if focal <= first.0 { return first.1 }
        if focal >= last.0 { return last.1 }
        for i in 1..<sorted.count where sorted[i].0 >= focal {
            let (f0, m0) = sorted[i - 1], (f1, m1) = sorted[i]
            // Exactly on a calibration point: return it, no float drift.
            if focal == f1 { return m1 }
            if focal == f0 { return m0 }
            let t = (focal - f0) / (f1 - f0)
            return lerp(m0, m1, t) ?? (t < 0.5 ? m0 : m1)
        }
        return last.1
    }

    /// Linear blend of coefficients, only when both points use the same
    /// model (blending a ptlens with a poly3 makes no sense; nearest wins).
    static func lerpDistortion(_ a: DistortionModel, _ b: DistortionModel, _ t: Float) -> DistortionModel? {
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        switch (a, b) {
        case let (.ptlens(a0, b0, c0), .ptlens(a1, b1, c1)):
            return .ptlens(a: mix(a0, a1), b: mix(b0, b1), c: mix(c0, c1))
        case let (.poly3(k0), .poly3(k1)):
            return .poly3(k1: mix(k0, k1))
        case let (.poly5(k0, l0), .poly5(k1, l1)):
            return .poly5(k1: mix(k0, k1), k2: mix(l0, l1))
        default:
            return nil
        }
    }

    static func lerpTCA(_ a: TCAModel, _ b: TCAModel, _ t: Float) -> TCAModel? {
        TCAModel(red: a.red + (b.red - a.red) * t, blue: a.blue + (b.blue - a.blue) * t)
    }

    // MARK: - Auto scale

    /// The scale that keeps every corrected pixel inside the source frame.
    ///
    /// Barrel distortion pulls the corners inward, so undistorting pushes
    /// them *out* past the sensor edge and the corrected frame would have
    /// empty corners. Shrinking the undistorted coordinates by `s < 1`
    /// before mapping fixes that. Lensfun tests eight border points; for
    /// each, this finds the `s` at which the mapped source point lands
    /// exactly on the border, and keeps the most restrictive.
    public static func autoScale(for model: DistortionModel, cropRatio: Float,
                                 width: Int, height: Int) -> Float {
        let w = Float(width), h = Float(height)
        let halfShort = min(w, h) / 2
        // Border points in centred pixel coordinates.
        let points: [SIMD2<Float>] = [
            SIMD2(w / 2, 0), SIMD2(-w / 2, 0), SIMD2(0, h / 2), SIMD2(0, -h / 2),
            SIMD2(w / 2, h / 2), SIMD2(-w / 2, h / 2), SIMD2(w / 2, -h / 2), SIMD2(-w / 2, -h / 2),
        ]
        var scale: Float = 10
        for p in points {
            // Source = p * s * factor(|p| * s * norm). Find the largest s
            // (in [0.3, 3]) such that the source stays inside the frame
            // along this ray; the source's radial position must be <= |p|.
            let rPix = simd_length(p)
            func sourceRatio(_ s: Float) -> Float {
                let ru = rPix * s / halfShort * cropRatio
                return s * model.factor(atUndistortedRadius: ru)   // = |source| / |p|
            }
            var lo: Float = 0.3, hi: Float = 3
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if sourceRatio(mid) <= 1 { lo = mid } else { hi = mid }
            }
            scale = min(scale, lo)
        }
        return min(max(scale, 0.3), 3)
    }
}

// simd_length for SIMD2<Float> without importing simd everywhere.
private func simd_length(_ v: SIMD2<Float>) -> Float { (v.x * v.x + v.y * v.y).squareRoot() }
