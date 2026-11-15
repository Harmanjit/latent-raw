import Foundation
import Metal
import simd

/// The scopes measured over part of the picture only: every pixel counts
/// in proportion to a weight, the selected local adjustment's mask value
/// there (0 outside, 1 fully inside, in between along a feather).
///
/// This is the CPU twin of the scope kernels (Histogram.metal and
/// Scopes.metal): the same sRGB encoding, bins, Rec.709 chroma and
/// Display P3 luminance, so a mask covering the whole frame gives the
/// same shapes the GPU measures. It runs on the small analysis render the
/// scopes already use (a few hundred thousand pixels), and pixels whose
/// weight is zero are skipped, so a small mask costs little.
///
/// Counts are whole numbers in the scope types, so weights are summed in
/// floating point and scaled by `weightScale` before rounding: a pixel
/// fully inside the mask adds `weightScale` to its bins, one half inside
/// half that. Every count, the histogram's `totalPixels` and
/// `aboveSDRWhite` included, carries the same scale, so fractions such as
/// `clippedFraction` are fractions of the masked area.
public enum MaskedScopeAccumulator {
    /// What one fully weighted pixel adds to a bin.
    public static let weightScale: Float = 256

    /// The white the colour kernel's "White on Black" mask overlay writes
    /// into a linear (unencoded) render, ColorPipeline.metal's
    /// `float white = encodeOutput != 0 ? 1.0 : 0.6`. It draws the mask
    /// squared (`overlay * overlay * white`), which `maskWeight` undoes.
    public static let overlayWhiteLinear: Float = 0.6

    /// The mask value behind one pixel of a linear "White on Black"
    /// overlay render: the mean of its channels, unsquared, in 0...1.
    public static func maskWeight(fromOverlay r: Float, _ g: Float, _ b: Float) -> Float {
        let v = (r + g + b) / 3 / overlayWhiteLinear
        guard v.isFinite, v > 0 else { return 0 }
        return min(v, 1).squareRoot()
    }

    /// Which scopes to measure; only those asked for are built.
    public struct Wanted: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let histogram = Wanted(rawValue: 1)
        public static let waveform = Wanted(rawValue: 2)
        public static let vectorscope = Wanted(rawValue: 4)
    }

    /// The scopes asked for; nil where not asked for.
    public struct Result: Sendable {
        public var histogram: Histogram?
        public var waveform: Waveform?
        public var vectorscope: Vectorscope?
    }

    /// Measures `rgba` (linear light, four floats a pixel, row-major,
    /// `width * height` pixels, as the viewport renders) weighted by
    /// `weights` (one per pixel, clamped to 0...1). With every weight 0
    /// the scopes are empty (peak 0), which the views draw as "no data".
    public static func accumulate(rgba: [Float], weights: [Float], width: Int, height: Int,
                                  wanted: Wanted) -> Result {
        let count = width * height
        precondition(rgba.count >= count * 4 && weights.count >= count, "buffers smaller than the image")
        let bins = Histogram.binCount
        let cols = Waveform.columns, rows = Waveform.rows
        let vs = Vectorscope.size

        var hist = wanted.contains(.histogram) ? [Float](repeating: 0, count: bins * 4) : []
        var wave = wanted.contains(.waveform) ? [Float](repeating: 0, count: rows * cols * 3) : []
        var vect = wanted.contains(.vectorscope) ? [Float](repeating: 0, count: vs * vs) : []
        var total: Float = 0, aboveWhite: Float = 0
        let plane = rows * cols
        let lastBin = Float(bins - 1), lastRow = Float(rows - 1), lastCell = Float(vs - 1)

        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                let w = min(max(weights[p], 0), 1)
                guard w > 0 else { continue }
                let linear = SIMD3<Float>(rgba[p * 4], rgba[p * 4 + 1], rgba[p * 4 + 2])
                let c = encode(linear)
                total += w

                if !hist.isEmpty {
                    hist[bin(c.x, lastBin)] += w
                    hist[bins + bin(c.y, lastBin)] += w
                    hist[2 * bins + bin(c.z, lastBin)] += w
                    let clamped = simd_clamp(linear, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                    let lum = (clamped.x * 0.2289746) + (clamped.y * 0.6917385) + (clamped.z * 0.0792869)
                    hist[3 * bins + bin(encode(lum), lastBin)] += w
                    if max(linear.x, max(linear.y, linear.z)) > 1.002 { aboveWhite += w }
                }
                if !wave.isEmpty {
                    let column = min(x * cols / width, cols - 1)
                    wave[bin(c.x, lastRow) * cols + column] += w
                    wave[plane + bin(c.y, lastRow) * cols + column] += w
                    wave[2 * plane + bin(c.z, lastRow) * cols + column] += w
                }
                if !vect.isEmpty {
                    let luma = (0.2126 * c.x) + (0.7152 * c.y) + (0.0722 * c.z)
                    let cb = (c.z - luma) / 1.8556
                    let cr = (c.x - luma) / 1.5748
                    let bx = Int(min(max((cb + 0.5) * lastCell + 0.5, 0), lastCell))
                    let by = Int(min(max((0.5 - cr) * lastCell + 0.5, 0), lastCell))
                    vect[by * vs + bx] += w
                }
            }
        }

        var result = Result()
        if !hist.isEmpty {
            let counts = hist.map(scaled)
            let red = Array(counts[0..<bins]), green = Array(counts[bins..<(2 * bins)])
            let blue = Array(counts[(2 * bins)..<(3 * bins)]), lum = Array(counts[(3 * bins)..<(4 * bins)])
            let peak = max(red.max() ?? 0, max(green.max() ?? 0, blue.max() ?? 0))
            result.histogram = Histogram(red: red, green: green, blue: blue, luminance: lum, peak: peak,
                                         aboveSDRWhite: Int(scaled(aboveWhite)),
                                         totalPixels: Int(scaled(total)))
        }
        if !wave.isEmpty {
            let counts = wave.map(scaled)
            let red = Array(counts[0..<plane]), green = Array(counts[plane..<(2 * plane)])
            let blue = Array(counts[(2 * plane)..<(3 * plane)])
            let peak = max(red.max() ?? 0, max(green.max() ?? 0, blue.max() ?? 0))
            result.waveform = Waveform(red: red, green: green, blue: blue, peak: peak)
        }
        if !vect.isEmpty {
            let counts = vect.map(scaled)
            result.vectorscope = Vectorscope(counts: counts, peak: counts.max() ?? 0)
        }
        return result
    }

    // MARK: Helpers

    private static func scaled(_ v: Float) -> UInt32 {
        UInt32(min((v * weightScale).rounded(), Float(UInt32.max)))
    }

    private static func bin(_ v: Float, _ last: Float) -> Int {
        Int(min(max(v, 0), 1) * last + 0.5)
    }

    /// The scope kernels' sRGB curve, clamping to 0...1 first.
    static func encode(_ v: Float) -> Float {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func encode(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(encode(v.x), encode(v.y), encode(v.z))
    }
}

/// Copies a rendered rgba16Float texture back to the CPU as floats, four
/// a pixel, for measuring there. Through a shared copy when the texture
/// is private to the GPU, as the pipeline's pooled textures are.
public enum ScopeReadback {
    public static func rgbaFloats(_ texture: MTLTexture, commandQueue: MTLCommandQueue) -> [Float]? {
        guard texture.pixelFormat == .rgba16Float else { return nil }
        let w = texture.width, h = texture.height
        var readable = texture
        if texture.storageMode == .private {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w,
                                                                      height: h, mipmapped: false)
            descriptor.storageMode = .shared
            guard let shared = texture.device.makeTexture(descriptor: descriptor),
                  let buffer = commandQueue.makeCommandBuffer(),
                  let blit = buffer.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: texture, to: shared)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            guard buffer.status != .error else { return nil }
            readable = shared
        }
        var halves = [Float16](repeating: 0, count: w * h * 4)
        halves.withUnsafeMutableBytes { bytes in
            readable.getBytes(bytes.baseAddress!, bytesPerRow: w * 8,
                              from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return halves.map { Float($0) }
    }
}
