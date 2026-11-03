import Foundation
import simd

/// A DNG hue/saturation/value table: ProfileHueSatMap or ProfileLookTable.
///
/// For each sample of hue, saturation and (optionally) value it holds a
/// hue shift in degrees, a saturation scale and a value scale. A colour is
/// looked up by its HSV in linear ProPhoto RGB, the three entries around it
/// are interpolated, and the colour is moved by them.
///
/// With one value division (most profiles) the table depends on hue and
/// saturation only, which scale doesn't change, so it works on scene-linear
/// values of any brightness. With several, the value axis covers [0, 1],
/// optionally sRGB-encoded, and brighter values use the top row.
public struct HueSatTable: Sendable, Equatable {
    public let hueDivisions: Int
    public let satDivisions: Int
    public let valDivisions: Int
    /// The value axis is indexed by the sRGB encoding of value
    /// (ProfileHueSatMapEncoding / ProfileLookTableEncoding = 1).
    public let sRGBValueEncoding: Bool
    /// (hue shift in degrees, saturation scale, value scale) per sample,
    /// value outermost, then hue, then saturation: the DNG storage order.
    public let entries: [SIMD3<Float>]

    /// The table's samples from a file: `dims` is (hue, sat, val), the
    /// value count optional; `values` is three floats per sample. nil when
    /// the sizes disagree or an entry isn't a number.
    public init?(dims: [Int], values: [Float], sRGBValueEncoding: Bool = false) {
        guard dims.count >= 2 else { return nil }
        let h = dims[0], s = dims[1], v = dims.count >= 3 ? max(dims[2], 1) : 1
        guard h >= 1, h <= 360, s >= 2, s <= 256, v <= 256 else { return nil }
        guard values.count == h * s * v * 3 else { return nil }
        var entries: [SIMD3<Float>] = []
        entries.reserveCapacity(h * s * v)
        for i in 0..<(h * s * v) {
            let e = SIMD3(values[i * 3], values[i * 3 + 1], values[i * 3 + 2])
            guard e.x.isFinite, e.y.isFinite, e.z.isFinite else { return nil }
            // Shifts beyond a half turn and negative scales are meaningless.
            entries.append(SIMD3(min(max(e.x, -180), 180), max(e.y, 0), max(e.z, 0)))
        }
        self.init(hue: h, sat: s, val: v, entries: entries, sRGBValueEncoding: sRGBValueEncoding)
    }

    public init(hue: Int, sat: Int, val: Int = 1, entries: [SIMD3<Float>], sRGBValueEncoding: Bool = false) {
        precondition(entries.count == hue * sat * val)
        self.hueDivisions = hue
        self.satDivisions = sat
        self.valDivisions = val
        self.entries = entries
        self.sRGBValueEncoding = sRGBValueEncoding
    }

    /// A table built from a function of a colour's hue (degrees), saturation
    /// and value (both 0...1), sampled on the given grid. How Latent's own
    /// profiles are defined.
    public init(hue: Int, sat: Int, val: Int = 1,
                _ entry: (_ hue: Float, _ saturation: Float, _ value: Float) -> SIMD3<Float>) {
        var entries: [SIMD3<Float>] = []
        entries.reserveCapacity(hue * sat * val)
        for vi in 0..<val {
            let value = val > 1 ? Float(vi) / Float(val - 1) : 1
            for hi in 0..<hue {
                let h = Float(hi) * 360 / Float(hue)
                for si in 0..<sat {
                    entries.append(entry(h, Float(si) / Float(sat - 1), value))
                }
            }
        }
        self.init(hue: hue, sat: sat, val: val, entries: entries)
    }

    public static let identityEntry = SIMD3<Float>(0, 1, 1)

    public var isIdentity: Bool { entries.allSatisfy { $0 == Self.identityEntry } }

    public func entry(hue: Int, sat: Int, val: Int) -> SIMD3<Float> {
        entries[(val * hueDivisions + hue) * satDivisions + sat]
    }

    /// `self` and `other` mixed: weight 1 is all `self`. The two must have
    /// the same shape (a DCP's two HueSatMaps always do).
    public func blended(with other: HueSatTable, weight: Float) -> HueSatTable {
        guard other.hueDivisions == hueDivisions, other.satDivisions == satDivisions,
              other.valDivisions == valDivisions else { return self }
        let w = min(max(weight, 0), 1)
        let mixed = zip(entries, other.entries).map { $0 * w + $1 * (1 - w) }
        return HueSatTable(hue: hueDivisions, sat: satDivisions, val: valDivisions,
                           entries: mixed, sRGBValueEncoding: sRGBValueEncoding)
    }

    /// The interpolated entry for a colour's HSV (hue in degrees). The
    /// same lookup the GPU makes, for tests and CPU work.
    public func lookup(hue: Float, saturation: Float, value: Float) -> SIMD3<Float> {
        var hf = (hue / 360).truncatingRemainder(dividingBy: 1)
        if hf < 0 { hf += 1 }
        hf *= Float(hueDivisions)
        let h0 = Int(hf) % hueDivisions, h1 = (h0 + 1) % hueDivisions
        let ht = hf - Float(Int(hf))

        let sf = min(max(saturation, 0), 1) * Float(satDivisions - 1)
        let s0 = min(Int(sf), satDivisions - 1), s1 = min(s0 + 1, satDivisions - 1)
        let st = sf - Float(s0)

        var v0 = 0, v1 = 0, vt: Float = 0
        if valDivisions > 1 {
            let clamped = min(max(value, 0), 1)
            let coordinate = sRGBValueEncoding ? Self.sRGBEncode(clamped) : clamped
            let vf = coordinate * Float(valDivisions - 1)
            v0 = min(Int(vf), valDivisions - 1); v1 = min(v0 + 1, valDivisions - 1)
            vt = vf - Float(v0)
        }
        func plane(_ v: Int) -> SIMD3<Float> {
            let a = entry(hue: h0, sat: s0, val: v) * (1 - st) + entry(hue: h0, sat: s1, val: v) * st
            let b = entry(hue: h1, sat: s0, val: v) * (1 - st) + entry(hue: h1, sat: s1, val: v) * st
            return a * (1 - ht) + b * ht
        }
        return valDivisions > 1 ? plane(v0) * (1 - vt) + plane(v1) * vt : plane(0)
    }

    /// Applies the table to a linear ProPhoto colour.
    public func apply(toProPhoto rgb: SIMD3<Float>) -> SIMD3<Float> {
        let hsv = ColorKit.rgbToHSV(simd_max(rgb, .zero))
        let e = lookup(hue: hsv.x, saturation: hsv.y, value: hsv.z)
        return ColorKit.hsvToRGB(SIMD3(hsv.x + e.x, min(hsv.y * e.y, 1), hsv.z * e.z))
    }

    static func sRGBEncode(_ x: Float) -> Float {
        x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1 / 2.4) - 0.055
    }
}

extension ColorKit {
    /// RGB to (hue in degrees, saturation, value), as the shaders do it.
    public static func rgbToHSV(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let d = mx - mn
        var h: Float = 0
        if d > 1e-6 {
            if mx == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.y { h = (c.z - c.x) / d + 2 }
            else { h = (c.x - c.y) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return SIMD3(h, mx > 1e-6 ? d / mx : 0, mx)
    }

    public static func hsvToRGB(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        var hue = (hsv.x + 360).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let h = hue / 60, s = hsv.y, v = hsv.z
        let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let rgb: SIMD3<Float>
        switch h {
        case ..<1: rgb = SIMD3(c, x, 0)
        case ..<2: rgb = SIMD3(x, c, 0)
        case ..<3: rgb = SIMD3(0, c, x)
        case ..<4: rgb = SIMD3(0, x, c)
        case ..<5: rgb = SIMD3(x, 0, c)
        default: rgb = SIMD3(c, 0, x)
        }
        return rgb + m
    }
}
