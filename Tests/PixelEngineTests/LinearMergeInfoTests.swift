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

    // MARK: - Lens

    /// Every field of the recipe's lens object, with values that only
    /// survive if nothing is rounded: LibRaw's Float apertures and the
    /// 64-bit "no maker lens ID" value.
    static let lensJSON = #"{"model":"","make":"Nikon","makerNotesName":"AF-S DX Zoom-Nikkor 17-55mm f/2.8G IF-ED","makerLensID":18446744073709551615,"nikonLensID":125,"nikonLensType":6,"minFocal":17,"maxFocal":55,"maxApertureAtMinFocal":2.799999952316284,"maxApertureAtMaxFocal":2.799999952316284,"cropFactor":1.4705882352941178}"#
    static let lens = LinearMergeInfo.Lens(model: "", identity: LensIdentity(
        make: "Nikon", makerNotesName: "AF-S DX Zoom-Nikkor 17-55mm f/2.8G IF-ED", makerLensID: .max,
        nikonLensID: 125, nikonLensType: 6, minFocal: 17, maxFocal: 55,
        maxApertureAtMinFocal: Double(Float(2.8)), maxApertureAtMaxFocal: Double(Float(2.8)),
        cropFactor: 1.4705882352941178))

    private static func withLens(_ lens: String) -> Data {
        let json = String(recipe.dropLast()) + #","lens":"# + lens + "}"
        return packet("<latent:Merge><![CDATA[\(json)]]></latent:Merge>")
    }

    func testLensObjectIsRead() {
        let info = LinearMergeInfo.parse(xmpPacket: Self.withLens(Self.lensJSON))
        XCTAssertEqual(info?.lens, Self.lens)
        XCTAssertEqual(info?.lens?.identity.makerLensID, UInt64.max, "the 64-bit value isn't rounded")
        XCTAssertEqual(info?.clipLevel, 128)
    }

    /// Each field on its own, so a key read into the wrong field shows.
    func testEachLensFieldRoundTrips() throws {
        let base = LensIdentity(make: "", makerNotesName: "", makerLensID: 0, nikonLensID: 0, nikonLensType: 0,
                                minFocal: 0, maxFocal: 0, maxApertureAtMinFocal: 0, maxApertureAtMaxFocal: 0,
                                cropFactor: 0)
        func identity(_ change: (inout [String: Any]) -> Void) -> LensIdentity {
            var f: [String: Any] = ["make": base.make, "makerNotesName": base.makerNotesName,
                                    "makerLensID": base.makerLensID, "nikonLensID": base.nikonLensID,
                                    "nikonLensType": base.nikonLensType, "minFocal": base.minFocal,
                                    "maxFocal": base.maxFocal, "maxApertureAtMinFocal": base.maxApertureAtMinFocal,
                                    "maxApertureAtMaxFocal": base.maxApertureAtMaxFocal, "cropFactor": base.cropFactor]
            change(&f)
            return LensIdentity(make: f["make"] as! String, makerNotesName: f["makerNotesName"] as! String,
                                makerLensID: f["makerLensID"] as! UInt64, nikonLensID: f["nikonLensID"] as! UInt8,
                                nikonLensType: f["nikonLensType"] as! UInt8, minFocal: f["minFocal"] as! Double,
                                maxFocal: f["maxFocal"] as! Double,
                                maxApertureAtMinFocal: f["maxApertureAtMinFocal"] as! Double,
                                maxApertureAtMaxFocal: f["maxApertureAtMaxFocal"] as! Double,
                                cropFactor: f["cropFactor"] as! Double)
        }
        let cases: [(String, LinearMergeInfo.Lens)] = [
            ("model", .init(model: "EF-S 18-55mm", identity: base)),
            ("make", .init(model: "", identity: identity { $0["make"] = "Canon" })),
            ("makerNotesName", .init(model: "", identity: identity { $0["makerNotesName"] = "EF 50mm f/1.4 USM" })),
            ("makerLensID", .init(model: "", identity: identity { $0["makerLensID"] = UInt64(198) })),
            ("nikonLensID", .init(model: "", identity: identity { $0["nikonLensID"] = UInt8(125) })),
            ("nikonLensType", .init(model: "", identity: identity { $0["nikonLensType"] = UInt8(6) })),
            ("minFocal", .init(model: "", identity: identity { $0["minFocal"] = 17.5 })),
            ("maxFocal", .init(model: "", identity: identity { $0["maxFocal"] = 55.0 })),
            ("maxApertureAtMinFocal", .init(model: "", identity: identity { $0["maxApertureAtMinFocal"] = 3.5 })),
            ("maxApertureAtMaxFocal", .init(model: "", identity: identity { $0["maxApertureAtMaxFocal"] = 5.6 })),
            ("cropFactor", .init(model: "", identity: identity { $0["cropFactor"] = 1.6 })),
        ]
        for (field, lens) in cases {
            let info = LinearMergeInfo(kind: "hdr", clipLevel: 2, lensApplied: false, baselineShift: 1, lens: lens)
            let decoded = try JSONDecoder().decode(LinearMergeInfo.self, from: JSONEncoder().encode(info))
            XCTAssertEqual(decoded, info, field)
            XCTAssertNotEqual(decoded.lens, .init(model: "", identity: base), "\(field) was lost")
        }
    }

    /// The decoder service sends merge info to the app as JSON; the lens
    /// crosses with it.
    func testLensSurvivesTheServiceReply() throws {
        let info = LinearMergeInfo(kind: "hdr", clipLevel: 0.25, lensApplied: false, baselineShift: 3, lens: Self.lens)
        let data = try JSONEncoder().encode(info)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lens = try XCTUnwrap(object["lens"] as? [String: Any])
        XCTAssertEqual(Set(lens.keys), ["model", "make", "makerNotesName", "makerLensID", "nikonLensID",
                                        "nikonLensType", "minFocal", "maxFocal", "maxApertureAtMinFocal",
                                        "maxApertureAtMaxFocal", "cropFactor"], "every field, unknowns included")
        XCTAssertEqual(try JSONDecoder().decode(LinearMergeInfo.self, from: data), info)
    }

    func testRecipeWithoutLensHasNoLens() {
        XCTAssertNil(LinearMergeInfo.parse(xmpPacket: Self.packet("<latent:Merge><![CDATA[\(Self.recipe)]]></latent:Merge>"))?.lens)
    }

    /// A later version may add lens keys, or leave some out.
    func testLensUnknownKeysAreIgnoredAndMissingOnesAreUnknown() {
        let info = LinearMergeInfo.parse(xmpPacket: Self.withLens(#"{"makerNotesName":"EF 50mm f/1.4 USM","mount":"EF","minFocal":50}"#))
        let lens = info?.lens
        XCTAssertEqual(lens?.model, "")
        XCTAssertEqual(lens?.identity.makerNotesName, "EF 50mm f/1.4 USM")
        XCTAssertEqual(lens?.identity.minFocal, 50)
        XCTAssertEqual(lens?.identity.maxFocal, 0)
        XCTAssertEqual(lens?.identity.makerLensID, LinearMergeInfo.Lens.makerLensIDNotSet)
    }

    /// A damaged lens costs only the lens: the clip level and lens state,
    /// which rendering needs, still come through.
    func testUnusableLensIsDroppedButTheRecipeIsKept() {
        for bad in [#""EF 50mm""#, #"{"nikonLensID":300}"#, #"{"minFocal":"17"}"#, "[1,2]"] {
            let info = LinearMergeInfo.parse(xmpPacket: Self.withLens(bad))
            XCTAssertEqual(info, expected, bad)
            XCTAssertNil(info?.lens, bad)
        }
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
