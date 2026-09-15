import XCTest
import ImageIO
import CoreGraphics
@testable import PixelEngine
@testable import RawCore

final class ExportMetadataTests: XCTestCase {
    // MARK: - Reading the raw

    /// The golden D750 file carries an artist, IPTC byline and the usual
    /// exposure details; the storage tags and maker blocks must not come along.
    func testD750SourceMetadataKeepsPhotoTagsAndDropsStorageTags() throws {
        let path = TestAssets.path("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let source = try SourceMetadata(path: path)
        let props = source.imageProperties(includingLocation: true)

        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String, "grodovsky@gmail.com")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel as String] as? String, "NIKON D750")
        for gone in [kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFCompression,
                     kCGImagePropertyTIFFPhotometricInterpretation] {
            XCTAssertNil(tiff[gone as String], "\(gone)")
        }
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifMeteringMode as String] as? Int, 5)
        XCTAssertEqual(exif[kCGImagePropertyExifFlash as String] as? Int, 15)
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int, 35)
        XCTAssertEqual(exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String, "59")
        XCTAssertNotNil(exif[kCGImagePropertyExifExposureBiasValue as String])
        let aux = try XCTUnwrap(props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any])
        XCTAssertNotNil(aux[kCGImagePropertyExifAuxSerialNumber as String])
        XCTAssertNil(aux["AFInfo"])
        let iptc = try XCTUnwrap(props[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCByline as String] as? [String], ["grodovsky@gmail.com"])
        XCTAssertNil(props["{MakerNikon}"])
        XCTAssertNil(props[kCGImagePropertyPixelWidth as String])

        // XMP carries only what the dictionaries don't rebuild.
        let xmp = try XCTUnwrap(source.xmpMetadata(includingLocation: true))
        XCTAssertNotNil(CGImageMetadataCopyTagWithPath(xmp, nil, "dc:creator" as CFString))
        let prefixes = (CGImageMetadataCopyTags(xmp) as? [CGImageMetadataTag] ?? [])
            .compactMap { CGImageMetadataTagCopyPrefix($0) as String? }
        XCTAssertFalse(prefixes.contains { ["exif", "tiff", "exifEX", "iio"].contains($0) }, "\(prefixes)")
    }

    func testScrubRemovesStorageTagsAndNonPlistValues() {
        let all: [String: Any] = [
            kCGImagePropertyPixelWidth as String: 160,
            kCGImagePropertyDPIWidth as String: 300,
            "{MakerNikon}": ["ShutterCount": 12],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFOrientation as String: 6,
                kCGImagePropertyTIFFCompression as String: 1,
                kCGImagePropertyTIFFCopyright as String: "CC0",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifCFAPattern as String: [0, 1, 1, 2],
                kCGImagePropertyExifColorSpace as String: 1,
                kCGImagePropertyExifFocalPlaneXResolution as String: 1234.5,
                kCGImagePropertyExifSubjectArea as String: [10, 20, 30, 40],
                kCGImagePropertyExifOffsetTimeOriginal as String: "+02:00",
                "Odd": NSNull(),
            ],
            kCGImagePropertyExifAuxDictionary as String: ["AFInfo": [0.1, 0.2], "Firmware": "1.10"],
            kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCImageOrientation as String: "P"],
        ]
        let clean = SourceMetadata.scrubbed(all)
        XCTAssertEqual(Set(clean.keys), [kCGImagePropertyDPIWidth as String, kCGImagePropertyTIFFDictionary as String,
                                         kCGImagePropertyExifDictionary as String,
                                         kCGImagePropertyExifAuxDictionary as String])
        XCTAssertEqual(clean[kCGImagePropertyTIFFDictionary as String] as? [String: String],
                       [kCGImagePropertyTIFFCopyright as String: "CC0"])
        XCTAssertEqual(clean[kCGImagePropertyExifDictionary as String] as? [String: String],
                       [kCGImagePropertyExifOffsetTimeOriginal as String: "+02:00"])
        XCTAssertEqual(clean[kCGImagePropertyExifAuxDictionary as String] as? [String: String], ["Firmware": "1.10"])
    }

    /// A peer can't make the app decode an oversized payload or smuggle a
    /// path expression in through a prefix.
    func testRefusesOversizedPayloadsAndOddNames() throws {
        let big = Data(count: SourceMetadata.maxPayloadBytes + 1)
        XCTAssertThrowsError(try SourceMetadata(properties: Data(), xmpTags: big))
        XCTAssertThrowsError(try SourceMetadata(properties: big, xmpTags: nil))

        let nodes: [[String: Any]] = [
            ["namespace": "http://example.com/a/", "prefix": "a:b", "name": "c", "type": 1, "value": "x"],
            ["namespace": "http://example.com/a/", "prefix": "a", "name": "c[1]", "type": 1, "value": "x"],
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: nodes, format: .binary, options: 0)
        XCTAssertNil(try SourceMetadata(properties: Data(), xmpTags: plist).xmpMetadata(includingLocation: true))
        XCTAssertFalse(SourceMetadata.isXMLName("1abc"))
        XCTAssertTrue(SourceMetadata.isXMLName("Iptc4xmpExt"))
    }

    // MARK: - Writing the export

    /// Everything a photo's metadata carries, round-tripped through the
    /// reader and the exporter in each format: kept, cleaned, overlaid.
    func testExportCarriesSourceMetadataWithLatentOverlays() throws {
        let source = SourceMetadata(imageData: try Self.richSourceJPEG())
        var metadata = ExportMetadata()
        metadata.source = source
        metadata.cameraModel = "Summary model"      // the file's own wins
        metadata.lensModel = "Matched lens profile"  // the file has none: fills in
        metadata.keywords = ["latent", "source"]
        metadata.rating = 4
        metadata.includeLocation = true

        let image = try Self.image(width: 64, height: 48, space: CGColorSpace.displayP3)
        for format in ExportSettings.Format.allCases {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("latent-metadata-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try Exporter.write(cgImage: image, to: url, settings: ExportSettings(format: format), metadata: metadata)

            let out = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(out, 0, nil) as? [String: Any])
            let label = format.rawValue
            XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int ?? 1, 1, label)

            let gps = try XCTUnwrap(props[kCGImagePropertyGPSDictionary as String] as? [String: Any], label)
            XCTAssertEqual(gps[kCGImagePropertyGPSLatitude as String] as? Double ?? 0, 59.9139, accuracy: 0.001, label)
            XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef as String] as? String, "N", label)

            let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any], label)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String, "A. Photographer", label)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFCopyright as String] as? String, "CC0", label)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFModel as String] as? String, "Camera X", label)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFSoftware as String] as? String, "Latent", label)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFOrientation as String] as? Int ?? 1, 1, label)

            let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any], label)
            XCTAssertEqual(exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String, "+02:00", label)
            XCTAssertEqual(exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String, "42", label)
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2024:06:01 12:34:56", label)
            XCTAssertEqual(exif[kCGImagePropertyExifExposureBiasValue as String] as? Double ?? 0, -0.7, accuracy: 0.01, label)
            XCTAssertEqual(exif[kCGImagePropertyExifMeteringMode as String] as? Int, 5, label)
            XCTAssertEqual(exif[kCGImagePropertyExifLensModel as String] as? String, "Matched lens profile", label)
            XCTAssertNil(exif[kCGImagePropertyExifSubjectArea as String], label)
            XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension as String] as? Int, 64, label)
            XCTAssertNotEqual(exif[kCGImagePropertyExifColorSpace as String] as? Int, 1, "P3 is not sRGB (\(label))")
            let aux = try XCTUnwrap(props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any], label)
            XCTAssertEqual(aux[kCGImagePropertyExifAuxSerialNumber as String] as? String, "12345", label)

            let xmp = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(out, 0, nil), label)
            func value(_ path: String) -> String? {
                CGImageMetadataCopyStringValueWithPath(xmp, nil, path as CFString) as String?
            }
            XCTAssertEqual(value("xmp:Rating"), "4", label)
            XCTAssertEqual(value("dc:title[x-default]"), "A title", label)
            XCTAssertEqual(value("Iptc4xmpExt:LocationCreated[0].Iptc4xmpExt:City"), "Oslo", label)
            XCTAssertNil(CGImageMetadataCopyTagWithPath(xmp, nil, "crs:Exposure2012" as CFString), label)
            let subjects = CGImageMetadataCopyTagWithPath(xmp, nil, "dc:subject" as CFString)
                .flatMap { CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] }?
                .compactMap { CGImageMetadataTagCopyValue($0) as? String }
            XCTAssertEqual(subjects, ["source", "latent"], label)
        }
    }

    /// Unless location is asked for, the file doesn't say where the photo
    /// was taken or which camera body and lens took it, neither in the
    /// dictionaries nor in XMP. Credits, captions and keywords stay.
    func testLocationAndSerialNumbersAreLeftOutUnlessAsked() throws {
        let source = SourceMetadata(imageData: try Self.richSourceJPEG())
        XCTAssertFalse(ExportMetadata().includeLocation, "off unless asked for")

        let kept = source.imageProperties(includingLocation: true)
        let stripped = source.imageProperties(includingLocation: false)
        func tag(_ props: [String: Any], _ dictionary: CFString, _ key: CFString) -> Any? {
            (props[dictionary as String] as? [String: Any])?[key as String]
        }
        XCTAssertNotNil(kept[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(stripped[kCGImagePropertyGPSDictionary as String])
        for (dictionary, key) in [(kCGImagePropertyExifDictionary, kCGImagePropertyExifBodySerialNumber),
                                  (kCGImagePropertyExifDictionary, kCGImagePropertyExifLensSerialNumber),
                                  (kCGImagePropertyExifAuxDictionary, kCGImagePropertyExifAuxSerialNumber),
                                  (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCity)] {
            XCTAssertNotNil(tag(kept, dictionary, key), "\(key)")
            XCTAssertNil(tag(stripped, dictionary, key), "\(key)")
        }
        XCTAssertEqual(tag(stripped, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist) as? String,
                       "A. Photographer")
        XCTAssertEqual(tag(stripped, kCGImagePropertyExifDictionary, kCGImagePropertyExifMeteringMode) as? Int, 5)

        var metadata = ExportMetadata()
        metadata.source = source
        metadata.keywords = ["latent"]
        let image = try Self.image(width: 64, height: 48, space: CGColorSpace.sRGB)
        for format in ExportSettings.Format.allCases {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("latent-location-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try Exporter.write(cgImage: image, to: url, settings: ExportSettings(format: format), metadata: metadata)

            let out = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(out, 0, nil) as? [String: Any])
            let label = format.rawValue
            XCTAssertNil(props[kCGImagePropertyGPSDictionary as String], label)
            XCTAssertNil(tag(props, kCGImagePropertyExifDictionary, kCGImagePropertyExifBodySerialNumber), label)
            XCTAssertNil(tag(props, kCGImagePropertyExifDictionary, kCGImagePropertyExifLensSerialNumber), label)
            XCTAssertNil(tag(props, kCGImagePropertyExifAuxDictionary, kCGImagePropertyExifAuxSerialNumber), label)
            XCTAssertNil(tag(props, kCGImagePropertyExifAuxDictionary, kCGImagePropertyExifAuxLensSerialNumber), label)
            XCTAssertNil(tag(props, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCity), label)
            XCTAssertEqual(tag(props, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist) as? String,
                           "A. Photographer", label)

            let xmp = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(out, 0, nil), label)
            let prefixes = (CGImageMetadataCopyTags(xmp) as? [CGImageMetadataTag] ?? [])
                .map { "\(CGImageMetadataTagCopyPrefix($0) as String? ?? ""):\(CGImageMetadataTagCopyName($0) as String? ?? "")" }
            for gone in ["Iptc4xmpExt:LocationCreated", "photoshop:City", "aux:SerialNumber", "aux:LensSerialNumber"] {
                XCTAssertFalse(prefixes.contains(gone), "\(gone) in \(label): \(prefixes)")
            }
            XCTAssertFalse(prefixes.contains { $0.hasPrefix("exif:GPS") }, "\(label): \(prefixes)")
            XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(xmp, nil, "dc:title[x-default]" as CFString) as String?,
                           "A title", label)
        }
    }

    /// The capture date written when the raw's own can't be read: EXIF's
    /// form in the Gregorian calendar, whatever the Mac's region uses.
    func testFallbackCaptureDateIgnoresTheUsersCalendarAndLocale() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let formatter = ExportMetadata.exifDateFormatter(timeZone: utc)
        XCTAssertEqual(formatter.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(formatter.calendar.identifier, .gregorian)
        XCTAssertEqual(formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000)), "2023:11:14 22:13:20")

        var metadata = ExportMetadata()
        metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        let exif = try XCTUnwrap(metadata.imageIOProperties[kCGImagePropertyExifDictionary] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
                       ExportMetadata.exifDateFormatter().string(from: metadata.captureDate!))
        XCTAssertTrue((exif[kCGImagePropertyExifDateTimeOriginal as String] as? String ?? "").hasPrefix("2023:11:1"))
    }

    /// Exif ColorSpace 1 only for sRGB, and no embedded thumbnail.
    func testSRGBJPEGIsTaggedAndHasNoThumbnail() throws {
        var metadata = ExportMetadata()
        metadata.source = SourceMetadata(imageData: try Self.richSourceJPEG())
        let image = try Self.image(width: 640, height: 480, space: CGColorSpace.sRGB)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latent-metadata-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.write(cgImage: image, to: url, settings: ExportSettings(format: .jpeg), metadata: metadata)

        let out = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(out, 0, nil) as? [String: Any])
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifColorSpace as String] as? Int, 1)
        // A thumbnail would be a second JPEG (its own start-of-image marker)
        // inside the EXIF block; the main image's is the only one.
        let bytes = [UInt8](try Data(contentsOf: url))
        let starts = (0..<(bytes.count - 2)).filter { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 && bytes[$0 + 2] == 0xFF }
        XCTAssertEqual(starts, [0])
    }

    // MARK: - Fixtures

    static func image(width: Int, height: Int, space: CFString) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: space)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// A JPEG standing in for a raw with everything a photo can carry,
    /// plus the tags an export must not keep.
    static func richSourceJPEG() throws -> Data {
        let xmpPacket = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"
          xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
          xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
          xmp:Rating="2" crs:Exposure2012="+1.00" aux:SerialNumber="12345" aux:LensSerialNumber="L678"
          photoshop:City="Oslo">
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">A title</rdf:li></rdf:Alt></dc:title>
        <Iptc4xmpExt:LocationCreated><rdf:Bag><rdf:li rdf:parseType="Resource">
          <Iptc4xmpExt:City>Oslo</Iptc4xmpExt:City></rdf:li></rdf:Bag></Iptc4xmpExt:LocationCreated>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let xmp = try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(xmpPacket.utf8) as CFData))
        let properties: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 59.9139, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 10.7522, kCGImagePropertyGPSLongitudeRef as String: "E",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFArtist as String: "A. Photographer", kCGImagePropertyTIFFCopyright as String: "CC0",
                kCGImagePropertyTIFFMake as String: "Maker", kCGImagePropertyTIFFModel as String: "Camera X",
                kCGImagePropertyTIFFOrientation as String: 6,
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2024:06:01 12:34:56",
                kCGImagePropertyExifSubsecTimeOriginal as String: "42",
                kCGImagePropertyExifOffsetTimeOriginal as String: "+02:00",
                kCGImagePropertyExifExposureBiasValue as String: -0.7,
                kCGImagePropertyExifMeteringMode as String: 5,
                kCGImagePropertyExifSubjectArea as String: [100, 80, 20, 20],
                kCGImagePropertyExifColorSpace as String: 1,
                kCGImagePropertyExifBodySerialNumber as String: "B999",
                kCGImagePropertyExifLensSerialNumber as String: "L678",
            ],
            kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCKeywords as String: ["source"],
                                                       kCGImagePropertyIPTCCity as String: "Oslo"],
        ]
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, try image(width: 200, height: 160, space: CGColorSpace.sRGB),
                                              xmp, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
