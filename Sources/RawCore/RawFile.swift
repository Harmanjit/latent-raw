import Foundation
import CLibRaw

/// Errors from opening or unpacking a raw file.
public enum RawFileError: Error, CustomStringConvertible {
    case fileNotFound(path: String)
    case mmapFailed(errno: Int32)
    case libRawOpenFailed
    case unsupportedCFA

    public var description: String {
        switch self {
        case .fileNotFound(let path):    return "No file at \(path)"
        case .mmapFailed(let e):          return "mmap failed (errno \(e))"
        case .libRawOpenFailed:           return "LibRaw could not open or unpack this file"
        case .unsupportedCFA:             return "Unsupported colour filter array"
        }
    }
}

/// Metadata pulled from a raw file cheaply, before any demosaic.
public struct RawSummary: Sendable {
    public let width: Int
    public let height: Int
    public let rawWidth: Int
    public let rawHeight: Int
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
}

/// A raw file, memory-mapped read-only and unpacked by LibRaw.
///
/// Ownership: `RawFile` owns both the mmap'd region and the LibRaw handle,
/// and tears both down in `deinit`. The sensor plane returned by
/// `rawSensorPlane` is only valid for the lifetime of this object.
public final class RawFile {
    private var handle: OpaquePointer?
    private let mappedBytes: UnsafeMutableRawPointer
    private let mappedLength: Int
    public let summary: RawSummary

    /// The camera's XYZ -> camera-RGB characterization matrix, row-major
    /// 3x3 (LibRaw's 4th row is dropped; it only matters for four-colour
    /// CFAs). nil when LibRaw has no profile for this camera.
    ///
    /// This is the Adobe ColorMatrix convention. ColorKit inverts and
    /// composes it to build the camera -> working-space transform.
    public let cameraToXYZMatrixRaw: [Float]?

    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RawFileError.fileNotFound(path: path)
        }

        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw RawFileError.mmapFailed(errno: errno) }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw RawFileError.mmapFailed(errno: errno) }
        let length = Int(st.st_size)

        guard let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            throw RawFileError.mmapFailed(errno: errno)
        }
        self.mappedBytes = mapped
        self.mappedLength = length

        guard let h = clibraw_open_buffer(mapped, length) else {
            munmap(mapped, length)
            throw RawFileError.libRawOpenFailed
        }
        self.handle = h

        var cSummary = CLibRawSummary()
        clibraw_get_summary(h, &cSummary)
        self.summary = RawSummary(
            width: Int(cSummary.width), height: Int(cSummary.height),
            rawWidth: Int(cSummary.raw_width), rawHeight: Int(cSummary.raw_height),
            cfaPattern: CFAPattern(rawValue: cSummary.cfa_pattern),
            cameraMultipliers: (cSummary.cam_mul.0, cSummary.cam_mul.1,
                                 cSummary.cam_mul.2, cSummary.cam_mul.3),
            blackLevel: cSummary.black_level, whiteLevel: cSummary.white_level,
            cameraMake: withUnsafePointer(to: cSummary.camera_make) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            },
            cameraModel: withUnsafePointer(to: cSummary.camera_model) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            },
            lensModel: withUnsafePointer(to: cSummary.lens_model) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            },
            iso: cSummary.iso, shutter: cSummary.shutter,
            aperture: cSummary.aperture, focalLength: cSummary.focal_length,
            captureTime: Date(timeIntervalSince1970: TimeInterval(cSummary.timestamp))
        )

        var matrix12 = [Float](repeating: 0, count: 12)
        let matrixResult = matrix12.withUnsafeMutableBufferPointer { buf in
            clibraw_get_cam_xyz(h, buf.baseAddress)
        }
        self.cameraToXYZMatrixRaw = (matrixResult == 0) ? Array(matrix12.prefix(9)) : nil
    }

    /// The unpacked sensor plane straight from LibRaw's own allocation.
    /// `PixelEngine` is the only module that should call this.
    public func rawSensorPlane() -> UnsafeBufferPointer<UInt16>? {
        guard let h = handle else { return nil }
        var length: Int = 0
        guard let ptr = clibraw_get_raw_plane(h, &length), length > 0 else { return nil }
        return UnsafeBufferPointer(start: ptr, count: length / MemoryLayout<UInt16>.size)
    }

    /// The camera's embedded JPEG preview — the basis for unedited-image
    /// thumbnails (DESIGN.md §10). Returns nil if the file has none.
    public func embeddedJPEGPreview() -> Data? {
        guard let h = handle else { return nil }
        var length: Int = 0
        guard clibraw_get_thumbnail(h, nil, &length) == 0, length > 0 else { return nil }
        var data = Data(count: length)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            var len = length
            return clibraw_get_thumbnail(h, buf.bindMemory(to: UInt8.self).baseAddress, &len) == 0
        }
        return ok ? data : nil
    }

    deinit {
        if let h = handle { clibraw_close(h) }
        munmap(mappedBytes, mappedLength)
    }
}
