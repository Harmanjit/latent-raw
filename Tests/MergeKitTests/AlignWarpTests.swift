import XCTest
import Metal
import simd
import PixelEngine
@testable import MergeKit

/// The GPU warp (Shaders/MergeWarp.metal) against a CPU reference, its
/// identity passthrough, its masks, its memory, and the GPU reduction the
/// aligner can start from.
final class AlignWarpTests: XCTestCase {
    /// A smooth but detailed RGBA test image: three different patterns,
    /// values from 0 to about 1.
    private func pattern(width: Int, height: Int) -> [Float] {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Float(x), fy = Float(y), i = (y * width + x) * 4
                pixels[i] = 0.5 + 0.45 * sin(fx * 0.21) * cos(fy * 0.13)
                pixels[i + 1] = 0.5 + 0.45 * sin((fx + 2 * fy) * 0.05)
                pixels[i + 2] = Float((x / 7 + y / 5) % 2) * 0.8 + 0.1
            }
        }
        return pixels
    }

    /// Every sampled output pixel matches the CPU's Catmull-Rom within half
    /// float precision, with coverage 1 inside the source and 0 outside,
    /// across a texture taller than one command-buffer band.
    func testWarpMatchesCPUReference() throws {
        let gpu = try HDRTestSupport.gpu()
        let (w, h) = (2100, 2000) // 4.2 MP: two bands
        let source = pattern(width: w, height: h)
        let texture = try AlignTestSupport.texture(source, width: w, height: h, gpu: gpu)
        let centre = SIMD2(Double(w), Double(h)) / 2
        let movingToReference = Homography.translation(13.3, -7.7)
            * Homography.cameraRotation(yaw: 0.4, pitch: -0.3, roll: 2, focalLength: 2500, principalPoint: centre)
        let warped = try AlignTestSupport.read(
            MergeWarpKernels.warp(texture, movingToReference: movingToReference, gpu: gpu), gpu: gpu)
        let referenceToMoving = movingToReference.inverse
        let halves = source.map { Float(Float16($0)) } // what the GPU actually reads

        var compared = 0, outside = 0, worst = 0.0
        let rows = Array(0..<24) + Array(1890..<1920) + Array(stride(from: 24, to: h, by: 37))
        halves.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            var channel = [Float](repeating: 0, count: w * h)
            for c in 0..<3 {
                for i in 0..<(w * h) { channel[i] = base[i * 4 + c] }
                channel.withUnsafeBufferPointer { plane in
                    for y in rows {
                        for x in stride(from: 0, to: w, by: 3) {
                            let p = Homography.apply(referenceToMoving, SIMD2(Double(x) + 0.5, Double(y) + 0.5))
                            let got = warped[(y * w + x) * 4 + c], alpha = warped[(y * w + x) * 4 + 3]
                            // Too close to the edge to say which side a float32 lands on.
                            let margin = min(p.x, p.y, Double(w) - p.x, Double(h) - p.y)
                            if abs(margin) < 0.01 { continue }
                            if margin < 0 {
                                if c == 0 { outside += 1 }
                                XCTAssertEqual(alpha, 0)
                                XCTAssertEqual(got, 0)
                                continue
                            }
                            XCTAssertEqual(alpha, 1)
                            let want = max(0, AlignTestSupport.sample(plane.baseAddress!, width: w, height: h, p.x, p.y))
                            worst = max(worst, abs(Double(got) - want))
                            compared += 1
                        }
                    }
                }
            }
        }
        print("align-warp | compared \(compared) samples, worst difference \(worst)")
        XCTAssertGreaterThan(compared, 50_000)
        XCTAssertGreaterThan(outside, 100, "the rotation should push some pixels outside")
        // The output is half float, whose steps are 1/2048 below 1.0 and
        // 1/1024 above it (the cubic overshoots past 1 at hard edges).
        XCTAssertLessThan(worst, 2e-3)
    }

    /// Catmull-Rom overshoots next to a hard edge; negative light is clamped to 0.
    func testRingingIsClampedToZero() throws {
        let gpu = try HDRTestSupport.gpu()
        let (w, h) = (64, 8)
        var pixels = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { pixels[(y * w + x) * 4 + c] = x < 32 ? 0 : 1 } } }
        let texture = try AlignTestSupport.texture(pixels, width: w, height: h, gpu: gpu)
        let warped = try AlignTestSupport.read(
            MergeWarpKernels.warp(texture, movingToReference: Homography.translation(0.5, 0), gpu: gpu), gpu: gpu)
        let row = (0..<w).map { warped[(4 * w + $0) * 4] }
        XCTAssertGreaterThanOrEqual(row.min() ?? -1, 0)
        // Just before the edge the cubic wants -0.0625: it reads 0.
        XCTAssertEqual(row[31], 0)
        XCTAssertGreaterThan(row[33], 1.0, "overshoot above the edge is real light and kept")
    }

    /// The identity doesn't resample: no destination gives back the very
    /// same texture, and a destination receives an exact copy.
    func testIdentityIsBitExactPassthrough() throws {
        let gpu = try HDRTestSupport.gpu()
        let (w, h) = (257, 131)
        let source = pattern(width: w, height: h)
        let texture = try AlignTestSupport.texture(source, width: w, height: h, gpu: gpu)
        let same = try MergeWarpKernels.warp(texture, movingToReference: Homography.identity, gpu: gpu)
        XCTAssertTrue(same === texture)
        let scaledIdentity = simd_double3x3(diagonal: SIMD3(repeating: 2.5))
        XCTAssertTrue(try MergeWarpKernels.warp(texture, movingToReference: scaledIdentity, gpu: gpu) === texture)

        let destination = try AlignTestSupport.texture([Float](repeating: 0.25, count: w * h * 4), width: w, height: h, gpu: gpu)
        let copied = try MergeWarpKernels.warp(texture, movingToReference: Homography.identity, into: destination, gpu: gpu)
        XCTAssertTrue(copied === destination)
        XCTAssertEqual(try AlignTestSupport.read(copied, gpu: gpu), try AlignTestSupport.read(texture, gpu: gpu))
    }

    /// A clip mask's footprint maximum moves exactly with a whole-pixel
    /// shift, and spreads over exactly the pixels a fractional sample uses.
    func testMaskFootprintMaximum() throws {
        let gpu = try HDRTestSupport.gpu()
        let (w, h) = (40, 30)
        var mask = [Float](repeating: 0, count: w * h)
        mask[12 * w + 20] = 1
        let texture = try AlignTestSupport.texture(mask, width: w, height: h, gpu: gpu, format: .r8Unorm)

        // moving (20, 12) lands at reference (23, 10).
        let whole = try AlignTestSupport.read(
            MergeWarpKernels.warpMask(texture, movingToReference: Homography.translation(3, -2),
                                      sampling: .footprintMaximum, gpu: gpu), gpu: gpu)
        XCTAssertEqual(whole.indices.filter { whole[$0] > 0 }, [10 * w + 23])

        // Half a pixel across: the cubic uses 4 columns, 1 row.
        let half = try AlignTestSupport.read(
            MergeWarpKernels.warpMask(texture, movingToReference: Homography.translation(0.5, 0),
                                      sampling: .footprintMaximum, gpu: gpu), gpu: gpu)
        XCTAssertEqual(half.indices.filter { half[$0] > 0 }, (19...22).map { 12 * w + $0 })

        let bilinear = try AlignTestSupport.read(
            MergeWarpKernels.warpMask(texture, movingToReference: Homography.translation(0.5, 0),
                                      sampling: .bilinear, gpu: gpu), gpu: gpu)
        XCTAssertEqual(bilinear[12 * w + 20], 0.5, accuracy: 1.0 / 255)
        XCTAssertEqual(bilinear[12 * w + 21], 0.5, accuracy: 1.0 / 255)
        XCTAssertEqual(bilinear.reduce(0, +), 1, accuracy: 2.0 / 255)

        // Outside the source reads `outside`.
        let shifted = try AlignTestSupport.read(
            MergeWarpKernels.warpMask(texture, movingToReference: Homography.translation(10, 0),
                                      sampling: .footprintMaximum, outside: 1, gpu: gpu), gpu: gpu)
        XCTAssertEqual(shifted[5 * w + 3], 1)
        XCTAssertEqual(shifted[5 * w + 30], 0)
    }

    /// Warping a 45 MP frame adds one output texture and nothing more.
    func testWarpMemoryIsOneFrame() throws {
        let gpu = try HDRTestSupport.gpu()
        let (w, h) = (8256, 5504)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let source = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
        var row = [Float16](repeating: 1, count: w * 4)
        for x in 0..<w { row[x * 4] = Float16(Float(x % 97) / 96); row[x * 4 + 1] = 0.5; row[x * 4 + 2] = 0.25 }
        let rows = [Float16]((0..<64).flatMap { _ in row })
        rows.withUnsafeBytes { bytes in
            for y in stride(from: 0, to: h, by: 64) {
                source.replace(region: MTLRegionMake2D(0, y, w, min(64, h - y)), mipmapLevel: 0,
                               withBytes: bytes.baseAddress!, bytesPerRow: w * 8)
            }
        }
        let before = gpu.device.currentAllocatedSize
        let start = Date()
        let movingToReference = Homography.translation(-11.5, 6.25)
            * Homography.rotation(degrees: 0.3, about: SIMD2(Double(w), Double(h)) / 2)
        let warped = try MergeWarpKernels.warp(source, movingToReference: movingToReference, gpu: gpu)
        let seconds = Date().timeIntervalSince(start)
        let added = gpu.device.currentAllocatedSize - before
        print(String(format: "align-warp | 45 MP warp: %.2f s, %.0f MB added (one frame is %.0f MB)", seconds,
                     Double(added) / 1e6, Double(MergeWarpKernels.extraBytes(width: w, height: h)) / 1e6))
        XCTAssertEqual(warped.width, w)
        XCTAssertLessThanOrEqual(added, MergeWarpKernels.extraBytes(width: w, height: h) + 64_000_000)
    }

    /// The GPU reduction the aligner can start from agrees with the CPU one.
    func testGPUReductionMatchesCPU() throws {
        let gpu = try HDRTestSupport.gpu()
        let (w, h) = (1200, 800), (ow, oh) = (700, 467)
        var pixels = pattern(width: w, height: h)
        // A clipped block in red.
        for y in 300..<340 { for x in 500..<560 { pixels[(y * w + x) * 4] = 1.5 } }
        let texture = try AlignTestSupport.texture(pixels, width: w, height: h, gpu: gpu)
        let clip = SIMD3<Float>(1.2, 1.2, 1.2)
        let gpuReduced = try MergeWarpKernels.alignmentReduction(of: texture, channelClip: clip, width: ow, height: oh,
                                                                 gpu: gpu)
        let halves = pixels.map { Float(Float16($0)) }
        var luminance = [Float](repeating: 0, count: w * h), clipped = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            luminance[i] = 0.25 * halves[4 * i] + 0.5 * halves[4 * i + 1] + 0.25 * halves[4 * i + 2]
            clipped[i] = halves[4 * i] >= clip.x || halves[4 * i + 1] >= clip.y || halves[4 * i + 2] >= clip.z ? 1 : 0
        }
        let cpu = AlignmentSampling.reduce([luminance, clipped], width: w, height: h, outWidth: ow, outHeight: oh)
        var worstLuminance: Float = 0, worstClipped: Float = 0
        for i in 0..<(ow * oh) {
            worstLuminance = max(worstLuminance, abs(gpuReduced.luminance[i] - cpu[0][i]))
            worstClipped = max(worstClipped, abs(gpuReduced.clippedShare[i] - cpu[1][i]))
        }
        XCTAssertLessThan(worstLuminance, 1e-4)
        XCTAssertLessThan(worstClipped, 1e-4)
        XCTAssertGreaterThan(gpuReduced.clippedShare.max() ?? 0, 0.99)
    }

    /// An `AlignmentImage` made from a texture on the GPU matches one made
    /// from the same pixels on the CPU.
    func testAlignmentImageFromTextureMatchesCPU() throws {
        let gpu = try HDRTestSupport.gpu()
        let (w, h) = (3300, 1400)
        let pixels = pattern(width: w, height: h)
        let texture = try AlignTestSupport.texture(pixels, width: w, height: h, gpu: gpu)
        let exposure = AlignmentExposure(gain: 0.5, channelClip: SIMD3(repeating: 1))
        let fromGPU = try AlignmentImage.make(texture: texture, exposure: exposure, gpu: gpu)
        let fromCPU = AlignmentImage(rgba: pixels.map { Float(Float16($0)) }, width: w, height: h,
                                     alphaIsClippedShare: false, exposure: exposure)
        XCTAssertEqual(fromGPU.levels.map(\.width), [400, 800, 1600, 3200])
        XCTAssertEqual(fromGPU.levels.map(\.width), fromCPU.levels.map(\.width))
        for (a, b) in zip(fromGPU.levels, fromCPU.levels) {
            XCTAssertEqual(a.scaleX, b.scaleX)
            var worst: Float = 0
            for i in stride(from: 0, to: a.logLuminance.count, by: 5) {
                worst = max(worst, abs(a.logLuminance[i] - b.logLuminance[i]))
            }
            XCTAssertLessThan(worst, 1e-3, "level \(a.width)")
            XCTAssertEqual(a.valid, b.valid, "level \(a.width)")
        }
    }
}
