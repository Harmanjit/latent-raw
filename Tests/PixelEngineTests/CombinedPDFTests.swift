import XCTest
import CoreGraphics
@testable import PixelEngine

/// Export › PDF › Combine into one PDF (ExportPDF+Combined.swift): the
/// contact-sheet geometry, the pages a combined file gets, the file only
/// appearing once finished, and older presets reading with it off.
final class CombinedPDFTests: XCTestCase {
    private func solid(_ w: Int, _ h: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [0.8, 0.3, 0.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()!
    }

    private func temporaryPDF() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("latent-combined-\(UUID().uuidString).pdf")
    }

    func testOlderOptionsDecodeWithCombineOff() throws {
        let old = try JSONDecoder().decode(ExportPDFOptions.self, from: Data(#"{"pageSize":"a4","marginMM":5}"#.utf8))
        XCTAssertFalse(old.combine)
        XCTAssertEqual(old.combinedLayout, .onePerPage)
        XCTAssertEqual(old.photosPerPage, 4)
        XCTAssertEqual(old.combinedFileName, "")
        var options = ExportPDFOptions()
        options.combine = true
        options.combinedLayout = .contactSheet
        options.photosPerPage = 9
        options.combinedFileName = "Proofs"
        let back = try JSONDecoder().decode(ExportPDFOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(back, options)
    }

    func testContactSheetGrid() {
        var options = ExportPDFOptions()
        let expected: [Int: (Int, Int)] = [1: (1, 1), 2: (2, 1), 4: (2, 2), 6: (3, 2), 9: (3, 3), 12: (4, 3),
                                           16: (4, 4), 20: (5, 4)]
        for (count, grid) in expected {
            options.photosPerPage = count
            XCTAssertEqual(options.sheetGrid.columns, grid.0, "\(count) per page")
            XCTAssertEqual(options.sheetGrid.rows, grid.1, "\(count) per page")
            XCTAssertGreaterThanOrEqual(options.sheetGrid.columns * options.sheetGrid.rows, count)
        }
        options.photosPerPage = 6
        options.pageSize = .fitImage
        XCTAssertEqual(options.sheetPageSize.width, 841.89, accuracy: 0.01, "A4, landscape for a wide grid")
        options.photosPerPage = 4
        options.pageSize = .letter
        XCTAssertEqual(options.sheetPageSize, CGSize(width: 612, height: 792))

        // Cells sit inside the margins, apart, in reading order.
        options.marginMM = 10
        let margin = 10 * 72 / 25.4
        let first = options.sheetCell(0), second = options.sheetCell(1), third = options.sheetCell(2)
        XCTAssertEqual(first.minX, margin, accuracy: 0.01)
        XCTAssertEqual(first.minY, margin, accuracy: 0.01)
        XCTAssertGreaterThan(second.minX, first.maxX)
        XCTAssertEqual(second.minY, first.minY, accuracy: 0.01)
        XCTAssertGreaterThan(third.minY, first.maxY)
        XCTAssertEqual(options.sheetCell(3).maxX, 612 - margin, accuracy: 0.01)
        XCTAssertEqual(options.sheetCell(3).maxY, 792 - margin, accuracy: 0.01)

        // The picture keeps its shape inside its cell, above the caption.
        let placed = options.sheetPlacement(slot: 0, pixelWidth: 3000, pixelHeight: 2000, hasCaption: true)
        XCTAssertEqual(placed.image.width / placed.image.height, 1.5, accuracy: 0.001)
        XCTAssertTrue(first.insetBy(dx: -0.01, dy: -0.01).contains(placed.image))
        let caption = try? XCTUnwrap(placed.caption)
        XCTAssertGreaterThanOrEqual(caption?.minY ?? 0, placed.image.maxY - 0.01)

        XCTAssertEqual(options.combinedPageCount(photos: 0), 0)
        options.combinedLayout = .contactSheet
        XCTAssertEqual(options.combinedPageCount(photos: 5), 2)
        XCTAssertEqual(options.combinedPageCount(photos: 8), 2)
        options.combinedLayout = .onePerPage
        XCTAssertEqual(options.combinedPageCount(photos: 5), 5)
    }

    func testRenderSizeFollowsTheLayout() throws {
        var options = ExportPDFOptions()
        XCTAssertNil(options.combinedMaxLongEdge(ppi: 300), "Fit to image renders full size")
        options.pageSize = .a4
        XCTAssertEqual(try XCTUnwrap(options.combinedMaxLongEdge(ppi: 300)), 3508)
        options.combinedLayout = .contactSheet
        options.photosPerPage = 16
        let cell = try XCTUnwrap(options.combinedMaxLongEdge(ppi: 300))
        XCTAssertLessThan(cell, 3508 / 3, "a small cell needs few pixels")
    }

    func testOnePerPageWritesAPagePerPhotoSizedToEach() throws {
        var options = ExportPDFOptions()
        options.combine = true
        options.marginMM = 0
        let url = temporaryPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CombinedPDFWriter(url: url, options: options, title: "Shoot")
        writer.add(solid(300, 200), caption: nil, ppi: 300)
        writer.add(solid(200, 400), caption: "DSC_0002", ppi: 300)
        writer.add(solid(600, 600), caption: nil, ppi: 150)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing in place until finished")
        try writer.finish(replacingExisting: false)
        XCTAssertEqual(writer.photoCount, 3)
        XCTAssertEqual(writer.pageCount, 3)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, 3)
        let first = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(first.width, 72, accuracy: 0.01)
        XCTAssertEqual(first.height, 48, accuracy: 0.01)
        let second = try XCTUnwrap(document.page(at: 2)).getBoxRect(.mediaBox)
        XCTAssertEqual(second.width, 48, accuracy: 0.01)
        XCTAssertGreaterThan(second.height, 96, "room for the caption")
        let third = try XCTUnwrap(document.page(at: 3)).getBoxRect(.mediaBox)
        XCTAssertEqual(third.width, 288, accuracy: 0.01, "at its own resolution")
    }

    func testContactSheetFillsPagesInTurn() throws {
        var options = ExportPDFOptions()
        options.combine = true
        options.combinedLayout = .contactSheet
        options.photosPerPage = 4
        options.pageSize = .a4
        let url = temporaryPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CombinedPDFWriter(url: url, options: options)
        for n in 0..<5 { writer.add(solid(300, 200), caption: "DSC_000\(n).NEF", ppi: 300) }
        try writer.finish(replacingExisting: false)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, 2)
        let box = try XCTUnwrap(document.page(at: 2)).getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, 595.276, accuracy: 0.01)
        XCTAssertEqual(box.height, 841.89, accuracy: 0.01)
    }

    func testDiscardAndEmptyLeaveNothing() throws {
        let url = temporaryPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let cancelled = try CombinedPDFWriter(url: url, options: ExportPDFOptions())
        cancelled.add(solid(10, 10), caption: nil, ppi: 300)
        cancelled.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try cancelled.finish(replacingExisting: false), "a discarded PDF can't be finished")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let empty = try CombinedPDFWriter(url: url, options: ExportPDFOptions())
        XCTAssertThrowsError(try empty.finish(replacingExisting: false), "an empty PDF is no export")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // Abandoned without either: nothing either.
        do {
            let dropped = try CombinedPDFWriter(url: url, options: ExportPDFOptions())
            dropped.add(solid(10, 10), caption: nil, ppi: 300)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
