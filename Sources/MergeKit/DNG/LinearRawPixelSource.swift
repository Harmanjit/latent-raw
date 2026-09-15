// Where the writer gets its pixels: a rectangle at a time, so the image is
// never copied whole.

import Accelerate
import Foundation
import Metal

/// A rectangle of pixels, in the image's own coordinates (origin top-left).
public struct PixelRegion: Sendable, Equatable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var pixelCount: Int { width * height }
    public var description: String { "\(width)x\(height) at (\(x), \(y))" }
}

/// Supplies the linear camera-RGB pixels of the image being written.
///
/// The writer asks for one tile's worth at a time, in reading order (left to
/// right, top to bottom), and never for a region outside the image. `fill`
/// must write `region.pixelCount x 3` half floats into the buffer: red,
/// green, blue for each pixel, row by row. The values are the merge's own:
/// linear camera RGB at unit white balance, *before* the writer divides them
/// to fit under 1.0 (see `ExposureNormalisation`).
///
/// Asking by rectangle is what keeps memory flat: a 45 MP image in half
/// floats is 270 MB, and the writer only ever holds one tile (512 x 512
/// pixels, 1.5 MB) of it. Throwing from `fill` stops the write, and the
/// half-written file is deleted.
///
/// Not Sendable: a source may hold a Metal texture. Use it on one thread.
public struct LinearRawPixelSource {
    public let width: Int
    public let height: Int
    let fill: (PixelRegion, UnsafeMutableBufferPointer<Float16>) throws -> Void

    public init(width: Int, height: Int,
                fill: @escaping (_ region: PixelRegion, _ rgb: UnsafeMutableBufferPointer<Float16>) throws -> Void) {
        self.width = width
        self.height = height
        self.fill = fill
    }

    /// Pixels already in memory, `channelsPerPixel` (3 for RGB, 4 for RGBA
    /// with alpha ignored) half floats per pixel, row by row. Holding the
    /// whole image is fine for tests and small merges; large ones should
    /// stream from where the pixels already are, such as `texture(_:commandQueue:)`.
    public static func buffer(_ pixels: [Float16], width: Int, height: Int,
                              channelsPerPixel: Int = 3) throws -> LinearRawPixelSource {
        guard width > 0, height > 0, channelsPerPixel == 3 || channelsPerPixel == 4 else {
            throw MergeDNGError.invalidDimensions(width: width, height: height)
        }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, count <= Int.max / channelsPerPixel, pixels.count == count * channelsPerPixel else {
            throw MergeDNGError.bufferSizeMismatch(expected: overflow ? Int.max : count * channelsPerPixel,
                                                   actual: pixels.count)
        }
        return LinearRawPixelSource(width: width, height: height) { region, rgb in
            try pixels.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                let start = base + (region.y * width + region.x) * channelsPerPixel
                try PixelCopy.rgb(from: start, channels: channelsPerPixel, sourceRowSamples: width * channelsPerPixel,
                                  region: region, into: rgb)
            }
        }
    }

    /// Streams an `rgba16Float` texture back from the GPU, a band of rows at
    /// a time, dropping alpha.
    ///
    /// The texture can be private storage (the pipeline's usual kind, which
    /// the CPU can't read): each band is first copied into a shared-storage
    /// texture one band tall. With `bandHeight` 512 and a 45 MP image that
    /// band is about 34 MB, against 360 MB for a full readable copy. All
    /// work already queued on the texture must have finished.
    public static func texture(_ texture: MTLTexture, commandQueue: MTLCommandQueue,
                               bandHeight: Int = 512) throws -> LinearRawPixelSource {
        let reader = try TextureBandReader(texture: texture, commandQueue: commandQueue, bandHeight: bandHeight)
        return LinearRawPixelSource(width: texture.width, height: texture.height) { region, rgb in
            try reader.read(region, into: rgb)
        }
    }
}

/// Reads regions of a texture through a band-sized shared copy, re-copying
/// only when a region falls outside the band already read. The writer asks
/// in reading order, so each band is copied once.
final class TextureBandReader {
    private let texture: MTLTexture
    private let commandQueue: MTLCommandQueue
    private let bandHeight: Int
    /// nil when the texture is itself shared storage and can be read directly.
    private let band: MTLTexture?
    /// Rows of the texture the band currently holds.
    private var bandRows: Range<Int> = 0..<0
    /// RGBA scratch for one region; reused between calls.
    private var rgba: [Float16] = []

    init(texture: MTLTexture, commandQueue: MTLCommandQueue, bandHeight: Int) throws {
        guard texture.pixelFormat == .rgba16Float, texture.textureType == .type2D else {
            throw MergeDNGError.unsupportedTexture("expected a 2D rgba16Float texture, got \(texture.pixelFormat.rawValue)")
        }
        guard bandHeight > 0 else { throw MergeDNGError.unsupportedTexture("band height must be positive") }
        self.texture = texture
        self.commandQueue = commandQueue
        self.bandHeight = min(bandHeight, texture.height)
        if texture.storageMode == .shared {
            band = nil
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: texture.width, height: self.bandHeight, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            guard let made = commandQueue.device.makeTexture(descriptor: descriptor) else {
                throw MergeDNGError.readbackFailed
            }
            band = made
        }
    }

    func read(_ region: PixelRegion, into rgb: UnsafeMutableBufferPointer<Float16>) throws {
        let needed = region.pixelCount * 4
        if rgba.count < needed { rgba = [Float16](repeating: 0, count: needed) }
        // A region taller than a band is read one band-height slice at a time.
        var row = 0
        while row < region.height {
            let rows = min(region.height - row, bandHeight)
            let slice = PixelRegion(x: region.x, y: region.y + row, width: region.width, height: rows)
            try readSlice(slice)
            try rgba.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                let destination = UnsafeMutableBufferPointer(rebasing: rgb[(row * region.width * 3)...])
                try PixelCopy.rgb(from: base, channels: 4, sourceRowSamples: slice.width * 4,
                                  region: slice, into: destination)
            }
            row += rows
        }
    }

    /// Reads a region no taller than a band into the start of `rgba`.
    private func readSlice(_ region: PixelRegion) throws {
        let bytesPerRow = region.width * 4 * MemoryLayout<Float16>.size
        guard let band else {
            texture.getBytes(&rgba, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(region.x, region.y, region.width, region.height), mipmapLevel: 0)
            return
        }
        if !bandRows.contains(region.y) || region.y + region.height > bandRows.upperBound {
            let rows = min(bandHeight, texture.height - region.y)
            guard let commands = commandQueue.makeCommandBuffer(),
                  let blit = commands.makeBlitCommandEncoder() else { throw MergeDNGError.readbackFailed }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: region.y, z: 0),
                      sourceSize: MTLSize(width: texture.width, height: rows, depth: 1),
                      to: band, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            guard commands.status == .completed else { throw MergeDNGError.readbackFailed }
            bandRows = region.y..<(region.y + rows)
        }
        band.getBytes(&rgba, bytesPerRow: bytesPerRow,
                      from: MTLRegionMake2D(region.x, region.y - bandRows.lowerBound, region.width, region.height),
                      mipmapLevel: 0)
    }
}

/// Copies interleaved half floats into the writer's RGB layout. Whole rows
/// go through memmove, and dropping alpha through vImage (which treats the
/// samples as 16-bit integers: it moves bytes, so every half float arrives
/// bit for bit), because per-sample Swift loops are slow in debug builds.
enum PixelCopy {
    /// `region.height` rows of `region.width` pixels starting at `source`,
    /// whose rows are `sourceRowSamples` samples apart, into `rgb`.
    static func rgb(from source: UnsafePointer<Float16>, channels: Int, sourceRowSamples: Int,
                    region: PixelRegion, into rgb: UnsafeMutableBufferPointer<Float16>) throws {
        guard let destination = rgb.baseAddress, rgb.count >= region.pixelCount * 3 else {
            throw MergeDNGError.bufferSizeMismatch(expected: region.pixelCount * 3, actual: rgb.count)
        }
        if channels == 3 {
            for row in 0..<region.height {
                UnsafeMutableRawPointer(destination + row * region.width * 3)
                    .copyMemory(from: source + row * sourceRowSamples, byteCount: region.width * 3 * 2)
            }
            return
        }
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(region.height),
                                 width: vImagePixelCount(region.width), rowBytes: sourceRowSamples * 2)
        var to = vImage_Buffer(data: destination, height: vImagePixelCount(region.height),
                               width: vImagePixelCount(region.width), rowBytes: region.width * 3 * 2)
        guard vImageConvert_RGBA16UtoRGB16U(&from, &to, vImage_Flags(kvImageDoNotTile)) == kvImageNoError else {
            throw MergeDNGError.internalInconsistency("dropping alpha failed")
        }
    }
}
