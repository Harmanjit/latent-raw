import Foundation
import simd
import ColorKit

/// What the pointer is over, as the Develop panel reads it out under the
/// histogram: the displayed colour as RGB percentages and as CIE Lab.
///
/// Built from the viewport's own pixels, which are linear Display P3
/// (`RenderOutput.edrDisplay`), so it describes the picture after every
/// adjustment, as Lightroom's readout does. RGB is shown with the sRGB
/// tone curve the way an encoded file would hold it, 0 to 100 %; Lab is
/// relative to a D50 white (Bradford-adapted from the D65 of P3), the
/// convention Photoshop and Lightroom use, so numbers can be compared.
public struct PixelReadout: Equatable, Sendable {
    /// Linear Display P3, as sampled (may pass 1 with HDR headroom).
    public var linear: SIMD3<Float>

    public init(linearDisplayP3: SIMD3<Float>) {
        linear = linearDisplayP3
    }

    /// 0…100 per channel, encoded with the sRGB curve, clamped to SDR.
    public var percent: SIMD3<Float> {
        SIMD3(Self.encode(linear.x), Self.encode(linear.y), Self.encode(linear.z)) * 100
    }

    /// L* 0…100, a*, b*.
    public var lab: SIMD3<Float> {
        let xyzD65 = ColorKit.displayP3ToXYZ * simd_max(linear, SIMD3(repeating: 0))
        let xyz = Self.bradfordD65toD50 * xyzD65
        let white = SIMD3<Float>(0.96422, 1.0, 0.82521)
        func f(_ t: Float) -> Float {
            let e: Float = 216.0 / 24389.0, k: Float = 24389.0 / 27.0
            return t > e ? cbrt(t) : (k * t + 16) / 116
        }
        let fx = f(xyz.x / white.x), fy = f(xyz.y / white.y), fz = f(xyz.z / white.z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// The tone and hue the colour kernel's curve and HSL bands would
    /// see for this pixel: Rec.2020 working primaries on the kernel's
    /// gamma 2.2 scale, `headroom` taken out. It is the picture after the
    /// curve, so callers that want the tone *before* it invert the curve.
    public func gradingCoordinates(headroom: Float = 1) -> (luma: Float, hue: Float, saturation: Float) {
        let working = Self.displayP3ToWorking * linear / max(headroom, 1)
        let p = simd_max(working, SIMD3(repeating: 0))
        let g = SIMD3(pow(p.x, 1 / 2.2), pow(p.y, 1 / 2.2), pow(p.z, 1 / 2.2))
        let luma = simd_dot(g, SIMD3(0.2627, 0.6780, 0.0593))
        let hsv = Self.hsv(g)
        return (min(max(luma, 0), 1), hsv.x, hsv.y)
    }

    /// The kernel's rgbToHSV (ColorPipeline.metal): hue in degrees.
    public static func hsv(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let d = mx - mn
        var h: Float = 0
        if d > 1e-6 {
            if mx == c.x { h = fmodf((c.y - c.z) / d, 6) }
            else if mx == c.y { h = (c.z - c.x) / d + 2 }
            else { h = (c.x - c.y) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return SIMD3(h, mx > 1e-6 ? d / mx : 0, mx)
    }

    static func encode(_ v: Float) -> Float {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static let displayP3ToWorking = ColorKit.rec2020ToXYZ.inverse * ColorKit.displayP3ToXYZ

    static let bradfordD65toD50 = ColorKit.matrix(rows: [
        [1.0478112, 0.0228866, -0.0501270],
        [0.0295424, 0.9904844, -0.0170491],
        [-0.0092345, 0.0150436, 0.7521316],
    ])
}

extension HSLAdjustments {
    /// How much each of the eight bands acts on `hue` (degrees): the
    /// kernel's `hslBandWeights`, two neighbouring bands sharing it.
    public static func bandWeights(hue: Float) -> [Float] {
        var w = [Float](repeating: 0, count: 8)
        let centres = bandCentres
        var lo = 7, hi = 0
        let span = 360 - centres[7]
        var t: Float = hue >= centres[7] ? (hue - centres[7]) / span : 0
        for i in 0..<7 where hue >= centres[i] && hue < centres[i + 1] {
            lo = i; hi = i + 1
            t = (hue - centres[i]) / (centres[i + 1] - centres[i])
            break
        }
        w[lo] += 1 - t
        w[hi] += t
        return w
    }
}

/// Which clipping the viewport paints: highlights red where any channel
/// has reached the top, shadows blue where every channel is at black,
/// Lightroom's colours. A display setting, never part of an edit.
public struct ClippingIndicators: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shadows = ClippingIndicators(rawValue: 1 << 0)
    public static let highlights = ClippingIndicators(rawValue: 1 << 1)
    public static let both: ClippingIndicators = [.shadows, .highlights]
}
