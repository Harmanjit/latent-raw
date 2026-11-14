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

// MARK: - Edge refine

/// Edge refine for brush and model masks: a guided filter (He, Sun and
/// Tang) that pulls the mask's edge onto the picture's own edges, so a
/// loosely painted sky or a model's soft outline follows the treeline.
///
/// The guide is the picture Auto Mask already builds (`BrushGuide`, the
/// raw at the masks' quarter resolution with the as-shot white balance
/// and no other edit), so a slider move never changes the result and the
/// preview and the export build the same one. Done on the CPU once per
/// change of the mask, the amount or the guide, before the slice goes to
/// the GPU (`BrushMaskSet.sync`); geometric shapes have no slice and are
/// never refined. Without a guide yet the mask is used as it is and
/// refined when the guide arrives.
extension MaskBitmap {
    /// The filter's radius, in fractions of the short side, at 1.
    public static let edgeRefineReach: Float = 0.02

    /// The mask filtered against `guide` (same size, or it is returned
    /// unchanged). `amount` (0…1) sets the radius and how far edges may
    /// move; 0 is exactly nothing.
    public func edgeRefined(_ amount: Float, guide: BrushGuide) -> MaskBitmap {
        let a = min(max(amount, 0), 1)
        guard a > 0, guide.width == width, guide.height == height else { return self }
        let n = width * height
        var luma = [Float](repeating: 0, count: n)
        for i in 0..<n { luma[i] = Float(guide.data[i * 3]) / 255 }
        let p = data.map { Float($0) / 255 }
        let radius = max(1, Int((1 + a * Self.edgeRefineReach * Float(min(width, height))).rounded()))
        // ε in the guide's units (13 stops over 0…1): a smaller one
        // follows fainter edges. About a third of a stop at full strength.
        let eps: Float = 0.0004 + (1 - a) * 0.004
        let q = Self.guidedFilter(p, guide: luma, width: width, height: height, radius: radius, eps: eps)
        return MaskBitmap(width: width, height: height,
                          data: q.map { UInt8(min(max($0 * 255, 0), 255).rounded()) })
    }

    /// The grey guided filter: per window, the mask as a linear function
    /// of the guide (least squares, regularised by `eps`), averaged.
    static func guidedFilter(_ p: [Float], guide i: [Float], width w: Int, height h: Int,
                             radius r: Int, eps: Float) -> [Float] {
        let n = p.count
        var ii = [Float](repeating: 0, count: n), ip = [Float](repeating: 0, count: n)
        for k in 0..<n { ii[k] = i[k] * i[k]; ip[k] = i[k] * p[k] }
        let meanI = boxBlur(i, width: w, height: h, radius: r)
        let meanP = boxBlur(p, width: w, height: h, radius: r)
        let corrI = boxBlur(ii, width: w, height: h, radius: r)
        let corrIP = boxBlur(ip, width: w, height: h, radius: r)
        var a = [Float](repeating: 0, count: n), b = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let variance = max(corrI[k] - meanI[k] * meanI[k], 0)
            let covariance = corrIP[k] - meanI[k] * meanP[k]
            a[k] = covariance / (variance + eps)
            b[k] = meanP[k] - a[k] * meanI[k]
        }
        let meanA = boxBlur(a, width: w, height: h, radius: r)
        let meanB = boxBlur(b, width: w, height: h, radius: r)
        var q = [Float](repeating: 0, count: n)
        for k in 0..<n { q[k] = min(max(meanA[k] * i[k] + meanB[k], 0), 1) }
        return q
    }
}

/// What a mask slice was last refined with: the amount and the guide.
/// nil (no key) is no refinement, so an element that never used the
/// slider uploads exactly as before.
struct MaskEdgeRefineKey: Equatable {
    let amount: Float
    let guide: UUID?

    init?(_ amount: Float, guide: BrushGuide?) {
        guard amount > 0 else { return nil }
        self.amount = amount
        self.guide = guide?.id
    }
}

extension BrushMaskRasterizer {
    /// The bitmap as drawn, rows packed to the width.
    func bitmap() -> MaskBitmap? {
        guard let data else { return nil }
        var out = [UInt8](repeating: 0, count: width * height)
        let rowBytes = bytesPerRow
        out.withUnsafeMutableBytes { dst in
            for y in 0..<height {
                dst.baseAddress!.advanced(by: y * width).copyMemory(from: data.advanced(by: y * rowBytes), byteCount: width)
            }
        }
        return MaskBitmap(width: width, height: height, data: out)
    }
}

extension LocalAdjustment {
    /// Whether any brush or model element has Edge refine on (and so the
    /// session needs the Auto Mask guide).
    public var usesEdgeRefine: Bool {
        maskElements.contains { $0.refine > 0 && $0.shape.usesMaskSlice }
    }
}
