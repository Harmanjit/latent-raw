import Foundation
import CoreML
import Metal
import PixelEngine

/// Neural noise reduction with NAFNet (SIDD, width 32), converted by
/// scripts/convert_nafnet.py. Runs on 256×256 tiles with overlap, on the
/// GPU by default (see CoreMLStore for why not the Neural Engine).
///
/// The network was trained on sRGB-encoded photographs, so the camera
/// RGB is gamma-encoded before it goes in and decoded after. That is
/// enough: camera space after white balance is a near-linear RGB with
/// noise statistics like any other, and the model's job is to tell
/// texture from noise, which doesn't depend on the primaries. Pixels
/// above 1.0 (clipped highlights, or specular values the white balance
/// pushed past white) are handed back unchanged: they carry no noise
/// worth removing and lie outside the model's input range.
public final class AIDenoiser: @unchecked Sendable {
    public static let packageName = "NAFNet_SIDD_width32"
    public static let modelName = EditStack.aiDenoiseModelName
    public static let tile = 256
    /// Overlap between neighbouring tiles; the seam is blended across it.
    public static let overlap = 32

    private let model: MLModel

    public static var isAvailable: Bool { CoreMLStore.isAvailable(packageName) }

    public static func load() async throws -> AIDenoiser {
        AIDenoiser(model: try await CoreMLStore.load(packageName))
    }

    private init(model: MLModel) { self.model = model }

    /// Denoises an RGBA float16 image (row-major, four halfs per pixel)
    /// in place, returning the result. `progress` receives tiles done and
    /// total. Checks for cancellation between tiles.
    public func denoise(_ pixels: [Float16], width: Int, height: Int,
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [Float16] {
        let t = Self.tile, o = Self.overlap, stride = t - o
        let cols = max(1, Int(ceil(Double(max(width - o, 1)) / Double(stride))))
        let rows = max(1, Int(ceil(Double(max(height - o, 1)) / Double(stride))))
        let total = cols * rows

        // Accumulate weighted results; weight ramps linearly across the
        // overlap so seams vanish.
        var accum = [Float](repeating: 0, count: width * height * 3)
        var weight = [Float](repeating: 0, count: width * height)
        let ramp: [Float] = (0..<t).map { i in
            let a = min(Float(i) + 0.5, Float(t - i) - 0.5)
            return min(1, a / Float(o))
        }

        var done = 0
        // A few tiles in flight keeps the GPU busy while the CPU packs the next.
        let inFlight = 3
        var index = 0
        try await withThrowingTaskGroup(of: (Int, Int, [Float]).self) { group in
            func submit(_ i: Int) {
                let row = i / cols, col = i % cols
                let x0 = min(col * stride, max(0, width - t))
                let y0 = min(row * stride, max(0, height - t))
                let input = Self.packTile(pixels, width: width, height: height, x0: x0, y0: y0)
                let model = self.model
                group.addTask {
                    try Task.checkCancellation()
                    let out = try Self.run(model, input: input)
                    return (x0, y0, out)
                }
            }
            while index < min(inFlight, total) { submit(index); index += 1 }
            while let (x0, y0, out) = try await group.next() {
                Self.accumulate(out, into: &accum, weight: &weight, ramp: ramp,
                                width: width, height: height, x0: x0, y0: y0)
                done += 1
                progress?(done, total)
                if index < total { submit(index); index += 1 }
            }
        }

        var result = pixels
        for i in 0..<(width * height) {
            let w = weight[i]
            guard w > 0 else { continue }
            for c in 0..<3 {
                let original = Float(pixels[i * 4 + c])
                if original > 1 { continue }   // clipped: keep
                let encoded = accum[i * 3 + c] / w
                result[i * 4 + c] = Float16(Self.decode(encoded))
            }
        }
        return result
    }

    // MARK: - Pieces

    static func encode(_ v: Float) -> Float { pow(max(v, 0), 1 / 2.2) }
    static func decode(_ v: Float) -> Float { pow(max(v, 0), 2.2) }

    /// Extracts a tile as the model's 1×3×T×T planar float array,
    /// gamma-encoded and clamped to [0, 1]. Tiles that fall off the
    /// image's edge (small images) are padded by clamping coordinates.
    static func packTile(_ pixels: [Float16], width: Int, height: Int, x0: Int, y0: Int) -> [Float] {
        let t = tile
        var out = [Float](repeating: 0, count: 3 * t * t)
        for y in 0..<t {
            let sy = min(y0 + y, height - 1)
            for x in 0..<t {
                let sx = min(x0 + x, width - 1)
                let i = (sy * width + sx) * 4
                for c in 0..<3 {
                    out[c * t * t + y * t + x] = min(encode(Float(pixels[i + c])), 1)
                }
            }
        }
        return out
    }

    static func run(_ model: MLModel, input: [Float]) throws -> [Float] {
        let t = tile
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: t), NSNumber(value: t)], dataType: .float32)
        input.withUnsafeBufferPointer { src in
            array.dataPointer.assumingMemoryBound(to: Float.self).update(from: src.baseAddress!, count: src.count)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: array)])
        let output = try model.prediction(from: provider)
        guard let result = output.featureValue(for: "denoised")?.multiArrayValue else {
            throw AIMaskError.noResult
        }
        return result.floats()
    }

    static func accumulate(_ out: [Float], into accum: inout [Float], weight: inout [Float], ramp: [Float],
                           width: Int, height: Int, x0: Int, y0: Int) {
        let t = tile
        for y in 0..<t {
            let sy = y0 + y
            guard sy < height else { break }
            for x in 0..<t {
                let sx = x0 + x
                guard sx < width else { break }
                let w = ramp[x] * ramp[y]
                let i = sy * width + sx
                weight[i] += w
                for c in 0..<3 {
                    accum[i * 3 + c] += w * min(max(out[c * t * t + y * t + x], 0), 1)
                }
            }
        }
    }
}

/// Runs the denoiser over a whole image session and stores the result
/// where the pipeline blends it in. Shared by the editor and the export
/// worker so both produce identical pixels.
public enum AIDenoiseWorker {
    /// Renders the frame's camera RGB at as-shot white balance, denoises
    /// it, and hands the texture to the session. Returns the seconds it
    /// took. Cancellation is honoured between tiles.
    @discardableResult
    public static func run(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                           denoiser: AIDenoiser,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> TimeInterval {
        let start = Date()
        var asShot = EditParameters()
        asShot.whiteBalance = session.asShotWhiteBalance
        let camera = try pipeline.renderCameraRGB(session, scale: .full, parameters: asShot)
        let width = camera.width, height = camera.height
        let pixels = try TextureReadback.float16Pixels(of: camera, gpu: gpu)

        let denoised = try await denoiser.denoise(pixels, width: width, height: height, progress: progress)
        try Task.checkCancellation()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else {
            throw AIMaskError.noResult
        }
        denoised.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: width * 8)
        }
        session.setAIDenoised(texture, model: AIDenoiser.modelName)
        return Date().timeIntervalSince(start)
    }
}
