import XCTest
@testable import Catalog

final class ParserHardeningTests: XCTestCase {
    /// A sidecar that declares an external entity must not have it
    /// resolved: the app never reads another file or URL on a sidecar's
    /// say-so. Foundation either drops the reference or fails to parse;
    /// both are acceptable, exposing the file's content is not.
    func testExternalEntitiesAreNeverLoaded() throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("latent-secret-\(UUID().uuidString).txt")
        try "TOPSECRET".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE x [ <!ENTITY leak SYSTEM "file://\(secret.path)"> ]>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="4" xmp:Label="&leak;"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        if let fields = try? XMPSidecar.read(xml: xml) {
            XCTAssertFalse((fields.label ?? "").contains("TOPSECRET"), "entity content leaked into a field")
        }
    }

    func testOversizedSidecarIsRefused() {
        let huge = String(repeating: "<!-- x -->", count: XMPSidecar.maximumSidecarBytes / 10 + 10)
        XCTAssertThrowsError(try XMPSidecar.read(xml: huge)) { error in
            XCTAssertTrue("\(error)".contains("limit"), "\(error)")
        }
    }

    /// The size cap is checked on what is read, not on a link: a symbolic
    /// link dropped into `_latent/xmp` under a sidecar's name must not
    /// make the parser read its target, however large, or at all.
    func testSidecarThatIsASymbolicLinkIsRefused() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("real.xmp")
        try XMPSidecar.write(XMPSidecar.Fields(rating: 5, label: nil, keywords: [], preservedFileName: nil,
                                               sourceHash: "xxh64:0", editStackJSON: ""), to: target)
        let link = tmp.appendingPathComponent("A.NEF.xmp")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try XMPSidecar.read(from: link), "a link was followed")
        XCTAssertEqual(try XMPSidecar.read(from: target).rating, 5, "a plain file still reads")

        // A large target behind a link is refused without being read.
        let big = tmp.appendingPathComponent("big.mov")
        XCTAssertTrue(fm.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(XMPSidecar.maximumSidecarBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try XMPSidecar.read(from: big)) { error in
            XCTAssertTrue("\(error)".contains("limit"), "\(error)")
        }
        let bigLink = tmp.appendingPathComponent("B.NEF.xmp")
        try fm.createSymbolicLink(at: bigLink, withDestinationURL: big)
        XCTAssertThrowsError(try XMPSidecar.read(from: bigLink))
    }
}
