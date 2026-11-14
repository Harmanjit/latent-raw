import Foundation
import CoreGraphics
import simd

/// The Remove tool's Fill and Blur modes (docs/wiki/Develop.md, "Spot
/// Removal"), beside Heal, Clone and Remove. Neither has a source: Fill
/// paints one colour over the patch, Blur softens what is under it. Both
/// take the patch's shape (a spot or a brush stroke), feather and opacity,
/// and run in Heal.metal's `healApply` with the other modes; Blur reuses
/// the heal's gather and Gaussian blur on a coarse grid, gathering the
/// whole area instead of only its surroundings.
extension HealPatch.Mode {
    /// Whether the mode copies from a source (Heal, Clone). Remove, Fill
    /// and Blur keep their source on the target and draw none.
    public var usesSource: Bool { self == .heal || self == .clone }

    /// The kernel's mode switch (Heal.metal).
    var gpuIndex: Float {
        switch self {
        case .heal: return 0
        case .clone: return 1
        case .remove: return 2
        case .fill: return 3
        case .blur: return 4
        }
    }
}

extension HealPatch {
    /// Fill's colour when none is picked: a mid grey, in linear Rec.2020.
    public static let defaultFillColour = SIMD3<Float>(repeating: 0.18)
    /// Blur's radius when none is set: 0.5 % of the short side, about
    /// 20 px on a 24 MP frame.
    public static let defaultBlurRadius: Float = 0.005
    /// The largest Blur radius, 5 % of the short side.
    public static let maximumBlurRadius: Float = 0.05
    /// Fill's brightness range, in stops.
    public static let fillBrightnessRange: ClosedRange<Float> = -4...4

    public var effectiveFillColour: SIMD3<Float> { fillColour ?? Self.defaultFillColour }
    public var effectiveFillBrightness: Float { fillBrightness ?? 0 }
    public var effectiveBlurRadius: Float { blurRadius ?? Self.defaultBlurRadius }

    /// Brings Fill's and Blur's fields from a file into range (called by
    /// `sanitized`): a colour that isn't finite or is negative is dropped
    /// to the default, values clamped to what the controls allow.
    func sanitizeModeFields(_ p: inout HealPatch) {
        if let c = fillColour {
            p.fillColour = [c.x, c.y, c.z].allSatisfy({ $0.isFinite }) ? simd_clamp(c, .zero, SIMD3(repeating: 16)) : nil
        }
        p.fillBrightness = fillBrightness.map {
            $0.isFinite ? min(max($0, Self.fillBrightnessRange.lowerBound), Self.fillBrightnessRange.upperBound) : 0
        }
        p.blurRadius = blurRadius.map {
            $0.isFinite ? min(max($0, 0), Self.maximumBlurRadius) : Self.defaultBlurRadius
        }
    }

    /// Blur's Gaussian, in sensor pixels at full resolution: its sigma is
    /// half the radius, which is what `HealFieldLayout(radius:)` makes of
    /// a radius, so the layout is that of the blur radius itself.
    func blurFieldLayout(sensorSize s: CGSize) -> HealFieldLayout {
        HealFieldLayout(radius: effectiveBlurRadius * Float(min(s.width, s.height)))
    }

    /// Fill's colour in the camera space the heal stage works in, with
    /// the brightness applied: the working-space colour taken back
    /// through the camera matrix.
    func fillCameraColour(cameraToWorking: simd_float3x3) -> SIMD3<Float> {
        let working = effectiveFillColour * powf(2, effectiveFillBrightness)
        let det = simd_determinant(cameraToWorking)
        guard det.isFinite, abs(det) > 1e-8 else { return working }
        return simd_max(cameraToWorking.inverse * working, .zero)
    }

    /// Linear Rec.2020 from a display sRGB colour (0…1, encoded): what
    /// the panel's colour well stores as Fill's colour. Approximate on
    /// purpose: the photo's own tone and colour edits still apply on top.
    public static func fillColour(fromSRGB c: SIMD3<Float>) -> SIMD3<Float> {
        func linear(_ v: Float) -> Float {
            let x = min(max(v, 0), 1)
            return x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)
        }
        let l = SIMD3(linear(c.x), linear(c.y), linear(c.z))
        let toRec2020 = simd_float3x3(rows: [
            SIMD3(0.6274, 0.3293, 0.0433),
            SIMD3(0.0691, 0.9195, 0.0114),
            SIMD3(0.0164, 0.0880, 0.8956),
        ])
        return toRec2020 * l
    }

    /// The display sRGB colour (0…1, encoded) of a Fill colour, for the
    /// colour well: the inverse of `fillColour(fromSRGB:)`.
    public static func sRGB(fromFillColour c: SIMD3<Float>) -> SIMD3<Float> {
        let toSRGB = simd_float3x3(rows: [
            SIMD3(1.6605, -0.5876, -0.0728),
            SIMD3(-0.1246, 1.1329, -0.0083),
            SIMD3(-0.0182, -0.1006, 1.1187),
        ])
        let l = toSRGB * c
        func encoded(_ v: Float) -> Float {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1 / 2.4) - 0.055
        }
        return SIMD3(encoded(l.x), encoded(l.y), encoded(l.z))
    }
}
