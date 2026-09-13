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
}
