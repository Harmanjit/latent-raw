import Foundation
import Metal

/// Brightness against horizontal position, per channel (DESIGN.md §8.3).
///
/// `counts` for a channel is `rows * columns` values, row-major, with
/// row 0 the darkest — index `row * columns + column`.
public struct Waveform: Sendable {
    public static let columns = 256
    public static let rows = 256

    public let red: [UInt32]
    public let green: [UInt32]
    public let blue: [UInt32]
    public let peak: UInt32
}

/// Chroma distribution: a square grid with neutral in the centre.
public struct Vectorscope: Sendable {
    public static let size = 128
    /// `size * size` values, row-major, row 0 at the top (highest Cr).
    public let counts: [UInt32]
    public let peak: UInt32

    /// For a vectorscope measured elsewhere (`MaskedScopeAccumulator`) or
    /// made up in a test.
    public init(counts: [UInt32], peak: UInt32) {
        self.counts = counts
        self.peak = peak
    }
}

/// Runs the scope kernels and reads their results back.
///
/// Like HistogramCalculator it owns its shared-storage result buffers so
/// nothing is allocated per frame. Each `compute` is a full GPU round
/// trip, so callers should measure a small analysis render rather than
/// the full preview, and only compute the scope that's actually visible.
public final class ScopeCalculator {
    private let gpu: GPUContext
    private let waveformBuffer: MTLBuffer
    private let vectorscopeBuffer: MTLBuffer

    private static let waveformBins = Waveform.rows * Waveform.columns * 3
    private static let vectorscopeBins = Vectorscope.size * Vectorscope.size

    public init(gpu: GPUContext) throws {
        self.gpu = gpu
        guard let wave = gpu.device.makeBuffer(length: Self.waveformBins * 4,
                                                options: .storageModeShared),
              let vector = gpu.device.makeBuffer(length: Self.vectorscopeBins * 4,
                                                  options: .storageModeShared) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        self.waveformBuffer = wave
        self.vectorscopeBuffer = vector
    }

    public func computeWaveform(from texture: MTLTexture, inputIsLinear: Bool) -> Waveform? {
        guard run(gpu.waveformPSO, on: texture, into: waveformBuffer, inputIsLinear: inputIsLinear)
        else { return nil }
        let plane = Waveform.rows * Waveform.columns
        let counts = waveformBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.waveformBins)
        let red   = Array(UnsafeBufferPointer(start: counts, count: plane))
        let green = Array(UnsafeBufferPointer(start: counts + plane, count: plane))
        let blue  = Array(UnsafeBufferPointer(start: counts + 2 * plane, count: plane))
        let peak = max(red.max() ?? 0, max(green.max() ?? 0, blue.max() ?? 0))
        return Waveform(red: red, green: green, blue: blue, peak: peak)
    }

    public func computeVectorscope(from texture: MTLTexture, inputIsLinear: Bool) -> Vectorscope? {
        guard run(gpu.vectorscopePSO, on: texture, into: vectorscopeBuffer, inputIsLinear: inputIsLinear)
        else { return nil }
        let counts = vectorscopeBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.vectorscopeBins)
        let values = Array(UnsafeBufferPointer(start: counts, count: Self.vectorscopeBins))
        return Vectorscope(counts: values, peak: values.max() ?? 0)
    }

    /// Clears `buffer`, runs `pso` over every pixel of `texture`, waits.
    private func run(_ pso: MTLComputePipelineState, on texture: MTLTexture,
                     into buffer: MTLBuffer, inputIsLinear: Bool) -> Bool {
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer() else { return false }
        if let blit = cmdBuffer.makeBlitCommandEncoder() {
            blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0)
            blit.endEncoding()
        }
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var linear: UInt32 = inputIsLinear ? 1 : 0
        encoder.setBytes(&linear, length: 4, index: 1)

        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(
            MTLSize(width: (texture.width + tw - 1) / tw,
                    height: (texture.height + th - 1) / th, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        return cmdBuffer.status != .error
    }
}

extension Vectorscope {
    /// Where a colour lands on the vectorscope, as fractions of its side
    /// (0…1 each way, y down): the same sRGB encoding, Rec.709 chroma and
    /// scaling as `computeVectorscope` in Scopes.metal, so a colour sample
    /// plotted here sits on the pixels it was read from.
    public static func position(ofLinear linear: SIMD3<Float>) -> SIMD2<Float> {
        func encode(_ v: Float) -> Float {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        let r = encode(linear.x), g = encode(linear.y), b = encode(linear.z)
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cb = (b - y) / 1.8556, cr = (r - y) / 1.5748
        return SIMD2(min(max(cb + 0.5, 0), 1), min(max(0.5 - cr, 0), 1))
    }

    /// The angle of a colour on the scope in degrees, counter-clockwise
    /// from the +Cb axis (right), as broadcast scopes measure it; nil for
    /// a neutral.
    public static func angle(ofLinear linear: SIMD3<Float>) -> Float? {
        let p = position(ofLinear: linear) - 0.5
        guard (p.x * p.x + p.y * p.y) > 1e-8 else { return nil }
        var a = atan2(-p.y, p.x) * 180 / .pi
        if a < 0 { a += 360 }
        return a
    }
}
