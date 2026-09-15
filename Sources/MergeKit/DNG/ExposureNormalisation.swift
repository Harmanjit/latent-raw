// Fitting a merge's pixel values under 1.0 without changing how it looks.

import Foundation
import Metal
import MetalPerformanceShaders

/// How far a merge's pixels are divided down before they're stored, and the
/// matching change to `BaselineExposure`.
///
/// **Why it's needed.** An HDR merge is scaled relative to its brightest
/// frame, whose white is 1.0, so highlights recovered from darker frames
/// reach 2, 8, 128... But Apple's RAW engine (ImageIO, Core Image, so the
/// Finder, Photos and Preview) clips float samples above 1.0: a DNG storing
/// 128 shows a flat white sky. The Phase 0 spike confirmed it.
///
/// **What's done.** Every sample is divided by 2^shift, the smallest power
/// of two that brings the maximum to 1.0 or below, and `shift` stops are
/// added to `BaselineExposure`, the DNG tag that tells a raw converter how
/// much to brighten by default. The picture opens exactly as bright as
/// before, and no sample is clipped. A power of two because dividing a float
/// by one only changes its exponent, so no value is rounded (until it gets
/// so small that half floats can't hold it: they keep about 14 stops below 1.0).
public struct ExposureNormalisation: Sendable, Equatable {
    /// Stops the pixels were divided by: 0 when they already fit.
    public let shift: Int

    public init(shift: Int) {
        self.shift = max(0, shift)
    }

    /// The normalisation for pixels whose largest value is `maximum`. Throws
    /// for infinity or NaN, which no division can fit under 1.0 and which
    /// mean something upstream went wrong.
    public init(maximum: Float) throws {
        self.init(shift: try Self.shift(forMaximum: maximum))
    }

    /// The smallest whole number of stops, 0 or more, with
    /// `maximum / 2^shift <= 1`.
    ///
    /// Worked from the float's exponent rather than `log2`, which may round:
    /// a maximum of exactly 4 needs 2 stops, and 4.0001 needs 3.
    public static func shift(forMaximum maximum: Float) throws -> Int {
        guard maximum.isFinite else { throw MergeDNGError.invalidMaximum(maximum) }
        guard maximum > 1 else { return 0 }
        // maximum = significand x 2^exponent, with significand in [1, 2).
        // An exact power of two (significand 1) fits at `exponent` stops;
        // anything above it needs one more.
        let exponent = Int(maximum.exponent)
        return maximum.significand == 1 ? exponent : exponent + 1
    }

    /// What every stored sample is multiplied by: 2^-shift.
    public var scale: Float { Float(sign: .plus, exponent: -shift, significand: 1) }

    /// A value in the merge's units (a clip level, say) as it is stored.
    public func stored(_ value: Float) -> Float { value * scale }

    /// The `BaselineExposure` to write for a merge that should open with
    /// `baselineExposure` before normalisation.
    public func storedBaselineExposure(_ baselineExposure: Double) -> Double {
        baselineExposure + Double(shift)
    }

    // MARK: - Finding the maximum

    /// The largest red, green or blue value in interleaved half floats
    /// (`channelsPerPixel` 3, or 4 with alpha ignored). NaN if any colour
    /// sample is NaN, so the caller's normalisation throws instead of
    /// quietly writing it; 0 for an empty buffer.
    public static func maximum(of pixels: UnsafeBufferPointer<Float16>, channelsPerPixel: Int = 3) -> Float {
        precondition(channelsPerPixel == 3 || channelsPerPixel == 4, "RGB or RGBA half floats")
        var largest: Float16 = 0
        var sawNaN = false
        var i = 0
        while i + 2 < pixels.count {
            for c in 0..<3 {
                let v = pixels[i + c]
                sawNaN = sawNaN || v.isNaN
                largest = max(largest, v)
            }
            i += channelsPerPixel
        }
        return sawNaN ? .nan : Float(largest)
    }

    /// The same, for an array.
    public static func maximum(of pixels: [Float16], channelsPerPixel: Int = 3) -> Float {
        pixels.withUnsafeBufferPointer { maximum(of: $0, channelsPerPixel: channelsPerPixel) }
    }

    /// The largest red, green or blue value in an `rgba16Float` texture,
    /// computed on the GPU (Metal Performance Shaders' per-channel min/max),
    /// so a 45 MP merge needn't come back to the CPU just to be measured.
    /// Waits for the GPU. All work already queued on the texture must have
    /// finished.
    ///
    /// Infinity comes back as infinity, so the normalisation throws. NaN
    /// handling is the GPU's; the writer checks every sample again anyway.
    public static func maximum(of texture: MTLTexture, commandQueue: MTLCommandQueue) throws -> Float {
        guard texture.pixelFormat == .rgba16Float, texture.textureType == .type2D else {
            throw MergeDNGError.unsupportedTexture("expected a 2D rgba16Float texture, got \(texture.pixelFormat.rawValue)")
        }
        let device = commandQueue.device
        // The kernel writes the minimum to pixel (0, 0) and the maximum to (1, 0).
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: 2, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let result = device.makeTexture(descriptor: descriptor),
              let commands = commandQueue.makeCommandBuffer() else { throw MergeDNGError.readbackFailed }
        let kernel = MPSImageStatisticsMinAndMax(device: device)
        kernel.encode(commandBuffer: commands, sourceTexture: texture, destinationTexture: result)
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { throw MergeDNGError.readbackFailed }
        var minMax = [Float](repeating: 0, count: 8)
        result.getBytes(&minMax, bytesPerRow: 2 * 4 * MemoryLayout<Float>.size,
                        from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0)
        let colour = minMax[4..<7]
        if colour.contains(where: \.isNaN) { return .nan }
        return colour.max() ?? 0
    }
}
