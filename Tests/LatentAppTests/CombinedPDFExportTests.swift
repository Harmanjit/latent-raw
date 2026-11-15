import XCTest
import PixelEngine
@testable import Catalog
@testable import latent_app

/// Combine into one PDF as the export queue plans it: the file's name, the
/// collision policy on that one name, and each photo's caption.
@MainActor
final class CombinedPDFExportTests: XCTestCase {
    private func record(_ name: String = "DSC_1.NEF") -> ImageRecord {
        ImageRecord(id: 7, relPath: "A/" + name, preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: nil, camera: "Nikon D750", lens: nil, lensId: nil, iso: nil, shutter: nil,
                    aperture: nil, focal: nil, width: 6000, height: 4000, orientation: nil, rating: 4, label: nil,
                    flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    func testOnlyAPDFExportCombines() {
        var preset = ExportPreset()
        preset.formats.pdf.combine = true
        XCTAssertFalse(preset.combinesPDF, "an image export ignores the PDF option")
        preset.fileKind = .pdf
        XCTAssertTrue(preset.combinesPDF)
        preset.formats.pdf.combine = false
        XCTAssertFalse(preset.combinesPDF, "off: one PDF per photo, as before")
    }

    func testNameAndFolder() {
        var preset = ExportPreset()
        XCTAssertEqual(preset.combinedPDFStem(catalogName: "Lisbon 2026"), "Lisbon 2026")
        XCTAssertEqual(preset.combinedPDFStem(catalogName: ""), "Photos")
        preset.formats.pdf.combinedFileName = "  Proofs/v2 "
        XCTAssertEqual(preset.combinedPDFStem(catalogName: "Lisbon"), "Proofs-v2", "no path characters")
        let root = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        XCTAssertEqual(preset.combinedPDFFolder(destination: root), root)
        preset.subfolder = "pdf"
        XCTAssertEqual(preset.combinedPDFFolder(destination: root).lastPathComponent, "pdf")
    }

    func testCollisionPolicySettlesTheOneName() throws {
        let folder = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        let free = try XCTUnwrap(ExportPreset.combinedPDFTarget(folder: folder, stem: "Shoot", fileExtension: "pdf",
                                                                collision: .skip, exists: { _ in false }))
        XCTAssertEqual(free.url.lastPathComponent, "Shoot.pdf")
        XCTAssertFalse(free.replaces)
        let taken: Set<String> = ["Shoot.pdf", "Shoot-1.pdf"]
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        XCTAssertNil(ExportPreset.combinedPDFTarget(folder: folder, stem: "Shoot", fileExtension: "pdf",
                                                    collision: .skip, exists: exists))
        let numbered = try XCTUnwrap(ExportPreset.combinedPDFTarget(folder: folder, stem: "Shoot", fileExtension: "pdf",
                                                                    collision: .addNumber, exists: exists))
        XCTAssertEqual(numbered.url.lastPathComponent, "Shoot-2.pdf")
        for policy in [ExportNaming.Collision.replace, .replaceIfChanged] {
            let replaced = try XCTUnwrap(ExportPreset.combinedPDFTarget(folder: folder, stem: "Shoot",
                                                                        fileExtension: "pdf", collision: policy,
                                                                        exists: exists))
            XCTAssertEqual(replaced.url.lastPathComponent, "Shoot.pdf")
            XCTAssertTrue(replaced.replaces)
        }
    }

    func testCaptions() {
        var preset = ExportPreset()
        preset.fileKind = .pdf
        preset.formats.pdf.combine = true
        XCTAssertNil(preset.combinedPDFCaption(for: record(), index: 0, catalogName: "Shoot"),
                     "one per page: the caption template, here none")
        preset.formats.pdf.combinedLayout = .contactSheet
        XCTAssertEqual(preset.combinedPDFCaption(for: record(), index: 0, catalogName: "Shoot"), "DSC_1.NEF",
                       "a contact sheet names each photo")
        preset.formats.pdf.captionTemplate = "{camera}"
        XCTAssertEqual(preset.combinedPDFCaption(for: record(), index: 0, catalogName: "Shoot"), "NikonD750")
    }
}
