import Foundation

/// Why a merge's DNG couldn't be written. Every case leaves no file behind.
public enum MergeDNGError: Error, Equatable, CustomStringConvertible {
    /// Width or height zero, negative, or beyond what TIFF can record.
    case invalidDimensions(width: Int, height: Int)
    /// Tiles must be a positive multiple of 16 pixels (DNG's recommendation,
    /// which some readers rely on).
    case invalidTileSize(Int)
    /// A pixel buffer of the wrong length for its stated size.
    case bufferSizeMismatch(expected: Int, actual: Int)
    /// The merge's maximum was infinity or NaN.
    case invalidMaximum(Float)
    /// A sample was NaN, infinite, or still beyond ±1.0 after normalisation,
    /// which means the maximum passed in was too small.
    case sampleOutOfRange(region: PixelRegion, value: Float)
    /// A metadata field couldn't be written as its tag requires.
    case invalidMetadata(String)
    case unsupportedTexture(String)
    case readbackFailed
    /// The preview JPEG or thumbnail couldn't be made from the image given.
    case previewEncodingFailed
    case compressionFailed(status: Int32)
    /// Classic TIFF offsets are 32-bit, so a file stops at 4 GB.
    case fileTooLarge(bytes: Int)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    /// A bug in the writer: its layout and its output disagreed.
    case internalInconsistency(String)

    public var description: String {
        switch self {
        case .invalidDimensions(let w, let h): return "An image of \(w) x \(h) pixels can't be written"
        case .invalidTileSize(let s): return "Tile size \(s) isn't a positive multiple of 16"
        case .bufferSizeMismatch(let e, let a): return "Expected \(e) pixel samples, got \(a)"
        case .invalidMaximum(let m): return "The merge's brightest value is \(m), which can't be stored"
        case .sampleOutOfRange(let r, let v): return "A sample of \(v) in the tile \(r) doesn't fit after normalisation"
        case .invalidMetadata(let why): return "Invalid DNG metadata: \(why)"
        case .unsupportedTexture(let why): return "Unsupported texture: \(why)"
        case .readbackFailed: return "Couldn't read the merged image back from the GPU"
        case .previewEncodingFailed: return "Couldn't make the DNG's preview images"
        case .compressionFailed(let s): return "Deflate compression failed (zlib status \(s))"
        case .fileTooLarge(let b): return "The DNG would be \(b / 1_000_000) MB; files stop at 4 GB"
        case .insufficientDiskSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough disk space: the merge needs \(f.string(fromByteCount: needed)) "
                + "and only \(f.string(fromByteCount: available)) is free"
        case .internalInconsistency(let why): return "DNG writer error: \(why)"
        }
    }
}
