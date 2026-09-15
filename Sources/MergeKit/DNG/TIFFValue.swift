// The building blocks of a TIFF file's directories: field types, fractions,
// tag values and tag numbers.
//
// A TIFF file (and a DNG is a TIFF) is a short header followed by "Image
// File Directories" (IFDs). An IFD is a list of 12-byte entries; each entry
// says *which* property it is (the tag number), *how* its value is stored
// (the field type: 8-bit bytes, 16-bit shorts, fractions...), *how many*
// values there are, and then either the value itself, when it fits in 4
// bytes, or the file offset where the value is written. Pixels are not in
// the IFD at all: the IFD holds the offsets and byte counts of the chunks
// (strips or tiles) the pixels were cut into.

import Foundation

/// TIFF field types (TIFF 6.0 section 2) and the size of one element.
enum TIFFFieldType: UInt16, Sendable {
    case byte = 1, ascii = 2, short = 3, long = 4, rational = 5
    case sbyte = 6, undefined = 7, sshort = 8, slong = 9, srational = 10
    case float = 11, double = 12

    var elementSize: Int {
        switch self {
        case .byte, .ascii, .sbyte, .undefined: return 1
        case .short, .sshort: return 2
        case .long, .slong, .float: return 4
        case .rational, .srational, .double: return 8
        }
    }
}

/// An unsigned fraction, TIFF's RATIONAL: two 32-bit integers.
struct TIFFRational: Sendable, Equatable {
    var numerator: UInt32
    var denominator: UInt32

    init(_ numerator: UInt32, _ denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// The nearest fraction over a fixed denominator, or nil when `value`
    /// is negative, not a number, or too big for the numerator. Metadata
    /// comes from camera files, so a bad value must become an error the
    /// writer can report rather than a trap in the integer conversion.
    init?(_ value: Double, denominator: UInt32) {
        let scaled = (value * Double(denominator)).rounded()
        guard scaled.isFinite, scaled >= 0, scaled <= Double(UInt32.max) else { return nil }
        self.init(UInt32(scaled), denominator)
    }
}

/// A signed fraction, TIFF's SRATIONAL.
struct TIFFSRational: Sendable, Equatable {
    var numerator: Int32
    var denominator: Int32

    init(_ numerator: Int32, _ denominator: Int32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// The nearest fraction over a fixed denominator, or nil when it can't
    /// be represented (see `TIFFRational`).
    init?(_ value: Double, denominator: Int32) {
        let scaled = (value * Double(denominator)).rounded()
        guard scaled.isFinite, scaled >= Double(Int32.min), scaled <= Double(Int32.max) else { return nil }
        self.init(Int32(scaled), denominator)
    }
}

/// The value of one IFD entry.
///
/// Most cases are plain numbers or text. The last three are *references*:
/// values that are file offsets or sizes nobody knows until the file is laid
/// out. They always serialise as LONGs (4 bytes each) and their element
/// count is known up front, so an entry's size never depends on where things
/// end up, and the layout can be computed in one pass before anything is
/// written.
enum TIFFValue {
    case bytes([UInt8])
    /// Text. The NUL terminator TIFF requires is added when serialising.
    case ascii(String)
    case shorts([UInt16])
    case longs([UInt32])
    case rationals([TIFFRational])
    case undefined([UInt8])
    case slongs([Int32])
    case srationals([TIFFSRational])
    case floats([Float])
    case doubles([Double])
    /// Child directories (SubIFDs, the EXIF IFD): written as their offsets.
    case directories([TIFFDirectory])
    /// The offsets of this directory's image chunks (StripOffsets or TileOffsets).
    case imageChunkOffsets
    /// The byte counts of this directory's image chunks, known once written.
    case imageChunkByteCounts

    var type: TIFFFieldType {
        switch self {
        case .bytes: return .byte
        case .ascii: return .ascii
        case .shorts: return .short
        case .longs, .directories, .imageChunkOffsets, .imageChunkByteCounts: return .long
        case .rationals: return .rational
        case .undefined: return .undefined
        case .slongs: return .slong
        case .srationals: return .srational
        case .floats: return .float
        case .doubles: return .double
        }
    }
}

/// Tag numbers this writer uses (TIFF 6.0, TIFF/EP, EXIF 2.3, DNG 1.4).
enum TIFFTag {
    static let newSubfileType: UInt16 = 254
    static let imageWidth: UInt16 = 256
    static let imageLength: UInt16 = 257
    static let bitsPerSample: UInt16 = 258
    static let compression: UInt16 = 259
    static let photometricInterpretation: UInt16 = 262
    static let make: UInt16 = 271
    static let model: UInt16 = 272
    static let stripOffsets: UInt16 = 273
    static let orientation: UInt16 = 274
    static let samplesPerPixel: UInt16 = 277
    static let rowsPerStrip: UInt16 = 278
    static let stripByteCounts: UInt16 = 279
    static let planarConfiguration: UInt16 = 284
    static let software: UInt16 = 305
    static let dateTime: UInt16 = 306
    static let predictor: UInt16 = 317
    static let tileWidth: UInt16 = 322
    static let tileLength: UInt16 = 323
    static let tileOffsets: UInt16 = 324
    static let tileByteCounts: UInt16 = 325
    static let subIFDs: UInt16 = 330
    static let sampleFormat: UInt16 = 339
    static let xmp: UInt16 = 700
    static let exposureTime: UInt16 = 33434
    static let fNumber: UInt16 = 33437
    static let exifIFD: UInt16 = 34665
    static let isoSpeedRatings: UInt16 = 34855
    static let exifVersion: UInt16 = 36864
    static let dateTimeOriginal: UInt16 = 36867
    static let focalLength: UInt16 = 37386
    static let lensSpecification: UInt16 = 42034
    static let lensMake: UInt16 = 42035
    static let lensModel: UInt16 = 42036
    static let dngVersion: UInt16 = 50706
    static let dngBackwardVersion: UInt16 = 50707
    static let uniqueCameraModel: UInt16 = 50708
    static let blackLevel: UInt16 = 50714
    static let whiteLevel: UInt16 = 50717
    static let defaultCropOrigin: UInt16 = 50719
    static let defaultCropSize: UInt16 = 50720
    static let colorMatrix1: UInt16 = 50721
    static let asShotNeutral: UInt16 = 50728
    static let baselineExposure: UInt16 = 50730
    static let lensInfo: UInt16 = 50736
    static let calibrationIlluminant1: UInt16 = 50778
    static let previewColorSpace: UInt16 = 50970
}
