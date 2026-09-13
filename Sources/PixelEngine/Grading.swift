import Foundation
import simd

/// Colour grading parameters (DESIGN.md §8.1 stage 11).

/// A point tone curve on [0,1] → [0,1]. Points are kept sorted by x with
/// the endpoints pinned to x = 0 and x = 1.
public struct ToneCurve: Equatable, Sendable, Codable {
    public var points: [SIMD2<Float>]

    public static let identity = ToneCurve(points: [SIMD2(0, 0), SIMD2(1, 1)])
    public static let lutSize = 256

    public init(points: [SIMD2<Float>]) {
        self.points = points
    }

    public var isIdentity: Bool { self == .identity }

    /// The curve sampled at `lutSize` evenly spaced inputs, using monotone
    /// cubic Hermite interpolation (Fritsch–Carlson). Monotone matters: a
    /// natural cubic spline through a steep S-curve overshoots and creates
    /// reversed tones between points, which looks like posterisation.
    public func lookupTable() -> [Float] {
        let pts = points.sorted { $0.x < $1.x }
        guard pts.count >= 2 else { return (0..<Self.lutSize).map { Float($0) / Float(Self.lutSize - 1) } }
        let n = pts.count
        let x = pts.map { $0.x }, y = pts.map { $0.y }

        // Secant slopes, then tangents limited to keep monotonicity.
        var delta = [Float](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { delta[i] = (y[i + 1] - y[i]) / max(x[i + 1] - x[i], 1e-6) }
        var m = [Float](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            m[i] = (delta[i - 1] * delta[i] <= 0) ? 0 : (delta[i - 1] + delta[i]) / 2
        }
        for i in 0..<(n - 1) where delta[i] != 0 {
            let a = m[i] / delta[i], b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * delta[i]
                m[i + 1] = t * b * delta[i]
            }
        }

        var lut = [Float](repeating: 0, count: Self.lutSize)
        var seg = 0
        for k in 0..<Self.lutSize {
            let t = Float(k) / Float(Self.lutSize - 1)
            if t <= x[0] { lut[k] = y[0]; continue }
            if t >= x[n - 1] { lut[k] = y[n - 1]; continue }
            while seg < n - 2 && t > x[seg + 1] { seg += 1 }
            let h = x[seg + 1] - x[seg]
            let u = (t - x[seg]) / max(h, 1e-6)
            let u2 = u * u, u3 = u2 * u
            let h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u
            let h01 = -2 * u3 + 3 * u2, h11 = u3 - u2
            lut[k] = min(max(h00 * y[seg] + h10 * h * m[seg] + h01 * y[seg + 1] + h11 * h * m[seg + 1], 0), 1)
        }
        return lut
    }
}

/// Per-hue-band adjustments, Lightroom's eight bands.
public struct HSLAdjustments: Equatable, Sendable, Codable {
    public static let bandNames = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    /// Band centres in degrees, matching the names above.
    public static let bandCentres: [Float] = [0, 30, 60, 120, 180, 240, 270, 300]

    /// -1...1 each; hue shifts up to ±30°, saturation 0...2×, luminance ±50%.
    public var hue: [Float]
    public var saturation: [Float]
    public var luminance: [Float]

    public static let neutral = HSLAdjustments(hue: Array(repeating: 0, count: 8),
                                               saturation: Array(repeating: 0, count: 8),
                                               luminance: Array(repeating: 0, count: 8))
    public init(hue: [Float], saturation: [Float], luminance: [Float]) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }
    public var isNeutral: Bool { self == .neutral }

    /// Packed for the GPU: 8 hue, 8 saturation, 8 luminance.
    var packed: [Float] { hue + saturation + luminance }
}

/// Shadow and highlight tints.
public struct SplitToning: Equatable, Sendable, Codable {
    public var shadowHue: Float        // degrees
    public var shadowSaturation: Float // 0...1
    public var highlightHue: Float
    public var highlightSaturation: Float
    /// -1 (everything counts as shadow) ... +1 (everything as highlight).
    public var balance: Float

    public static let neutral = SplitToning(shadowHue: 215, shadowSaturation: 0,
                                            highlightHue: 45, highlightSaturation: 0, balance: 0)
    public init(shadowHue: Float, shadowSaturation: Float, highlightHue: Float,
                highlightSaturation: Float, balance: Float) {
        self.shadowHue = shadowHue; self.shadowSaturation = shadowSaturation
        self.highlightHue = highlightHue; self.highlightSaturation = highlightSaturation
        self.balance = balance
    }
    public var isNeutral: Bool { shadowSaturation == 0 && highlightSaturation == 0 }
}
