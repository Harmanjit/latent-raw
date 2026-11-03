import Foundation
import Metal
import simd
import ColorKit

/// The image as the colour controls see it: display-referred, gamma 2.2,
/// in the working primaries, which is the domain the grading stage of
/// ColorPipeline.metal works in. Point Colour's picker and Auto B&W read
/// it from a small analysis render.
public struct GradingImage: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, one colour per pixel, each channel about 0...1.
    public let pixels: [SIMD3<Float>]

    public init(width: Int, height: Int, pixels: [SIMD3<Float>]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Which controls have already acted on the colours read.
    public enum Stage: Sendable {
        /// Curves only: what the Black & White mix sees.
        case beforeColourMix
        /// Curves and HSL: what Point Colour sees.
        case beforePointColour
    }

    /// Renders the image small with the controls from `stage` on turned
    /// off, so the colours are those the control is about to change.
    public static func render(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                              parameters: EditParameters, stage: Stage) throws -> GradingImage {
        var p = parameters
        if stage == .beforeColourMix { p.hsl = .neutral }
        p.vibrance = 0
        p.splitToning = .neutral
        let calibration = p.colour.calibration
        p.colour = ColourControls(calibration: calibration)
        let output = RenderOutput(space: .rec2020, headroom: 1, encoded: false, toneMapped: true)
        let texture = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: output)
        let halfs = try TextureReadback.float16Pixels(of: texture, gpu: gpu)
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(halfs.count / 4)
        for i in stride(from: 0, to: halfs.count, by: 4) {
            let linear = SIMD3<Float>(Float(halfs[i]), Float(halfs[i + 1]), Float(halfs[i + 2]))
            pixels.append(Self.perceptual(linear))
        }
        return GradingImage(width: texture.width, height: texture.height, pixels: pixels)
    }

    /// Linear display value -> the grading stage's gamma 2.2 value.
    static func perceptual(_ linear: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(pow(max(linear.x, 0), 1 / 2.2), pow(max(linear.y, 0), 1 / 2.2), pow(max(linear.z, 0), 1 / 2.2))
    }

    /// The mean colour of a small square around a point given as a
    /// fraction of the frame (0...1 each way), so one noisy pixel can't
    /// decide the pick. Nil outside the frame.
    public func averageColour(at normalized: SIMD2<Float>, radius: Int = 2) -> SIMD3<Float>? {
        guard width > 0, height > 0, normalized.x >= 0, normalized.x <= 1,
              normalized.y >= 0, normalized.y <= 1 else { return nil }
        let cx = min(Int(normalized.x * Float(width)), width - 1)
        let cy = min(Int(normalized.y * Float(height)), height - 1)
        var sum = SIMD3<Float>(repeating: 0)
        var n: Float = 0
        for y in max(cy - radius, 0)...min(cy + radius, height - 1) {
            for x in max(cx - radius, 0)...min(cx + radius, width - 1) {
                sum += pixels[y * width + x]; n += 1
            }
        }
        return n > 0 ? sum / n : nil
    }
}

extension BlackAndWhite {
    /// Auto: a grey mix for this image that renders each colour at the
    /// lightness it appears to have in colour.
    ///
    /// A plain luminance conversion makes a red flower and the green leaves
    /// around it the same grey when their luminance matches, though in
    /// colour the red looks much brighter: saturated colours look lighter
    /// than greys of the same luminance (the Helmholtz-Kohlrausch effect).
    /// Fairchild and Pirrotta's estimate of that effect gives, for each
    /// pixel, the CIE lightness it seems to have; the band's mix is then
    /// the least-squares fit, over the band's pixels and weighted by how
    /// colourful each is, of the shader's grey change to that target. A
    /// band the image barely uses keeps 0.
    public static func autoMix(for image: GradingImage) -> [Float] {
        autoMix(pixels: image.pixels)
    }

    static func autoMix(pixels: [SIMD3<Float>]) -> [Float] {
        var numerator = [Double](repeating: 0, count: 8)
        var denominator = [Double](repeating: 0, count: 8)
        let toXYZ = ColorKit.rec2020ToXYZ
        let white = SIMD3<Float>(0.95047, 1, 1.08883)
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }

        for raw in pixels {
            let p = simd_clamp(raw, SIMD3(repeating: 0), SIMD3(repeating: 1))
            let hsv = PointColour.hsv(p)
            guard hsv.y > 0.05 else { continue }
            // The grey the shader starts from (`workingLuma`, on these
            // gamma 2.2 values).
            let grey = 0.2627 * p.x + 0.6780 * p.y + 0.0593 * p.z
            guard grey > 0.01 else { continue }
            let linear = SIMD3(pow(p.x, 2.2), pow(p.y, 2.2), pow(p.z, 2.2))
            let xyz = toXYZ * linear / white
            let fx = f(xyz.x), fy = f(xyz.y), fz = f(xyz.z)
            let L = 116 * fy - 16, a = 500 * (fx - fy), b = 200 * (fy - fz)
            let chroma = (a * a + b * b).squareRoot()
            let hue = atan2(b, a) * 180 / .pi
            let lift = (2.5 - 0.025 * L) * (0.116 * abs(sin((hue - 90) / 2 * .pi / 180)) + 0.085) * chroma
            let target = min(max(L + lift, 0), 100)
            // Lightness back to luminance, then to the gamma 2.2 grey.
            let fyT = (target + 16) / 116
            let yT = fyT > 0.2069 ? fyT * fyT * fyT : (fyT - 16.0 / 116.0) / 7.787
            let greyTarget = pow(max(yT, 1e-6), 1 / 2.2)
            let wanted = log2(greyTarget / grey)
            // The shader's grey change for mix m is 2^(m * s * 1.5).
            let reach = Double(hsv.y * 1.5)
            let weights = BlackAndWhite.bandWeights(hue: hsv.x)
            for band in 0..<8 where weights[band] > 0 {
                let w = Double(weights[band])
                numerator[band] += w * reach * Double(wanted)
                denominator[band] += w * reach * reach
            }
        }
        // A band needs the weight of about 0.2% of the frame at full
        // colour before its mix means anything.
        let minimum = Double(pixels.count) * 0.002 * 2.25
        return (0..<8).map { band in
            guard denominator[band] > max(minimum, 1e-9) else { return 0 }
            let m = Float(numerator[band] / denominator[band])
            return (min(max(m, -1), 1) * 100).rounded() / 100
        }
    }

    /// The HSL panel's band weights for a hue in degrees, as `hslBandWeights`
    /// in ColorPipeline.metal computes them: the two bands either side,
    /// linearly.
    static func bandWeights(hue: Float) -> [Float] {
        let centres = HSLAdjustments.bandCentres
        var w = [Float](repeating: 0, count: 8)
        if hue >= centres[7] {
            let t = (hue - centres[7]) / (360 - centres[7])
            w[7] += 1 - t; w[0] += t
            return w
        }
        for i in 0..<7 where hue >= centres[i] && hue < centres[i + 1] {
            let t = (hue - centres[i]) / (centres[i + 1] - centres[i])
            w[i] += 1 - t; w[i + 1] += t
            return w
        }
        w[0] = 1
        return w
    }
}
