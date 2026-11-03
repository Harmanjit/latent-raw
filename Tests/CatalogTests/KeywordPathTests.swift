import XCTest
@testable import Catalog

/// Hierarchical keywords as paths: typing them, writing them to sidecars
/// the way Lightroom does, reading them back, completing them, and the
/// Keyword List's tree.
final class KeywordPathTests: XCTestCase {
    func testParsingTypedKeywords() {
        XCTAssertEqual(KeywordPath.parse("sky, Places > France > Paris ,, sky,  dusk "),
                       ["sky", "Places|France|Paris", "dusk"])
        XCTAssertEqual(KeywordPath.parse("Places|France| Paris"), ["Places|France|Paris"])
        XCTAssertEqual(KeywordPath.parse(" > , >> "), [])
        XCTAssertEqual(KeywordPath.normalized("  a >  > b "), "a|b")
        XCTAssertNil(KeywordPath.normalized("   "))
    }

    func testLevels() {
        let path = "Places|France|Paris"
        XCTAssertEqual(KeywordPath.leaf(path), "Paris")
        XCTAssertEqual(KeywordPath.parent(path), "Places|France")
        XCTAssertNil(KeywordPath.parent("sky"))
        XCTAssertEqual(KeywordPath.ancestors(path), ["Places", "Places|France"])
        XCTAssertEqual(KeywordPath.display(path), "Places › France › Paris")
        XCTAssertEqual(KeywordPath.parse(KeywordPath.entryText(path)), [path])
        XCTAssertTrue(KeywordPath.path(path, isWithin: "Places"))
        XCTAssertTrue(KeywordPath.path(path, isWithin: path))
        XCTAssertFalse(KeywordPath.path("Placeshold", isWithin: "Places"), "a level, not a prefix of a name")
    }

    func testSubjectsAndMergeRoundTrip() {
        let keywords = ["Places|France|Paris", "France", "sky"]
        XCTAssertEqual(KeywordPath.flatSubjects(keywords), ["France", "Paris", "Places", "sky"])
        // What Latent writes reads back as the same keywords.
        XCTAssertEqual(KeywordPath.merge(subjects: KeywordPath.flatSubjects(keywords), hierarchical: keywords), keywords)
        // A subject added by an application that knows nothing of hierarchies stays.
        XCTAssertEqual(KeywordPath.merge(subjects: ["Paris", "Places", "France", "dog"], hierarchical: ["Places|France|Paris"]),
                       ["Places|France|Paris", "dog"])
        // No hierarchy at all: the subjects as they were.
        XCTAssertEqual(KeywordPath.merge(subjects: ["b", "a"], hierarchical: []), ["b", "a"])
    }

    func testSuggestionsRankLeafMatchesFirst() {
        let available = ["Places|France|Paris", "Paris Hilton", "People|Pat", "sky", "Places|Spain"]
        XCTAssertEqual(KeywordPath.suggestions(for: "pa", in: available),
                       ["Paris Hilton", "People|Pat", "Places|France|Paris", "Places|Spain"])
        XCTAssertEqual(KeywordPath.suggestions(for: "pla", in: available), ["Places|France|Paris", "Places|Spain"])
        XCTAssertEqual(KeywordPath.suggestions(for: "Places > Fr", in: available), ["Places|France|Paris"])
        XCTAssertEqual(KeywordPath.suggestions(for: "ky", in: available), ["sky"])
        XCTAssertEqual(KeywordPath.suggestions(for: " ", in: available), [])
        XCTAssertEqual(KeywordPath.suggestions(for: "p", in: available, limit: 2).count, 2)
    }

    func testCompletingTheLastKeyword() {
        XCTAssertEqual(KeywordPath.completing("sky, Pa", with: "Places|France|Paris"), "sky, Places > France > Paris, ")
        XCTAssertEqual(KeywordPath.completing("", with: "sky"), "sky, ")
        XCTAssertEqual(KeywordPath.lastToken("sky, Pla"), "Pla")
    }

    func testRenamingMovesEverythingInside() {
        XCTAssertEqual(KeywordPath.replacing("Places|Paris", with: "Places|France|Paris", in: "Places|Paris|Louvre"),
                       "Places|France|Paris|Louvre")
        XCTAssertEqual(KeywordPath.replacing("Places|Paris", with: "X", in: "Places|Parisian"), "Places|Parisian")
        XCTAssertEqual(KeywordPath.replacing("sky", with: "Sky", in: "sky"), "Sky")
    }

    func testTreeCountsPhotosBeneathEachLevel() {
        let index: [Int64: Set<String>] = [
            1: ["Places|France|Paris", "sky"],
            2: ["Places|France|Lyon"],
            3: ["Places|Spain", "Places|France|Paris"],
        ]
        let tree = KeywordTree.build(from: index)
        XCTAssertEqual(tree.map(\.name), ["Places", "sky"])
        let places = tree[0]
        XCTAssertEqual(places.count, 3)
        XCTAssertEqual(places.children.map(\.name), ["France", "Spain"])
        XCTAssertEqual(places.children[0].count, 3)
        XCTAssertEqual(places.children[0].children.map(\.name), ["Lyon", "Paris"])
        XCTAssertEqual(places.children[0].children[1].count, 2)
        XCTAssertEqual(places.children[0].children[1].path, "Places|France|Paris")

        let found = KeywordTree.filter(tree, matching: "ly")
        XCTAssertEqual(found.map(\.name), ["Places"])
        XCTAssertEqual(found[0].children.map(\.name), ["France"])
        XCTAssertEqual(found[0].children[0].children.map(\.name), ["Lyon"])
    }

    func testFilterFindsKeywordsInside() {
        var filter = LibraryFilter()
        filter.keyword = "Places|France"
        let record = ImageRecord(relPath: "a.NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
        XCTAssertTrue(filter.matches(record, isEdited: false, keywords: ["Places|France|Paris"]))
        XCTAssertTrue(filter.matches(record, isEdited: false, keywords: ["Places|France"]))
        XCTAssertFalse(filter.matches(record, isEdited: false, keywords: ["Places"]))
        XCTAssertFalse(filter.matches(record, isEdited: false, keywords: ["Places|Frances"]))
    }

    // MARK: Sidecars

    func testSidecarWritesLightroomHierarchyAndReadsItBack() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fields = XMPSidecar.Fields(rating: 2, keywords: ["Places|France|Paris", "sky"], sourceHash: "xxh64:0")
        let url = tmp.appendingPathComponent("a.NEF.xmp")
        try XMPSidecar.write(fields, to: url)
        let xml = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(xml.contains(#"xmlns:lr="http://ns.adobe.com/lightroom/1.0/""#))
        XCTAssertTrue(xml.contains("<lr:hierarchicalSubject><rdf:Bag>"))
        XCTAssertTrue(xml.contains("<rdf:li>Places|France|Paris</rdf:li>"))
        for level in ["Places", "France", "Paris", "sky"] {
            XCTAssertTrue(xml.contains("<rdf:li>\(level)</rdf:li>"), level)
        }
        XCTAssertEqual(try XMPSidecar.read(from: url), fields)
    }

    /// A sidecar of flat keywords is written exactly as before hierarchies.
    func testFlatKeywordSidecarHasNoLightroomBlock() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("a.NEF.xmp")
        try XMPSidecar.write(XMPSidecar.Fields(keywords: ["sky", "sea"], sourceHash: "xxh64:0"), to: url)
        let xml = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(xml.contains("lr:"))
        XCTAssertTrue(xml.contains("   </rdf:Bag></dc:subject>\n   <latent:EditStack>"))
    }

    func testReadsLightroomClassicSidecar() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/">
           <dc:subject><rdf:Bag><rdf:li>Animals</rdf:li><rdf:li>Dog</rdf:li><rdf:li>beach</rdf:li></rdf:Bag></dc:subject>
           <lr:hierarchicalSubject><rdf:Bag><rdf:li>Animals|Dog</rdf:li><rdf:li>beach</rdf:li></rdf:Bag></lr:hierarchicalSubject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        XCTAssertEqual(try XMPSidecar.read(xml: xml).keywords, ["Animals|Dog", "beach"])
    }
}
