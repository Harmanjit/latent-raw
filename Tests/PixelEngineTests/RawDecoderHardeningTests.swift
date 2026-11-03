import XCTest
import ImageIO
import IOSurface
@testable import RawCore

/// The app's side of the decoder service when the service misbehaves:
/// replies of impossible shape, oversized payloads, a decode that never
/// returns, and requests that must not queue behind one another. The
/// service is exported on an anonymous listener in this process, so the
/// real NSXPC path runs without an app bundle.
final class RawDecoderHardeningTests: XCTestCase {
    private func linearFixture() throws -> RawFile {
        try RawFile(path: LinearFixtures.path(LinearFixtures.mergeHDR))
    }

    // MARK: - Reply shape

    /// A reply with too few camera multipliers is an error, not an
    /// index-out-of-range trap, even for a metadata-only open.
    func testShortCameraMultipliersAreRefused() throws {
        var meta = try linearFixture().snapshotMetadata
        meta.cameraMultipliers = [1]
        XCTAssertThrowsError(try RawFile(serviceReply: meta, plane: nil, preview: nil, metadataOnly: true))
        _ = meta.summary   // the property itself no longer traps
    }

    /// Sizes whose product overflows, or that are negative, are refused
    /// before anything multiplies them, on both the linear and Bayer paths.
    func testImpossibleSizesAreRefused() throws {
        let decoded = try linearFixture()
        let surface = try XCTUnwrap(decoded.linearPlane?.surface)
        let good = decoded.snapshotMetadata
        XCTAssertNoThrow(try RawFile(serviceReply: good, plane: surface, preview: nil, metadataOnly: false))

        var bayer = good
        bayer.cfaCode = 0x94
        XCTAssertNotEqual(bayer.summary.sourceKind, .linearRGB)

        for base in [good, bayer] {
            var overflow = base
            overflow.width = Int.max / 2 + 1; overflow.height = 4
            overflow.rawWidth = overflow.width; overflow.rawHeight = 4
            XCTAssertThrowsError(try RawFile(serviceReply: overflow, plane: surface, preview: nil, metadataOnly: false))

            var negative = base
            negative.width = -2; negative.height = -2
            negative.planeSampleCount = base.cfaCode == 0xFE ? 16 : 4
            XCTAssertThrowsError(try RawFile(serviceReply: negative, plane: surface, preview: nil, metadataOnly: false))
            XCTAssertThrowsError(try RawFile(serviceReply: negative, plane: nil, preview: nil, metadataOnly: true))

            var outside = base
            outside.leftMargin = 1   // the active area now runs past the readout
            XCTAssertThrowsError(try RawFile(serviceReply: outside, plane: surface, preview: nil, metadataOnly: false))

            var huge = base
            huge.leftMargin = Int.max   // would overflow the area check itself
            XCTAssertThrowsError(try RawFile(serviceReply: huge, plane: nil, preview: nil, metadataOnly: true))
        }
    }

    /// A metadata-only reply whose visible size doesn't fit the readout
    /// (LibRaw reports such sizes for a Fuji SuperCCD) is accepted, as the
    /// in-process metadata-only open accepts it. With a plane, which was
    /// cut to that area, it is still refused.
    func testMetadataOnlyReplyNeedNotFitTheReadout() throws {
        var meta = try linearFixture().snapshotMetadata
        meta.width = meta.rawWidth + 100
        meta.height = meta.rawHeight + 50
        let opened = try RawFile(serviceReply: meta, plane: nil, preview: nil, metadataOnly: true)
        XCTAssertEqual(opened.summary.width, meta.width)
        XCTAssertThrowsError(try meta.validate(withPlane: true))
    }

    /// An embedded preview over the cap is dropped rather than handed to
    /// ImageIO in the app; one at the cap is kept.
    func testOversizedPreviewIsDropped() throws {
        let meta = try linearFixture().snapshotMetadata
        let over = try RawFile(serviceReply: meta, plane: nil, preview: Data(count: RawDecoderXPC.maxPreviewBytes + 1),
                               metadataOnly: true)
        XCTAssertNil(over.embeddedJPEGPreview())
        let at = try RawFile(serviceReply: meta, plane: nil, preview: Data(count: RawDecoderXPC.maxPreviewBytes),
                             metadataOnly: true)
        XCTAssertEqual(at.embeddedJPEGPreview()?.count, RawDecoderXPC.maxPreviewBytes)
    }

    // MARK: - The connection

    /// A decode that never replies ends in an error once the deadline
    /// passes, and the connection is kept: other requests on it, here the
    /// next one, still get their answers rather than a dropped connection.
    func testHungDecodeTimesOutAndTheConnectionStays() throws {
        let service = FakeService()
        let client = service.client(timeout: 0.5)
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }

        let start = Date()
        XCTAssertThrowsError(try client.decode(fileDescriptor: fd, metadataOnly: true)) { error in
            guard case RawDecoderClient.ClientError.connectionLost = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        let metadata = try client.readMetadata(fileDescriptor: fd)
        XCTAssertEqual(metadata.properties, Data("ok".utf8))
        XCTAssertEqual(service.connections, 1, "the timeout dropped a connection others share")
    }

    /// A request still running past the service's watchdog ends the
    /// service (here, calls the stand-in for the exit), whichever
    /// connection it came on.
    func testServiceEndsItselfWhenARequestIsStuck() throws {
        let stuck = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let service = RawDecoderService(decodeWork: { _, _, reply in
            _ = release.wait(timeout: .now() + 10)
            reply(nil, nil, nil, "done")
        }, watchdog: 0.3, onStuck: { stuck.signal() })
        let file = FileHandle(forReadingAtPath: "/dev/null")!
        service.decode(file, metadataOnly: true) { _, _, _, _ in }
        XCTAssertEqual(stuck.wait(timeout: .now() + 5), .success, "the stuck request was left running")
    }

    /// A request that finishes in time disarms its watchdog.
    func testWatchdogStaysQuietForAFinishedRequest() throws {
        let stuck = DispatchSemaphore(value: 0)
        let replied = DispatchSemaphore(value: 0)
        let service = RawDecoderService(decodeWork: { _, _, reply in
            reply(nil, nil, nil, "done")
        }, watchdog: 0.3, onStuck: { stuck.signal() })
        let file = FileHandle(forReadingAtPath: "/dev/null")!
        service.decode(file, metadataOnly: true) { _, _, _, _ in replied.signal() }
        XCTAssertEqual(replied.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(stuck.wait(timeout: .now() + 1), .timedOut, "the watchdog fired after the reply")
    }

    /// Metadata JSON past its cap is refused before it is parsed.
    func testOversizedMetadataIsRefused() throws {
        let service = FakeService()
        service.decodeReply = Data(count: RawDecoderClient.maxMetadataBytes + 1)
        let client = service.client(timeout: 10)
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        XCTAssertThrowsError(try client.decode(fileDescriptor: fd, metadataOnly: true)) { error in
            guard case RawDecoderClient.ClientError.serviceFailed(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("refused"), why)
        }
    }

    /// Two decodes on one connection run at the same time in the service:
    /// each waits inside its work until the other has started, which can
    /// only happen if the service doesn't run them one after the other.
    func testServiceRunsDecodesConcurrently() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let listener = NSXPCListener.anonymous()
        let delegate = ExportingDelegate {
            RawDecoderService { _, _, reply in
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
                reply(nil, nil, nil, "done")
            }
        }
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let endpoint = listener.endpoint
        let client = RawDecoderClient(timeout: 20) { NSXPCConnection(listenerEndpoint: endpoint) }
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }

        let finished = DispatchGroup()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: finished) {
                _ = try? client.decode(fileDescriptor: fd, metadataOnly: false)
            }
        }
        let first = entered.wait(timeout: .now() + 5)
        let second = entered.wait(timeout: .now() + 5)
        release.signal(); release.signal()
        XCTAssertEqual(first, .success)
        XCTAssertEqual(second, .success, "the second decode waited for the first")
        XCTAssertEqual(finished.wait(timeout: .now() + 15), .success)
    }

    // MARK: - Location in vendor XMP

    /// A drone's own XMP copy of its position goes with the rest of the
    /// location when location is left out; its other tags stay.
    func testVendorXMPLocationIsLeftOutUnlessAsked() throws {
        let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:drone-dji="http://www.dji.com/drone-dji/1.0/"
          drone-dji:GpsLatitude="59.9139" drone-dji:GpsLongitude="10.7522" drone-dji:GpsLongtitude="10.7522"
          drone-dji:AbsoluteAltitude="+120.5" drone-dji:RelativeAltitude="+80.2"
          drone-dji:GimbalYawDegree="-12.3"/>
        </rdf:RDF></x:xmpmeta>
        """
        let xmp = try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, try XCTUnwrap(ctx.makeImage()), xmp, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = SourceMetadata(imageData: data as Data)

        func names(_ metadata: CGImageMetadata?) -> Set<String> {
            Set((metadata.flatMap { CGImageMetadataCopyTags($0) as? [CGImageMetadataTag] } ?? [])
                .compactMap { CGImageMetadataTagCopyName($0) as String? })
        }
        let location: Set<String> = ["GpsLatitude", "GpsLongitude", "GpsLongtitude", "AbsoluteAltitude",
                                     "RelativeAltitude"]
        let kept = names(source.xmpMetadata(includingLocation: true))
        XCTAssertTrue(location.isSubset(of: kept), "\(kept)")
        let stripped = names(source.xmpMetadata(includingLocation: false))
        XCTAssertTrue(stripped.isDisjoint(with: location), "\(stripped)")
        XCTAssertTrue(stripped.contains("GimbalYawDegree"), "\(stripped)")
    }
}

// MARK: - Test services

/// Exports whatever object `make` returns on each new connection.
private final class ExportingDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let make: () -> RawDecoderProtocol
    init(make: @escaping () -> RawDecoderProtocol) { self.make = make }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = RawDecoderXPC.makeInterface()
        connection.exportedObject = make()
        connection.resume()
        return true
    }
}

/// A service whose first connection never answers a decode (as LibRaw
/// stuck in a loop would) but answers metadata reads at once, and whose
/// later connections answer everything at once.
private final class FakeService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let listener = NSXPCListener.anonymous()
    /// Answers to decodes on later connections.
    var decodeReply = Data()

    var connections: Int { lock.lock(); defer { lock.unlock() }; return count }

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }
    deinit { listener.invalidate() }

    func client(timeout: TimeInterval) -> RawDecoderClient {
        let endpoint = listener.endpoint
        return RawDecoderClient(timeout: timeout) { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock(); count += 1; let hangs = count == 1 && decodeReply.isEmpty; lock.unlock()
        connection.exportedInterface = RawDecoderXPC.makeInterface()
        connection.exportedObject = Endpoint(hangs: hangs, decodeReply: decodeReply)
        connection.resume()
        return true
    }

    final class Endpoint: NSObject, RawDecoderProtocol, @unchecked Sendable {
        let hangs: Bool
        let decodeReply: Data
        /// Replies held, never called, so the request stays open.
        private var held: [Any] = []
        init(hangs: Bool, decodeReply: Data) { self.hangs = hangs; self.decodeReply = decodeReply }

        func decode(_ file: FileHandle, metadataOnly: Bool,
                    reply: @escaping (Data?, IOSurface?, Data?, String?) -> Void) {
            if hangs { held.append(reply); return }
            reply(decodeReply, nil, nil, nil)
        }

        func readMetadata(_ file: FileHandle, reply: @escaping (Data?, Data?, String?) -> Void) {
            reply(Data("ok".utf8), nil, nil)
        }
    }
}
