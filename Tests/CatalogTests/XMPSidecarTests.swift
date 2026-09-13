import XCTest
@testable import Catalog

final class XMPSidecarTests: XCTestCase {
    func testRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = XMPSidecar.Fields(
            rating: 4, label: "Green", keywords: ["Yosemite", "Half Dome & sky"],
            preservedFileName: "DSC_0001.NEF",
            sourceHash: "xxh64:ef46db3751d8e999",
            editStackJSON: #"{"schema":1,"modules":{"exposure":{"ev":0.7}}}"#)

        let url = tmp.appendingPathComponent("sub/DSC_0001-2.NEF.xmp")
        try XMPSidecar.write(original, to: url)
        let back = try XMPSidecar.read(from: url)
        XCTAssertEqual(back, original)
    }

    /// A Lightroom-style sidecar with no Latent fields still yields the
    /// standard ones, and an empty edit stack.
    func testForeignSidecarYieldsStandardFields() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmp:Rating="3">
           <xmp:Label>Red</xmp:Label>
           <dc:subject><rdf:Bag><rdf:li>travel</rdf:li></rdf:Bag></dc:subject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let f = try XMPSidecar.read(xml: xml)
        XCTAssertEqual(f.rating, 3)
        XCTAssertEqual(f.label, "Red")
        XCTAssertEqual(f.keywords, ["travel"])
        XCTAssertEqual(f.editStackJSON, "")
        XCTAssertEqual(f.sourceHash, "")
    }
}
