import Foundation
import simd

/// An Adobe DNG Camera Profile (.dcp) read from disk.
///
/// A DCP is a small TIFF-structured file (magic "IIRC" or "MMCR" instead
/// of TIFF's 42) whose first IFD carries the colour tags of the DNG
/// specification: the matrices that take camera RGB to XYZ under one or
/// two calibration illuminants, optional hue/saturation/value tables that
/// bend colours the matrices can't, and an optional tone curve.
///
/// Only parsing lives here; `CameraProfileMath` turns a profile into the
/// matrix and tables a render uses. Latent never ships Adobe's profiles:
/// the user imports ones they have (from Adobe's DNG Converter, a camera
/// maker, or tools such as dcamprof), and nothing is downloaded.
public struct DCPProfile: Sendable, Equatable {
    /// ProfileName, or nil when the file has none.
    public var name: String?
    /// UniqueCameraModel: which camera the profile was made for, in
    /// Adobe's naming ("Nikon D750", "Sony ILCE-7M3").
    public var uniqueCameraModel: String?
    public var copyright: String?

    /// One calibration point: the illuminant (an EXIF LightSource code)
    /// and the matrices measured under it.
    public struct Calibration: Sendable, Equatable {
        public var illuminant: Int
        /// XYZ -> camera (reference) RGB, row-major as stored.
        public var colorMatrix: simd_float3x3?
        /// White-balanced camera RGB -> XYZ D50, row-major as stored.
        public var forwardMatrix: simd_float3x3?
        /// ProfileHueSatMapData for this illuminant.
        public var hueSatMap: HueSatTable?
    }

    /// The first and (for a dual-illuminant profile) second calibration.
    public var calibration1: Calibration
    public var calibration2: Calibration?

    /// ProfileLookTableData: a creative table applied after exposure.
    public var lookTable: HueSatTable?
    /// ProfileToneCurve: (input, output) pairs on [0, 1], linear light.
    public var toneCurve: [SIMD2<Float>]?
    /// BaselineExposureOffset, in stops.
    public var baselineExposureOffset: Float

    public init(name: String? = nil, uniqueCameraModel: String? = nil, copyright: String? = nil,
                calibration1: Calibration, calibration2: Calibration? = nil,
                lookTable: HueSatTable? = nil, toneCurve: [SIMD2<Float>]? = nil,
                baselineExposureOffset: Float = 0) {
        self.name = name
        self.uniqueCameraModel = uniqueCameraModel
        self.copyright = copyright
        self.calibration1 = calibration1
        self.calibration2 = calibration2
        self.lookTable = lookTable
        self.toneCurve = toneCurve
        self.baselineExposureOffset = baselineExposureOffset
    }

    /// True when the profile's tone curve would change anything.
    public var hasToneCurve: Bool {
        guard let curve = toneCurve, curve.count >= 2 else { return false }
        return curve.contains { abs($0.x - $0.y) > 1e-4 }
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case notAProfile
        case truncated
        case noColorMatrix
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notAProfile: return "This file isn't a DNG camera profile (.dcp)."
            case .truncated: return "The profile file is cut short."
            case .noColorMatrix: return "The profile has no colour matrix, so it can't describe a camera."
            case .malformed(let what): return "The profile's \(what) is malformed."
            }
        }
    }

    // MARK: - Parsing

    /// DNG tag numbers (DNG Specification 1.6, chapter 4 and 6).
    enum Tag {
        static let uniqueCameraModel = 50708
        static let colorMatrix1 = 50721
        static let colorMatrix2 = 50722
        static let calibrationIlluminant1 = 50778
        static let calibrationIlluminant2 = 50779
        static let profileName = 50936
        static let hueSatMapDims = 50937
        static let hueSatMapData1 = 50938
        static let hueSatMapData2 = 50939
        static let toneCurve = 50940
        static let copyright = 50942
        static let forwardMatrix1 = 50964
        static let forwardMatrix2 = 50965
        static let lookTableDims = 50981
        static let lookTableData = 50982
        static let hueSatMapEncoding = 51107
        static let lookTableEncoding = 51108
        static let baselineExposureOffset = 51109
    }

    /// The most values any one tag may hold. A 90 x 30 x 30 table is
    /// 243,000 floats, well past any real profile; this only stops a
    /// corrupt count from asking for gigabytes.
    static let maximumValues = 1 << 21

    /// Reads a .dcp file's bytes. Also accepts a plain TIFF/DNG (magic 42),
    /// whose first IFD can carry the same tags.
    public init(data: Data) throws {
        let reader = try TIFFReader(data: data)
        let entries = try reader.firstIFD()

        func matrix(_ tag: Int) throws -> simd_float3x3? {
            guard let e = entries[tag] else { return nil }
            let v = try reader.floats(e)
            guard v.count >= 9 else { throw ParseError.malformed("matrix") }
            return ColorKit.matrix(rows: [[v[0], v[1], v[2]], [v[3], v[4], v[5]], [v[6], v[7], v[8]]])
        }
        func int(_ tag: Int) throws -> Int? {
            guard let e = entries[tag] else { return nil }
            return try reader.floats(e).first.map { Int($0) }
        }
        func string(_ tag: Int) throws -> String? {
            guard let e = entries[tag] else { return nil }
            return try reader.string(e)
        }

        var hueSatDims: [Int]?
        if let e = entries[Tag.hueSatMapDims] { hueSatDims = try reader.floats(e).map { Int($0) } }
        let hueSatSRGB = try int(Tag.hueSatMapEncoding) == 1
        func table(_ tag: Int, dims: [Int]?, sRGB: Bool) throws -> HueSatTable? {
            guard let e = entries[tag], let dims else { return nil }
            let values = try reader.floats(e)
            guard let t = HueSatTable(dims: dims, values: values, sRGBValueEncoding: sRGB) else {
                throw ParseError.malformed("colour table")
            }
            return t.isIdentity ? nil : t
        }

        let cm1 = try matrix(Tag.colorMatrix1)
        guard let cm1 else { throw ParseError.noColorMatrix }
        let illuminant1 = try int(Tag.calibrationIlluminant1) ?? 21   // D65 when unstated
        calibration1 = Calibration(illuminant: illuminant1, colorMatrix: cm1,
                                   forwardMatrix: try matrix(Tag.forwardMatrix1),
                                   hueSatMap: try table(Tag.hueSatMapData1, dims: hueSatDims, sRGB: hueSatSRGB))
        if let cm2 = try matrix(Tag.colorMatrix2) {
            calibration2 = Calibration(illuminant: try int(Tag.calibrationIlluminant2) ?? 21,
                                       colorMatrix: cm2,
                                       forwardMatrix: try matrix(Tag.forwardMatrix2),
                                       hueSatMap: try table(Tag.hueSatMapData2, dims: hueSatDims, sRGB: hueSatSRGB))
        } else {
            calibration2 = nil
        }

        var lookDims: [Int]?
        if let e = entries[Tag.lookTableDims] { lookDims = try reader.floats(e).map { Int($0) } }
        lookTable = try table(Tag.lookTableData, dims: lookDims,
                              sRGB: try int(Tag.lookTableEncoding) == 1)

        if let e = entries[Tag.toneCurve] {
            let v = try reader.floats(e)
            guard v.count >= 4, v.count % 2 == 0 else { throw ParseError.malformed("tone curve") }
            var points: [SIMD2<Float>] = []
            for i in stride(from: 0, to: v.count, by: 2) {
                let x = v[i], y = v[i + 1]
                guard x.isFinite, y.isFinite else { throw ParseError.malformed("tone curve") }
                points.append(SIMD2(min(max(x, 0), 1), min(max(y, 0), 1)))
            }
            // The specification requires increasing inputs; a file that
            // breaks that can't be evaluated sensibly.
            for i in 1..<points.count where points[i].x <= points[i - 1].x {
                throw ParseError.malformed("tone curve")
            }
            toneCurve = points
        } else {
            toneCurve = nil
        }

        if let e = entries[Tag.baselineExposureOffset] {
            let v = try reader.floats(e).first ?? 0
            baselineExposureOffset = v.isFinite ? min(max(v, -5), 5) : 0
        } else {
            baselineExposureOffset = 0
        }

        name = try string(Tag.profileName)
        uniqueCameraModel = try string(Tag.uniqueCameraModel)
        copyright = try string(Tag.copyright)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Evaluates the tone curve at `x` (linear in, linear out), by
    /// piecewise-linear interpolation between its points. Adobe evaluates
    /// it as a cubic spline; between the dozens of points a real curve has,
    /// the difference is invisible.
    public func toneCurveValue(_ x: Float) -> Float {
        guard let c = toneCurve, c.count >= 2 else { return x }
        let x = min(max(x, 0), 1)
        if x <= c[0].x { return c[0].y }
        for i in 1..<c.count where x <= c[i].x {
            let a = c[i - 1], b = c[i]
            let t = (x - a.x) / max(b.x - a.x, 1e-9)
            return a.y + (b.y - a.y) * t
        }
        return c[c.count - 1].y
    }
}

// MARK: - TIFF structure

/// Just enough TIFF to read one IFD's tags, with every offset checked.
struct TIFFReader {
    let data: Data
    let littleEndian: Bool

    struct Entry {
        var type: Int
        var count: Int
        /// Where the value starts: in the entry itself when it fits in four
        /// bytes, otherwise at the offset the entry gives.
        var valueOffset: Int
    }

    init(data: Data) throws {
        guard data.count >= 8 else { throw DCPProfile.ParseError.notAProfile }
        self.data = data
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        if b0 == 0x49, b1 == 0x49 { littleEndian = true }
        else if b0 == 0x4D, b1 == 0x4D { littleEndian = false }
        else { throw DCPProfile.ParseError.notAProfile }
        let magic = Int(u16(at: 2))
        // 0x4352 is "RC" read in the file's byte order, the DCP magic.
        guard magic == 0x4352 || magic == 42 else { throw DCPProfile.ParseError.notAProfile }
    }

    func u16(at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        let a = UInt16(data[i]), b = UInt16(data[i + 1])
        return littleEndian ? (a | b << 8) : (a << 8 | b)
    }

    func u32(at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        let bytes = (0..<4).map { UInt32(data[i + $0]) }
        return littleEndian
            ? bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24
            : bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
    }

    func firstIFD() throws -> [Int: Entry] {
        let ifd = Int(u32(at: 4))
        guard ifd >= 8, ifd + 2 <= data.count else { throw DCPProfile.ParseError.truncated }
        let count = Int(u16(at: ifd))
        guard ifd + 2 + count * 12 <= data.count else { throw DCPProfile.ParseError.truncated }
        var entries: [Int: Entry] = [:]
        for n in 0..<count {
            let at = ifd + 2 + n * 12
            let tag = Int(u16(at: at))
            let type = Int(u16(at: at + 2))
            let valueCount = Int(u32(at: at + 4))
            guard let size = Self.typeSize(type) else { continue }   // unknown type: skip the tag
            guard valueCount <= DCPProfile.maximumValues else { throw DCPProfile.ParseError.malformed("tag \(tag)") }
            let bytes = size * valueCount
            let offset = bytes <= 4 ? at + 8 : Int(u32(at: at + 8))
            guard offset >= 0, offset + bytes <= data.count else { throw DCPProfile.ParseError.truncated }
            entries[tag] = Entry(type: type, count: valueCount, valueOffset: offset)
        }
        return entries
    }

    static func typeSize(_ type: Int) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return nil
        }
    }

    /// Any numeric entry as floats.
    func floats(_ e: Entry) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(e.count)
        for n in 0..<e.count {
            let at = e.valueOffset + n * (Self.typeSize(e.type) ?? 1)
            switch e.type {
            case 1, 7: out.append(Float(data[data.startIndex + at]))
            case 6: out.append(Float(Int8(bitPattern: data[data.startIndex + at])))
            case 3: out.append(Float(u16(at: at)))
            case 8: out.append(Float(Int16(bitPattern: u16(at: at))))
            case 4: out.append(Float(u32(at: at)))
            case 9: out.append(Float(Int32(bitPattern: u32(at: at))))
            case 5:
                let d = u32(at: at + 4)
                out.append(d == 0 ? 0 : Float(Double(u32(at: at)) / Double(d)))
            case 10:
                let d = Int32(bitPattern: u32(at: at + 4))
                out.append(d == 0 ? 0 : Float(Double(Int32(bitPattern: u32(at: at))) / Double(d)))
            case 11: out.append(Float(bitPattern: u32(at: at)))
            case 12:
                let hi = UInt64(u32(at: littleEndian ? at + 4 : at))
                let lo = UInt64(u32(at: littleEndian ? at : at + 4))
                out.append(Float(Double(bitPattern: hi << 32 | lo)))
            default: throw DCPProfile.ParseError.malformed("value type")
            }
        }
        return out
    }

    func string(_ e: Entry) throws -> String? {
        guard e.type == 2 || e.type == 1 || e.type == 7 else { return nil }
        let start = data.startIndex + e.valueOffset
        var bytes = Array(data[start..<(start + e.count)])
        if let nul = bytes.firstIndex(of: 0) { bytes.removeSubrange(nul...) }
        let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
