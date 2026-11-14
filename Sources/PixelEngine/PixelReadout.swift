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
    /// The tone equalizer's mask under the pointer, in EV with its
    /// compensation applied (the value its bands are read at), while the
    /// equalizer is in use; nil otherwise.
    public var toneEqualizerMaskEV: Float?

    public init(linearDisplayP3: SIMD3<Float>, toneEqualizerMaskEV: Float? = nil) {
        linear = linearDisplayP3
        self.toneEqualizerMaskEV = toneEqualizerMaskEV
    }

    /// The readout's tone equalizer part: "Mask −4.3 EV", or "" without one.
    public var toneEqualizerText: String {
        guard let m = toneEqualizerMaskEV, m.isFinite else { return "" }
        return String(format: "Mask %+.1f EV", m).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    /// How far the brightest channel is above SDR white, in stops, when
    /// it is (an HDR view); nil within SDR.
    public var stopsAboveSDRWhite: Float? {
        let peak = max(linear.x, max(linear.y, linear.z))
        return peak > 1.0001 && peak.isFinite ? log2(peak) : nil
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
    /// Visualise HDR Ranges: the picture in grey, with what lies above SDR
    /// white coloured by how many stops above it, and what reaches the HDR
    /// ceiling in magenta (Present.metal's `hdrRangeIndicator`). Not one of
    /// J's two.
    public static let hdrRanges = ClippingIndicators(rawValue: 1 << 2)
}

// MARK: - Readout spaces and area statistics

/// How the colour picker writes a colour out. `standard` is the readout
/// Latent has always shown (RGB in percent and Lab together); the others
/// are one space each, as darktable's colour picker offers them.
public enum PixelReadoutSpace: String, CaseIterable, Identifiable, Sendable {
    case standard, rgbPercent, rgb255, hsl, lch, lab
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .standard:   return "RGB % and Lab"
        case .rgbPercent: return "RGB %"
        case .rgb255:     return "RGB 0–255"
        case .hsl:        return "HSL"
        case .lch:        return "LCh"
        case .lab:        return "Lab (D50)"
        }
    }
    /// The three component names, in order.
    public var componentNames: (String, String, String) {
        switch self {
        case .standard, .rgbPercent, .rgb255: return ("R", "G", "B")
        case .hsl: return ("H", "S", "L")
        case .lch: return ("L", "C", "h")
        case .lab: return ("L", "a", "b")
        }
    }
}

extension PixelReadout {
    /// 0…255 per channel, encoded with the sRGB curve, as an 8-bit file
    /// would hold it.
    public var rgb255: SIMD3<Float> { percent / 100 * 255 }

    /// Hue in degrees, saturation and lightness in percent, from the
    /// encoded RGB (the usual HSL of a colour picker).
    public var hsl: SIMD3<Float> {
        let c = percent / 100
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let l = (mx + mn) / 2
        let d = mx - mn
        let s: Float = d < 1e-6 ? 0 : d / (1 - abs(2 * l - 1))
        return SIMD3(Self.hsv(c).x, min(max(s, 0), 1) * 100, l * 100)
    }

    /// L*, chroma and hue angle in degrees (0…360), from `lab`.
    public var lch: SIMD3<Float> {
        let l = lab
        let chroma = (l.y * l.y + l.z * l.z).squareRoot()
        var hue = atan2(l.z, l.y) * 180 / .pi
        if hue < 0 { hue += 360 }
        return SIMD3(l.x, chroma, chroma < 1e-4 ? 0 : hue)
    }

    /// The three numbers `space` shows. `standard` gives the RGB percent.
    public func components(in space: PixelReadoutSpace) -> SIMD3<Float> {
        switch space {
        case .standard, .rgbPercent: return percent
        case .rgb255: return rgb255
        case .hsl: return hsl
        case .lch: return lch
        case .lab: return lab
        }
    }

    /// The readout as one line of text in `space`: "R 50  G 40  B 30 %".
    /// `standard` is exactly the line the Develop panel has always shown.
    public func text(in space: PixelReadoutSpace) -> String {
        if space == .standard {
            let p = percent, l = lab
            return String(format: "R %.0f  G %.0f  B %.0f %%   L %.0f  a %.0f  b %.0f",
                          p.x, p.y, p.z, l.x, l.y, l.z)
        }
        return Self.text(components(in: space), space: space)
    }

    /// Three numbers of `space` as text, with their names and unit.
    public static func text(_ c: SIMD3<Float>, space: PixelReadoutSpace) -> String {
        let (a, b, d) = space.componentNames
        switch space {
        case .standard, .rgbPercent:
            return String(format: "%@ %.0f  %@ %.0f  %@ %.0f %%", a, c.x, b, c.y, d, c.z)
        case .rgb255:
            return String(format: "%@ %.0f  %@ %.0f  %@ %.0f", a, c.x, b, c.y, d, c.z)
        case .hsl:
            return String(format: "%@ %.0f°  %@ %.0f  %@ %.0f %%", a, c.x, b, c.y, d, c.z)
        case .lch:
            return String(format: "%@ %.0f  %@ %.0f  %@ %.0f°", a, c.x, b, c.y, d, c.z)
        case .lab:
            return String(format: "%@ %.0f  %@ %.0f  %@ %.0f", a, c.x, b, c.y, d, c.z)
        }
    }
}

/// How much of the picture the colour picker averages: one pixel, or a
/// square so many image pixels across.
public enum PixelSampleSize: Int, CaseIterable, Identifiable, Sendable {
    case point = 1, five = 5, fifteen = 15, thirtyOne = 31
    public var id: Int { rawValue }
    public var title: String { self == .point ? "Point" : "\(rawValue) px" }
    /// Pixels either side of the centre, in image pixels.
    public var radius: Int { rawValue / 2 }
}

/// The colours of a sampled square: their mean, and per component of a
/// readout space their least and greatest, as darktable's area picker
/// reports them.
public struct PixelAreaStatistics: Equatable, Sendable {
    /// Linear Display P3, one per pixel read. Never empty.
    public let pixels: [SIMD3<Float>]

    /// Nil when `pixels` is empty.
    public init?(pixels: [SIMD3<Float>]) {
        guard !pixels.isEmpty else { return nil }
        self.pixels = pixels
    }

    /// The mean colour, averaged in linear light.
    public var mean: PixelReadout {
        let sum = pixels.reduce(SIMD3<Float>(repeating: 0), +)
        return PixelReadout(linearDisplayP3: sum / Float(pixels.count))
    }

    /// Least and greatest of each component in `space` (hue taken as it
    /// comes, without wrapping round 0°).
    public func range(in space: PixelReadoutSpace) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in pixels {
            let c = PixelReadout(linearDisplayP3: p).components(in: space)
            lo = simd_min(lo, c); hi = simd_max(hi, c)
        }
        return (lo, hi)
    }
}
