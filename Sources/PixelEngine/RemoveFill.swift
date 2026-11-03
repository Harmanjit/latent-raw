import Foundation
import CoreGraphics
import Metal
import simd

/// The outline of an object a Remove patch fills, found by Detect Objects
/// (Segment Anything on the area brushed) and stored with the patch, so a
/// render or an export never needs the model: one bit per cell over a box
/// on the raw grid.
///
/// The box is placed relative to the patch's target, so moving the patch
/// moves the outline with it.
public struct RemoveObjectMask: Codable, Hashable, Sendable {
    /// The box's top-left corner as an offset from the patch's target, and
    /// its size, in normalized sensor coordinates.
    public var origin: SIMD2<Float>
    public var size: SIMD2<Float>
    /// Cells across and down.
    public var width: Int
    public var height: Int
    /// One bit per cell, row by row, the first cell in the top bit of the
    /// first byte. Base64 in the JSON: a 256 x 256 outline is 11 KB.
    public var bits: Data

    /// Cells per side at most; Detect Objects stores 256.
    public static let maximumSide = 512

    public init?(cells: [Bool], width: Int, height: Int, origin: SIMD2<Float>, size: SIMD2<Float>) {
        guard width > 0, height > 0, width <= Self.maximumSide, height <= Self.maximumSide,
              cells.count == width * height else { return nil }
        var bytes = [UInt8](repeating: 0, count: (cells.count + 7) / 8)
        for (i, on) in cells.enumerated() where on { bytes[i >> 3] |= 0x80 >> UInt8(i & 7) }
        self.origin = origin
        self.size = size
        self.width = width
        self.height = height
        self.bits = Data(bytes)
    }

    public func contains(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        let i = y * width + x
        return bits[bits.startIndex + i >> 3] & (0x80 >> UInt8(i & 7)) != 0
    }

    /// One byte per cell, 255 inside the object, for the GPU.
    public var cellBytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width where contains(x: x, y: y) { out[y * width + x] = 255 } }
        return out
    }

    /// Fraction of the cells inside the object.
    public var coverage: Double {
        let on = bits.reduce(0) { $0 + $1.nonzeroBitCount }
        return Double(on) / Double(max(width * height, 1))
    }

    /// Sensor-pixel box of the outline for a patch at `target`.
    public func bounds(target: SIMD2<Float>, sensorSize s: CGSize) -> CGRect {
        let corner = target + origin
        return CGRect(x: CGFloat(corner.x) * s.width, y: CGFloat(corner.y) * s.height,
                      width: CGFloat(size.x) * s.width, height: CGFloat(size.y) * s.height)
    }

    /// The mask as a render can trust it, or nil: numbers finite, a box of
    /// positive size no bigger than the sensor, and as many bits as cells.
    public var sanitized: RemoveObjectMask? {
        guard [origin.x, origin.y, size.x, size.y].allSatisfy(\.isFinite),
              width > 0, height > 0, width <= Self.maximumSide, height <= Self.maximumSide,
              bits.count == (width * height + 7) / 8,
              size.x > 0, size.y > 0, size.x <= 1, size.y <= 1,
              abs(origin.x) <= 2, abs(origin.y) <= 2 else { return nil }
        return self
    }
}

extension HealPatch {
    /// How large a Remove patch may be, as a fraction of the sensor's short
    /// side along its longest side: past that the region it synthesises
    /// from, at full resolution, costs more memory than an export should.
    public static let maximumRemoveExtent: Float = 0.35

    /// Whether a Remove patch's area is within `maximumRemoveExtent`.
    public func removeFitsLimit(sensorSize s: CGSize) -> Bool {
        let box = targetBounds(sensorSize: s)
        return Float(max(box.width, box.height)) <= Self.maximumRemoveExtent * Float(min(s.width, s.height)) + 1
    }

    /// How far around a Remove patch's area it looks for texture, in
    /// sensor pixels: about its own size, at least 3% and at most 8% of
    /// the short side. Relative to the sensor, so a binned preview, a tile
    /// and an export draw on the same surroundings.
    public func removeContextMarginPixels(sensorSize s: CGSize) -> CGFloat {
        let hole = targetBounds(sensorSize: s)
        let short = min(s.width, s.height)
        return min(max(max(hole.width, hole.height), 0.03 * short), 0.08 * short)
    }

    /// The sensor region a Remove patch reads: its area and the margin.
    public func removeContextBounds(sensorSize s: CGSize) -> CGRect {
        let m = removeContextMarginPixels(sensorSize: s)
        return targetBounds(sensorSize: s).insetBy(dx: -m, dy: -m)
    }

    /// A seed for the fill's random numbers from the patch's id: the same
    /// patch fills the same way in every render, on every launch (Swift's
    /// own hash is salted per process, so it won't do).
    var removeSeed: UInt32 {
        var h: UInt32 = 2_166_136_261
        withUnsafeBytes(of: id.uuid) { bytes in
            for b in bytes { h = (h ^ UInt32(b)) &* 16_777_619 }
        }
        return h
    }
}

/// Mirror of `RemoveRegionGPU` in Remove.metal.
struct RemoveRegionGPU {
    var size: SIMD2<Int32>
    var origin: SIMD2<Int32>
    var centre: SIMD2<Float>
    var radius: Float
    var pathCount: Int32
    var maskOrigin: SIMD2<Float>
    var maskScale: SIMD2<Float>
    var maskSize: SIMD2<Int32>
}

/// Mirror of `RemoveLevelGPU` in Remove.metal.
struct RemoveLevelGPU {
    var size: SIMD2<Int32>
    var nnfOrigin: SIMD2<Int32>
    var nnfSize: SIMD2<Int32>
    var seed: UInt32
    var pass: UInt32 = 0
    var step: Int32 = 1
    var useHole: Int32 = 0
}

/// Where one Remove patch lands on the texture being rendered.
struct RemovePlan {
    var region: RemoveRegionGPU
    /// Stroke points, region pixels (empty for a circle).
    var path: [SIMD2<Float>]
    /// The hole's box at level 0, region pixels, `hi` exclusive.
    var holeLo: SIMD2<Int32>
    var holeHi: SIMD2<Int32>
    /// Pyramid levels, finest first.
    var levels: [RemoveLevelGPU]
    var mask: RemoveObjectMask?
}

/// Encodes content-aware Remove (Remove.metal) onto a command buffer.
enum RemoveStage {
    /// Patch radius of the synthesis (7 x 7 patches), as in Remove.metal.
    static let patchRadius: Int32 = 3
    /// The hole's longest side at the coarsest level, texels: small enough
    /// that every patch there reaches known pixels.
    static let coarsestHole: Int32 = 8

    /// The patch's region on a `width` x `height` texture placed at
    /// `tileOrigin` (sensor pixels, `binSpan` sensor pixels a texel), or nil
    /// when its area misses the texture. The region is worked out on the
    /// sensor's texel grid before the texture clips it, so a tile holding
    /// the whole region (`HealPatch.regionIncludingSources`) gets exactly
    /// the region, the pyramid and the random numbers the whole frame does.
    static func plan(_ p: HealPatch, width: Int, height: Int, sensorSize: SIMD2<Float>,
                     tileOrigin: SIMD2<Float>, binSpan: Float) -> RemovePlan? {
        guard p.mode == .remove, binSpan > 0, width > 0, height > 0 else { return nil }
        let s = CGSize(width: CGFloat(sensorSize.x), height: CGFloat(sensorSize.y))
        let sensorRect = CGRect(origin: .zero, size: s)
        let hole = p.targetBounds(sensorSize: s)
        let context = p.removeContextBounds(sensorSize: s).intersection(sensorRect)
        guard !context.isNull, !hole.isEmpty,
              [hole.minX, hole.minY, hole.maxX, hole.maxY].allSatisfy(\.isFinite) else { return nil }
        let span = CGFloat(binSpan)
        let shift = SIMD2<Int32>(Int32((tileOrigin.x / binSpan).rounded()), Int32((tileOrigin.y / binSpan).rounded()))
        func texel(_ v: CGFloat, up: Bool) -> Int32 {
            let t = (v / span)
            return Int32(clamping: Int(up ? t.rounded(.up) : t.rounded(.down)))
        }
        // Region on the sensor's texel grid, then on this texture.
        let gLo = SIMD2(texel(context.minX, up: false), texel(context.minY, up: false))
        let gHi = SIMD2(texel(context.maxX, up: true), texel(context.maxY, up: true))
        let lo = simd_clamp(gLo &- shift, .zero, SIMD2(Int32(width), Int32(height)))
        let hi = simd_clamp(gHi &- shift, .zero, SIMD2(Int32(width), Int32(height)))
        let size = hi &- lo
        guard size.x > 2 * patchRadius + 2, size.y > 2 * patchRadius + 2 else { return nil }

        // The hole's box in region texels, a texel spare each side.
        let hLo = SIMD2(texel(hole.minX, up: false), texel(hole.minY, up: false)) &- shift &- lo &- 1
        let hHi = SIMD2(texel(hole.maxX, up: true), texel(hole.maxY, up: true)) &- shift &- lo &+ 1
        let holeLo = simd_clamp(hLo, .zero, size), holeHi = simd_clamp(hHi, .zero, size)
        guard holeHi.x > holeLo.x, holeHi.y > holeLo.y else { return nil }

        let toRegion = { (n: SIMD2<Float>) -> SIMD2<Float> in
            (n * sensorSize - tileOrigin) / binSpan - SIMD2<Float>(lo)
        }
        let path = p.isStroke ? p.pathPoints().map(toRegion) : []
        var region = RemoveRegionGPU(size: size, origin: lo, centre: toRegion(p.target),
                                     radius: p.radius * min(sensorSize.x, sensorSize.y) / binSpan,
                                     pathCount: Int32(path.count),
                                     maskOrigin: .zero, maskScale: .zero, maskSize: .zero)
        if let mask = p.objectMask {
            let boxSize = mask.size * sensorSize / binSpan
            region.maskOrigin = toRegion(p.target + mask.origin)
            region.maskScale = SIMD2(Float(mask.width), Float(mask.height)) / simd_max(boxSize, SIMD2(repeating: 1e-6))
            region.maskSize = SIMD2(Int32(mask.width), Int32(mask.height))
        }

        // Halve until the hole is small, while the region still has room
        // for sources around it.
        let seed = p.removeSeed
        var levels: [RemoveLevelGPU] = []
        var levelSize = size
        var l: Int32 = 0
        while true {
            let lLo = holeLo &>> l, lHi = ((holeHi &- 1) &>> l) &+ 1
            let r = SIMD2(repeating: patchRadius)
            let nLo = simd_clamp(lLo &- r, .zero, levelSize), nHi = simd_clamp(lHi &+ r, .zero, levelSize)
            levels.append(RemoveLevelGPU(size: levelSize, nnfOrigin: nLo, nnfSize: nHi &- nLo, seed: seed))
            let holeSide = (lHi &- lLo).max()
            let next = (levelSize &+ 1) &>> 1
            guard l < 10, holeSide > coarsestHole, next.min() >= 4 * patchRadius + 2 else { break }
            levelSize = next
            l += 1
        }
        return RemovePlan(region: region, path: path, holeLo: holeLo, holeHi: holeHi, levels: levels,
                          mask: p.objectMask)
    }

    /// Patches in order with red eyes last, as `HealStage.encode` does,
    /// when some are Remove patches: runs of heal and clone patches go
    /// through the heal kernels, each Remove patch fills in place between
    /// them, each reading what the patches before it left.
    static func encodeWithRemovals(patches: [HealPatch], redEyes: [RedEyeSpot],
                                   cameraToWorking: simd_float3x3,
                                   input: MTLTexture, output: MTLTexture,
                                   sensorSize: SIMD2<Float>, tileOrigin: SIMD2<Float>, binSpan: Float,
                                   gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height,
              input.pixelFormat == output.pixelFormat else { throw RenderError.commandBufferFailed }
        try blit(input, to: output, commandBuffer)
        // The heal kernels read one texture and write another, so a run
        // reads a copy of the working texture.
        var copy: MTLTexture?
        var run: [HealPatch] = []
        var groups: [[HealPatch]] = []
        for p in patches {
            if p.mode == .remove {
                if !run.isEmpty { groups.append(run); run = [] }
                groups.append([p])
            } else {
                run.append(p)
            }
        }
        if !run.isEmpty { groups.append(run) }
        if !redEyes.isEmpty { groups.append([]) }
        for group in groups {
            if let p = group.first, p.mode == .remove {
                try encode(p, working: output, sensorSize: sensorSize, tileOrigin: tileOrigin,
                           binSpan: binSpan, gpu: gpu, commandBuffer: commandBuffer)
                continue
            }
            if copy == nil {
                copy = gpu.makePrivateTexture(width: output.width, height: output.height, pixelFormat: output.pixelFormat)
            }
            guard let copy else { throw RenderError.gpuBufferAllocationFailed }
            try blit(output, to: copy, commandBuffer)
            try HealStage.encodeSpots(patches: group, redEyes: group.isEmpty ? redEyes : [],
                                      cameraToWorking: cameraToWorking, input: copy, output: output,
                                      sensorSize: sensorSize, tileOrigin: tileOrigin, binSpan: binSpan,
                                      gpu: gpu, commandBuffer: commandBuffer)
        }
    }

    private static func blit(_ from: MTLTexture, to: MTLTexture, _ commandBuffer: MTLCommandBuffer) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
        blit.copy(from: from, to: to)
        blit.endEncoding()
    }

    /// Fills one Remove patch's area in `working`, in place.
    static func encode(_ p: HealPatch, working: MTLTexture, sensorSize: SIMD2<Float>,
                       tileOrigin: SIMD2<Float>, binSpan: Float,
                       gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard let plan = plan(p, width: working.width, height: working.height, sensorSize: sensorSize,
                              tileOrigin: tileOrigin, binSpan: binSpan) else { return }
        let device = gpu.device
        func texture(_ size: SIMD2<Int32>, _ format: MTLPixelFormat) throws -> MTLTexture {
            guard let t = gpu.makePrivateTexture(width: max(Int(size.x), 1), height: max(Int(size.y), 1),
                                                 pixelFormat: format) else {
                throw RenderError.gpuBufferAllocationFailed
            }
            return t
        }
        let levels = plan.levels
        var images: [[MTLTexture]] = []
        var holes: [MTLTexture] = []
        var zones: [MTLTexture] = []
        for level in levels {
            images.append([try texture(level.size, .rgba16Float), try texture(level.size, .rgba16Float)])
            holes.append(try texture(level.size, .r8Uint))
            zones.append(try texture(level.size, .r8Uint))
        }
        // Match textures sized for the finest level's, the largest.
        let nnfSize = levels[0].nnfSize
        let nnfs = [try texture(nnfSize, .rgba32Float), try texture(nnfSize, .rgba32Float)]

        // The object outline, one byte a cell; a texel placeholder without.
        let maskTexture: MTLTexture
        do {
            let w = plan.mask?.width ?? 1, h = plan.mask?.height ?? 1
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.gpuBufferAllocationFailed }
            let bytes = plan.mask?.cellBytes ?? [0]
            bytes.withUnsafeBytes {
                t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w)
            }
            maskTexture = t
        }

        let pipelines = try (
            prepare: gpu.lazyPipeline(.removePrepare), downsample: gpu.lazyPipeline(.removeDownsample),
            zone: gpu.lazyPipeline(.removeZone), initNNF: gpu.lazyPipeline(.removeInitNNF),
            upsample: gpu.lazyPipeline(.removeUpsampleNNF), propagate: gpu.lazyPipeline(.removePropagate),
            search: gpu.lazyPipeline(.removeRandomSearch), vote: gpu.lazyPipeline(.removeVote),
            composite: gpu.lazyPipeline(.removeComposite))
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        defer { encoder.endEncoding() }
        var region = plan.region
        let regionBytes = MemoryLayout<RemoveRegionGPU>.stride
        let levelBytes = MemoryLayout<RemoveLevelGPU>.stride

        // Level 0 from the working texture, then the pyramid.
        encoder.setComputePipelineState(pipelines.prepare)
        encoder.setTexture(working, index: 0)
        encoder.setTexture(images[0][0], index: 1)
        encoder.setTexture(holes[0], index: 2)
        encoder.setTexture(maskTexture, index: 3)
        encoder.setBytes(&region, length: regionBytes, index: 0)
        var path = plan.path.isEmpty ? [SIMD2<Float>.zero] : plan.path
        encoder.setBytes(&path, length: path.count * MemoryLayout<SIMD2<Float>>.stride, index: 1)
        dispatch(encoder, pipelines.prepare, region.size)
        for l in levels.indices.dropFirst() {
            var fine = levels[l - 1].size, coarse = levels[l].size
            encoder.setComputePipelineState(pipelines.downsample)
            encoder.setTexture(images[l - 1][0], index: 0)
            encoder.setTexture(holes[l - 1], index: 1)
            encoder.setTexture(images[l][0], index: 2)
            encoder.setTexture(holes[l], index: 3)
            encoder.setBytes(&fine, length: 8, index: 0)
            encoder.setBytes(&coarse, length: 8, index: 1)
            dispatch(encoder, pipelines.downsample, coarse)
        }
        for l in levels.indices {
            var size = levels[l].size
            encoder.setComputePipelineState(pipelines.zone)
            encoder.setTexture(holes[l], index: 0)
            encoder.setTexture(zones[l], index: 1)
            encoder.setBytes(&size, length: 8, index: 0)
            dispatch(encoder, pipelines.zone, size)
        }

        // Coarse to fine. `current` is the image each level reads; the vote
        // writes the other and they swap. `match` is the match texture
        // holding the latest matches. Every dispatch gets its own pass
        // number, so no two draw the same random numbers.
        var pass: UInt32 = 0
        var match = 0
        var current = Array(repeating: 0, count: levels.count)
        func run(_ pso: MTLComputePipelineState, _ level: inout RemoveLevelGPU, textures: [MTLTexture],
                 coarser: RemoveLevelGPU? = nil, grid: SIMD2<Int32>) {
            pass &+= 1
            level.pass = pass
            encoder.setComputePipelineState(pso)
            for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
            encoder.setBytes(&level, length: levelBytes, index: 0)
            if var coarser { encoder.setBytes(&coarser, length: levelBytes, index: 1) }
            dispatch(encoder, pso, grid)
        }
        // Propagation steps halving from up to 8 texels (a quarter of the
        // match box for a small one), then random search.
        func searchPass(_ level: inout RemoveLevelGPU, _ l: Int) {
            var step: Int32 = 1
            while step * 2 <= min(8, max(1, level.nnfSize.max() / 4)) { step *= 2 }
            while step >= 1 {
                level.step = step
                run(pipelines.propagate, &level,
                    textures: [images[l][current[l]], zones[l], nnfs[match], nnfs[1 - match]], grid: level.nnfSize)
                match = 1 - match
                step /= 2
            }
            run(pipelines.search, &level,
                textures: [images[l][current[l]], zones[l], nnfs[match], nnfs[1 - match]], grid: level.nnfSize)
            match = 1 - match
        }
        func vote(_ level: inout RemoveLevelGPU, _ l: Int) {
            run(pipelines.vote, &level,
                textures: [images[l][current[l]], zones[l], nnfs[match], images[l][1 - current[l]]], grid: level.size)
            current[l] = 1 - current[l]
        }
        for l in levels.indices.reversed() {
            var level = levels[l]
            let coarsest = l == levels.count - 1
            // The hole still holds the object until the first vote, so the
            // first matches are scored on the known pixels alone.
            level.useHole = 0
            if coarsest {
                run(pipelines.initNNF, &level,
                    textures: [images[l][current[l]], zones[l], nnfs[1 - match]], grid: level.nnfSize)
                match = 1 - match
                searchPass(&level, l)
            } else {
                // The coarser level's matches, placed by its own box.
                run(pipelines.upsample, &level,
                    textures: [images[l][current[l]], zones[l], nnfs[match], nnfs[1 - match]],
                    coarser: levels[l + 1], grid: level.nnfSize)
                match = 1 - match
            }
            vote(&level, l)
            level.useHole = 1
            let iterations = coarsest ? 5 : (l == 0 ? 2 : 3)
            for _ in 0..<iterations {
                searchPass(&level, l)
                vote(&level, l)
            }
        }

        encoder.setComputePipelineState(pipelines.composite)
        encoder.setTexture(images[0][current[0]], index: 0)
        encoder.setTexture(holes[0], index: 1)
        encoder.setTexture(working, index: 2)
        encoder.setBytes(&region, length: regionBytes, index: 0)
        dispatch(encoder, pipelines.composite, region.size)
    }

    private static func dispatch(_ encoder: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState,
                                 _ size: SIMD2<Int32>) {
        let w = max(Int(size.x), 1), h = max(Int(size.y), 1)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }
}
