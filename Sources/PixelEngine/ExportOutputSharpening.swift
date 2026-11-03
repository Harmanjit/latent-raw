import Foundation
import Metal

/// Output sharpening, as Lightroom's export offers it: a final sharpen
/// made for where the file is going, applied after the resize so it
/// suits the file's own pixels (`ExportSharpen.metal`).
///
/// Why it is needed: shrinking a photo averages its pixels, and print
/// spreads ink into the paper. Either way the result looks softer than the
/// photo did on screen at 100%, and the right amount of crispness to add
/// back depends on the destination:
///
/// - **Screen**: a fine radius (well under a pixel's width of blur) and a
///   light touch; a monitor shows every pixel as it is.
/// - **Matte paper**: ink spreads most into uncoated paper, so the most
///   sharpening, over a radius that grows with the print resolution
///   (more pixels per inch means each pixel is smaller on paper).
/// - **Glossy paper**: holds detail better than matte, so less.
///
/// Low, Standard and High scale the amount. The edit's own sharpening (in
/// Develop › Detail) is untouched; this is extra, for the file only.
public struct OutputSharpening: Sendable, Hashable, Codable {
    public enum Medium: String, Sendable, Codable, CaseIterable {
        case screen, matte, glossy

        public var title: String {
            switch self {
            case .screen: "Screen"
            case .matte: "Matte paper"
            case .glossy: "Glossy paper"
            }
        }
    }

    public enum Strength: String, Sendable, Codable, CaseIterable {
        case low, standard, high

        public var title: String {
            switch self {
            case .low: "Low"
            case .standard: "Standard"
            case .high: "High"
            }
        }
    }

    public var medium: Medium
    public var strength: Strength

    public init(medium: Medium = .screen, strength: Strength = .standard) {
        self.medium = medium
        self.strength = strength
    }

    /// The print resolution assumed for paper when the export writes none.
    public static let defaultPrintPPI = 300.0
    /// Most taps either side of a pixel (a 9 x 9 neighbourhood).
    static let maximumRadius = 4

    /// The filter's settings for a file at `ppi`.
    public struct Filter: Equatable, Sendable {
        /// Gaussian radius in output pixels.
        public var sigma: Float
        /// Share of the detail added back.
        public var amount: Float
        /// Detail smaller than this (in encoded 0...1 units) is ignored.
        public var threshold: Float
        /// Taps either side.
        public var radius: Int
    }

    public func filter(ppi: Double?) -> Filter {
        let scale: [Strength: Float]
        let sigma: Float
        let threshold: Float
        switch medium {
        case .screen:
            sigma = 0.6
            scale = [.low: 0.4, .standard: 0.7, .high: 1.0]
            threshold = 1.5 / 255
        case .matte, .glossy:
            // A pixel at 240 ppi is about a tenth of a millimetre; ink
            // spread is roughly constant on paper, so in pixels the radius
            // grows with the resolution.
            let ppi = Float(ppi ?? Self.defaultPrintPPI)
            sigma = min(max(0.6 * ppi / 240, 0.5), 1.6)
            scale = medium == .matte ? [.low: 0.7, .standard: 1.1, .high: 1.5]
                                     : [.low: 0.5, .standard: 0.8, .high: 1.15]
            threshold = 1 / 255
        }
        let radius = min(max(Int((2.5 * sigma).rounded(.up)), 1), Self.maximumRadius)
        return Filter(sigma: sigma, amount: scale[strength] ?? 0.7, threshold: threshold, radius: radius)
    }

    /// The filter on the CPU, the shader's twin, for tests to compare
    /// against. `pixels` are RGB rows, top first.
    public static func reference(_ pixels: [SIMD3<Float>], width: Int, height: Int,
                                 filter: Filter) -> [SIMD3<Float>] {
        func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        var out = pixels
        let k = -0.5 / (filter.sigma * filter.sigma)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0, weights: Float = 0
                for dy in -filter.radius...filter.radius {
                    let sy = min(max(y + dy, 0), height - 1)
                    for dx in -filter.radius...filter.radius {
                        let sx = min(max(x + dx, 0), width - 1)
                        let w = exp(Float(dx * dx + dy * dy) * k)
                        sum += w * luma(pixels[sy * width + sx])
                        weights += w
                    }
                }
                let c = pixels[y * width + x]
                var detail = luma(c) - sum / weights
                detail = (detail < 0 ? -1 : 1) * max(abs(detail) - filter.threshold, 0)
                out[y * width + x] = (c + filter.amount * detail).clamped(lowerBound: .zero, upperBound: .one)
            }
        }
        return out
    }
}

/// Mirror of `OutputSharpenUniforms` in ExportSharpen.metal: three floats
/// and an int, 16 bytes.
struct OutputSharpenUniforms {
    var sigma: Float
    var amount: Float
    var threshold: Float
    var radius: Int32
}

extension Exporter {
    /// The intermediate an export is packed into when it is to be sharpened:
    /// float, so the sharpen reads the resized pixels before they are
    /// quantised (32-bit for a 16-bit file, whose steps half floats can't
    /// hold near white).
    func sharpeningIntermediate(width: Int, height: Int, bitsPerComponent: Int) throws -> MTLTexture {
        guard let texture = gpu.makePrivateTexture(width: width, height: height,
                                                   pixelFormat: bitsPerComponent == 16 ? .rgba32Float : .rgba16Float)
        else { throw ExportError.readbackFailed }
        return texture
    }

    /// Sharpens `source` (the packed, resized pixels, display-encoded)
    /// into `dest`, the file's 8- or 16-bit texture.
    func applyOutputSharpening(_ sharpening: OutputSharpening, ppi: Double?,
                               from source: MTLTexture, into dest: MTLTexture) throws {
        let filter = sharpening.filter(ppi: ppi)
        let pso = try gpu.lazyPipeline(.exportOutputSharpen)
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else { throw ExportError.readbackFailed }
        encoder.setComputePipelineState(pso)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(dest, index: 1)
        var uniforms = OutputSharpenUniforms(sigma: filter.sigma, amount: filter.amount,
                                             threshold: filter.threshold, radius: Int32(filter.radius))
        encoder.setBytes(&uniforms, length: MemoryLayout<OutputSharpenUniforms>.size, index: 0)
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (dest.width + tw - 1) / tw, height: (dest.height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status != .error else { throw ExportError.readbackFailed }
    }
}
