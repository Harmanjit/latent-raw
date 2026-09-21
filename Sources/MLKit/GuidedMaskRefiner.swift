import Foundation
import CoreGraphics
import PixelEngine

/// Sharpens a coarse subject mask against the image it came from, for
/// models whose manifest says `refine: guided` (U²-Net's edges are soft
/// at its 320 px; docs/Retouch.md §5).
///
/// He, Sun and Tang's guided filter: in every window of radius `radius`
/// the mask is fitted as `a·I + b` over the guide's luminance `I`, and
/// each pixel takes the mean of the fits that cover it. Where the guide
/// is flat the fit is a constant (the mask's local mean); across an edge
/// in the guide the mask follows it, so a blurred boundary snaps to the
/// picture's own. `epsilon` says how much luminance variation counts as
/// an edge; 1e-3 on a 0…1 guide is the paper's usual choice.
public enum GuidedMaskRefiner {
    /// Upsamples `mask` to `guide`'s size with a guided filter on the
    /// guide's luminance (CPU, box sums). Radius and epsilon are in guide
    /// pixels and squared luminance.
    public static func refine(_ mask: MaskBitmap, guide: CGImage, radius: Int = 8, epsilon: Float = 1e-3) -> MaskBitmap {
        let width = guide.width, height = guide.height
        guard width > 0, height > 0, let luminance = luminance(of: guide) else { return mask }
        let coarse = mask.resampled(width: width, height: height)
        let count = width * height
        var p = [Float](repeating: 0, count: count)
        for i in 0..<count { p[i] = Float(coarse.data[i]) / 255 }
        let I = luminance

        // The five window means the fit needs, each one box filter.
        let meanI = boxFiltered(I, width: width, height: height, radius: radius)
        let meanP = boxFiltered(p, width: width, height: height, radius: radius)
        var product = [Float](repeating: 0, count: count)
        for i in 0..<count { product[i] = I[i] * I[i] }
        let corrI = boxFiltered(product, width: width, height: height, radius: radius)
        for i in 0..<count { product[i] = I[i] * p[i] }
        let corrIP = boxFiltered(product, width: width, height: height, radius: radius)

        // a = cov(I, p) / (var(I) + ε), b = mean(p) − a·mean(I), per window.
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let variance = corrI[i] - meanI[i] * meanI[i]
            let covariance = corrIP[i] - meanI[i] * meanP[i]
            a[i] = covariance / (variance + epsilon)
            b[i] = meanP[i] - a[i] * meanI[i]
        }
        let meanA = boxFiltered(a, width: width, height: height, radius: radius)
        let meanB = boxFiltered(b, width: width, height: height, radius: radius)

        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let q = meanA[i] * I[i] + meanB[i]
            out[i] = UInt8(min(max(q, 0), 1) * 255 + 0.5)
        }
        return MaskBitmap(width: width, height: height, data: out)
    }

    /// The guide as 0…1 luminance, drawn once into an 8-bit grey context
    /// (Core Graphics does the colour conversion).
    static func luminance(of image: CGImage) -> [Float]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var out = [Float](repeating: 0, count: width * height)
        for i in 0..<out.count { out[i] = Float(bytes[i]) / 255 }
        return out
    }

    /// The mean over the (2r+1)² window round each pixel, clipped at the
    /// edges (the window shrinks there rather than reading outside).
    /// Separable running sums: one pass along rows, one down columns.
    static func boxFiltered(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let r = max(radius, 0)
        var rows = [Float](repeating: 0, count: width * height)
        var out = [Float](repeating: 0, count: width * height)
        values.withUnsafeBufferPointer { source in
            rows.withUnsafeMutableBufferPointer { rows in
                for y in 0..<height {
                    let row = y * width
                    var sum: Float = 0
                    var n = 0
                    // Prime the window for x = 0, then slide it.
                    for x in 0...min(r, width - 1) { sum += source[row + x]; n += 1 }
                    for x in 0..<width {
                        rows[row + x] = sum / Float(n)
                        let leaving = x - r, entering = x + r + 1
                        if leaving >= 0 { sum -= source[row + leaving]; n -= 1 }
                        if entering < width { sum += source[row + entering]; n += 1 }
                    }
                }
            }
        }
        rows.withUnsafeBufferPointer { rows in
            out.withUnsafeMutableBufferPointer { out in
                var sums = [Float](repeating: 0, count: width)
                var n = 0
                for y in 0...min(r, height - 1) {
                    for x in 0..<width { sums[x] += rows[y * width + x] }
                    n += 1
                }
                for y in 0..<height {
                    let scale = 1 / Float(n)
                    for x in 0..<width { out[y * width + x] = sums[x] * scale }
                    let leaving = y - r, entering = y + r + 1
                    if leaving >= 0 {
                        for x in 0..<width { sums[x] -= rows[leaving * width + x] }
                        n -= 1
                    }
                    if entering < height {
                        for x in 0..<width { sums[x] += rows[entering * width + x] }
                        n += 1
                    }
                }
            }
        }
        return out
    }
}
