import XCTest
import PixelEngine
import ColorKit
@testable import Catalog
@testable import latent_app

/// The export options added with borders, PDF and OpenEXR as a preset
/// holds them: older presets decode to the old behaviour, every option
/// reaches the settings, and sizes typed in cm or inches become pixels.
@MainActor
final class ExportFormatPresetTests: XCTestCase {
    private func record(_ relPath: String = "A/DSC_1.NEF") -> ImageRecord {
        ImageRecord(id: 7, relPath: relPath, preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: nil, camera: "Nikon D750", lens: nil, lensId: nil, iso: nil, shutter: nil,
                    aperture: nil, focal: nil, width: 6000, height: 4000, orientation: nil, rating: 4, label: nil,
                    flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    func testOlderPresetsDecodeToTheOldBehaviour() throws {
        let old = Data(#"{"format":"png","colorSpaceIsP3":false,"profile":{"kind":"adobeRGB","name":"Adobe RGB (1998)"}}"#.utf8)
        let preset = try JSONDecoder().decode(ExportPreset.self, from: old)
        XCTAssertEqual(preset.formats, ExportFormatOptions())
        let settings = preset.settings
        XCTAssertEqual(settings.bitsPerComponent, 8, "an old PNG preset stays 8-bit")
        XCTAssertNil(settings.border)
        XCTAssertFalse(settings.keywordHierarchy)
        XCTAssertFalse(settings.embedsEdit)
        XCTAssertNil(settings.colorProfile?.intent)
        XCTAssertEqual(settings.colorProfile?.renderingIntent, .relativeColorimetric)
        // A mangled options block is ignored rather than failing the preset.
        let mangled = Data(#"{"format":"heic","formats":{"pngBitDepth":"lots","heicBitDepth":10,"border":7}}"#.utf8)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: mangled)
        XCTAssertEqual(decoded.formats.pngBitDepth, 8)
        XCTAssertEqual(decoded.formats.heicBitDepth, 10)
        XCTAssertEqual(decoded.formats.border, ExportBorder())
    }

    func testOptionsRoundTripAndReachTheSettings() throws {
        var preset = ExportPreset()
        preset.format = .tiff
        preset.tiffBitDepth = 32
        preset.profile = .proPhoto
        preset.formats.borderEnabled = true
        preset.formats.border.size = 3
        preset.formats.greyscaleWhenMonochrome = true
        preset.formats.renderingIntent = .perceptual
        preset.formats.keywordHierarchy = true
        preset.formats.embedEdit = true
        preset.formats.sizeUnit = .centimetres
        let back = try JSONDecoder().decode(ExportPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(back, preset)
        XCTAssertEqual(back.tiffBitDepth, 32, "32-bit float survives a reload")
        let s = back.settings
        XCTAssertTrue(s.writesFloatTIFF)
        XCTAssertEqual(s.border?.size, 3)
        XCTAssertTrue(s.greyscaleWhenMonochrome)
        XCTAssertEqual(s.colorProfile?.intent, .perceptual)
        XCTAssertEqual(s.colorProfile?.renderingIntent, .perceptual)
        XCTAssertTrue(s.keywordHierarchy)
        XCTAssertTrue(s.embedsEdit)

        // None means no metadata at all: the extras go with it.
        preset.includeMetadata = false
        XCTAssertFalse(preset.settings.keywordHierarchy)
        XCTAssertFalse(preset.settings.embedsEdit)
        // A border that draws nothing isn't passed on.
        preset.formats.border = ExportBorder()
        preset.formats.border.size = 0
        XCTAssertNil(preset.settings.border)
    }

    func testOverwriteIfChangedReplacesThroughTheWorker() {
        var preset = ExportPreset()
        preset.collision = .replaceIfChanged
        let request = preset.workerRequest(for: record(), root: URL(fileURLWithPath: "/cat"),
                                           destination: URL(fileURLWithPath: "/out/x.jpg"), editStackJSON: nil,
                                           keywords: [])
        XCTAssertTrue(request.replacesExisting)
        XCTAssertTrue(ExportNaming.Collision.allCases.contains(.replaceIfChanged))
    }

    func testSizesInCentimetresAndInches() {
        XCTAssertEqual(ExportSizeUnit.inches.pixels(value: 10, ppi: 300), 3000)
        XCTAssertEqual(ExportSizeUnit.centimetres.pixels(value: 25.4, ppi: 300), 3000)
        XCTAssertEqual(ExportSizeUnit.centimetres.value(pixels: 3000, ppi: 300), 25.4, accuracy: 0.0001)
        XCTAssertEqual(ExportSizeUnit.pixels.pixels(value: 1234, ppi: 72), 1234)
        XCTAssertTrue(ExportSizing.Mode.longEdge.usesLengths)
        XCTAssertFalse(ExportSizing.Mode.megapixels.usesLengths)
    }

    func testPDFNamesItsFilesAndBuildsACaption() {
        var preset = ExportPreset()
        preset.fileKind = .pdf
        XCTAssertEqual(preset.fileExtension, "pdf")
        XCTAssertFalse(preset.rendersImage)
        XCTAssertNil(preset.pdfJob(for: record(), index: 0, catalogName: "Shoot")?.caption)
        preset.formats.pdf.captionTemplate = "{name} {camera}"
        preset.formats.pdf.pageSize = .a4
        let job = preset.pdfJob(for: record(), index: 0, catalogName: "Shoot")
        XCTAssertEqual(job?.caption, "DSC_1 NikonD750")
        XCTAssertEqual(job?.ppi, 300)
        XCTAssertEqual(job?.maxLongEdge, 3508, "A4's long side at 300 ppi")
        preset.addToCatalog = true
        XCTAssertNil(preset.exportedFile(URL(fileURLWithPath: "/x.pdf"), from: record()), "a catalog can't open a PDF")
        preset.fileKind = .image
        XCTAssertNil(preset.pdfJob(for: record(), index: 0, catalogName: "Shoot"))
    }

    /// The edit embedded in exports uses the sidecar's own namespace, so
    /// either reader finds it.
    func testEmbeddedEditNamespaceIsTheSidecars() {
        XCTAssertEqual(ExportMetadata.latentNamespace, XMPSidecar.namespaceURI)
    }
}
