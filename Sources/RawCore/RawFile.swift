import Foundation
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
    /// The Bayer order at the plane's (0, 0), i.e. the active area's corner.
    public let cfaPattern: CFAPattern
    public let cameraMultipliers: (Float, Float, Float, Float)
    public let blackLevel: Float
    public let whiteLevel: Float
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

/// Which demosaic family a file needs. Only `.bayer` gets the full v1
/// GPU treatment for now (DESIGN.md §9.1).
public enum CFAPattern: Sendable {
    case bayer(order: UInt8)   // packed 2x2 order, straight from LibRaw's `filters`
    case xTrans                // v1.x
    case monochrome            // no demosaic needed at all
    case other                 // four-colour CFA, Foveon, etc. — LibRaw CPU fallback

    init(rawValue: UInt8) {
        switch rawValue {
        case 0xFF: self = .other
        default:   self = .bayer(order: rawValue)
        }
    }

    /// The byte LibRaw gave us, for transport across the decoder service.
    var rawCode: UInt8 {
        switch self {
        case .bayer(let order): order
        default: 0xFF
        }
    }
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

    /// The unpacked sensor data; nil for metadata-only opens.
    public let sensorPlane: SensorPlane?
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
        }
        isMetadataOnly = metadataOnly
        decodedInService = false
    }

    /// Decoded by the service. The plane arrives as a shared surface the
    /// service filled; nothing is copied on this side.
    private init(remoteFileDescriptor fd: Int32, metadataOnly: Bool) throws {
        let reply = try RawDecoderClient.shared.decode(fileDescriptor: fd, metadataOnly: metadataOnly)
        let meta = reply.metadata
        if metadataOnly {
            sensorPlane = nil
        } else {
            // Every stage indexes the plane as width x height, so a reply
            // whose count disagrees with its own dimensions is refused
            // here, before anything reads past what the surface holds.
            guard let surface = reply.plane, meta.planeSampleCount == meta.width * meta.height,
                  let plane = SensorPlane(surface: surface, count: meta.planeSampleCount) else {
                throw RawDecoderClient.ClientError.serviceFailed("no usable sensor plane in reply")
            }
            sensorPlane = plane
        }
        preview = reply.preview
        lastThumbnailError = meta.thumbnailError
        isMetadataOnly = metadataOnly
        decodedInService = true
        summary = meta.summary
        cameraToXYZMatrixRaw = meta.cameraToXYZ
    }

    private static func readSummary(_ h: OpaquePointer) -> RawSummary {
        var c = CLibRawSummary()
        clibraw_get_summary(h, &c)
        func str<T>(_ field: T, _ capacity: Int) -> String {
            withUnsafePointer(to: field) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
        }
        return RawSummary(
            activeArea: SensorActiveArea(
                left: Int(c.left_margin), top: Int(c.top_margin), width: Int(c.width), height: Int(c.height),
                fullWidth: Int(c.raw_width), fullHeight: Int(c.raw_height)),
            cfaPattern: CFAPattern(rawValue: c.cfa_pattern),
            cameraMultipliers: (c.cam_mul.0, c.cam_mul.1, c.cam_mul.2, c.cam_mul.3),
            blackLevel: c.black_level, whiteLevel: c.white_level,
            cameraMake: str(c.camera_make, 64), cameraModel: str(c.camera_model, 64),
            lensModel: str(c.lens_model, 64),
            iso: c.iso, shutter: c.shutter, aperture: c.aperture, focalLength: c.focal_length,
            captureTime: Date(timeIntervalSince1970: TimeInterval(c.timestamp)),
            orientation: Int(c.orientation),
            lens: LensIdentity(
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
                            planeSampleCount: sensorPlane?.count ?? 0)
    }
}
