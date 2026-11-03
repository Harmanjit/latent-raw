import XCTest
import ImageIO
@testable import PixelEngine

/// Hierarchical keywords leave the app as flat IPTC keywords, every level.
final class ExportKeywordTests: XCTestCase {
    func testHierarchyIsFlattenedOnce() {
        XCTAssertEqual(ExportMetadata.flattenedKeywords(["Places|France|Paris", "France", "sky", "Places|Spain"]),
                       ["Places", "France", "Paris", "sky", "Spain"])
        XCTAssertEqual(ExportMetadata.flattenedKeywords([]), [])
    }

    func testIPTCKeywordsCarryEveryLevel() {
        var metadata = ExportMetadata()
        metadata.keywords = ["Animals|Dog"]
        let iptc = metadata.imageIOProperties[kCGImagePropertyIPTCDictionary] as? [String: Any]
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCKeywords as String] as? [String], ["Animals", "Dog"])
    }
}
