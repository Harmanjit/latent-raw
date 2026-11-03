import Foundation
import IOSurface
import os

/// What a decode produces, in a form that crosses a process boundary.
///
/// The service sends three payloads: this metadata as JSON, the pixels as
/// an IOSurface (shared memory: XPC passes a reference, and the app's GPU
/// reads the very pages the service wrote), and the embedded preview as
/// `Data`. The surface holds a `SensorPlane` for a Bayer raw or a
/// `LinearPlane` for a linear source; `cfaCode` says which, and the app
/// checks the surface's size against it either way. IOSurface is the only
/// non-plist class on the wire, and the interface whitelists exactly that.
///
/// The service and the app are built together and ship in one bundle, so
/// the two ends always agree on this shape; no older payload can arrive.
public struct RawSnapshotMetadata: Codable, Sendable, Equatable {
    /// The active area (the plane's size) and where it sits in the
    /// `rawWidth x rawHeight` readout; see `SensorActiveArea`.
    public var width, height, leftMargin, topMargin: Int
    public var rawWidth, rawHeight: Int
    /// 0xFF for non-Bayer, 0xFE for a linear source (`CFAPattern.linearRGB`),
    /// else the packed 2x2 order.
    public var cfaCode: UInt8
    public var cameraMultipliers: [Float]
    public var blackLevel, whiteLevel: Float
    /// Four values: R, G, B, second green.
    public var channelBlackLevels: [Float]
    public var dataMaximum: Float
    public var baselineExposure: Float
    public var mergeInfo: LinearMergeInfo?
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
    /// Samples in the plane, checked against the surface's size: UInt16
    /// photosites for a Bayer raw (`width x height`), Float16 channel
    /// values for a linear source (`width x height x 4`).
    public var planeSampleCount: Int

    public init(summary s: RawSummary, cameraToXYZ: [Float]?, thumbnailError: Int32, isMetadataOnly: Bool,
                planeSampleCount: Int) {
        let area = s.activeArea
        width = area.width; height = area.height; leftMargin = area.left; topMargin = area.top
        rawWidth = area.fullWidth; rawHeight = area.fullHeight
        cfaCode = s.cfaPattern.rawCode
        cameraMultipliers = [s.cameraMultipliers.0, s.cameraMultipliers.1, s.cameraMultipliers.2, s.cameraMultipliers.3]
        blackLevel = s.blackLevel; whiteLevel = s.whiteLevel
        let black = s.channelBlackLevels
        channelBlackLevels = [black[0], black[1], black[2], black[3]]
        dataMaximum = s.dataMaximum; baselineExposure = s.baselineExposure; mergeInfo = s.mergeInfo
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

    /// The largest side the shim can report: its size fields are uint16.
    static let maxSide = Int(UInt16.max)

    /// Refuses a reply whose shape the app would otherwise trust: four
    /// camera multipliers, and every size and margin within what LibRaw
    /// can report, with the active area inside the readout. The sizes are
    /// range-checked before anything adds or multiplies them, so a
    /// compromised service gets an error back rather than an overflow trap
    /// in the app, and no negative size reaches the render pipeline.
    func validate() throws {
        guard cameraMultipliers.count == 4 else {
            throw RawDecoderClient.ClientError.serviceFailed("reply has \(cameraMultipliers.count) camera multipliers")
        }
        let sides = [width, height, leftMargin, topMargin, rawWidth, rawHeight]
        guard sides.allSatisfy({ (0...Self.maxSide).contains($0) }),
              SensorActiveArea(left: leftMargin, top: topMargin, width: width, height: height,
                               fullWidth: rawWidth, fullHeight: rawHeight).isValid else {
            throw RawDecoderClient.ClientError.serviceFailed(
                "reply has an impossible size: \(width)x\(height) at (\(leftMargin), \(topMargin)) in \(rawWidth)x\(rawHeight)")
        }
    }

    public var summary: RawSummary {
        RawSummary(
            activeArea: SensorActiveArea(left: leftMargin, top: topMargin, width: width, height: height,
                                         fullWidth: rawWidth, fullHeight: rawHeight),
            cfaPattern: CFAPattern(rawValue: cfaCode),
            // `validate` refuses any other count; this keeps the property
            // itself from trapping on one that wasn't validated.
            cameraMultipliers: cameraMultipliers.count == 4
                ? (cameraMultipliers[0], cameraMultipliers[1], cameraMultipliers[2], cameraMultipliers[3])
                : (0, 0, 0, 0),
            blackLevel: blackLevel, whiteLevel: whiteLevel,
            // Four values from a well-behaved service; anything else is
            // read as "no per-channel offsets" rather than trusted.
            channelBlackLevels: channelBlackLevels.count == 4
                ? SIMD4(channelBlackLevels[0], channelBlackLevels[1], channelBlackLevels[2], channelBlackLevels[3])
                : SIMD4(repeating: blackLevel),
            dataMaximum: dataMaximum, baselineExposure: baselineExposure, mergeInfo: mergeInfo,
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
    /// The largest embedded preview that crosses into the app. A camera's
    /// own JPEG is a few megabytes, tens for the biggest sensors; a file
    /// can carry far more (LibRaw allows 512 MB), which would otherwise be
    /// copied into the app's heap per thumbnail job. The service keeps a
    /// larger one back and the app refuses one that arrives anyway.
    static let maxPreviewBytes = 64 << 20

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
/// crash on a malicious file also causes). Calls block their caller, as
/// every caller of `RawFile.init` already expects, but never for longer
/// than `timeout`: a file that sends LibRaw into an endless loop would
/// otherwise hold its caller (the main actor, for an open in Develop) for
/// good, and every later request on the connection with it. On expiry the
/// connection is dropped, which ends the service and the stuck decode
/// with it (the service exits when its last connection goes), and the
/// next call starts a fresh one.
public final class RawDecoderClient: @unchecked Sendable {
    public static let shared = RawDecoderClient(timeout: 60) {
        NSXPCConnection(serviceName: RawDecoderXPC.serviceName)
    }
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let makeConnection: @Sendable () -> NSXPCConnection
    /// The longest wait for one reply. A full decode of a large raw read
    /// from a slow network volume takes seconds; this is far beyond that.
    let timeout: TimeInterval

    /// The reply's metadata is a few kilobytes of JSON; more is refused
    /// before parsing, like `SourceMetadata.maxPayloadBytes`.
    static let maxMetadataBytes = 1 << 20

    /// `makeConnection` lets tests talk to a service of their own on an
    /// anonymous listener.
    init(timeout: TimeInterval, makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.timeout = timeout
        self.makeConnection = makeConnection
    }

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

    private func currentConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let c = makeConnection()
        c.remoteObjectInterface = RawDecoderXPC.makeInterface()
        // Only this connection's own invalidation clears the slot: an old
        // connection's, arriving late, must not drop its replacement.
        let id = ObjectIdentifier(c)
        c.invalidationHandler = { [weak self] in self?.forget(id) }
        c.resume()
        connection = c
        return c
    }

    private func forget(_ id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        if let connection, ObjectIdentifier(connection) == id { self.connection = nil }
    }

    /// Sends one request and waits for whichever comes first: its reply,
    /// the transport error, or the deadline.
    private func call<Reply>(_ send: (RawDecoderProtocol, @escaping (Reply) -> Void) -> Void) throws -> Reply {
        let c = currentConnection()
        let outcome = ReplyOutcome<Reply>()
        guard let proxy = c.remoteObjectProxyWithErrorHandler({ outcome.finish(.failure($0)) })
                as? RawDecoderProtocol else {
            throw ClientError.connectionLost("no proxy")
        }
        send(proxy) { outcome.finish(.success($0)) }
        guard let result = outcome.wait(timeout: timeout) else {
            RawDecoderXPC.logger.error("raw decoder gave no reply in \(Int(self.timeout)) s; dropping the connection")
            forget(ObjectIdentifier(c))
            c.invalidate()
            throw ClientError.connectionLost("no reply in \(Int(timeout)) s")
        }
        switch result {
        case .success(let reply):
            return reply
        case .failure(let transportError):
            RawDecoderXPC.logger.error("raw decoder transport error: \(String(describing: transportError), privacy: .public)")
            throw ClientError.connectionLost(String(describing: transportError))
        }
    }

    /// Decodes, blocking the caller. `plane` is nil for metadata-only opens.
    public func decode(fileDescriptor fd: Int32, metadataOnly: Bool) throws
        -> (metadata: RawSnapshotMetadata, plane: IOSurface?, preview: Data?) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let start = Date()
        let result: (Data?, IOSurface?, Data?, String?) = try call { proxy, done in
            proxy.decode(handle, metadataOnly: metadataOnly) { meta, plane, preview, error in
                done((meta, plane, preview, error))
            }
        }
        if let error = result.3 {
            RawDecoderXPC.logger.error("raw decoder service error: \(error, privacy: .public)")
            throw ClientError.serviceFailed(error)
        }
        guard let metaData = result.0 else { throw ClientError.serviceFailed("empty reply") }
        guard metaData.count <= Self.maxMetadataBytes else {
            throw ClientError.serviceFailed("metadata of \(metaData.count) bytes refused")
        }
        let metadata = try JSONDecoder().decode(RawSnapshotMetadata.self, from: metaData)
        RawDecoderXPC.logger.notice("decoded \(metadata.cameraModel, privacy: .public) in service, \(Int(Date().timeIntervalSince(start) * 1000)) ms, plane \(result.1?.allocationSize ?? 0) bytes shared")
        return (metadata, result.1, result.2)
    }

    /// Reads a file's metadata for export, blocking the caller.
    public func readMetadata(fileDescriptor fd: Int32) throws -> SourceMetadata {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let result: (Data?, Data?, String?) = try call { proxy, done in
            proxy.readMetadata(handle) { properties, xmpTags, error in
                done((properties, xmpTags, error))
            }
        }
        if let error = result.2 {
            RawDecoderXPC.logger.error("raw decoder service error: \(error, privacy: .public)")
            throw ClientError.serviceFailed(error)
        }
        guard let properties = result.0 else { throw ClientError.serviceFailed("empty reply") }
        return try SourceMetadata(properties: properties, xmpTags: result.1)
    }
}

/// One request's outcome: the reply or the transport error, whichever
/// XPC delivers (it delivers exactly one), on the connection's queue.
private final class ReplyOutcome<Reply>: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Reply, Error>?

    func finish(_ value: Result<Reply, Error>) {
        lock.lock()
        let first = result == nil
        if first { result = value }
        lock.unlock()
        if first { done.signal() }
    }

    /// nil when nothing arrived in time.
    func wait(timeout: TimeInterval) -> Result<Reply, Error>? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return result
    }
}
