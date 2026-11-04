import Foundation
import Metal
import simd

/// Distraction Removal › Reflections (docs/wiki/Develop.md, "Reflections"):
/// takes the reflection of a window pane off the scene behind it.
///
/// The edit holds only the amount and which model it was set on. The
/// correction itself is derived, like Lens Blur's depth map: MLKit runs a
/// reflection-removal model the user imported (none is bundled; see
/// scripts/convert_reflection_removal.py) on the analysis render, and
/// turns what the model kept into a per-channel gain map at the model's
/// resolution (`ReflectionMap`). The session holds the map, the export
/// makes it again, and the render multiplies the graded picture by the
/// gains, mixed in by the amount. With no model installed nothing is made
/// and the stage never runs: there is no stand-in that would only pretend.
public struct ReflectionRemoval: Codable, Equatable, Sendable {
    /// 0 (off) … 100: how much of the model's result to take, from the
    /// photo as shot to the model's de-reflected picture.
    public var amount: Float
    /// The model the amount was set on, "<id>@<version>". Nil until the
    /// amount first moves off zero.
    public var model: String?

    public init(amount: Float = 0, model: String? = nil) {
        self.amount = amount
        self.model = model
    }

    public static let neutral = ReflectionRemoval()

    public var isActive: Bool { amount.isFinite && amount > 0 }
    /// Nothing to store: the module is absent from the edit, so an edit
    /// that never used it encodes exactly as before.
    public var isNeutral: Bool { !isActive }

    /// A render can trust it: the amount in 0…100, 0 when not finite.
    public var sanitized: ReflectionRemoval {
        var s = self
        s.amount = amount.isFinite ? min(max(amount, 0), 100) : 0
        return s
    }

    private enum CodingKeys: String, CodingKey { case amount, model }

    /// Lenient, like Lens Blur: a missing key keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? 0
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

/// What a reflection-removal model made of a photo: for each pixel of its
/// output, the gain (linear light, per channel) that takes the photo to
/// the model's de-reflected picture. In sensor orientation on the
/// analysis render's grid (the edit's lens and keystone geometry, whole
/// frame), so the render samples it the way Lens Blur samples depth.
///
/// Gains are stored as bytes, `gainRange` at 255, four per pixel (RGBA,
/// alpha unused) so the bytes go straight into an rgba8Unorm texture. A
/// reflection only ever adds light, so most gains are below 1; the range
/// leaves room above it for a model that also restores what the glass
/// dimmed.
public struct ReflectionMap: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// width × height × 4 bytes.
    public var gains: [UInt8]
    /// The model that made it, "<id>@<version>".
    public var source: String

    public static let gainRange: Float = 2

    public init(width: Int, height: Int, gains: [UInt8], source: String) {
        self.width = width
        self.height = height
        self.gains = gains
        self.source = source
    }

    public var isValid: Bool { width > 0 && height > 0 && gains.count == width * height * 4 }

    /// A gain as its stored byte; not finite reads as no change.
    public static func byte(forGain g: Float) -> UInt8 {
        guard g.isFinite else { return byte(forGain: 1) }
        return UInt8((min(max(g, 0), gainRange) / gainRange * 255).rounded())
    }

    public static func gain(forByte b: UInt8) -> Float { Float(b) / 255 * gainRange }

    /// The gains of one pixel, for tests and the panel.
    public func gain(x: Int, y: Int) -> SIMD3<Float> {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return SIMD3(Self.gain(forByte: gains[i]), Self.gain(forByte: gains[i + 1]), Self.gain(forByte: gains[i + 2]))
    }
}

/// Mirror of `ReflectionParamsGPU` in Reflections.metal.
struct ReflectionParamsGPU {
    var tileOrigin: SIMD2<Float>
    var sensorSize: SIMD2<Float>
    var binSpan: Float
    var amount: Float
    var isLinear: UInt32
    var padding: Float = 0
}

/// Encodes the reflection stage (Shaders/Reflections.metal): the graded
/// image times the session's gain map, mixed in by the amount. Separate
/// from RenderPipeline so tests can run it on a synthetic texture.
enum ReflectionStage {
    static func params(_ removal: ReflectionRemoval, geometry g: LensBlurStage.Geometry) -> ReflectionParamsGPU {
        ReflectionParamsGPU(tileOrigin: g.tileOrigin, sensorSize: g.sensorSize, binSpan: g.binSpan,
                            amount: removal.sanitized.amount / 100, isLinear: g.isLinear ? 1 : 0)
    }

    /// The result, in a texture of the session's in the reflections role
    /// (reflectionsPreview for the binned preview).
    static func encode(input: MTLTexture, gains: MTLTexture, removal: ReflectionRemoval,
                       geometry: LensBlurStage.Geometry, session: ImageSession, preview: Bool,
                       gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height, pixelFormat: .rgba16Float,
                                         role: preview ? .reflectionsPreview : .reflections)
        try encode(input: input, output: output, gains: gains, removal: removal, geometry: geometry,
                   gpu: gpu, commandBuffer: commandBuffer)
        return output
    }

    /// The same into a texture the caller owns (the tests' entry point).
    static func encode(input: MTLTexture, output: MTLTexture, gains: MTLTexture, removal: ReflectionRemoval,
                       geometry: LensBlurStage.Geometry, gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        let pso = try gpu.lazyPipeline(.reflectionApply)
        var p = params(removal, geometry: geometry)
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(gains, index: 2)
        encoder.setBytes(&p, length: MemoryLayout<ReflectionParamsGPU>.stride, index: 0)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (input.width + tw - 1) / tw, height: (input.height + th - 1) / th,
                                             depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
    }
}

// The gain map on the session, like the depth map (ImageSession+Depth.swift):
// made by MLKit, handed over, uploaded once. Small (a model's output), so
// memory pressure leaves it alone.
extension ImageSession {
    public var reflectionMap: ReflectionMap? { reflectionStore?.map }

    public var hasReflectionMap: Bool { reflectionStore != nil }

    /// Replaces the gain map (nil drops it); an invalid one is dropped.
    public func setReflectionMap(_ map: ReflectionMap?) {
        reflectionStore = map.flatMap { $0.isValid ? ($0, nil) : nil }
    }

    /// The gain map as an rgba8Unorm texture at its own size; nil without
    /// a map, which tells the pipeline to skip the stage.
    func reflectionTexture() -> MTLTexture? {
        guard let store = reflectionStore else { return nil }
        if let texture = store.texture { return texture }
        let map = store.map
        guard map.isValid else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: map.width,
                                                         height: map.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = [.shaderRead]
        guard let texture = gpu.device.makeTexture(descriptor: d) else { return nil }
        map.gains.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, map.width, map.height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: map.width * 4)
        }
        reflectionStore = (map, texture)
        return texture
    }
}
