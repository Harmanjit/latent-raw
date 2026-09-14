import Foundation
import Metal

/// A computed histogram of a rendered image.
///
/// Measured on the *display-referred* image, after tone mapping and
/// encoding — which is what Lightroom and Capture One show too. Worth
/// knowing what that implies: a highlight can sit comfortably below 255
/// here while being genuinely clipped in the sensor data, because the tone
/// curve compressed it back into range. A raw-clipping indicator is a
/// separate thing, and isn't this.
public struct Histogram: Sendable {
    public static let binCount = 256

    public let red: [UInt32]
    public let green: [UInt32]
    public let blue: [UInt32]
    /// Relative luminance (Display P3 weights, in linear light), encoded
    /// with the sRGB curve like the channels: how light each pixel looks.
    public let luminance: [UInt32]

    /// The largest count in any bin of the three colour channels, for
    /// scaling the display.
    public let peak: UInt32

    /// Pixels with any channel above SDR white (1.0 in the linear render).
    /// Always 0 for a render with no headroom, and for encoded input.
    public let aboveSDRWhite: Int

    /// Fraction of pixels sitting in the topmost bin, per channel — a rough
    /// "how much is blown" readout.
    public var clippedFraction: (red: Float, green: Float, blue: Float) {
        let total = Float(max(totalPixels, 1))
        return (Float(red[Self.binCount - 1]) / total,
                Float(green[Self.binCount - 1]) / total,
                Float(blue[Self.binCount - 1]) / total)
    }

    /// Fraction of pixels sitting in the bottom bin, per channel: shadows
    /// crushed to black.
    public var shadowClippedFraction: (red: Float, green: Float, blue: Float) {
        let total = Float(max(totalPixels, 1))
        return (Float(red[0]) / total, Float(green[0]) / total, Float(blue[0]) / total)
    }

    /// Fraction of pixels brighter than SDR white: highlights an SDR screen
    /// or file can't show as bright as the HDR view does.
    public var aboveSDRWhiteFraction: Float {
        Float(aboveSDRWhite) / Float(max(totalPixels, 1))
    }

    public let totalPixels: Int
}

/// Runs the histogram kernel and reads the result back to the CPU.
///
/// Owns its result buffer so it isn't reallocated per frame. The buffer is
/// shared-storage (DESIGN.md §7.2) because the CPU has to read it — one of
/// the few places in the pipeline where data genuinely crosses back.
///
/// Cost note: this is a second full read of the display texture, about 1ms
/// at viewport resolution. It could be fused into the colour kernel, which
/// already reads every pixel, saving that pass entirely. Kept separate for
/// now because fusing would make the histogram unconditional and tangle two
/// unrelated concerns in one kernel. Worth revisiting if the render budget
/// ever gets tight.
public final class HistogramCalculator {
    private let gpu: GPUContext
    private let resultBuffer: MTLBuffer
    /// Four channels of bins, then the above-white counter. Matches
    /// Histogram.metal.
    private static let totalBins = Histogram.binCount * 4 + 1

    public init(gpu: GPUContext) throws {
        self.gpu = gpu
        let byteLength = Self.totalBins * MemoryLayout<UInt32>.size
        guard let buffer = gpu.device.makeBuffer(length: byteLength,
                                                  options: .storageModeShared) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        self.resultBuffer = buffer
    }

    /// Computes the histogram of `texture`. Returns nil if the GPU work
    /// fails; a missing histogram is a cosmetic loss, not a render failure,
    /// so callers should treat it as optional rather than an error.
    /// `inputIsLinear`: pass true for textures rendered with a linear
    /// (EDR) output; the kernel applies the sRGB curve itself so the
    /// histogram shape matches an encoded render.
    public func compute(from texture: MTLTexture, inputIsLinear: Bool = false) -> Histogram? {
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer() else { return nil }

        // Clear last frame's counts. A blit fill is cheaper than a kernel
        // launch for 4KB.
        if let blit = cmdBuffer.makeBlitCommandEncoder() {
            blit.fill(buffer: resultBuffer, range: 0..<resultBuffer.length, value: 0)
            blit.endEncoding()
        }

        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(gpu.histogramPSO)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(resultBuffer, offset: 0, index: 0)
        var linear: UInt32 = inputIsLinear ? 1 : 0
        encoder.setBytes(&linear, length: 4, index: 1)

        let pso = gpu.histogramPSO
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        let groups = MTLSize(width: (texture.width + tw - 1) / tw,
                              height: (texture.height + th - 1) / th,
                              depth: 1)
        encoder.dispatchThreadgroups(groups,
                                      threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status != .error else { return nil }

        let counts = resultBuffer.contents().bindMemory(to: UInt32.self,
                                                          capacity: Self.totalBins)
        let bins = Histogram.binCount
        let red = Array(UnsafeBufferPointer(start: counts, count: bins))
        let green = Array(UnsafeBufferPointer(start: counts + bins, count: bins))
        let blue = Array(UnsafeBufferPointer(start: counts + 2 * bins, count: bins))
        let luminance = Array(UnsafeBufferPointer(start: counts + 3 * bins, count: bins))

        let peak = max(red.max() ?? 0, max(green.max() ?? 0, blue.max() ?? 0))

        return Histogram(red: red, green: green, blue: blue, luminance: luminance, peak: peak,
                          aboveSDRWhite: Int(counts[4 * bins]),
                          totalPixels: texture.width * texture.height)
    }
}
