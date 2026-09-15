import XCTest
@testable import MergeKit

final class MergeRecipeTests: XCTestCase {
    func testJSONUsesTheContractKeys() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.recipe().jsonData()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "kind", "algorithmVersion", "clipLevel", "lensApplied",
                                        "baselineShift", "reference", "options", "sources"])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["kind"] as? String, "hdr")
        XCTAssertEqual(json["algorithmVersion"] as? String, "1")
        XCTAssertEqual(json["clipLevel"] as? Double, 8)
        XCTAssertEqual(json["lensApplied"] as? Bool, false)
        XCTAssertEqual(json["baselineShift"] as? Int, 0)
        XCTAssertEqual(json["reference"] as? Int, 1)
        let source = try XCTUnwrap((json["sources"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(source.keys), ["path", "hash", "captureTime"])
        XCTAssertEqual(source["captureTime"] as? Int64, 1_789_498_799)
        XCTAssertEqual(MergeRecipe.Kind.hdrPanorama.rawValue, "hdrPanorama")
    }

    func testJSONRoundTripsWithEveryOptionType() throws {
        var recipe = Fixtures.recipe(clipLevel: 0.95)
        recipe.kind = .hdrPanorama
        recipe.options = [
            "s": .string("é/<&>\"quote\""), "n": .number(-2.5), "t": .bool(true), "f": .bool(false),
            "one": .number(1), "none": .null, "list": .array([.number(1), .string("two"), .null]),
            "nested": .object(["projection": .string("cylindrical"), "rows": .array([])]),
        ]
        let decoded = try MergeRecipe(jsonData: recipe.jsonData())
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.options["t"], .bool(true), "true stays a bool, not 1")
        XCTAssertEqual(decoded.options["one"], .number(1), "1 stays a number, not true")
        XCTAssertEqual(try recipe.jsonData(), try decoded.jsonData(), "the same recipe is the same bytes")
    }

    func testDecodingIgnoresUnknownKeys() throws {
        let json = """
        {"version":1,"kind":"panorama","algorithmVersion":"3","clipLevel":1,"lensApplied":true,
         "baselineShift":2,"reference":0,"options":{},"futureField":{"x":[1,2]},
         "sources":[{"path":"a/b.CR3","hash":"00ff","captureTime":5,"extra":true}]}
        """
        let recipe = try MergeRecipe(jsonData: Data(json.utf8))
        XCTAssertEqual(recipe.kind, .panorama)
        XCTAssertTrue(recipe.lensApplied)
        XCTAssertEqual(recipe.sources, [.init(path: "a/b.CR3", hash: "00ff", captureTime: 5)])
    }

    // MARK: XMP

    func testPacketIsWellFormedXMPWithTheElement() throws {
        let recipe = Fixtures.recipe()
        let packet = try MergeXMP.packet(for: recipe)
        XCTAssertTrue(packet.hasPrefix("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"))
        XCTAssertTrue(packet.hasSuffix("<?xpacket end=\"w\"?>"))

        // Foundation's XML parser: well-formed, one Description, the
        // namespace as the contract gives it, and the JSON as the element's text.
        let body = packet.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
        let document = try XMLDocument(xmlString: body, options: [])
        let descriptions = try document.nodes(forXPath: "//*[local-name()='Description']")
        XCTAssertEqual(descriptions.count, 1)
        let description = try XCTUnwrap(descriptions.first as? XMLElement)
        XCTAssertEqual(description.namespace(forPrefix: "latent")?.stringValue,
                       "https://github.com/Harmanjit/latent-raw/ns/1.0/")
        let merge = try XCTUnwrap(description.elements(forLocalName: "Merge",
                                                       uri: MergeXMP.namespaceURI).first)
        XCTAssertEqual(try MergeRecipe(jsonData: Data(XCTUnwrap(merge.stringValue).utf8)), recipe)
        XCTAssertEqual(try MergeXMP.recipe(fromXMP: packet), recipe)
        XCTAssertTrue(try MergeXMP.element(for: recipe).hasPrefix("<latent:Merge><![CDATA[{"))
    }

    func testCDATAEndMarkerInsideTheJSONIsSplit() throws {
        var recipe = Fixtures.recipe()
        recipe.sources[0].path = "odd]]>name]]>.NEF"
        recipe.options["note"] = .string("]]]]>>")
        let element = try MergeXMP.element(for: recipe)
        // Every CDATA section ends at the first "]]>" after it opens, so none may hold another.
        let sections = element.components(separatedBy: "<![CDATA[").dropFirst()
        XCTAssertEqual(sections.count, 4, "one section, plus one per end marker in the JSON: \(element)")
        for section in sections {
            XCTAssertEqual(section.components(separatedBy: "]]>").count, 2, "one end marker in \(section)")
        }

        let packet = try MergeXMP.packet(for: recipe)
        XCTAssertEqual(try MergeXMP.recipe(fromXMP: packet), recipe)
        // And a real XML parser agrees.
        let body = packet.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
        let merge = try XCTUnwrap(try XMLDocument(xmlString: body, options: [])
            .nodes(forXPath: "//*[local-name()='Merge']").first)
        XCTAssertEqual(try MergeRecipe(jsonData: Data(XCTUnwrap(merge.stringValue).utf8)), recipe)
    }

    func testCharactersXMLForbidsAreEscapedInTheJSON() throws {
        var recipe = Fixtures.recipe()
        recipe.sources[0].path = "bell\u{7}tab\tnon\u{FFFE}char.NEF"
        let element = try MergeXMP.element(for: recipe)
        XCTAssertTrue(element.unicodeScalars.allSatisfy(MergeXMP.isXMLCharacter))
        XCTAssertEqual(try MergeXMP.recipe(fromXMP: element), recipe)
        _ = try XMLDocument(xmlString: "<r xmlns:latent=\"\(MergeXMP.namespaceURI)\">\(element)</r>", options: [])
    }

    func testReadsEscapedTextAsAnXMPToolkitMightRewriteIt() throws {
        let recipe = Fixtures.recipe()
        let json = String(decoding: try recipe.jsonData(), as: UTF8.self)
        let escaped = json.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "{", with: "&#123;")
            .replacingOccurrences(of: "}", with: "&#x7D;")
        XCTAssertEqual(try MergeXMP.recipe(fromXMP: "<x><latent:Merge>\(escaped)</latent:Merge></x>"), recipe)
        XCTAssertNil(try MergeXMP.recipe(fromXMP: "<x:xmpmeta/>"))
        XCTAssertThrowsError(try MergeXMP.recipe(fromXMP: "<latent:Merge><![CDATA[not json]]></latent:Merge>"))
    }
}
