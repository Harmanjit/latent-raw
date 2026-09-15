import Foundation

// The panorama stitcher's contract (Phase 8b): what it takes, what it hands
// back, and how it reports. The geometry solver (Pano/Geometry) says where
// each photo goes (`PanoramaLayout`), the frame preparation (Pano/Prep)
// makes the pixels, and `PanoramaStitcher` warps, seams and blends them
// into the panorama a tile at a time. docs/PhotoMerge.md section 4
// describes the pipeline; PanoramaStitcher.swift the method.

/// One prepared photo as the stitcher sees it.
///
/// Pixels are rgba16Float, row by row: linear camera RGB at unit white
/// balance, lens-corrected, with alpha 1 inside the corrected image and 0
/// outside it (colour there is ignored). They are at the decode span's
/// resolution, so a full-resolution pixel (u, v) of the photo, as
/// `PanoramaCamera` measures it, is prepared pixel (u, v) x `sampleScale`
/// (both with the origin at the top-left corner of the top-left pixel).
public struct PanoramaPreparedFrame: Sendable, Equatable {
    /// The photo it was made from: `PanoramaCamera.frameIndex`.
    public let frameIndex: Int
    public let width: Int
    public let height: Int
    /// Prepared pixels per full-resolution pixel: 1 / decode span.
    public let sampleScale: Double

    public init(frameIndex: Int, width: Int, height: Int, sampleScale: Double) {
        self.frameIndex = frameIndex; self.width = width; self.height = height; self.sampleScale = sampleScale
    }

    /// Bytes of pixels: 4 half floats per pixel.
    public var byteCount: Int { width * height * 8 }
}

/// Where the stitcher reads prepared frames from. `PanoramaFrameStore`
/// (scratch files) is the app's; tests can supply their own.
public protocol PanoramaBlendFrameSource: AnyObject {
    /// The prepared frame of photo `frameIndex`, or nil if there is none.
    func preparedFrame(_ frameIndex: Int) -> PanoramaPreparedFrame?
    /// Calls `body` with the frame's pixels (`byteCount` bytes, see
    /// `PanoramaPreparedFrame`), valid only during the call.
    func withPixels<Result>(of frameIndex: Int, _ body: (UnsafeRawBufferPointer) throws -> Result) throws -> Result
    /// Deletes whatever holds the frames (scratch files). The stitcher calls
    /// it when a stitch finishes, fails or is cancelled, if asked to.
    func removeScratch()
}

/// How to stitch.
public struct PanoramaBlendOptions: Sendable, Equatable {
    /// Output pixels per side of a blend tile, before its apron; rounded up
    /// to a multiple of the tiles' pyramid unit (8 px for most panoramas).
    /// Larger tiles are a little faster and need a lot more GPU memory
    /// (roughly 120 bytes per pixel of tile plus apron; see
    /// `PanoramaBlendPlan.tileTextureBytes`). On a 16 GB Mac, a
    /// 16,384 x 6,400 px panorama of 17 photos takes 3.1 s of tiles and
    /// 780 MB at 1,024 px, and 2.3 s and 1,190 MB at 2,048 px.
    public var tileSize: Int
    /// The frames' clip level after exposure gains, in the frames' units
    /// (1 for unit white balance at gain 1). The blend works in
    /// log(x + eps) with eps = 1e-3 x this.
    public var clipLevel: Double
    /// How many bytes of prepared frames (with their mip levels) may sit on
    /// the GPU at once; the least recently used go first. At least one
    /// frame is always loaded, whatever this says. The default holds six
    /// 24 MP photos decoded at span 2; a smaller cache only means loading
    /// some of them again for the next row of tiles.
    public var frameCacheBytes: Int
    /// The number of pyramid levels to blend with; nil chooses from the
    /// width of the overlaps (`PanoramaBlendPlan.bands`).
    public var bands: Int?
    /// Delete the frame source's scratch files when the stitch completes,
    /// fails or is cancelled.
    public var removeScratchWhenFinished: Bool

    public init(tileSize: Int = 1024, clipLevel: Double = 1, frameCacheBytes: Int = 384 << 20, bands: Int? = nil,
                removeScratchWhenFinished: Bool = true) {
        self.tileSize = tileSize; self.clipLevel = clipLevel; self.frameCacheBytes = frameCacheBytes
        self.bands = bands; self.removeScratchWhenFinished = removeScratchWhenFinished
    }
}

/// One finished tile of the panorama, handed to the consumer in reading
/// order (left to right, top to bottom).
public struct PanoramaStitchedTile {
    /// Where the tile sits in the output image (`PanoramaOutputSize`'s pixels).
    public let region: PixelRegion
    /// `region.pixelCount x 4` half floats, row by row: straight (not
    /// premultiplied) linear camera RGB, and alpha, the share of the pixel
    /// any photo covers (0 with black colour outside every photo). Valid
    /// only during the call.
    public let pixels: UnsafeBufferPointer<Float16>
}

/// How far a stitch has got.
public struct PanoramaBlendProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Warping every photo at low resolution: seams, and the blend's
        /// coarse levels. `completed` counts photos.
        case seams
        /// Blending the full-resolution tiles. `completed` counts tiles.
        case tiles
    }

    public let stage: Stage
    public let completed: Int
    public let total: Int

    /// 0...1 over the whole stitch; the seams stage counts for a tenth.
    public var fraction: Double {
        let part = total > 0 ? Double(completed) / Double(total) : 1
        switch stage {
        case .seams: return 0.1 * part
        case .tiles: return 0.1 + 0.9 * part
        }
    }
}

/// The seam owners, at the resolution the seams were computed at.
public struct PanoramaSeamMap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Output pixels per map pixel along each side (8 up to 32,768 px wide).
    public let step: Int
    /// Per pixel, row by row: the owning photo's position in
    /// `PanoramaLayout.cameras`, or -1 where no photo covers it.
    public let labels: [Int16]
    /// Per pixel: the largest share of it any photo covers, 0...1.
    public let coverage: [Float]
}

/// What a stitch cost.
public struct PanoramaBlendStatistics: Sendable, Equatable {
    /// Seams and the blend's coarse levels.
    public var prepareSeconds: Double = 0
    /// Full-resolution tiles, including handing them to the consumer.
    public var tileSeconds: Double = 0
    public var tilesCompleted = 0
    /// Frames copied to the GPU (a frame evicted and needed again counts twice).
    public var frameUploads = 0
    /// The most texture memory the stitch itself held at once (frames,
    /// tiles, coarse levels), counted from the textures it made.
    public var peakTextureBytes = 0
    /// The most prepared-frame memory on the GPU at once.
    public var peakFrameCacheBytes = 0
    /// The largest rise of `MTLDevice.currentAllocatedSize` over its value
    /// when the stitcher was made, sampled at the stitch's fullest points.
    /// It counts every allocation in the process.
    public var peakDeviceBytes = 0

    public init() {}
}

public enum PanoramaBlendError: Error, Equatable, CustomStringConvertible {
    /// A camera's photo has no prepared frame.
    case missingFrame(frameIndex: Int)
    /// A prepared frame can't be used (empty, or no sample scale).
    case invalidFrame(frameIndex: Int, reason: String)
    /// The layout or output size can't be stitched.
    case invalidLayout(String)
    /// A scratch file couldn't be made, written or read.
    case scratchFile(String)

    public var description: String {
        switch self {
        case .missingFrame(let index): return "Photo \(index) has no prepared frame"
        case .invalidFrame(let index, let reason): return "Photo \(index)'s prepared frame can't be used: \(reason)"
        case .invalidLayout(let reason): return "The panorama can't be stitched: \(reason)"
        case .scratchFile(let reason): return "Panorama scratch file: \(reason)"
        }
    }
}
