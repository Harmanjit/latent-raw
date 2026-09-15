import Foundation
import IOSurface
import CLibRaw

/// Errors from opening or unpacking a raw file.
public enum RawFileError: Error, CustomStringConvertible {
    case fileNotFound(path: String)
    case mmapFailed(errno: Int32)
    case libRawOpenFailed
    case unsupportedCFA
    case planeAllocationFailed

    public var description: String {
        switch self {
        case .fileNotFound(let path):    return "No file at \(path)"
        case .mmapFailed(let e):          return "mmap failed (errno \(e))"
        case .libRawOpenFailed:           return "LibRaw could not open or unpack this file"
        case .unsupportedCFA:             return "Unsupported colour filter array"
        case .planeAllocationFailed:      return "Could not allocate memory for the sensor data"
        }
    }
}

/// Where the picture sits in the camera's sensor readout.
///
/// LibRaw unpacks the whole readout, `fullWidth x fullHeight`. Only the
/// active area inside it is picture: around it many cameras record
/// optically masked photosites (black strips a camera measures its black
/// level from, 100-250 columns on the left of a Canon file) or padding
/// with no image data (right and bottom columns on some Nikons). LibRaw
/// calls the active area "visible" and its offsets `left_margin` and
/// `top_margin`; its CFA pattern counts from the active area's corner.
///
/// `RawFile` copies only this rectangle into the sensor plane, so the
/// plane, every render and every edit coordinate start at the active
/// area's top-left photosite and nothing downstream sees the border.
public struct SensorActiveArea: Sendable, Equatable {
    public let left: Int
    public let top: Int
    public let width: Int
    public let height: Int
    /// The whole readout, border included.
    public let fullWidth: Int
    public let fullHeight: Int

    public init(left: Int, top: Int, width: Int, height: Int, fullWidth: Int, fullHeight: Int) {
        self.left = left; self.top = top; self.width = width; self.height = height
        self.fullWidth = fullWidth; self.fullHeight = fullHeight
    }

    /// True when the readout is all picture: nothing to cut away.
    public var isWholeReadout: Bool {
        left == 0 && top == 0 && width == fullWidth && height == fullHeight
    }

    /// True when the rectangle is non-empty and lies inside the readout,
    /// the condition for copying it out of a readout-sized buffer.
    public var isValid: Bool {
        left >= 0 && top >= 0 && width > 0 && height > 0
            && left + width <= fullWidth && top + height <= fullHeight
    }
}

/// Metadata pulled from a raw file cheaply, before any demosaic.
public struct RawSummary: Sendable {
    /// Where the picture is in the sensor readout (see `SensorActiveArea`).
    public let activeArea: SensorActiveArea
    /// The picture's size in photosites: LibRaw's visible size, which the
    /// catalog records as the image's dimensions.
    public var width: Int { activeArea.width }
    public var height: Int { activeArea.height }
    /// The sensor plane's size: the grid every render stage, mask and
    /// edit coordinate works in. The plane is cut to the active area, so
    /// this is the same as `width x height`; the pipeline's own name for
    /// it is kept because its code talks about "sensor" pixels.
    public var rawWidth: Int { activeArea.width }
    public var rawHeight: Int { activeArea.height }
    /// The Bayer order at the plane's (0, 0), i.e. the active area's
    /// corner, or `.linearRGB` for an image that is already demosaiced.
    public let cfaPattern: CFAPattern
    /// Which kind of source this is; see `RawSourceKind`.
    public var sourceKind: RawSourceKind { cfaPattern == .linearRGB ? .linearRGB : .bayer }
    public let cameraMultipliers: (Float, Float, Float, Float)
    /// The black level every channel shares. The render pipeline's Bayer
    /// stages subtract this one value.
    public let blackLevel: Float
    /// LibRaw's `maximum`: the value a saturated photosite reads.
    public let whiteLevel: Float
    /// The black level of each colour channel (R, G, B, and the Bayer
    /// quad's second green), in sensor counts: `blackLevel` plus LibRaw's
    /// per-channel offsets, with any repeating black pattern averaged in.
    /// Merging needs these, because a channel whose black sits a few
    /// counts higher tints every shadow once frames of different exposure
    /// are scaled to match. Today's renders don't use them yet.
    public let channelBlackLevels: SIMD4<Float>
    /// The largest value actually present in the image, in the units of
    /// `whiteLevel` (black not subtracted). Some cameras saturate below
    /// their nominal white, so where clipping starts is
    /// `min(whiteLevel, dataMaximum)`. 0 for metadata-only opens.
    public let dataMaximum: Float
    /// DNG BaselineExposure, in stops: how much brighter than its stored
    /// values the file asks to be shown. 0 for other raws and DNGs that
    /// don't say. The pipeline applies it only to linear sources, as a
    /// gain at the camera-RGB seam (see `ImageSession.sourceGain`).
    public let baselineExposure: Float
    /// A Photo Merge result's own description (clip level, whether lens
    /// correction is baked in), from its XMP. nil for everything else,
    /// and for a merge whose recipe can't be read.
    public let mergeInfo: LinearMergeInfo?
    public let cameraMake: String
    public let cameraModel: String
    public let lensModel: String
    public let iso: Double
    public let shutter: Double
    public let aperture: Double
    public let focalLength: Double
    public let captureTime: Date
    /// LibRaw's `flip`: 0 upright, 3 rotated 180°, 5 rotated 90° CCW,
    /// 6 rotated 90° CW. What the camera recorded, not yet applied.
    public let orientation: Int
    /// Lens identity for profile lookup (LensKit).
    public let lens: LensIdentity
}

/// What the file says about the lens, beyond its (often empty) name.
public struct LensIdentity: Sendable, Equatable {
    public let make: String
    /// Name from the maker notes, when the camera recorded one.
    public let makerNotesName: String
    public let makerLensID: UInt64
    public let nikonLensID: UInt8
    public let nikonLensType: UInt8
    public let minFocal: Double
    public let maxFocal: Double
    public let maxApertureAtMinFocal: Double
    public let maxApertureAtMaxFocal: Double
    /// Sensor crop factor vs 35mm, 0 when the file doesn't say.
    public let cropFactor: Double

    public var isZoom: Bool { maxFocal > minFocal + 0.5 }

    public init(make: String, makerNotesName: String, makerLensID: UInt64, nikonLensID: UInt8,
                nikonLensType: UInt8, minFocal: Double, maxFocal: Double,
                maxApertureAtMinFocal: Double, maxApertureAtMaxFocal: Double, cropFactor: Double) {
        self.make = make
        self.makerNotesName = makerNotesName
        self.makerLensID = makerLensID
        self.nikonLensID = nikonLensID
        self.nikonLensType = nikonLensType
        self.minFocal = minFocal
        self.maxFocal = maxFocal
        self.maxApertureAtMinFocal = maxApertureAtMinFocal
        self.maxApertureAtMaxFocal = maxApertureAtMaxFocal
        self.cropFactor = cropFactor
    }
}

/// Which demosaic family a file needs. `.bayer` and `.linearRGB` get the
/// full GPU treatment (DESIGN.md §9.1).
public enum CFAPattern: Sendable, Equatable {
    case bayer(order: UInt8)   // packed 2x2 order, straight from LibRaw's `filters`
    case xTrans                // v1.x
    case monochrome            // no demosaic needed at all
    case other                 // four-colour CFA, Foveon, etc. — LibRaw CPU fallback
    /// Already demosaiced: three colours at every pixel, from a LinearRaw
    /// DNG such as a Photo Merge result. Its pixels arrive as a
    /// `LinearPlane`, not a `SensorPlane`.
    case linearRGB

    /// The code a linear image travels under. A Bayer order byte packs a
    /// colour index (0 red, 1 green, 2 blue, 3 second green) for each
    /// photosite of the 2x2 quad, and every real Bayer quad contains a red,
    /// a 0. 0xFE is 11 11 11 10 in binary, colours 2, 3, 3, 3: no red, so
    /// no Bayer file produces it (and the shim reports the rare four-colour
    /// filter that would as 0xFF, "other").
    static let linearRGBCode: UInt8 = 0xFE

    init(rawValue: UInt8) {
        switch rawValue {
        case 0xFF: self = .other
        case Self.linearRGBCode: self = .linearRGB
        default:   self = .bayer(order: rawValue)
        }
    }

    /// The byte LibRaw gave us, for transport across the decoder service.
    var rawCode: UInt8 {
        switch self {
        case .bayer(let order): order
        case .linearRGB: Self.linearRGBCode
        default: 0xFF
        }
    }
}

/// The two kinds of image the render pipeline takes in.
public enum RawSourceKind: String, Sendable, Codable {
    /// A mosaic sensor readout: one colour per photosite, to be demosaiced.
    case bayer
    /// Linear camera RGB at unit white balance, already demosaiced (a
    /// LinearRaw DNG, such as a Photo Merge result).
    case linearRGB
}

/// A raw file, unpacked by LibRaw.
///
/// Two ways to get there. Inside the app bundle the decoding runs in the
/// `LatentRawDecoder` XPC service: a separate process with no file
/// access of its own, handed an open descriptor, sandboxed on its own.
/// A crafted file that exploits the decoder gets a process that can do
/// nothing, and the app sees an error rather than a crash. Everywhere
/// else (`swift run`, the CLI, tests) LibRaw runs in this process from a
/// read-only memory map.
///
/// Either way the result is the same: LibRaw is asked for everything
/// once (metadata, sensor plane, embedded preview) and closed straight
/// away, so its own copy of the sensor data is freed before the image is
/// ever shown. The plane lives in a `SensorPlane` that the GPU uses in
/// place.
public final class RawFile {
    public let summary: RawSummary
    /// True when opened with `metadataOnly`: no sensor plane is available.
    public let isMetadataOnly: Bool
    /// True when the decode ran in the isolated service.
    public let decodedInService: Bool

    /// The camera's XYZ -> camera-RGB characterization matrix, row-major
    /// 3x3 (LibRaw's 4th row is dropped; it only matters for four-colour
    /// CFAs). nil when LibRaw has no profile for this camera.
    ///
    /// This is the Adobe ColorMatrix convention. ColorKit inverts and
    /// composes it to build the camera -> working-space transform.
    public let cameraToXYZMatrixRaw: [Float]?

    /// The unpacked sensor data; nil for metadata-only opens and for
    /// linear sources.
    public let sensorPlane: SensorPlane?
    /// The pixels of a linear source (`summary.sourceKind == .linearRGB`);
    /// nil for metadata-only opens and for Bayer raws.
    public let linearPlane: LinearPlane?
    private let preview: Data?
    /// Diagnostic: the return code from LibRaw's thumbnail call.
    public let lastThumbnailError: Int32

    /// `metadataOnly` skips decoding the sensor data — EXIF, the colour
    /// matrix and the embedded preview are still available, at roughly a
    /// hundredth of the cost. The catalog uses this; rendering needs the
    /// full open.
    public convenience init(path: String, metadataOnly: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RawFileError.fileNotFound(path: path)
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw RawFileError.mmapFailed(errno: errno) }
        defer { close(fd) }
        if RawDecoderXPC.isServiceAvailable {
            try self.init(remoteFileDescriptor: fd, metadataOnly: metadataOnly)
        } else {
            try self.init(fileDescriptor: fd, metadataOnly: metadataOnly)
        }
    }

    /// In-process LibRaw over a read-only map of `fd`. The decoder
    /// service uses this on the descriptor it is handed.
    public init(fileDescriptor fd: Int32, metadataOnly: Bool) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw RawFileError.mmapFailed(errno: errno) }
        let length = Int(st.st_size)
        guard length > 0, let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            throw RawFileError.mmapFailed(errno: errno)
        }
        defer { munmap(mapped, length) }
        let opened = metadataOnly ? clibraw_open_buffer_metadata(mapped, length)
                                  : clibraw_open_buffer(mapped, length)
        guard let h = opened else { throw RawFileError.libRawOpenFailed }
        defer { clibraw_close(h) }

        summary = Self.readSummary(h)
        var matrix12 = [Float](repeating: 0, count: 12)
        let matrixResult = matrix12.withUnsafeMutableBufferPointer { buf in
            clibraw_get_cam_xyz(h, buf.baseAddress)
        }
        cameraToXYZMatrixRaw = (matrixResult == 0) ? Array(matrix12.prefix(9)) : nil
        (preview, lastThumbnailError) = Self.readPreview(h)

        if metadataOnly {
            sensorPlane = nil
            linearPlane = nil
        } else if summary.sourceKind == .linearRGB {
            sensorPlane = nil
            linearPlane = try Self.readLinearPlane(h, summary: summary)
        } else {
            var planeLength = 0
            guard let ptr = clibraw_get_raw_plane(h, &planeLength), planeLength > 0 else {
                throw RawFileError.libRawOpenFailed
            }
            let readout = UnsafeBufferPointer(start: ptr, count: planeLength / MemoryLayout<UInt16>.size)
            // The one copy: just the active area, straight into the surface
            // the GPU (and, from the service, the app) will read.
            guard let plane = SensorPlane(copying: summary.activeArea, of: readout) else {
                throw RawFileError.planeAllocationFailed
            }
            sensorPlane = plane
            linearPlane = nil
        }
        isMetadataOnly = metadataOnly
        decodedInService = false
    }

    /// The linear image LibRaw unpacked, copied once into a `LinearPlane`
    /// with the plane's contract applied (see `LinearPlane`).
    private static func readLinearPlane(_ h: OpaquePointer, summary: RawSummary) throws -> LinearPlane {
        var format = CLIBRAW_LINEAR_NONE
        var length = 0
        guard let pointer = clibraw_get_linear_image(h, &format, &length), length > 0 else {
            throw RawFileError.libRawOpenFailed
        }
        let sourceFormat: LinearPlane.SourceFormat
        switch format {
        case CLIBRAW_LINEAR_FLOAT3: sourceFormat = .float3
        case CLIBRAW_LINEAR_UINT16X3: sourceFormat = .uint16(count: 3)
        case CLIBRAW_LINEAR_UINT16X4: sourceFormat = .uint16(count: 4)
        default: throw RawFileError.unsupportedCFA
        }
        let black = summary.channelBlackLevels
        guard let plane = LinearPlane(copying: summary.activeArea,
                                      of: UnsafeRawBufferPointer(start: pointer, count: length),
                                      format: sourceFormat, channelBlack: SIMD3(black.x, black.y, black.z),
                                      white: summary.whiteLevel) else {
            throw RawFileError.planeAllocationFailed
        }
        return plane
    }

    /// Decoded by the service. The plane arrives as a shared surface the
    /// service filled; nothing is copied on this side.
    private convenience init(remoteFileDescriptor fd: Int32, metadataOnly: Bool) throws {
        let reply = try RawDecoderClient.shared.decode(fileDescriptor: fd, metadataOnly: metadataOnly)
        try self.init(serviceReply: reply.metadata, plane: reply.plane, preview: reply.preview,
                      metadataOnly: metadataOnly)
    }

    /// What the app makes of the service's reply: the metadata, and the
    /// surface adopted as the plane its metadata says it is. Separate from
    /// the connection so tests can hand it a reply of their own.
    init(serviceReply meta: RawSnapshotMetadata, plane surface: IOSurface?, preview: Data?,
         metadataOnly: Bool) throws {
        let summary = meta.summary
        if metadataOnly {
            sensorPlane = nil
            linearPlane = nil
        } else if summary.sourceKind == .linearRGB {
            // Four Float16 per pixel; the same check as below, in samples.
            guard let surface, meta.planeSampleCount == meta.width * meta.height * LinearPlane.channels,
                  let plane = LinearPlane(surface: surface, width: meta.width, height: meta.height) else {
                throw RawDecoderClient.ClientError.serviceFailed("no usable linear plane in reply")
            }
            sensorPlane = nil
            linearPlane = plane
        } else {
            // Every stage indexes the plane as width x height, so a reply
            // whose count disagrees with its own dimensions is refused
            // here, before anything reads past what the surface holds.
            guard let surface, meta.planeSampleCount == meta.width * meta.height,
                  let plane = SensorPlane(surface: surface, count: meta.planeSampleCount) else {
                throw RawDecoderClient.ClientError.serviceFailed("no usable sensor plane in reply")
            }
            sensorPlane = plane
            linearPlane = nil
        }
        self.preview = preview
        lastThumbnailError = meta.thumbnailError
        isMetadataOnly = metadataOnly
        decodedInService = true
        self.summary = summary
        cameraToXYZMatrixRaw = meta.cameraToXYZ
    }

    /// A linear source assembled in memory rather than read from a file:
    /// the summary and colour matrix of some image, with pixels that
    /// follow the `LinearPlane` contract. Tests use it to feed the
    /// pipeline known linear data.
    init(summary: RawSummary, cameraToXYZ: [Float]?, linearPlane: LinearPlane) {
        precondition(summary.sourceKind == .linearRGB
                        && linearPlane.width == summary.rawWidth && linearPlane.height == summary.rawHeight)
        self.summary = summary
        cameraToXYZMatrixRaw = cameraToXYZ
        self.linearPlane = linearPlane
        sensorPlane = nil
        preview = nil
        lastThumbnailError = 0
        isMetadataOnly = false
        decodedInService = false
    }

    /// A Bayer raw assembled in memory rather than read from a file (see
    /// `bayerSource`): the summary of some raw, with a sensor plane that
    /// matches it.
    init(summary: RawSummary, cameraToXYZ: [Float]?, sensorPlane: SensorPlane) {
        precondition(summary.sourceKind == .bayer && sensorPlane.count == summary.rawWidth * summary.rawHeight)
        self.summary = summary
        cameraToXYZMatrixRaw = cameraToXYZ
        self.sensorPlane = sensorPlane
        linearPlane = nil
        preview = nil
        lastThumbnailError = 0
        isMetadataOnly = false
        decodedInService = false
    }

    private static func readSummary(_ h: OpaquePointer) -> RawSummary {
        var c = CLibRawSummary()
        clibraw_get_summary(h, &c)
        func str<T>(_ field: T, _ capacity: Int) -> String {
            withUnsafePointer(to: field) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
        }
        let isLinear = c.is_linear_rgb != 0
        // Only a merge result carries merge info, and only a linear source
        // can be one, so ordinary raws skip the XML parse entirely.
        var mergeInfo: LinearMergeInfo?
        if isLinear {
            var xmpLength = 0
            if let xmp = clibraw_get_xmp(h, &xmpLength), xmpLength > 0 {
                mergeInfo = LinearMergeInfo.parse(xmpPacket: Data(bytes: xmp, count: xmpLength))
            }
        }
        // A merge's recipe carries its reference frame's lens exactly as
        // that raw described it, maker-notes name and IDs included. EXIF,
        // all a DNG can hold, has no room for those, so LibRaw's reading of
        // this file would match lens profiles on less than the source did.
        let recipeLens = mergeInfo?.lens
        return RawSummary(
            activeArea: SensorActiveArea(
                left: Int(c.left_margin), top: Int(c.top_margin), width: Int(c.width), height: Int(c.height),
                fullWidth: Int(c.raw_width), fullHeight: Int(c.raw_height)),
            cfaPattern: isLinear ? .linearRGB : CFAPattern(rawValue: c.cfa_pattern),
            cameraMultipliers: (c.cam_mul.0, c.cam_mul.1, c.cam_mul.2, c.cam_mul.3),
            blackLevel: c.black_level, whiteLevel: c.white_level,
            channelBlackLevels: SIMD4(c.channel_black.0, c.channel_black.1, c.channel_black.2, c.channel_black.3),
            dataMaximum: c.data_maximum, baselineExposure: c.baseline_exposure, mergeInfo: mergeInfo,
            cameraMake: str(c.camera_make, 64), cameraModel: str(c.camera_model, 64),
            lensModel: recipeLens?.model ?? str(c.lens_model, 64),
            iso: c.iso, shutter: c.shutter, aperture: c.aperture, focalLength: c.focal_length,
            captureTime: Date(timeIntervalSince1970: TimeInterval(c.timestamp)),
            orientation: Int(c.orientation),
            lens: recipeLens?.identity ?? LensIdentity(
                make: str(c.lens_make, 64), makerNotesName: str(c.lens_makernotes, 128),
                makerLensID: c.lens_id, nikonLensID: c.nikon_lens_id, nikonLensType: c.nikon_lens_type,
                minFocal: Double(c.lens_min_focal), maxFocal: Double(c.lens_max_focal),
                maxApertureAtMinFocal: Double(c.lens_max_ap_min_focal),
                maxApertureAtMaxFocal: Double(c.lens_max_ap_max_focal),
                cropFactor: Double(c.crop_factor)))
    }

    private static func readPreview(_ h: OpaquePointer) -> (Data?, Int32) {
        var length: Int = 0
        let rc = clibraw_get_thumbnail(h, nil, &length)
        guard rc == 0, length > 0 else { return (nil, rc) }
        var data = Data(count: length)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            var len = length
            return clibraw_get_thumbnail(h, buf.bindMemory(to: UInt8.self).baseAddress, &len) == 0
        }
        return (ok ? data : nil, rc)
    }

    /// The unpacked sensor plane. `PixelEngine` is the only module that
    /// should call this. Valid for the lifetime of this object.
    public func rawSensorPlane() -> UnsafeBufferPointer<UInt16>? {
        sensorPlane?.samples
    }

    /// The camera's embedded JPEG preview — the basis for unedited-image
    /// thumbnails (DESIGN.md §10). Returns nil if the file has none.
    public func embeddedJPEGPreview() -> Data? { preview }

    /// What the service sends back for this file.
    public var snapshotMetadata: RawSnapshotMetadata {
        RawSnapshotMetadata(summary: summary, cameraToXYZ: cameraToXYZMatrixRaw,
                            thumbnailError: lastThumbnailError, isMetadataOnly: isMetadataOnly,
                            planeSampleCount: sensorPlane?.count
                                ?? linearPlane.map { $0.width * $0.height * LinearPlane.channels } ?? 0)
    }
}
