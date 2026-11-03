import XCTest
import ImageIO
@testable import PixelEngine
@testable import RawCore

/// The title, caption, creator and copyright typed in Latent reach every
/// export format: in the IPTC block, the TIFF dictionary and XMP, over the
/// raw's own values, and with or without XMP from the source.
final class ExportDescriptionTests: XCTestCase {
    private let typed = ExportDescription(title: "Harbour", caption: "Boats at dusk\nsecond line",
                                                creator: "Ann Smith; Bo Lee", copyright: "© 2026 Ann Smith")

    private func written(_ metadata: ExportMetadata, _ format: ExportSettings.Format) throws -> (props: [String: Any], xmp: CGImageMetadata?) {
        let image = try ExportMetadataTests.image(width: 32, height: 24, space: CGColorSpace.sRGB)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-description-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.write(cgImage: image, to: url, settings: ExportSettings(format: format), metadata: metadata)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        return (props, CGImageSourceCopyMetadataAtIndex(source, 0, nil))
    }

    private func check(_ out: (props: [String: Any], xmp: CGImageMetadata?), _ label: String) throws {
        let tiff = try XCTUnwrap(out.props[kCGImagePropertyTIFFDictionary as String] as? [String: Any], label)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCopyright as String] as? String, "© 2026 Ann Smith", label)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String, "Ann Smith; Bo Lee", label)
        let xmp = try XCTUnwrap(out.xmp, label)
        func value(_ path: String) -> String? {
            CGImageMetadataCopyStringValueWithPath(xmp, nil, path as CFString) as String?
        }
        XCTAssertEqual(value("dc:title[x-default]"), "Harbour", label)
        XCTAssertEqual(value("dc:description[x-default]"), "Boats at dusk\nsecond line", label)
        XCTAssertEqual(value("dc:rights[x-default]"), "© 2026 Ann Smith", label)
        XCTAssertEqual(value("dc:creator[0]"), "Ann Smith", label)
        XCTAssertEqual(value("dc:creator[1]"), "Bo Lee", label)
    }

    func testDescriptionReachesEveryFormatWithoutSourceMetadata() throws {
        var metadata = ExportMetadata()
        metadata.cameraModel = "Camera"
        metadata.descriptive = typed
        for format in ExportSettings.Format.allCases {
            try check(try written(metadata, format), format.rawValue)
        }
    }

    /// The raw's own title, artist and copyright give way to what was typed.
    func testDescriptionReplacesTheSourcesOwnValues() throws {
        var metadata = ExportMetadata()
        metadata.source = SourceMetadata(imageData: try ExportMetadataTests.richSourceJPEG())
        metadata.descriptive = typed
        for format in ExportSettings.Format.allCases {
            try check(try written(metadata, format), format.rawValue)
        }
    }

    func testEmptyDescriptionWritesNothingNew() throws {
        XCTAssertTrue(ExportDescription(title: "  ", caption: nil, creator: "", copyright: "\n").isEmpty)
        var metadata = ExportMetadata()
        metadata.cameraModel = "Camera"
        let out = try written(metadata, .jpeg)
        XCTAssertNil(out.props[kCGImagePropertyIPTCDictionary as String])
        let tiff = out.props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFCopyright as String])
    }
}
