import Foundation
import IOSurface
import os

/// What a decode produces, in a form that crosses a process boundary.
///
/// The service sends three payloads: this metadata as JSON, the sensor
/// plane as an IOSurface (shared memory: XPC passes a reference, and the
/// app's GPU reads the very pages the service wrote), and the embedded
/// preview as `Data`. IOSurface is the only non-plist class on the wire,
/// and the interface whitelists exactly that.
///
/// The service and the app are built together and ship in one bundle, so
/// the two ends always agree on this shape; no older payload can arrive.
public struct RawSnapshotMetadata: Codable, Sendable, Equatable {
    /// The active area (the plane's size) and where it sits in the
    /// `rawWidth x rawHeight` readout; see `SensorActiveArea`.
    public var width, height, leftMargin, topMargin: Int
    public var rawWidth, rawHeight: Int
    /// 0xFF for non-Bayer, else the packed 2x2 order.
    public var cfaCode: UInt8
    public var cameraMultipliers: [Float]
    public var blackLevel, whiteLevel: Float
    public var cameraMake, cameraModel, lensModel: String
    public var iso, shutter, aperture, focalLength: Double
    public var timestamp: Int64
    public var orientation: Int
    public var lensMake, lensMakerNotesName: String
    public var makerLensID: UInt64
    public var nikonLensID, nikonLensType: UInt8
    public var minFocal, maxFocal, maxApertureAtMinFocal, maxApertureAtMaxFocal, cropFactor: Double
    public var cameraToXYZ: [Float]?
    public var thumbnailError: Int32
    public var isMetadataOnly: Bool
    /// UInt16 samples in the plane; checked against `width x height` and
    /// the surface's size.
    public var planeSampleCount: Int

    public init(summary s: RawSummary, cameraToXYZ: [Float]?, thumbnailError: Int32, isMetadataOnly: Bool,
                planeSampleCount: Int) {
        let area = s.activeArea
        width = area.width; height = area.height; leftMargin = area.left; topMargin = area.top
        rawWidth = area.fullWidth; rawHeight = area.fullHeight
        cfaCode = s.cfaPattern.rawCode
        cameraMultipliers = [s.cameraMultipliers.0, s.cameraMultipliers.1, s.cameraMultipliers.2, s.cameraMultipliers.3]
        blackLevel = s.blackLevel; whiteLevel = s.whiteLevel
        cameraMake = s.cameraMake; cameraModel = s.cameraModel; lensModel = s.lensModel
        iso = s.iso; shutter = s.shutter; aperture = s.aperture; focalLength = s.focalLength
        timestamp = Int64(s.captureTime.timeIntervalSince1970)
        orientation = s.orientation
        lensMake = s.lens.make; lensMakerNotesName = s.lens.makerNotesName
        makerLensID = s.lens.makerLensID; nikonLensID = s.lens.nikonLensID; nikonLensType = s.lens.nikonLensType
        minFocal = s.lens.minFocal; maxFocal = s.lens.maxFocal
        maxApertureAtMinFocal = s.lens.maxApertureAtMinFocal; maxApertureAtMaxFocal = s.lens.maxApertureAtMaxFocal
        cropFactor = s.lens.cropFactor
        self.cameraToXYZ = cameraToXYZ
        self.thumbnailError = thumbnailError
        self.isMetadataOnly = isMetadataOnly
        self.planeSampleCount = planeSampleCount
    }

    public var summary: RawSummary {
        RawSummary(
            activeArea: SensorActiveArea(left: leftMargin, top: topMargin, width: width, height: height,
                                         fullWidth: rawWidth, fullHeight: rawHeight),
            cfaPattern: CFAPattern(rawValue: cfaCode),
            cameraMultipliers: (cameraMultipliers[0], cameraMultipliers[1], cameraMultipliers[2], cameraMultipliers[3]),
            blackLevel: blackLevel, whiteLevel: whiteLevel,
            cameraMake: cameraMake, cameraModel: cameraModel, lensModel: lensModel,
            iso: iso, shutter: shutter, aperture: aperture, focalLength: focalLength,
            captureTime: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            orientation: orientation,
            lens: LensIdentity(make: lensMake, makerNotesName: lensMakerNotesName, makerLensID: makerLensID,
                               nikonLensID: nikonLensID, nikonLensType: nikonLensType,
                               minFocal: minFocal, maxFocal: maxFocal,
                               maxApertureAtMinFocal: maxApertureAtMinFocal,
                               maxApertureAtMaxFocal: maxApertureAtMaxFocal, cropFactor: cropFactor))
    }
}

/// The XPC interface: decode the file behind an open descriptor, or read
/// its metadata for export. The service never receives a path and has no
/// file access of its own; the descriptor is the only thing it can read.
@objc public protocol RawDecoderProtocol {
    func decode(_ file: FileHandle, metadataOnly: Bool,
                reply: @escaping (_ metadataJSON: Data?, _ plane: IOSurface?, _ preview: Data?, _ error: String?) -> Void)

    /// Reads the photo's own metadata for export (`SourceMetadata`): two
    /// binary property lists, the dictionaries and the XMP tag tree.
    func readMetadata(_ file: FileHandle,
                      reply: @escaping (_ properties: Data?, _ xmpTags: Data?, _ error: String?) -> Void)
}

public enum RawDecoderXPC {
    public static let serviceName = "com.latent.app.rawdecoder"
    public static let bundleName = "LatentRawDecoder.xpc"
    static let logger = Logger(subsystem: "com.latent.app", category: "rawdecoder")

    /// The interface both ends use. The reply's plane argument is
    /// allowed to decode as an IOSurface and nothing else.
    public static func makeInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: RawDecoderProtocol.self)
        let selector = #selector(RawDecoderProtocol.decode(_:metadataOnly:reply:))
        interface.setClasses(NSSet(object: IOSurface.self) as! Set<AnyHashable>, for: selector, argumentIndex: 1, ofReply: true)
        return interface
    }

    /// True when this process is the app bundle and carries the service.
    /// `LATENT_RAW_INPROCESS=1` forces in-process decoding for debugging,
    /// in debug builds only: a release bundle can't be told to parse raw
    /// files outside the sandboxed decoder.
    public static var isServiceAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LATENT_RAW_INPROCESS"] == "1" { return false }
        #endif
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/\(bundleName)")
        let available = FileManager.default.fileExists(atPath: url.path)
        if !loggedAvailability {
            loggedAvailability = true
            logger.notice("raw decoder service \(available ? "found" : "not found", privacy: .public) at \(url.path, privacy: .public)")
        }
        return available
    }
    nonisolated(unsafe) private static var loggedAvailability = false
}

/// Host-side client. One connection, made lazily and remade after the
/// service exits (which XPC does on its own after idle time, and which a
/// crash on a malicious file also causes). Calls are synchronous because
/// every caller of `RawFile.init` already blocks on the decode.
public final class RawDecoderClient: @unchecked Sendable {
    public static let shared = RawDecoderClient()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public enum ClientError: Error, CustomStringConvertible {
        case serviceFailed(String)
        case connectionLost(String)
        public var description: String {
            switch self {
            case .serviceFailed(let s): "raw decoder service: \(s)"
            case .connectionLost(let s): "raw decoder connection lost (\(s)); the file may have crashed the decoder"
            }
        }
    }

    private func proxy(errorHandler: @escaping (Error) -> Void) -> RawDecoderProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            let c = NSXPCConnection(serviceName: RawDecoderXPC.serviceName)
            c.remoteObjectInterface = RawDecoderXPC.makeInterface()
            c.invalidationHandler = { [weak self] in
                self?.lock.lock(); self?.connection = nil; self?.lock.unlock()
            }
            c.resume()
            connection = c
        }
        return connection?.synchronousRemoteObjectProxyWithErrorHandler(errorHandler) as? RawDecoderProtocol
    }

    /// Decodes synchronously. `plane` is nil for metadata-only opens.
    public func decode(fileDescriptor fd: Int32, metadataOnly: Bool) throws
        -> (metadata: RawSnapshotMetadata, plane: IOSurface?, preview: Data?) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var result: (Data?, IOSurface?, Data?, String?) = (nil, nil, nil, nil)
        var transportError: Error?
        guard let proxy = proxy(errorHandler: { transportError = $0 }) else {
            throw ClientError.connectionLost("no proxy")
        }
        let start = Date()
        proxy.decode(handle, metadataOnly: metadataOnly) { meta, plane, preview, error in
            result = (meta, plane, preview, error)
        }
        if let transportError {
            RawDecoderXPC.logger.error("raw decoder transport error: \(String(describing: transportError), privacy: .public)")
            throw ClientError.connectionLost(String(describing: transportError))
        }
        if let error = result.3 {
            RawDecoderXPC.logger.error("raw decoder service error: \(error, privacy: .public)")
            throw ClientError.serviceFailed(error)
        }
        guard let metaData = result.0 else { throw ClientError.serviceFailed("empty reply") }
        let metadata = try JSONDecoder().decode(RawSnapshotMetadata.self, from: metaData)
        RawDecoderXPC.logger.notice("decoded \(metadata.cameraModel, privacy: .public) in service, \(Int(Date().timeIntervalSince(start) * 1000)) ms, plane \(result.1?.allocationSize ?? 0) bytes shared")
        return (metadata, result.1, result.2)
    }

    /// Reads a file's metadata for export, synchronously.
    public func readMetadata(fileDescriptor fd: Int32) throws -> SourceMetadata {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var result: (Data?, Data?, String?) = (nil, nil, nil)
        var transportError: Error?
        guard let proxy = proxy(errorHandler: { transportError = $0 }) else {
            throw ClientError.connectionLost("no proxy")
        }
        proxy.readMetadata(handle) { properties, xmpTags, error in
            result = (properties, xmpTags, error)
        }
        if let transportError {
            RawDecoderXPC.logger.error("raw decoder transport error: \(String(describing: transportError), privacy: .public)")
            throw ClientError.connectionLost(String(describing: transportError))
        }
        if let error = result.2 {
            RawDecoderXPC.logger.error("raw decoder service error: \(error, privacy: .public)")
            throw ClientError.serviceFailed(error)
        }
        guard let properties = result.0 else { throw ClientError.serviceFailed("empty reply") }
        return try SourceMetadata(properties: properties, xmpTags: result.1)
    }
}
