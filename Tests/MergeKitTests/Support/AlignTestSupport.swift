import Foundation
import Metal
import simd
import XCTest
import PixelEngine
import RawCore
@testable import MergeKit

/// What the alignment tests share: a real scene to cut synthetic frames
/// from, a CPU reference for the GPU warp, and the real brackets.
enum AlignTestSupport {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let assets = repository.appendingPathComponent("TestAssets")

    /// A planar Float32 image.
    struct Plane {
        let width: Int
        let height: Int
        var values: [Float]
    }

    // MARK: - The scene

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedScene: Plane?

    /// The golden D750 NEF as linear luminance, 2 x 2 binned (each Bayer
    /// quad's colours, so no demosaic softens it), scaled so its brightest
    /// 0.1% reach 1.0 as in the spike. Skips the test when the file is missing.
    static func scene() throws -> Plane {
        lock.lock(); defer { lock.unlock() }
        if let scene = cachedScene { return scene }
        let url = assets.appendingPathComponent("golden_nikon_d750_cc0.nef")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("TestAssets/golden_nikon_d750_cc0.nef is missing")
        }
        let gpu = try HDRTestSupport.gpu()
        let file = try RawFile(path: url.path)
        let levels = try HDRMerger.levels(for: file, gpu: gpu)
        let image = try HDRMergeKernels.analysisImage(of: file, span: 2, levels: levels, gpu: gpu)
        var values = [Float](repeating: 0, count: image.width * image.height)
        for i in values.indices {
            let p = image.pixels
            values[i] = max(0, 0.25 * p[4 * i] + 0.5 * p[4 * i + 1] + 0.25 * p[4 * i + 2])
        }
        let sorted = stride(from: 0, to: values.count, by: 97).map { values[$0] }.sorted()
        let top = max(sorted[Int(0.999 * Double(sorted.count - 1))], 1e-6)
        for i in values.indices { values[i] /= top }
        let scene = Plane(width: image.width, height: image.height, values: values)
        cachedScene = scene
        return scene
    }

    // MARK: - Synthetic frames

    /// Catmull-Rom weights, as MergeWarp.metal computes them.
    @inline(__always)
    static func catmullRom(_ t: Double) -> (Double, Double, Double, Double) {
        let t2 = t * t, t3 = t2 * t
        return (-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
    }

    /// A Catmull-Rom sample of `plane` at top-left continuous coordinates,
    /// edge pixels repeated beyond the border (the GPU warp's rule).
    /// Written out longhand: tests run unoptimised, and this runs millions
    /// of times per frame.
    static func sample(_ plane: UnsafePointer<Float>, width: Int, height: Int, _ x: Double, _ y: Double) -> Double {
        let ux = x - 0.5, uy = y - 0.5
        let bx = Int(ux.rounded(.down)), by = Int(uy.rounded(.down))
        let (x0, x1, x2, x3) = catmullRom(ux - Double(bx))
        let (y0, y1, y2, y3) = catmullRom(uy - Double(by))
        let c0 = min(max(bx - 1, 0), width - 1), c1 = min(max(bx, 0), width - 1)
        let c2 = min(max(bx + 1, 0), width - 1), c3 = min(max(bx + 2, 0), width - 1)
        func row(_ j: Int) -> Double {
            let r = plane + min(max(j, 0), height - 1) * width
            return x0 * Double(r[c0]) + x1 * Double(r[c1]) + x2 * Double(r[c2]) + x3 * Double(r[c3])
        }
        return y0 * row(by - 1) + y1 * row(by) + y2 * row(by + 1) + y3 * row(by + 2)
    }

    /// A `width x height` view of `scene` where view pixel p shows the scene
    /// at `viewToScene` p, exposed by `gain` and, with `seed`, given shot
    /// and read noise (30,000 e- full well, 3 e- read noise), clipping at
    /// 1.0 and 14-bit steps: the spike's sensor model.
    static func frame(_ scene: Plane, width: Int, height: Int, viewToScene: simd_double3x3, gain: Double,
                      seed: UInt64?) -> Plane {
        var out = [Float](repeating: 0, count: width * height)
        let fullWell = 30_000.0, readNoise = 3.0
        scene.values.withUnsafeBufferPointer { sceneBuffer in
            out.withUnsafeMutableBufferPointer { outBuffer in
                nonisolated(unsafe) let s = sceneBuffer.baseAddress!, o = outBuffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: height) { j in
                    var rng = SplitMix(seed: (seed ?? 0) &* 1_000_003 &+ UInt64(j))
                    for i in 0..<width {
                        let p = Homography.apply(viewToScene, SIMD2(Double(i) + 0.5, Double(j) + 0.5))
                        var v = max(0, sample(s, width: scene.width, height: scene.height, p.x, p.y)) * gain
                        if seed != nil {
                            let electrons = min(v * fullWell, 2 * fullWell)
                            v = (electrons + rng.gaussian() * (max(electrons, 0) + readNoise * readNoise).squareRoot())
                                / fullWell
                        }
                        v = min(max(v, 0), 1)
                        o[j * width + i] = Float((v * 16383).rounded() / 16383)
                    }
                }
            }
        }
        return Plane(width: width, height: height, values: out)
    }

    /// An `AlignmentImage` of a synthetic luminance frame (clip at 1.0).
    static func alignmentImage(_ plane: Plane, gain: Double) -> AlignmentImage {
        AlignmentImage(luminance: plane.values, width: plane.width, height: plane.height,
                       exposure: AlignmentExposure(gain: gain))
    }

    /// A reference frame and a moving frame whose content is the reference's
    /// moved by `truth` (moving -> reference): moving(p) = reference(truth p).
    /// The views sit centred in the scene.
    static func pair(truth: simd_double3x3, width: Int = 1600, height: Int = 1067,
                     referenceGain: Double = 1, movingGain: Double = 1, noise: Bool = true,
                     seed: UInt64 = 1) throws -> (reference: AlignmentImage, moving: AlignmentImage) {
        let scene = try scene()
        let crop = Homography.translation(Double(scene.width - width) / 2, Double(scene.height - height) / 2)
        let reference = frame(scene, width: width, height: height, viewToScene: crop, gain: referenceGain,
                              seed: noise ? seed : nil)
        let moving = frame(scene, width: width, height: height, viewToScene: crop * truth, gain: movingGain,
                           seed: noise ? seed + 7919 : nil)
        return (alignmentImage(reference, gain: referenceGain), alignmentImage(moving, gain: movingGain))
    }

    /// Deterministic random numbers, so every run makes the same frames.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func gaussian() -> Double {
            let u1 = max(uniform(), 1e-300), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    // MARK: - GPU helpers

    /// A shared rgba16Float texture holding `pixels` (4 per pixel).
    static func texture(_ pixels: [Float], width: Int, height: Int, gpu: GPUContext,
                        format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
        switch format {
        case .rgba16Float:
            let halves = pixels.map { Float16($0) }
            halves.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: width * 8)
            }
        case .r8Unorm:
            let bytes = pixels.map { UInt8(min(max($0, 0), 1) * 255) }
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: width)
            }
        case .r32Float:
            pixels.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: width * 4)
            }
        default:
            XCTFail("unsupported test format \(format)")
        }
        return texture
    }

    /// A texture's values as Float, any of the formats `texture` makes.
    static func read(_ texture: MTLTexture, gpu: GPUContext) throws -> [Float] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let readable = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
        let commands = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, to: readable)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
        switch texture.pixelFormat {
        case .rgba16Float:
            var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
            readable.getBytes(&halves, bytesPerRow: texture.width * 8, from: region, mipmapLevel: 0)
            return halves.map { Float($0) }
        case .r8Unorm:
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
            readable.getBytes(&bytes, bytesPerRow: texture.width, from: region, mipmapLevel: 0)
            return bytes.map { Float($0) / 255 }
        case .r32Float:
            var values = [Float](repeating: 0, count: texture.width * texture.height)
            readable.getBytes(&values, bytesPerRow: texture.width * 4, from: region, mipmapLevel: 0)
            return values
        default:
            XCTFail("unsupported test format \(texture.pixelFormat)")
            return []
        }
    }

    // MARK: - Real brackets

    /// A real bracket's frames prepared for alignment, brightest first: each
    /// frame 2 x 2 binned by the HDR analysis kernel, with its exposure
    /// measured against its neighbour as the HDR merge measures it.
    static func realBracket(_ folder: String) throws -> (images: [AlignmentImage], names: [String]) {
        let directory = assets.appendingPathComponent("merge").appendingPathComponent(folder)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("TestAssets/merge/\(folder) is missing")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["nef", "cr2"].contains($0.pathExtension.lowercased()) }
        let gpu = try HDRTestSupport.gpu()
        let merger = try HDRTestSupport.merger()
        let bracket = try merger.validate(urls)
        var images: [AlignmentImage] = []
        var previous: (frame: HDRAnalysisFrame, ev: Double)?
        for member in bracket {
            try autoreleasepool {
                let file = try RawFile(path: member.url.path)
                let levels = try HDRMerger.levels(for: file, gpu: gpu)
                let image = try HDRMergeKernels.analysisImage(of: file, span: 2, levels: levels, gpu: gpu)
                let frame = HDRAnalysisFrame(image, levels: levels)
                var ev = 0.0
                if let previous {
                    let exif = log2(bracket[images.count - 1].exposure / member.exposure)
                    let measured = HDRExposure.measuredStops(brighter: previous.frame, darker: frame)
                    ev = previous.ev - HDRExposure.pairStops(measured: measured.stops, samples: measured.samples,
                                                             exif: exif).stops
                }
                images.append(AlignmentImage(analysis: image, fullWidth: file.summary.rawWidth,
                                             fullHeight: file.summary.rawHeight,
                                             exposure: AlignmentExposure(gain: pow(2, ev), channelClip: levels.channelClip)))
                previous = (frame, ev)
            }
        }
        return (images, bracket.map { $0.url.lastPathComponent })
    }
}
