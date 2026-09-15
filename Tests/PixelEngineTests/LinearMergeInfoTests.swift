import XCTest
@testable import RawCore

/// Reading the `latent:Merge` recipe out of an XMP packet: the forms it can
/// take, and everything that must quietly give no merge info instead.
final class LinearMergeInfoTests: XCTestCase {
    static let recipe = #"{"version":1,"kind":"hdr","algorithmVersion":"1","clipLevel":128,"lensApplied":false,"baselineShift":7,"reference":2,"options":{"deghost":"low"},"sources":[{"path":"a.NEF","hash":"00ff","captureTime":1789473600}]}"#

    static func packet(_ body: String, namespace: String = LinearMergeInfo.namespace, prefix: String = "latent") -> Data {
        Data("""
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:\(prefix)="\(namespace)" xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:format>image/dng</dc:format>
           \(body)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """.utf8)
    }

    let expected = LinearMergeInfo(kind: "hdr", clipLevel: 128, lensApplied: false, baselineShift: 7)

    func testCDATAElementAsLatentWritesIt() {
        let data = Self.packet("<latent:Merge><![CDATA[\(Self.recipe)]]></latent:Merge>")
        XCTAssertEqual(LinearMergeInfo.parse(xmpPacket: data), expected)
    }

    func testEscapedTextElement() {
        let escaped = Self.recipe.replacingOccurrences(of: "\"", with: "&quot;")
        XCTAssertEqual(LinearMergeInfo.parse(xmpPacket: Self.packet("<latent:Merge>\(escaped)</latent:Merge>")), expected)
    }

    /// Found by namespace, whatever prefix a tool rewrote it with.
    func testOtherPrefixForTheSameNamespace() {
        let data = Self.packet("<lm:Merge><![CDATA[\(Self.recipe)]]></lm:Merge>", prefix: "lm")
        XCTAssertEqual(LinearMergeInfo.parse(xmpPacket: data), expected)
    }

    /// XMP lets a simple property be an attribute of rdf:Description.
    func testAttributeForm() {
        let attribute = Self.recipe.replacingOccurrences(of: "\"", with: "&quot;")
        let data = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:latent="\(LinearMergeInfo.namespace)" latent:Merge="\(attribute)"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
        XCTAssertEqual(LinearMergeInfo.parse(xmpPacket: data), expected)
    }

    /// The recipe grows over time; a reader only takes what it knows.
    func testUnknownKeysAreIgnored() {
        let json = #"{"kind":"panorama","clipLevel":1.5,"lensApplied":true,"baselineShift":0,"projection":"cylindrical","version":9,"sources":[]}"#
        XCTAssertEqual(LinearMergeInfo.parse(xmpPacket: Self.packet("<latent:Merge><![CDATA[\(json)]]></latent:Merge>")),
                       LinearMergeInfo(kind: "panorama", clipLevel: 1.5, lensApplied: true, baselineShift: 0))
    }

    func testAbsentOrUnusableGivesNil() {
        let cases: [(String, Data)] = [
            ("no element", Self.packet("")),
            ("wrong namespace", Self.packet("<latent:Merge><![CDATA[\(Self.recipe)]]></latent:Merge>",
                                            namespace: "https://example.com/other/")),
            ("not JSON", Self.packet("<latent:Merge>hello</latent:Merge>")),
            ("truncated JSON", Self.packet("<latent:Merge><![CDATA[{\"kind\":\"hdr\",\"clipLevel\":]]></latent:Merge>")),
            ("missing clipLevel", Self.packet(#"<latent:Merge><![CDATA[{"kind":"hdr","lensApplied":false,"baselineShift":0}]]></latent:Merge>"#)),
            ("wrong type", Self.packet(#"<latent:Merge><![CDATA[{"kind":"hdr","clipLevel":"1","lensApplied":false,"baselineShift":0}]]></latent:Merge>"#)),
            ("zero clip level", Self.packet(#"<latent:Merge><![CDATA[{"kind":"hdr","clipLevel":0,"lensApplied":false,"baselineShift":0}]]></latent:Merge>"#)),
            ("negative clip level", Self.packet(#"<latent:Merge><![CDATA[{"kind":"hdr","clipLevel":-2,"lensApplied":false,"baselineShift":0}]]></latent:Merge>"#)),
            ("empty", Data()),
            ("not XML", Data([0xFF, 0xD8, 0x00, 0x13, 0x37])),
        ]
        for (name, data) in cases {
            XCTAssertNil(LinearMergeInfo.parse(xmpPacket: data), name)
        }
    }

    /// A packet damaged after the element still gives what came before.
    func testDamageAfterTheElementDoesNotSpoilIt() {
        let good = String(decoding: Self.packet("<latent:Merge><![CDATA[\(Self.recipe)]]></latent:Merge>"), as: UTF8.self)
        let cut = good.components(separatedBy: "</rdf:Description>")[0] + "<oops"
        XCTAssertEqual(LinearMergeInfo.parse(xmpPacket: Data(cut.utf8)), expected)
    }

    /// What the plane stores for values the contract forbids.
    func testPlaneCleaning() {
        XCTAssertEqual(LinearPlane.clean(.nan), 0)
        XCTAssertEqual(LinearPlane.clean(-.infinity), 0)
        XCTAssertEqual(LinearPlane.clean(.infinity), 0)
        XCTAssertEqual(LinearPlane.clean(-0.001), 0)
        XCTAssertEqual(LinearPlane.clean(0.5), 0.5)
        XCTAssertEqual(LinearPlane.clean(1e9), 65504)
    }
}
