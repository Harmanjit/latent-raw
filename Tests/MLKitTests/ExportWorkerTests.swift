import XCTest
import ImageIO
@testable import MLKit
@testable import PixelEngine
@testable import RawCore
import ColorKit

final class ExportWorkerTests: XCTestCase {
    func testResizedHEICWithEditAndMetadata() async throws {
        let path = AIMaskTests.assetPath("HSB_2615.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("latent-export-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: out) }

        var p = EditParameters(); p.exposureEV = 1
        let json = try EditStack(parameters: p).encodeJSON()
        let request = ExportWorker.Request(
            sourceURL: URL(fileURLWithPath: path), destinationURL: out, editStackJSON: json,
            userRotation: 1, settings: ExportSettings(format: .heic, quality: 0.85),
            colorSpace: .displayP3, maxLongEdge: 1600, keywords: ["test", "d750"], rating: 4)
        let outcome = try await ExportWorker.export(request, gpu: gpu)
        print(String(format: "EXPORT %dx%d in %.0f ms", outcome.pixelWidth, outcome.pixelHeight, outcome.seconds * 1000))

        // Portrait file rotated one more turn: long edge 1600, and it's
        // the *width* now (camera portrait + 90° = landscape).
        XCTAssertEqual(max(outcome.pixelWidth, outcome.pixelHeight), 1600)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.heic")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, outcome.pixelWidth)
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        // The camera's own model string, carried from the raw (LibRaw's
        // shortened "D750" only fills in when the file can't be read).
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "NIKON D750")
        // The raw says "rotated" (8); the exported pixels are already upright.
        XCTAssertEqual(tiff[kCGImagePropertyTIFFOrientation] as? Int ?? 1, 1)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first, 200)
        XCTAssertEqual(exif[kCGImagePropertyExifFNumber] as? Double ?? 0, 5.0, accuracy: 0.01)
        XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension] as? Int, outcome.pixelWidth)
        XCTAssertEqual(exif[kCGImagePropertyExifColorSpace] as? Int, 0xFFFF)
        let iptc = try XCTUnwrap(props[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords] as? [String], ["test", "d750"])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCStarRating] as? Int, 4)
        // Colour space tag survives.
        let space = props[kCGImagePropertyProfileName] as? String ?? ""
        XCTAssertTrue(space.lowercased().contains("p3"), "profile: \(space)")
    }

    /// The golden D750 raw exported as JPEG: the photo's own metadata
    /// comes along, storage tags don't, and the metadata switch really
    /// does write pixels only.
    func testGoldenRawJPEGCarriesCameraMetadataAndStripsStorageTags() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        func export(includeMetadata: Bool) async throws -> (props: [CFString: Any], data: Data, width: Int) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("latent-export-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: out) }
            let request = ExportWorker.Request(
                sourceURL: URL(fileURLWithPath: path), destinationURL: out, editStackJSON: nil, userRotation: 0,
                settings: ExportSettings(format: .jpeg), colorSpace: .sRGB, maxLongEdge: 800,
                keywords: includeMetadata ? ["latent"] : [], rating: includeMetadata ? 3 : 0,
                includeMetadata: includeMetadata)
            let outcome = try await ExportWorker.export(request, gpu: gpu)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            return (props, try Data(contentsOf: out), outcome.pixelWidth)
        }

        let (props, data, width) = try await export(includeMetadata: true)
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "NIKON CORPORATION")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist] as? String, "grodovsky@gmail.com")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFSoftware] as? String, "Latent")
        XCTAssertNil(tiff[kCGImagePropertyTIFFPhotometricInterpretation])
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2017:01:15 21:38:27")
        XCTAssertEqual(exif[kCGImagePropertyExifSubsecTimeOriginal] as? String, "59")
        XCTAssertEqual(exif[kCGImagePropertyExifMeteringMode] as? Int, 5)
        XCTAssertEqual(exif[kCGImagePropertyExifFlash] as? Int, 15)
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, 35)
        XCTAssertEqual(exif[kCGImagePropertyExifSensitivityType] as? Int, 2)
        XCTAssertNotNil(exif[kCGImagePropertyExifExposureBiasValue])
        XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension] as? Int, width)
        XCTAssertEqual(exif[kCGImagePropertyExifColorSpace] as? Int, 1)
        XCTAssertNil(exif[kCGImagePropertyExifCFAPattern])
        let aux = try XCTUnwrap(props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any])
        XCTAssertNotNil(aux[kCGImagePropertyExifAuxSerialNumber])
        XCTAssertNil(aux["AFInfo" as CFString])
        XCTAssertNil(props["{MakerNikon}" as CFString])
        let iptc = try XCTUnwrap(props[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCByline] as? [String], ["grodovsky@gmail.com"])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords] as? [String], ["latent"])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCStarRating] as? Int, 3)
        // No embedded thumbnail: the main image's start-of-image marker is the only one.
        let bytes = [UInt8](data)
        XCTAssertEqual((0..<(bytes.count - 2)).filter { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 && bytes[$0 + 2] == 0xFF }, [0])

        let bare = try await export(includeMetadata: false).props
        let bareTIFF = bare[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(bareTIFF[kCGImagePropertyTIFFMake])
        XCTAssertNil(bareTIFF[kCGImagePropertyTIFFArtist])
        XCTAssertNil((bare[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(bare[kCGImagePropertyIPTCDictionary])
        XCTAssertNil(bare[kCGImagePropertyExifAuxDictionary])
    }

    func testFullSizeTIFFKeeps16BitsAndRegeneratesAIMask() async throws {
        let path = AIMaskTests.assetPath("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        try XCTSkipUnless(SegmentationModel.isAvailable)
        let gpu = try GPUContext()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("latent-export-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: out) }

        var p = EditParameters()
        p.locals = [LocalAdjustment(name: "sky", shape: .ai(kind: "sky", modelVersion: SegmentationModel.modelVersion), exposureEV: -1)]
        let request = ExportWorker.Request(
            sourceURL: URL(fileURLWithPath: path), destinationURL: out,
            editStackJSON: try EditStack(parameters: p).encodeJSON(), userRotation: 0,
            settings: ExportSettings(format: .tiff), colorSpace: .sRGB, maxLongEdge: nil)
        let outcome = try await ExportWorker.export(request, gpu: gpu)
        XCTAssertEqual(outcome.masksGenerated, 1)
        XCTAssertEqual(outcome.pixelWidth, 6032)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 16)
    }

    /// The editor's "Export open image" encodes its current parameters as
    /// a save would and hands them to the worker, where it used to render
    /// the parameters directly. For an edit without computed state (AI
    /// masks, neural denoise) the two must give the same pixels, or that
    /// switch changed ordinary exports; with the worker, the file also
    /// carries its metadata, which the direct render never wrote.
    func testEditorEncodedEditExportsTheSamePixelsAsItsParameters() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let tmp = FileManager.default.temporaryDirectory
        let direct = tmp.appendingPathComponent("latent-direct-\(UUID().uuidString).tif")
        let worker = tmp.appendingPathComponent("latent-worker-\(UUID().uuidString).tif")
        defer { for url in [direct, worker] { try? FileManager.default.removeItem(at: url) } }

        // Parameters as the editor holds them: the image's defaults (a
        // numeric as-shot white balance) with an edit over them.
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        var p = EditParameters()
        p.whiteBalance = session.asShotWhiteBalance
        p.exposureEV = 0.3
        p.crop = CropParameters(centre: [0.5, 0.52], size: [0.8, 0.8], angle: 2)
        p.locals = [
            LocalAdjustment(name: "ball", shape: .radial(centre: [0.5, 0.55], radii: [0.3, 0.3], feather: 0.5),
                            exposureEV: 0.8, saturation: 0.3),
            LocalAdjustment(name: "top", shape: .linear(start: [0.5, 0.0], end: [0.5, 0.45]),
                            exposureEV: -1, contrast: 0.2, warmth: -0.4),
        ]
        var stack = EditStack(parameters: p)
        if let lens = session.lensCorrection {
            stack.setLensProvenance(profile: lens.profileName, databaseVersion: lens.databaseVersion)
        }
        let settings = ExportSettings(format: .tiff)

        let texture = try RenderPipeline(gpu: gpu).render(session, scale: .full, parameters: p, output: .file(.sRGB))
        try Exporter(gpu: gpu).write(texture, to: direct, settings: settings, colorSpace: .sRGB,
                                     rotation: ExportPlan.rotation(for: file.summary, userRotation: 1), crop: p.crop)

        let request = ExportWorker.Request(
            sourceURL: URL(fileURLWithPath: path), destinationURL: worker,
            editStackJSON: try stack.encodeJSON(), userRotation: 1, settings: settings,
            colorSpace: .sRGB, maxLongEdge: nil, keywords: ["ball"], rating: 3, includeMetadata: true)
        _ = try await ExportWorker.export(request, gpu: gpu)

        let a = try Self.decodedPixels(direct), b = try Self.decodedPixels(worker)
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        XCTAssertEqual(a.bitsPerComponent, b.bitsPerComponent)
        XCTAssertTrue(a.bytes == b.bytes, "the encoded edit rendered different pixels from its parameters")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(worker as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        // The camera's own EXIF strings are carried over (see ExportMetadata).
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "NIKON D750")
        let iptc = try XCTUnwrap(props[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords] as? [String], ["ball"])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCStarRating] as? Int, 3)
    }

    /// The stored samples of an image file, as decoded, with their layout.
    static func decodedPixels(_ url: URL) throws -> (width: Int, height: Int, bitsPerComponent: Int, bytes: Data) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return (image.width, image.height, image.bitsPerComponent, data)
    }
}
