import Foundation
import simd

// What the dialog's preview stitches: the 1/8-scale copies the analysis
// already made, kept in memory so changing an option re-stitches without
// touching the raw files again.

/// Prepared frames held in memory, for the stitcher (`PanoramaFrameStore`
/// is the merge's, on disk). Half floats, the same layout the store keeps:
/// straight linear camera RGB and coverage in alpha.
///
/// Safe from several threads: nothing changes after `init`.
final class PanoramaPreviewFrames: PanoramaBlendFrameSource, @unchecked Sendable {
    private let frames: [Int: PanoramaPreparedFrame]
    private let pixels: [Int: [Float16]]
    /// The photos these were made from, in capture order, so a merger can
    /// tell whether a cache belongs to the analysis it is given.
    let urls: [URL]
    /// Per photo, where it clips (`PanoramaFramePrep.Measured.clipLevel`).
    let clipLevels: [Float]
    let byteCount: Int

    /// The thumbnails of `inputs` (Float32 rgba at `thumbnailSpan`) as half
    /// floats. Frame `i` is photo `i`, in capture order.
    init(inputs: [PanoramaFrameInput], urls: [URL], clipLevels: [Float]) {
        var frames: [Int: PanoramaPreparedFrame] = [:], pixels: [Int: [Float16]] = [:], bytes = 0
        for (index, input) in inputs.enumerated() {
            let thumbnail = input.thumbnail
            var halves = [Float16](repeating: 0, count: thumbnail.width * thumbnail.height * 4)
            for i in halves.indices { halves[i] = Float16(min(max(thumbnail.rgba[i], -65_504), 65_504)) }
            frames[index] = PanoramaPreparedFrame(frameIndex: index, width: thumbnail.width,
                                                  height: thumbnail.height, sampleScale: 1 / Double(thumbnail.span))
            pixels[index] = halves
            bytes += halves.count * 2
        }
        self.frames = frames
        self.pixels = pixels
        self.urls = urls
        self.clipLevels = clipLevels
        byteCount = bytes
    }

    func preparedFrame(_ frameIndex: Int) -> PanoramaPreparedFrame? { frames[frameIndex] }

    func withPixels<Result>(of frameIndex: Int, _ body: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        guard let halves = pixels[frameIndex] else { throw PanoramaBlendError.missingFrame(frameIndex: frameIndex) }
        return try halves.withUnsafeBytes { try body($0) }
    }

    /// Nothing on disk to delete: the stitcher may call this freely.
    func removeScratch() {}
}

/// The one set of preview frames a merger holds, replaced by each analysis
/// and dropped by `releasePreviews()`.
final class PanoramaPreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: PanoramaPreviewFrames?

    /// Most memory the frames may take: 17 photos of 24 MP at 1/8 come to
    /// 52 MB, so only an unusually long panorama of unusually large photos
    /// goes over. Past it nothing is kept and a preview reads the photos
    /// again.
    static let budgetBytes = 512 << 20

    func store(_ made: PanoramaPreviewFrames) {
        lock.withLock { frames = made.byteCount <= Self.budgetBytes ? made : nil }
    }

    /// The frames for photos `urls`, or nil if they were never kept, were
    /// released, or belong to another set of photos.
    func frames(for urls: [URL]) -> PanoramaPreviewFrames? {
        lock.withLock { frames?.urls == urls ? frames : nil }
    }

    func release() { lock.withLock { frames = nil } }
}
