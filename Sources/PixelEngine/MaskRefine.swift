import Foundation

/// Feather and Edge for model masks (subject, sky, Click to Select):
/// done on the mask's pixels on the CPU, once per change, before they go
/// to the GPU. A model's edge is where it is, and these move or soften it.
///
/// - **Edge** grows (positive) or shrinks (negative) the mask by up to
///   3% of the frame's short side. A box blur of that radius turns the
///   hard edge into a ramp; reading the ramp near its foot (grow) or near
///   its top (shrink) moves the edge outward or inward by most of the
///   radius, with a soft edge rather than a stair step.
/// - **Feather** softens the edge with a blur of up to 3% of the short
///   side (three box passes, close to a Gaussian).
extension MaskBitmap {
    /// The radius, in fractions of the short side, that a slider at 1 reaches.
    public static let refineReach: Float = 0.03

    public func refined(feather: Float, edge: Float) -> MaskBitmap {
        let f = min(max(feather, 0), 1), e = min(max(edge, -1), 1)
        if f == 0 && e == 0 { return self }
        let short = Float(min(width, height))
        var values = data.map { Float($0) / 255 }

        let edgeRadius = Int((abs(e) * Self.refineReach * short).rounded())
        if edgeRadius >= 1 {
            let ramp = Self.boxBlur(values, width: width, height: height, radius: edgeRadius)
            if e > 0 {
                for i in values.indices { values[i] = max(values[i], Self.smoothstep(0, 0.15, ramp[i])) }
            } else {
                for i in values.indices { values[i] = min(values[i], Self.smoothstep(0.85, 1, ramp[i])) }
            }
        }

        let featherRadius = Int((f * Self.refineReach * short / 1.7).rounded())
        if featherRadius >= 1 {
            for _ in 0..<3 { values = Self.boxBlur(values, width: width, height: height, radius: featherRadius) }
        }
        return MaskBitmap(width: width, height: height,
                          data: values.map { UInt8(min(max($0 * 255, 0), 255).rounded()) })
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let u = min(max((x - a) / (b - a), 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// Separable box blur with running sums (cost independent of the
    /// radius), clamping at the borders.
    static func boxBlur(_ src: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        let n = Float(2 * r + 1)
        for y in 0..<h {
            let row = y * w
            var sum: Float = 0
            for k in -r...r { sum += src[row + min(max(k, 0), w - 1)] }
            for x in 0..<w {
                tmp[row + x] = sum / n
                sum += src[row + min(x + r + 1, w - 1)] - src[row + max(x - r, 0)]
            }
        }
        for x in 0..<w {
            var sum: Float = 0
            for k in -r...r { sum += tmp[min(max(k, 0), h - 1) * w + x] }
            for y in 0..<h {
                out[y * w + x] = sum / n
                sum += tmp[min(y + r + 1, h - 1) * w + x] - tmp[max(y - r, 0) * w + x]
            }
        }
        return out
    }
}
