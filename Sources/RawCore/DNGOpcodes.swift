import Foundation

// MARK: - What a DNG asks to have done

/// The corrections a DNG carries in its opcode lists (DNG 1.3 and later,
/// TIFF tags 51009 OpcodeList2 and 51022 OpcodeList3) that Latent can
/// apply: lens-shading gain maps, radial vignetting and rectilinear
/// distortion. Phones and many mirrorless cameras write these instead of
/// fixing the raw data, and expect the reader to apply them.
///
/// Read by walking the file's TIFF directories here, in Swift, with every
/// offset and count checked against the file's size, rather than through
/// LibRaw: LibRaw keeps the opcode bytes to itself. The raw itself is still
/// decoded in the sandboxed service; this reads only a few small tags.
public struct DNGOpcodeList: Sendable, Equatable {
    public var gainMaps: [DNGGainMap] = []
    public var vignette: DNGFixVignetteRadial?
    public var warp: DNGWarpRectilinear?
    /// Opcode IDs present but not applied (WarpFisheye, the per-row and
    /// per-column ones, bad-pixel lists and so on), for the panel to say so.
    public var unsupported: [UInt32] = []
    /// A stable fingerprint of the opcode bytes, naming the gain map in
    /// caches.
    public var fingerprint: String = ""

    public init() {}

    /// True when nothing in the lists is something Latent applies.
    public var isEmpty: Bool { gainMaps.isEmpty && vignette == nil && warp == nil }
}

/// GainMap (opcode 9): per-position gains on a grid over the image, for a
/// rectangle of it and a set of planes, sampled bilinearly between grid
/// points. On a Bayer raw there is normally one per CFA position (Top and
/// Left 0 or 1, both pitches 2).
public struct DNGGainMap: Sendable, Equatable {
    public var top: Int, left: Int, bottom: Int, right: Int
    public var plane: Int, planes: Int
    public var rowPitch: Int, colPitch: Int
    public var pointsV: Int, pointsH: Int
    /// Grid spacing and origin, in fractions of the image's height (V) and
    /// width (H).
    public var spacingV: Double, spacingH: Double
    public var originV: Double, originH: Double
    public var mapPlanes: Int
    /// `pointsV x pointsH x mapPlanes` gains, row by row.
    public var gains: [Float]

    public init(top: Int, left: Int, bottom: Int, right: Int, plane: Int, planes: Int, rowPitch: Int, colPitch: Int,
                pointsV: Int, pointsH: Int, spacingV: Double, spacingH: Double, originV: Double, originH: Double,
                mapPlanes: Int, gains: [Float]) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
        self.plane = plane; self.planes = planes; self.rowPitch = rowPitch; self.colPitch = colPitch
        self.pointsV = pointsV; self.pointsH = pointsH
        self.spacingV = spacingV; self.spacingH = spacingH; self.originV = originV; self.originH = originH
        self.mapPlanes = mapPlanes; self.gains = gains
    }

    /// The gain at relative position (`v`, `h`) of the image (0...1 down
    /// and across) for map plane `mapPlane`: bilinear between the grid
    /// points, clamped to the grid at its edges, as the DNG SDK does.
    public func gain(v: Double, h: Double, mapPlane: Int) -> Float {
        let p = min(max(mapPlane, 0), mapPlanes - 1)
        func index(_ value: Double, origin: Double, spacing: Double, count: Int) -> (Int, Int, Double) {
            guard count > 1, spacing > 0 else { return (0, 0, 0) }
            let f = min(max((value - origin) / spacing, 0), Double(count - 1))
            let i = min(Int(f), count - 2)
            return (i, i + 1, f - Double(i))
        }
        let (r0, r1, fr) = index(v, origin: originV, spacing: spacingV, count: pointsV)
        let (c0, c1, fc) = index(h, origin: originH, spacing: spacingH, count: pointsH)
        func at(_ r: Int, _ c: Int) -> Double { Double(gains[(r * pointsH + c) * mapPlanes + p]) }
        let top = at(r0, c0) + (at(r0, c1) - at(r0, c0)) * fc
        let bottom = at(r1, c0) + (at(r1, c1) - at(r1, c0)) * fc
        return Float(top + (bottom - top) * fr)
    }
}

/// FixVignetteRadial (opcode 3): each pixel multiplied by
/// 1 + k0 r² + k1 r⁴ + k2 r⁶ + k3 r⁸ + k4 r¹⁰, r the distance from the
/// optical centre normalised to 1 at the farthest corner.
public struct DNGFixVignetteRadial: Sendable, Equatable {
    public var k: [Double]          // five
    /// Optical centre in fractions of width and height.
    public var centre: SIMD2<Double>

    public init(k: [Double], centre: SIMD2<Double>) { self.k = k; self.centre = centre }

    public func gain(atNormalisedRadius r: Double) -> Double {
        let r2 = r * r
        var power = r2, g = 1.0
        for c in k { g += c * power; power *= r2 }
        return g
    }
}

/// WarpRectilinear (opcode 1): for each plane, a destination pixel at
/// normalised radius r reads from the source at radius
/// r (kr0 + kr1 r² + kr2 r⁴ + kr3 r⁶), plus two tangential terms.
public struct DNGWarpRectilinear: Sendable, Equatable {
    public struct Plane: Sendable, Equatable {
        public var kr: [Double]     // four
        public var kt: [Double]     // two
        public init(kr: [Double], kt: [Double]) { self.kr = kr; self.kt = kt }

        public func radialFactor(atNormalisedRadius r: Double) -> Double {
            let r2 = r * r
            return kr[0] + kr[1] * r2 + kr[2] * r2 * r2 + kr[3] * r2 * r2 * r2
        }
    }
    public var planes: [Plane]
    public var centre: SIMD2<Double>

    public init(planes: [Plane], centre: SIMD2<Double>) { self.planes = planes; self.centre = centre }
}

// MARK: - Reading

public enum DNGOpcodes {
    public enum ReadError: Error, Equatable {
        case notTIFF
        case truncated
        case malformed(String)
    }

    static let opcodeList2Tag: UInt16 = 51009
    static let opcodeList3Tag: UInt16 = 51022
    static let newSubfileTypeTag: UInt16 = 254
    static let subIFDsTag: UInt16 = 330

    /// Limits that no real file comes near, so a crafted one can't make
    /// the reader loop or allocate without bound.
    static let maxDirectories = 64
    static let maxEntries = 4096
    static let maxListBytes = 32 << 20
    static let maxOpcodes = 512
    static let maxGainSamples = 4 << 20

    /// Whether a file at `path` is worth looking in: a DNG by its name.
    public static func mayHaveOpcodes(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "dng"
    }

    /// The opcodes of the DNG at `url`, or nil when it has none Latent
    /// applies or can't be read as a DNG. Memory-mapped, so only the pages
    /// the directories and lists sit on are read.
    public static func read(url: URL) -> DNGOpcodeList? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard let list = try? read(tiff: data), !list.isEmpty else { return nil }
        return list
    }

    /// The opcodes in a TIFF/DNG file's bytes. Empty when it has no opcode
    /// lists. Lists come from the main image's directory (NewSubfileType 0,
    /// usually a SubIFD of a DNG whose first directory is its preview),
    /// else the first directory that has any.
    public static func read(tiff data: Data) throws -> DNGOpcodeList {
        let reader = try TIFFReader(data: data)
        var queue = [try reader.u32(4)]
        var visited = Set<UInt32>()
        var candidates: [(isMain: Bool, list2: Range<Int>?, list3: Range<Int>?)] = []
        while let offset = queue.first, visited.count < maxDirectories {
            queue.removeFirst()
            guard offset != 0, !visited.contains(offset) else { continue }
            visited.insert(offset)
            let ifd = try reader.directory(at: Int(offset))
            if ifd.list2 != nil || ifd.list3 != nil {
                candidates.append((ifd.subfileType == 0, ifd.list2, ifd.list3))
            }
            queue += ifd.subIFDs
            if ifd.next != 0 { queue.append(ifd.next) }
        }
        guard let chosen = candidates.first(where: { $0.isMain }) ?? candidates.first else { return DNGOpcodeList() }
        var list = DNGOpcodeList()
        var fingerprint = FNV1a()
        for range in [chosen.list2, chosen.list3].compactMap({ $0 }) {
            let bytes = data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
            fingerprint.add(bytes)
            try parseList(Data(bytes), into: &list)
        }
        list.fingerprint = String(format: "%016llx", fingerprint.value)
        return list
    }

    /// One opcode list. Always big-endian, whatever the file's byte order.
    static func parseList(_ bytes: Data, into list: inout DNGOpcodeList) throws {
        let r = BigEndianReader(data: bytes)
        let count = Int(try r.u32(0))
        guard count <= maxOpcodes else { throw ReadError.malformed("\(count) opcodes") }
        var position = 4
        for _ in 0..<count {
            let id = try r.u32(position)
            let size = Int(try r.u32(position + 12))
            let start = position + 16
            guard size >= 0, start + size <= bytes.count else { throw ReadError.truncated }
            switch id {
            case 1: list.warp = try parseWarp(r, at: start, size: size)
            case 3: list.vignette = try parseVignette(r, at: start, size: size)
            case 9: list.gainMaps.append(try parseGainMap(r, at: start, size: size))
            default: list.unsupported.append(id)
            }
            position = start + size
        }
    }

    static func parseWarp(_ r: BigEndianReader, at start: Int, size: Int) throws -> DNGWarpRectilinear {
        let n = Int(try r.u32(start))
        guard (1...4).contains(n), size >= 4 + n * 48 + 16 else { throw ReadError.malformed("WarpRectilinear") }
        var planes: [DNGWarpRectilinear.Plane] = []
        for p in 0..<n {
            let base = start + 4 + p * 48
            let values = try (0..<6).map { try r.f64(base + $0 * 8) }
            guard values.allSatisfy(\.isFinite) else { throw ReadError.malformed("WarpRectilinear") }
            planes.append(.init(kr: Array(values[0..<4]), kt: Array(values[4..<6])))
        }
        let cBase = start + 4 + n * 48
        let centre = SIMD2(try r.f64(cBase), try r.f64(cBase + 8))
        guard centre.x.isFinite, centre.y.isFinite else { throw ReadError.malformed("WarpRectilinear") }
        return DNGWarpRectilinear(planes: planes, centre: centre)
    }

    static func parseVignette(_ r: BigEndianReader, at start: Int, size: Int) throws -> DNGFixVignetteRadial {
        guard size >= 56 else { throw ReadError.malformed("FixVignetteRadial") }
        let values = try (0..<7).map { try r.f64(start + $0 * 8) }
        guard values.allSatisfy(\.isFinite) else { throw ReadError.malformed("FixVignetteRadial") }
        return DNGFixVignetteRadial(k: Array(values[0..<5]), centre: SIMD2(values[5], values[6]))
    }

    static func parseGainMap(_ r: BigEndianReader, at start: Int, size: Int) throws -> DNGGainMap {
        guard size >= 76 else { throw ReadError.malformed("GainMap") }
        let ints = try (0..<10).map { Int(try r.u32(start + $0 * 4)) }
        let doubles = try (0..<4).map { try r.f64(start + 40 + $0 * 8) }
        let mapPlanes = Int(try r.u32(start + 72))
        let (pointsV, pointsH) = (ints[8], ints[9])
        guard (1...4096).contains(pointsV), (1...4096).contains(pointsH), (1...4).contains(mapPlanes),
              pointsV * pointsH * mapPlanes <= maxGainSamples,
              ints[6] >= 1, ints[7] >= 1, ints[5] >= 1,
              doubles.allSatisfy(\.isFinite),
              pointsV == 1 || doubles[0] > 0, pointsH == 1 || doubles[1] > 0 else {
            throw ReadError.malformed("GainMap")
        }
        let samples = pointsV * pointsH * mapPlanes
        guard size >= 76 + samples * 4 else { throw ReadError.truncated }
        var gains = [Float](repeating: 1, count: samples)
        for i in 0..<samples {
            let g = try r.f32(start + 76 + i * 4)
            gains[i] = g.isFinite ? g : 1
        }
        return DNGGainMap(top: ints[0], left: ints[1], bottom: ints[2], right: ints[3], plane: ints[4], planes: ints[5],
                          rowPitch: ints[6], colPitch: ints[7], pointsV: pointsV, pointsH: pointsH,
                          spacingV: doubles[0], spacingH: doubles[1], originV: doubles[2], originH: doubles[3],
                          mapPlanes: mapPlanes, gains: gains)
    }
}

// MARK: - Byte readers

/// Bounds-checked reads in the TIFF's own byte order.
struct TIFFReader {
    let data: Data
    let littleEndian: Bool

    init(data: Data) throws {
        self.data = data
        guard data.count >= 8 else { throw DNGOpcodes.ReadError.notTIFF }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        if b0 == 0x49, b1 == 0x49 { littleEndian = true }
        else if b0 == 0x4D, b1 == 0x4D { littleEndian = false }
        else { throw DNGOpcodes.ReadError.notTIFF }
        guard try u16(2) == 42 else { throw DNGOpcodes.ReadError.notTIFF }
    }

    func byte(_ offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < data.count else { throw DNGOpcodes.ReadError.truncated }
        return data[data.startIndex + offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        let a = UInt16(try byte(offset)), b = UInt16(try byte(offset + 1))
        return littleEndian ? a | b << 8 : a << 8 | b
    }

    func u32(_ offset: Int) throws -> UInt32 {
        let a = UInt32(try u16(offset)), b = UInt32(try u16(offset + 2))
        return littleEndian ? a | b << 16 : a << 16 | b
    }

    struct Directory {
        var subfileType: UInt32 = 0
        var subIFDs: [UInt32] = []
        var list2: Range<Int>?
        var list3: Range<Int>?
        var next: UInt32 = 0
    }

    static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12: return 8
        default: return 0
        }
    }

    func directory(at offset: Int) throws -> Directory {
        let count = Int(try u16(offset))
        guard count <= DNGOpcodes.maxEntries else { throw DNGOpcodes.ReadError.malformed("\(count) entries") }
        var d = Directory()
        for i in 0..<count {
            let e = offset + 2 + i * 12
            let tag = try u16(e), type = try u16(e + 2)
            let n = Int(try u32(e + 4))
            let size = Self.typeSize(type)
            guard size > 0, n <= DNGOpcodes.maxListBytes else { continue }
            let bytes = n * size
            // Values of four bytes or fewer sit in the entry itself.
            let valueOffset = bytes <= 4 ? e + 8 : Int(try u32(e + 8))
            switch tag {
            case DNGOpcodes.newSubfileTypeTag where n >= 1:
                d.subfileType = type == 3 ? UInt32(try u16(valueOffset)) : try u32(valueOffset)
            case DNGOpcodes.subIFDsTag where size == 4:
                for j in 0..<min(n, DNGOpcodes.maxDirectories) { d.subIFDs.append(try u32(valueOffset + j * 4)) }
            case DNGOpcodes.opcodeList2Tag, DNGOpcodes.opcodeList3Tag:
                guard valueOffset >= 0, bytes >= 4, valueOffset + bytes <= data.count else {
                    throw DNGOpcodes.ReadError.truncated
                }
                if tag == DNGOpcodes.opcodeList2Tag { d.list2 = valueOffset..<(valueOffset + bytes) }
                else { d.list3 = valueOffset..<(valueOffset + bytes) }
            default:
                break
            }
        }
        d.next = (try? u32(offset + 2 + count * 12)) ?? 0
        return d
    }
}

/// Bounds-checked big-endian reads, for opcode lists.
struct BigEndianReader {
    let data: Data

    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw DNGOpcodes.ReadError.truncated }
        let s = data.startIndex + offset
        return UInt32(data[s]) << 24 | UInt32(data[s + 1]) << 16 | UInt32(data[s + 2]) << 8 | UInt32(data[s + 3])
    }

    func u64(_ offset: Int) throws -> UInt64 {
        UInt64(try u32(offset)) << 32 | UInt64(try u32(offset + 4))
    }

    func f64(_ offset: Int) throws -> Double { Double(bitPattern: try u64(offset)) }
    func f32(_ offset: Int) throws -> Float { Float(bitPattern: try u32(offset)) }
}

/// FNV-1a, 64-bit: a fingerprint that is the same in every process.
struct FNV1a {
    var value: UInt64 = 0xcbf29ce484222325
    mutating func add(_ bytes: some Sequence<UInt8>) {
        for b in bytes { value = (value ^ UInt64(b)) &* 0x100000001b3 }
    }
}
