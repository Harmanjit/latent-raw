// Deflate (TIFF Compression 8) with the floating-point predictor
// (Predictor 3, Adobe's TIFF Technical Note 3; 34894 and 34895 are DNG 1.4's
// "X2" and "X4" variants, which difference every 2nd or 4th pixel instead).
//
// Raw IEEE float bytes look random to deflate: the low byte of a sample
// changes wildly between neighbours even when the value barely does. The
// predictor rearranges each row so that similar bytes sit next to each other
// and then stores differences, which are mostly small numbers deflate
// squeezes well. Per row of a chunk it:
//   1. writes each sample big-endian and regroups the bytes into planes
//      (every sample's most significant byte, then every next byte...);
//   2. replaces each byte with its difference from the byte `distance`
//      positions earlier (distance = samples per pixel x the variant's factor).
// LibRaw's DecodeFPDelta undoes exactly this; the Phase 0 spike checked the
// round trip bit for bit.
//
// Only for tiles: Apple's RawCamera crashes on deflate-compressed *strips*
// (docs/PhotoMerge.md section 0), so the writer never offers that pairing.

import Foundation
import zlib

/// The predictor stored with deflate-compressed tiles.
public enum FloatPredictor: UInt16, Sendable, CaseIterable {
    case none = 1
    case floatingPoint = 3
    case floatingPointX2 = 34894
    case floatingPointX4 = 34895

    var factor: Int {
        switch self {
        case .none, .floatingPoint: return 1
        case .floatingPointX2: return 2
        case .floatingPointX4: return 4
        }
    }
}

enum FloatDeflate {
    /// Applies the predictor in place to a chunk of little-endian float16
    /// samples: `width` pixels per row, `rows` rows, `samplesPerPixel` each.
    static func predict(_ chunk: inout [UInt8], width: Int, rows: Int, samplesPerPixel: Int,
                        predictor: FloatPredictor) {
        guard predictor != .none else { return }
        let samplesPerRow = width * samplesPerPixel
        let rowBytes = samplesPerRow * 2
        let distance = samplesPerPixel * predictor.factor
        var planes = [UInt8](repeating: 0, count: rowBytes)
        chunk.withUnsafeMutableBufferPointer { buffer in
            for row in 0..<rows {
                let base = row * rowBytes
                // 1. Byte planes, most significant first.
                for s in 0..<samplesPerRow {
                    planes[s] = buffer[base + s * 2 + 1]
                    planes[samplesPerRow + s] = buffer[base + s * 2]
                }
                // 2. Differences, back to front so each uses the original earlier byte.
                var i = rowBytes - 1
                while i >= distance {
                    planes[i] = planes[i] &- planes[i - distance]
                    i -= 1
                }
                for i in 0..<rowBytes { buffer[base + i] = planes[i] }
            }
        }
    }

    /// The most bytes `compress` can return for `byteCount` bytes: deflate
    /// makes data that doesn't compress slightly bigger.
    static func compressionBound(_ byteCount: Int) -> Int {
        Int(compressBound(uLong(byteCount)))
    }

    /// zlib-wrapped deflate, which TIFF Compression 8 means (LibRaw calls
    /// zlib's `uncompress`, which checks the zlib header and Adler-32 sum).
    static func compress(_ bytes: [UInt8], level: Int32 = 6) throws -> [UInt8] {
        var destinationLength = compressBound(uLong(bytes.count))
        var out = [UInt8](repeating: 0, count: Int(destinationLength))
        let status = compress2(&out, &destinationLength, bytes, uLong(bytes.count), level)
        guard status == Z_OK else { throw MergeDNGError.compressionFailed(status: status) }
        out.removeSubrange(Int(destinationLength)...)
        return out
    }
}
