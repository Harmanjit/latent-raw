import Foundation
import Metal
import PixelEngine

/// Prepared frames on the GPU, loaded from the frame source when a warp
/// needs one and dropped, least recently used first, when the budget would
/// be exceeded. A stitch warps one frame at a time, so a single loaded
/// frame always suffices; the budget only saves loading the same frames
/// again for the next tile.
final class PanoramaFrameCache {
    private struct Entry {
        let texture: MTLTexture
        var lastUse: Int
    }

    private let kernels: MergePanoBlendKernels
    private let source: PanoramaBlendFrameSource
    private let budget: Int
    private var entries: [Int: Entry] = [:]
    /// Textures of frames no longer cached, kept to be refilled: the photos
    /// of one panorama are almost always the same size, so the stitch then
    /// allocates frame memory once instead of for every load.
    private var spare: [MTLTexture] = []
    private var clock = 0

    private(set) var uploads = 0
    private(set) var peakBytes = 0
    var bytes: Int { entries.values.reduce(0) { $0 + $1.texture.allocatedSize } + spare.reduce(0) { $0 + $1.allocatedSize } }

    init(kernels: MergePanoBlendKernels, source: PanoramaBlendFrameSource, budget: Int) {
        self.kernels = kernels
        self.source = source
        self.budget = budget
    }

    /// Photo `frameIndex`'s frame on the GPU (premultiplied, with mips).
    func texture(_ frameIndex: Int, frame: PanoramaPreparedFrame) throws -> MTLTexture {
        clock += 1
        if var entry = entries[frameIndex] {
            entry.lastUse = clock
            entries[frameIndex] = entry
            return entry.texture
        }
        // Make room first, so the old frames are gone before the new one
        // arrives. A mip chain adds a third to the frame's 8 bytes a pixel.
        let incoming = frame.byteCount * 4 / 3
        while !entries.isEmpty, bytes + incoming > budget {
            let oldest = entries.min { $0.value.lastUse < $1.value.lastUse }!.key
            if let texture = entries[oldest]?.texture {
                // Letting go isn't enough: Metal holds on to the command
                // buffers that used a texture for a while, so its memory
                // would only come back later. Marking it empty frees the
                // memory now (its contents go with it, and nothing reads it
                // again); keeping the texture lets the next frame refill it.
                texture.setPurgeableState(.empty)
                spare.append(texture)
            }
            entries[oldest] = nil
        }
        // A spare of the right size is refilled; the rest are let go.
        let reusable = spare.firstIndex { $0.width == frame.width && $0.height == frame.height }
        let reusing = reusable.map { spare.remove(at: $0) }
        spare.removeAll()
        // In a pool of its own: uploading autoreleases objects that hold the
        // texture, which would otherwise outlive its eviction.
        let texture = try autoreleasepool {
            try source.withPixels(of: frameIndex) { pixels -> MTLTexture in
                guard pixels.count >= frame.byteCount, let base = pixels.baseAddress else {
                    throw PanoramaBlendError.invalidFrame(frameIndex: frameIndex, reason: "fewer pixels than its size")
                }
                return try kernels.uploadFrame(base, width: frame.width, height: frame.height, reusing: reusing)
            }
        }
        entries[frameIndex] = Entry(texture: texture, lastUse: clock)
        uploads += 1
        peakBytes = max(peakBytes, bytes)
        return texture
    }

    func removeAll() {
        for entry in entries.values { entry.texture.setPurgeableState(.empty) }
        for texture in spare { texture.setPurgeableState(.empty) }
        entries = [:]
        spare = []
    }
}
