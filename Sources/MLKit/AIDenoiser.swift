import Foundation
import CoreML
import Metal
import os
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
///
/// The encoded values are lifted onto a pedestal (`pedestal`) before they
/// go in, because the network itself is unstable near black: a tile whose
/// encoded mean is below about 0.07, with little texture or noise (deep,
/// smooth shadows in an underexposed frame) sends NAFNet's deepest encoder
/// into a runaway, and the tile comes out as a flat block of garbage, up to
/// ten times out of range. That happens in PyTorch at float32 with the
/// published weights too, so it is the model, not Core ML or float16.
/// Above about 0.08 the network is well behaved at every noise level, and
/// it is close to shift-equivariant there, so mapping [0, 1] onto
/// [pedestal, 1] and back costs nothing measurable.
public final class AIDenoiser: @unchecked Sendable {
    /// The bundled network and the optional, larger one (`OptionalModel`).
    public enum Variant: String, CaseIterable, Sendable {
        case standard, high

        public var packageName: String {
            switch self {
            case .standard: "NAFNet_SIDD_width32"
            case .high: "NAFNet_SIDD_width64"
            }
        }
        /// Recorded in the edit stack, so a file says which network made it.
        public var modelName: String {
            switch self {
            case .standard: "nafnet-sidd-w32"
            case .high: "nafnet-sidd-w64"
            }
        }
        public var displayName: String {
            switch self {
            case .standard: "Standard (bundled)"
            case .high: "High quality (downloaded)"
            }
        }
        public var isAvailable: Bool { CoreMLStore.isAvailable(packageName) }
    }

    public static let tile = 256
    /// Overlap between neighbouring tiles; the seam is blended across it.
    public static let overlap = 32
    /// Encoded black is fed to the network at this level (see above).
    static let pedestal: Float = 0.15
    /// A tile whose output drifts further than this from its input, in
    /// encoded units averaged over 16×16 blocks, is a failed prediction:
    /// denoising moves local means by well under 0.02.
    static let divergenceLimit: Float = 0.05
    static let preferenceKey = "latent.aiDenoiseModel"

    public let variant: Variant
    private let model: MLModel

    /// The user's choice, falling back to the bundled model when the
    /// chosen one isn't installed. Read by the editor and the export
    /// worker alike, so exports match the screen.
    public static var preferredVariant: Variant {
        get {
            let stored = UserDefaults.standard.string(forKey: preferenceKey).flatMap(Variant.init(rawValue:)) ?? .standard
            return stored.isAvailable ? stored : .standard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }

    public static var isAvailable: Bool { Variant.standard.isAvailable }
    public var modelName: String { variant.modelName }

    public static func load(_ variant: Variant? = nil) async throws -> AIDenoiser {
        let v = variant ?? preferredVariant
        return AIDenoiser(variant: v, model: try await CoreMLStore.load(v.packageName))
    }

    private init(variant: Variant, model: MLModel) { self.variant = variant; self.model = model }

    /// One loaded network per variant for the export worker, print and
    /// contact-sheet cells. Loading builds a fresh MLModel from the
    /// compiled copy every time, so a batch of N exports used to load the
    /// 56 MB network N times. A failed load is not kept, so the next ask
    /// tries again.
    private static let sharedLoads = OSAllocatedUnfairLock<[Variant: Task<AIDenoiser, Error>]>(initialState: [:])

    /// The loaded network for `variant` (the preferred one by default),
    /// loading it on the first ask; later asks get the same instance until
    /// `releaseShared()`.
    public static func shared(_ variant: Variant? = nil) async throws -> AIDenoiser {
        let v = variant ?? preferredVariant
        let task = sharedLoads.withLock { loads in
            if let running = loads[v] { return running }
            let task = Task<AIDenoiser, Error> { try await load(v) }
            loads[v] = task
            return task
        }
        do {
            return try await task.value
        } catch {
            sharedLoads.withLock { loads in if loads[v] == task { loads[v] = nil } }
            throw error
        }
    }

    /// Memory pressure: drops the shared networks. A denoise in flight
    /// keeps its own reference until it finishes.
    public static func releaseShared() {
        sharedLoads.withLock { $0.removeAll() }
    }

    /// Denoises an RGBA float16 image (row-major, four halfs per pixel),
    /// returning the result. `white` is the largest value an unclipped
    /// pixel can take (after white balance a channel can sit well above
    /// 1.0); everything is scaled by it so the network sees [0, 1].
    /// Pixels at or near clipping fade back to the original with a soft
    /// ramp — per pixel, never per channel, which would leave a coloured
    /// grid where one channel clips and another doesn't. `progress`
    /// receives tiles done and total. Checks for cancellation between tiles.
    public func denoise(_ pixels: [Float16], width: Int, height: Int, white: Float = 1,
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [Float16] {
        // Through self, which is Sendable, rather than the MLModel itself.
        return try await Self.assemble(pixels, width: width, height: height, white: white,
                                       progress: progress) { [self] input in
            var out = try Self.unpack(Self.run(self.model, input: input))
            // Should the network still fail on some tile, keep
            // the noisy original there rather than a broken block.
            if Self.diverged(input: input, output: out) { out = Self.unpack(input) }
            return out
        }
    }

    /// The tiling around `denoise`: packs each tile, hands it to
    /// `runTile` (packed input in, unpacked output out) and blends the
    /// answers back into the frame. Separate from the network so tests can
    /// check the blending with a stand-in.
    ///
    /// The weighted sums are kept for one band of rows, a tile high, rather
    /// than the whole frame: tile rows go top to bottom, so once the next
    /// row of tiles starts lower down, the rows above it are final and are
    /// written into the result and dropped. Full-frame float sums cost 16
    /// bytes a pixel, about 1.6 GB for a 100 MP frame, on top of the input
    /// and the result.
    static func assemble(_ pixels: [Float16], width: Int, height: Int, white: Float,
                         progress: (@Sendable (Int, Int) -> Void)?,
                         runTile: @escaping @Sendable ([Float]) throws -> [Float]) async throws -> [Float16] {
        let white = max(white, 1e-3)
        let t = Self.tile, o = Self.overlap, stride = t - o
        let cols = max(1, Int(ceil(Double(max(width - o, 1)) / Double(stride))))
        let rows = max(1, Int(ceil(Double(max(height - o, 1)) / Double(stride))))
        let total = cols * rows
        func tileX(_ col: Int) -> Int { min(col * stride, max(0, width - t)) }
        func tileY(_ row: Int) -> Int { min(row * stride, max(0, height - t)) }

        // Accumulate weighted results; weight ramps linearly across the
        // overlap so seams vanish. The band holds rows bandTop..<bandTop+bandRows.
        let bandRows = min(t, height)
        var accum = [Float](repeating: 0, count: width * bandRows * 3)
        var weight = [Float](repeating: 0, count: width * bandRows)
        var bandTop = 0
        let ramp: [Float] = (0..<t).map { i in
            let a = min(Float(i) + 0.5, Float(t - i) - 0.5)
            return min(1, a / Float(o))
        }

        var result = pixels
        /// Writes the finished rows lo..<hi (all inside the band) into `result`.
        func finish(_ lo: Int, _ hi: Int) {
            for y in lo..<hi {
                for x in 0..<width {
                    let i = y * width + x, bi = (y - bandTop) * width + x
                    let w = weight[bi]
                    guard w > 0 else { continue }
                    let r = Float(pixels[i * 4]), g = Float(pixels[i * 4 + 1]), b = Float(pixels[i * 4 + 2])
                    // Near-clipped pixels keep their original value, fading in
                    // over the last 15% below white so there is no visible edge.
                    let peak = max(r, g, b) / white
                    let keep = Self.smoothstep(0.85, 1.0, peak)
                    if keep >= 1 { continue }
                    for c in 0..<3 {
                        let original = Float(pixels[i * 4 + c])
                        let denoised = Self.decode(accum[bi * 3 + c] / w) * white
                        result[i * 4 + c] = Float16(denoised + (original - denoised) * keep)
                    }
                }
            }
        }
        /// Finishes the rows above `top` and slides the band down to start there.
        func moveBand(to top: Int) {
            finish(bandTop, min(top, bandTop + bandRows))
            let shift = min(top - bandTop, bandRows)
            let kept = (bandRows - shift) * width
            for k in 0..<kept {
                weight[k] = weight[k + shift * width]
                for c in 0..<3 { accum[k * 3 + c] = accum[(k + shift * width) * 3 + c] }
            }
            for k in kept..<(bandRows * width) {
                weight[k] = 0
                for c in 0..<3 { accum[k * 3 + c] = 0 }
            }
            bandTop = top
        }

        var done = 0
        // Tiles finish out of order, and up to `inFlight` of them may
        // belong to later rows than the band's; those wait here.
        var waiting: [Int: [(Int, [Float])]] = [:]
        var doneInRow = [Int](repeating: 0, count: rows)
        var bandRow = 0
        // A few tiles in flight keeps the GPU busy while the CPU packs the next.
        let inFlight = 3
        var index = 0
        try await withThrowingTaskGroup(of: (Int, Int, [Float]).self) { group in
            func submit(_ i: Int) {
                let row = i / cols, col = i % cols
                let x0 = tileX(col), y0 = tileY(row)
                let input = Self.packTile(pixels, width: width, height: height, x0: x0, y0: y0, white: white)
                group.addTask {
                    try Task.checkCancellation()
                    return (row, x0, try runTile(input))
                }
            }
            while index < min(inFlight, total) { submit(index); index += 1 }
            while let (row, x0, out) = try await group.next() {
                if row == bandRow {
                    Self.accumulate(out, into: &accum, weight: &weight, ramp: ramp,
                                    width: width, height: height, x0: x0, y0: tileY(row), top: bandTop)
                } else {
                    waiting[row, default: []].append((x0, out))
                }
                doneInRow[row] += 1
                // A finished row of tiles: slide the band to the next row
                // and blend in what already came back for it.
                while bandRow < rows - 1, doneInRow[bandRow] == cols {
                    bandRow += 1
                    moveBand(to: tileY(bandRow))
                    for (x, tileOut) in waiting.removeValue(forKey: bandRow) ?? [] {
                        Self.accumulate(tileOut, into: &accum, weight: &weight, ramp: ramp,
                                        width: width, height: height, x0: x, y0: tileY(bandRow), top: bandTop)
                    }
                }
                done += 1
                progress?(done, total)
                if index < total { submit(index); index += 1 }
            }
        }
        finish(bandTop, min(height, bandTop + bandRows))
        return result
    }

    // MARK: - Pieces

    static func encode(_ v: Float) -> Float { pow(max(v, 0), 1 / 2.2) }
    static func decode(_ v: Float) -> Float { pow(max(v, 0), 2.2) }
    static func lift(_ v: Float) -> Float { pedestal + (1 - pedestal) * v }
    /// Undoes `lift` on a model output and clamps to the encoded range.
    static func unpack(_ out: [Float]) -> [Float] {
        let scale = 1 / (1 - pedestal)
        return out.map { v in v.isFinite ? min(max((v - pedestal) * scale, 0), 1) : 0 }
    }

    /// Whether a tile's output (unpacked) has left its input (packed, as
    /// fed to the model) at low frequencies, or isn't finite.
    static func diverged(input: [Float], output: [Float]) -> Bool {
        let t = tile, b = 16, n = t / b
        let scale = 1 / (1 - pedestal)
        for c in 0..<3 {
            for by in 0..<n {
                for bx in 0..<n {
                    var sIn: Float = 0, sOut: Float = 0
                    for y in (by * b)..<(by * b + b) {
                        let row = c * t * t + y * t
                        for x in (bx * b)..<(bx * b + b) {
                            sIn += (input[row + x] - pedestal) * scale
                            sOut += output[row + x]
                        }
                    }
                    let d = abs(sOut - sIn) / Float(b * b)
                    if !(d <= divergenceLimit) { return true }
                }
            }
        }
        return false
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Extracts a tile as the model's 1×3×T×T planar float array, scaled
    /// by `white`, gamma-encoded, clamped to [0, 1] and lifted onto the
    /// pedestal. Tiles that fall off the image's edge (small images) are
    /// padded by clamping.
    static func packTile(_ pixels: [Float16], width: Int, height: Int, x0: Int, y0: Int,
                         white: Float) -> [Float] {
        let t = tile
        let inv = 1 / white
        var out = [Float](repeating: 0, count: 3 * t * t)
        for y in 0..<t {
            let sy = min(y0 + y, height - 1)
            for x in 0..<t {
                let sx = min(x0 + x, width - 1)
                let i = (sy * width + sx) * 4
                for c in 0..<3 {
                    out[c * t * t + y * t + x] = lift(min(encode(Float(pixels[i + c]) * inv), 1))
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

    /// Adds one tile into sums that start at row `top` of the frame.
    static func accumulate(_ out: [Float], into accum: inout [Float], weight: inout [Float], ramp: [Float],
                           width: Int, height: Int, x0: Int, y0: Int, top: Int = 0) {
        let t = tile
        for y in 0..<t {
            let sy = y0 + y
            guard sy < height else { break }
            for x in 0..<t {
                let sx = x0 + x
                guard sx < width else { break }
                let w = ramp[x] * ramp[y]
                let i = (sy - top) * width + sx
                weight[i] += w
                for c in 0..<3 {
                    accum[i * 3 + c] += w * out[c * t * t + y * t + x]
                }
            }
        }
    }
}

/// Why the neural denoiser won't run on an image.
public enum AIDenoiseError: Error, CustomStringConvertible {
    /// The image is a linear source, such as an HDR merge (see
    /// `ImageSession.supportsAIDenoise`).
    case linearSource

    public var description: String {
        switch self {
        case .linearSource:
            "AI noise reduction isn't available for merged and linear DNG images: the model only handles values up to white"
        }
    }
}

/// Runs the denoiser over a whole image session and stores the result
/// where the pipeline blends it in. Shared by the editor and the export
/// worker so both produce identical pixels.
///
/// It is three steps rather than one so that the session and the pipeline,
/// which belong to whichever actor owns them (the main actor in the
/// editor), are touched only on that actor: `prepare` and `install` are
/// synchronous and run where they are called; only plain pixels cross to
/// `denoise`, which runs the network off the caller's actor. `run` strings
/// the three together for a caller that owns its session outright (the
/// export worker, the tests).
public enum AIDenoiseWorker {
    /// What the network needs from a session: camera RGB at as-shot white
    /// balance, read back from the GPU, and the white point. Plain values.
    public struct Prepared: Sendable {
        public let pixels: [Float16]
        public let width: Int
        public let height: Int
        public let white: Float
        public let start: Date
    }

    /// The network's answer, waiting to be installed into the session on
    /// the actor that owns it.
    public struct Result: Sendable {
        public let pixels: [Float16]
        public let width: Int
        public let height: Int
        public let model: String
        /// Seconds from `prepare` to the last tile.
        public let seconds: TimeInterval
    }

    /// Step one: renders the frame's camera RGB at as-shot white balance
    /// and reads it back. Synchronous, so it runs on the session's actor.
    ///
    /// Throws `AIDenoiseError.linearSource` for a linear source before
    /// doing any work. The network sees values up to white and hands back
    /// anything near or above it unchanged (`denoise`); an HDR merge keeps
    /// much of its picture above 1.0, where the result would be a noisy
    /// image with a denoised patchwork below a hard-to-see threshold.
    public static func prepare(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext) throws -> Prepared {
        guard session.supportsAIDenoise else { throw AIDenoiseError.linearSource }
        let start = Date()
        var asShot = EditParameters()
        asShot.whiteBalance = session.asShotWhiteBalance
        let camera = try pipeline.renderCameraRGB(session, scale: .full, parameters: asShot)
        let pixels = try TextureReadback.float16Pixels(of: camera, gpu: gpu)
        let m = session.asShotMultipliers
        return Prepared(pixels: pixels, width: camera.width, height: camera.height,
                        white: max(m.x, m.y, m.z, 1), start: start)
    }

    /// Step two: the network, tile by tile, off the caller's actor.
    /// Cancellation is honoured between tiles.
    public static func denoise(_ prepared: Prepared, denoiser: AIDenoiser,
                               progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Result {
        let denoised = try await denoiser.denoise(prepared.pixels, width: prepared.width, height: prepared.height,
                                                  white: prepared.white, progress: progress)
        try Task.checkCancellation()
        return Result(pixels: denoised, width: prepared.width, height: prepared.height,
                      model: denoiser.modelName, seconds: Date().timeIntervalSince(prepared.start))
    }

    /// Step three: wraps the answer in a texture and hands it to the
    /// session. Synchronous, so it runs on the session's actor.
    public static func install(_ result: Result, into session: ImageSession, gpu: GPUContext) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: result.width, height: result.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else {
            throw AIMaskError.noResult
        }
        result.pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, result.width, result.height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: result.width * 8)
        }
        session.setAIDenoised(texture, model: result.model)
    }

    /// All three steps, for a caller that owns its session and pipeline.
    /// Returns the seconds it took.
    @discardableResult
    public static func run(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                           denoiser: AIDenoiser,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> TimeInterval {
        let prepared = try prepare(session: session, pipeline: pipeline, gpu: gpu)
        let result = try await denoise(prepared, denoiser: denoiser, progress: progress)
        try install(result, into: session, gpu: gpu)
        return result.seconds
    }
}
