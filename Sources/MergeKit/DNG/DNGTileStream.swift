// Turns a pixel source into the main image's tiles, one at a time.

import Accelerate
import Foundation
import os

#if !_endian(little)
#error("DNGTileStream writes half floats in memory order, which must be little-endian")
#endif

/// Produces the main image's tiles in the order the directory lists them:
/// left to right, top to bottom.
///
/// For each tile it asks the source for the part inside the image, lays it
/// into a full-size tile buffer (whatever the image doesn't reach stays 0),
/// divides by the normalisation, checks every sample, and hands the bytes
/// on, compressed or not. The buffers are reused, so memory stays at a few
/// tiles' worth, about 6 MB (a row of tiles more when compressing, which is
/// done in parallel).
///
/// The tile's bytes are the half floats exactly as they sit in memory. That
/// is little-endian on every Mac Latent runs on, which is the byte order the
/// file declares ("II"); the check above turns any other platform into a
/// build error rather than a file of scrambled pixels.
struct DNGTileStream {
    let pixels: LinearRawPixelSource
    let tileSize: Int
    let normalisation: ExposureNormalisation
    let compression: DNGTileCompression

    var tilesAcross: Int { (pixels.width + tileSize - 1) / tileSize }
    var tilesDown: Int { (pixels.height + tileSize - 1) / tileSize }
    /// Every tile is full size: 3 half floats, 2 bytes each, per pixel.
    var tileByteCount: Int { tileSize * tileSize * 3 * 2 }

    var imageData: TIFFImageData {
        let count = tilesAcross * tilesDown
        let uncompressed = count * tileByteCount
        switch compression {
        case .none:
            return TIFFImageData(chunkCount: count, maximumByteCount: uncompressed) { emit in
                try produceUncompressed(emit)
            }
        case .deflate(let predictor):
            // Deflate can grow data that doesn't compress; zlib's bound covers it.
            let bound = count * FloatDeflate.compressionBound(tileByteCount)
            return TIFFImageData(chunkCount: count, maximumByteCount: max(bound, uncompressed)) { emit in
                try produceDeflated(predictor: predictor, emit)
            }
        }
    }

    /// The part of tile (column, row) inside the image.
    func region(column: Int, row: Int) -> PixelRegion {
        let x = column * tileSize, y = row * tileSize
        return PixelRegion(x: x, y: y, width: min(tileSize, pixels.width - x), height: min(tileSize, pixels.height - y))
    }

    private func produceUncompressed(_ emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        let buffers = TileBuffers(samples: tileSize * tileSize * 3)
        for row in 0..<tilesDown {
            for column in 0..<tilesAcross {
                try Task.checkCancellation()
                try fillTile(buffers, region: region(column: column, row: row))
                try emit(UnsafeRawBufferPointer(buffers.halfFloats))
            }
        }
    }

    private func produceDeflated(predictor: FloatPredictor, _ emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        let buffers = TileBuffers(samples: tileSize * tileSize * 3)
        let across = tilesAcross, size = tileSize
        for row in 0..<tilesDown {
            // The source is read on this thread, in order; only compression,
            // which touches nothing shared, runs in parallel.
            var raw: [[UInt8]] = []
            raw.reserveCapacity(across)
            for column in 0..<across {
                try Task.checkCancellation()
                try fillTile(buffers, region: region(column: column, row: row))
                raw.append(Array(UnsafeRawBufferPointer(buffers.halfFloats)))
            }
            let tiles = raw
            let results = OSAllocatedUnfairLock(initialState: [Result<[UInt8], any Error>](
                repeating: .success([]), count: across))
            DispatchQueue.concurrentPerform(iterations: across) { i in
                var bytes = tiles[i]
                FloatDeflate.predict(&bytes, width: size, rows: size, samplesPerPixel: 3, predictor: predictor)
                let compressed = Result { try FloatDeflate.compress(bytes) }
                results.withLock { $0[i] = compressed }
            }
            for result in results.withLock({ $0 }) {
                try result.get().withUnsafeBytes { try emit($0) }
            }
        }
    }

    /// Fills the tile buffer with the region's pixels, normalised, zeros elsewhere.
    ///
    /// Bulk copies go through `memset` and `copyMemory` (memmove) rather
    /// than element loops: a Swift loop over a tile's 786,432 samples is
    /// quick in a release build but seconds per image in a debug one.
    private func fillTile(_ buffers: TileBuffers, region: PixelRegion) throws {
        let tile = buffers.halfFloats
        guard let base = tile.baseAddress else { return }
        memset(base, 0, tile.count * MemoryLayout<Float16>.stride)
        let samples = region.pixelCount * 3
        if region.width == tileSize {
            // A full-width tile: the region's rows are the tile's first rows,
            // so the source can write straight into it.
            try pixels.fill(region, UnsafeMutableBufferPointer(rebasing: tile[0..<samples]))
        } else {
            // A right-edge tile: rows are narrower than the tile's, so the
            // source fills a compact buffer and each row is copied to the
            // start of its tile row.
            let edge = UnsafeMutableBufferPointer(rebasing: buffers.edge[0..<samples])
            try pixels.fill(region, edge)
            guard let edgeBase = edge.baseAddress else { return }
            let rowBytes = region.width * 3 * MemoryLayout<Float16>.stride
            for row in 0..<region.height {
                UnsafeMutableRawPointer(base + row * tileSize * 3)
                    .copyMemory(from: edgeBase + row * region.width * 3, byteCount: rowBytes)
            }
        }
        try normalise(buffers, region: region)
    }

    /// Divides every sample by 2^shift and checks it landed within ±1.0.
    ///
    /// Accelerate does the arithmetic a whole tile per call, for the same
    /// reason as above; its half-float conversions use the CPU's own
    /// instructions. Going through 32-bit floats changes nothing: every half
    /// float converts exactly, the product is exact, and converting back
    /// rounds exactly as multiplying the half floats directly would.
    private func normalise(_ buffers: TileBuffers, region: PixelRegion) throws {
        let count = buffers.halfFloats.count
        guard let floats = buffers.floats.baseAddress else { return }
        var halfBuffer = vImage_Buffer(data: buffers.halfFloats.baseAddress, height: 1,
                                       width: vImagePixelCount(count), rowBytes: count * 2)
        var floatBuffer = vImage_Buffer(data: floats, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        let flags = vImage_Flags(kvImageDoNotTile)
        guard vImageConvert_Planar16FtoPlanarF(&halfBuffer, &floatBuffer, flags) == kvImageNoError else {
            throw MergeDNGError.internalInconsistency("half-float conversion failed")
        }
        if normalisation.shift > 0 {
            var scale = normalisation.scale
            vDSP_vsmul(floats, 1, &scale, floats, 1, vDSP_Length(count))
            guard vImageConvert_PlanarFtoPlanar16F(&floatBuffer, &halfBuffer, flags) == kvImageNoError else {
                throw MergeDNGError.internalInconsistency("half-float conversion failed")
            }
        }
        // The largest magnitude finds values beyond ±1. It can't be trusted
        // with NaN, but the sum can: one NaN or infinity anywhere makes it
        // NaN or infinite, while a tile of values within ±1 sums to well
        // under Float's range.
        var largest: Float = 0, sum: Float = 0
        vDSP_maxmgv(floats, 1, &largest, vDSP_Length(count))
        vDSP_sve(floats, 1, &sum, vDSP_Length(count))
        guard sum.isFinite, largest <= 1 else {
            let bad = buffers.floats.first { !($0.magnitude <= 1) } ?? largest
            throw MergeDNGError.sampleOutOfRange(region: region, value: bad / normalisation.scale)
        }
    }
}

/// Working memory for one tile, allocated once per write.
final class TileBuffers {
    /// The tile as stored: half floats, full size.
    let halfFloats: UnsafeMutableBufferPointer<Float16>
    /// The same samples as 32-bit floats, for Accelerate.
    let floats: UnsafeMutableBufferPointer<Float>
    /// Where a right-edge tile's narrower rows are filled before being laid out.
    let edge: UnsafeMutableBufferPointer<Float16>

    init(samples: Int) {
        halfFloats = .allocate(capacity: samples)
        floats = .allocate(capacity: samples)
        edge = .allocate(capacity: samples)
        halfFloats.initialize(repeating: 0)
        floats.initialize(repeating: 0)
        edge.initialize(repeating: 0)
    }

    deinit {
        halfFloats.deallocate()
        floats.deallocate()
        edge.deallocate()
    }
}
