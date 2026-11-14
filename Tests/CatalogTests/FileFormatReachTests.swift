import XCTest
import UniformTypeIdentifiers
import ImageIO
@testable import Catalog
import RawCore

/// The rarer raw extensions and JPEG XL: which files Latent catalogs, how
/// they pair and sort, and that a format ImageIO can't read is left out.
final class FileFormatReachTests: XCTestCase {
    static let addedRawExtensions = [
        "ari", "bay", "bmq", "cap", "cine", "cs1", "dc2", "dcr", "erf", "gpr", "ia",
        "k25", "kc2", "kdc", "mdc", "mef", "pxn", "qtk", "raw", "rdc", "rw1", "sti",
    ]

    func testRareRawExtensionsAreIndexedAsRaws() {
        for ext in Self.addedRawExtensions {
            XCTAssertTrue(Catalog.rawExtensions.contains(ext), ext)
            XCTAssertTrue(Catalog.indexedExtensions.contains(ext), ext)
        }
        // The list is lower case, as the scan compares it, and the earlier
        // formats are still there.
        XCTAssertTrue(Catalog.rawExtensions.allSatisfy { $0 == $0.lowercased() })
        for ext in ["nef", "cr3", "arw", "dng", "raf", "x3f"] { XCTAssertTrue(Catalog.rawExtensions.contains(ext), ext) }
    }

    func testNoRawExtensionIsAlsoAPictureFormat() {
        // A raw extension that ImageIO also claimed would be opened two ways.
        XCTAssertTrue(Catalog.rawExtensions.isDisjoint(with: RenderedImageFormat.formatNames.keys))
        XCTAssertTrue(Catalog.rawExtensions.isDisjoint(with: RenderedImageFormat.pairCompanionExtensions))
    }

    func testRareRawsPairWithTheirJPEGs() {
        let paths = ["K/DCP_0001.KDC", "K/DCP_0001.JPG", "M/IMG_0002.mef", "M/IMG_0002.jpg",
                     "P/P1000003.RAW", "P/P1000003.JPG", "G/GOPR0004.GPR", "G/GOPR0004.JPG"]
        let pairs = RawJPEGPairs.companions(in: paths)
        XCTAssertEqual(pairs["K/DCP_0001.JPG"], "K/DCP_0001.KDC")
        XCTAssertEqual(pairs["M/IMG_0002.jpg"], "M/IMG_0002.mef")
        XCTAssertEqual(pairs["P/P1000003.JPG"], "P/P1000003.RAW")
        XCTAssertEqual(pairs["G/GOPR0004.JPG"], "G/GOPR0004.GPR")
    }

    func testFileTypeSortCallsRareRawsRaw() throws {
        for ext in ["KDC", "erf", "RAW", "gpr", "cine"] {
            let record = try makeRecord(relPath: "a/photo.\(ext)")
            XCTAssertEqual(LibrarySortKey.fileType(of: record), "Raw", ext)
        }
    }

    func testJPEGXLIsKnownAndKeptWhenImageIOReadsIt() throws {
        XCTAssertEqual(RenderedImageFormat.formatNames["jxl"], "JPEG XL")
        let type = try XCTUnwrap(UTType(filenameExtension: "jxl"))
        let withJXL = RenderedImageFormat.extensions(readableTypes: [type.identifier, UTType.jpeg.identifier])
        XCTAssertTrue(withJXL.contains("jxl"))
        XCTAssertTrue(withJXL.contains("jpg"))
    }

    func testJPEGXLIsDroppedWhenImageIOCannotReadIt() {
        let without = RenderedImageFormat.extensions(readableTypes: [UTType.jpeg.identifier, UTType.png.identifier])
        XCTAssertFalse(without.contains("jxl"))
        XCTAssertEqual(without, ["jpg", "jpeg", "jpe", "png"])
        XCTAssertTrue(RenderedImageFormat.extensions(readableTypes: []).isEmpty)
    }

    func testThisMacsSetFollowsImageIO() {
        // Whatever this Mac decodes: JPEG XL is in exactly when ImageIO
        // lists its type as readable.
        let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        let jxlReadable = UTType(filenameExtension: "jxl").map { readable.contains($0.identifier) } ?? false
        XCTAssertEqual(RenderedImageFormat.extensions.contains("jxl"), jxlReadable)
        XCTAssertEqual(Catalog.indexedExtensions.contains("jxl"), jxlReadable)
        XCTAssertTrue(RenderedImageFormat.extensions.contains("jpg"))
    }

    private func makeRecord(relPath: String) throws -> ImageRecord {
        ImageRecord(id: 1, relPath: relPath, preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }
}
