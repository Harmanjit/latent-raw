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

    /// A sidecar written before the rename uses the rawhead: prefix for
    /// flag, rotation and hash. Rebuilding a catalog from it must keep them.
    func testReadsPreRenamePrefix() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:rawhead="https://github.com/OWNER/rawhead/ns/1.0/"
            xmp:Rating="3" rawhead:Flag="1" rawhead:Rotation="2"
            rawhead:SourceHash="xxh64:00ff" rawhead:SchemaVersion="1" rawhead:ProcessVersion="1.0">
           <rawhead:EditStack>{"schema":1}</rawhead:EditStack>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let f = try XMPSidecar.read(xml: xml)
        XCTAssertEqual(f.rating, 3)
        XCTAssertEqual(f.flag, 1)
        XCTAssertEqual(f.rotation, 2)
        XCTAssertEqual(f.sourceHash, "xxh64:00ff")
        XCTAssertEqual(f.editStackJSON, "{\"schema\":1}")
    }

    /// A Photo Merge result's recipe is written as its own element, exactly
    /// as given, and left out entirely for every other photo.
    func testMergeBlockRoundTripsAndIsLeftOutWhenEmpty() throws {
        let json = #"{"version":1,"kind":"hdr","algorithmVersion":"1","clipLevel":128,"sources":[]}"#
        let merged = XMPSidecar.Fields(rating: 2, sourceHash: "xxh64:00", mergeJSON: json)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: url) }

        try XMPSidecar.write(merged, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<latent:Merge><![CDATA[\(json)]]></latent:Merge>"), text)
        XCTAssertEqual(try XMPSidecar.read(from: url), merged)

        try XMPSidecar.write(.init(rating: 2, sourceHash: "xxh64:00"), to: url)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("Merge"))
        XCTAssertEqual(try XMPSidecar.read(from: url).mergeJSON, "")
    }

    /// `]]>` would end a CDATA section early and make the sidecar unreadable.
    /// JSON may hold it inside a string (a snapshot's name, a merged file's
    /// path), so every JSON element must bring it back byte for byte,
    /// however many times and wherever it appears.
    func testCDATAEndMarkerInsideJSONRoundTrips() throws {
        let awkward = ["]]>", "a]]>b", "]]>]]>", "]]]>>", "x]]", ">y", "]]]]><![CDATA[>"]
        func json(_ key: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [key: awkward], options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        let original = XMPSidecar.Fields(
            sourceHash: "xxh64:00",
            editStackJSON: try json("edit"), snapshotsJSON: "[" + (try json("snap")) + "]",
            historyJSON: "[" + (try json("hist")) + "]", mergeJSON: try json("merge"))
        XCTAssertTrue(original.mergeJSON.contains("]]>"), "the test must exercise the marker")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cdata-\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: url) }
        try XMPSidecar.write(original, to: url)
        XCTAssertEqual(try XMPSidecar.read(from: url), original)
    }

    /// Sidecars from before the rename use `rawhead:`; a merge block under
    /// that prefix is read like the other elements.
    func testReadsMergeBlockUnderPreRenamePrefix() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description xmlns:rawhead="https://github.com/OWNER/rawhead/ns/1.0/" rawhead:SourceHash="xxh64:00ff">
           <rawhead:Merge><![CDATA[{"version":1,"kind":"panorama"}]]></rawhead:Merge>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        XCTAssertEqual(try XMPSidecar.read(xml: xml).mergeJSON, #"{"version":1,"kind":"panorama"}"#)
    }
}
