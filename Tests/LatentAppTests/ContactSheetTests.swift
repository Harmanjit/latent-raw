import XCTest
import AppKit
import ImageIO
import PixelEngine
@testable import latent_app

/// Contact sheets: settings to layout, the store, file names, and writing a
/// PDF or a picture through SafeFileWriter.
@MainActor
final class ContactSheetTests: XCTestCase {
    func testSettingsBecomeALayout() {
        var settings = ContactSheetSettings()
        XCTAssertEqual(settings.format, .pdf)
        XCTAssertEqual(settings.pagePixelSize, CGSize(width: 2480, height: 3508))
        settings.columns = 4
        settings.rows = 5
        settings.margin = 100
        settings.spacing = 20
        settings.caption = .nameAndDate
        settings.captionSize = 40
        let layout = settings.layout(imageCount: 45, title: "Trip")
        XCTAssertEqual(layout.margins, LayoutInsets(all: 100))
        XCTAssertEqual(layout.columns, 4)
        XCTAssertEqual(layout.rows, 5)
        XCTAssertEqual(layout.headerHeight, 40 * 1.6 * 2)
        XCTAssertEqual(layout.footerHeight, 40 * 2.2)
        XCTAssertEqual(layout.captionHeight, CaptionContent.nameAndDate.height(fontSize: 40))
        XCTAssertFalse(layout.autoRotate)
        XCTAssertFalse(layout.centersPartialPages)
        XCTAssertEqual(settings.pageCount(imageCount: 45), 3)
        XCTAssertEqual(settings.style(title: "  Trip ").header, "Trip")
        XCTAssertTrue(settings.style(title: "Trip").showsPageNumbers)
        // No title text, or the title switched off: no band for it.
        XCTAssertEqual(settings.layout(imageCount: 45, title: " ").headerHeight, 0)
        settings.showsTitle = false
        XCTAssertEqual(settings.layout(imageCount: 45, title: "Trip").headerHeight, 0)
        XCTAssertNil(settings.style(title: "Trip").header)

        // A picture holds every photo on its one page, without page numbers.
        settings.format = .jpeg
        XCTAssertNil(settings.effectiveRows)
        XCTAssertEqual(settings.pageCount(imageCount: 45), 1)
        XCTAssertEqual(settings.layout(imageCount: 45, title: nil).rowCount(forImageCount: 45), 12)
        XCTAssertEqual(settings.layout(imageCount: 45, title: nil).footerHeight, 0)
        XCTAssertFalse(settings.style(title: nil).showsPageNumbers)
        // Rows 0 is "auto" for a PDF too.
        settings.format = .pdf
        settings.rows = 0
        XCTAssertEqual(settings.pageCount(imageCount: 45), 1)

        // Orientation turns a preset; a custom size is as typed, within range.
        settings.orientation = .landscape
        XCTAssertEqual(settings.pagePixelSize, CGSize(width: 3508, height: 2480))
        settings.pageSize = .uhd4K
        settings.orientation = .portrait
        XCTAssertEqual(settings.pagePixelSize, CGSize(width: 2160, height: 3840))
        settings.pageSize = .custom
        settings.customWidth = 100_000
        settings.customHeight = 1000
        XCTAssertEqual(settings.pagePixelSize, CGSize(width: 8192, height: 1000))

        // PDF pages come out at their paper size.
        var a4 = ContactSheetSettings()
        XCTAssertEqual(a4.pdfPointsPerPixel * 2480, 595.2, accuracy: 0.01)
        a4.pageSize = .custom
        a4.customWidth = 8192
        XCTAssertEqual(a4.pdfPointsPerPixel, 1)
    }

    func testStoreRoundTripsAndRepairs() throws {
        let suite = "latent.tests.sheet.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ContactSheetStore(defaults: defaults)
        XCTAssertEqual(store.settings, ContactSheetSettings())
        var settings = ContactSheetSettings()
        settings.format = .png
        settings.colorSpace = .displayP3
        settings.background = .darkGrey
        settings.columns = 7
        settings.caption = .nameAndCamera
        store.settings = settings
        XCTAssertEqual(ContactSheetStore(defaults: defaults).settings, settings)

        defaults.set(Data(#"{"columns":99,"margin":-4,"format":"tiff","caption":"name"}"#.utf8), forKey: ContactSheetStore.key)
        let repaired = store.settings
        XCTAssertEqual(repaired.columns, 12)
        XCTAssertEqual(repaired.margin, 0)
        XCTAssertEqual(repaired.format, .pdf)
        XCTAssertEqual(repaired.caption, .name)
        defaults.set(Data("nonsense".utf8), forKey: ContactSheetStore.key)
        XCTAssertEqual(store.settings, ContactSheetSettings())
    }

    func testFileNamesAreSafe() {
        XCTAssertEqual(ContactSheetNaming.fileName(title: "Trip", format: .pdf), "Trip Contact Sheet.pdf")
        XCTAssertEqual(ContactSheetNaming.fileName(title: nil, format: .jpeg), "Contact Sheet.jpg")
        XCTAssertEqual(ContactSheetNaming.fileName(title: "  ", format: .png), "Contact Sheet.png")
        XCTAssertEqual(ContactSheetNaming.fileName(title: "2024/09: Trip", format: .pdf), "2024-09- Trip Contact Sheet.pdf")
        XCTAssertEqual(ContactSheetNaming.fileName(title: "../.hidden", format: .pdf), "-.hidden Contact Sheet.pdf")
        XCTAssertEqual(ContactSheetNaming.fileName(title: ".secret", format: .pdf), "secret Contact Sheet.pdf")
        XCTAssertLessThanOrEqual(ContactSheetNaming.fileName(title: String(repeating: "é", count: 300), format: .pdf).utf8.count, 255)
    }

    func items(_ count: Int) -> [SheetItem] {
        FakeRenders.items((0..<count).map { ["red", "blue", "green"][$0 % 3] + "\($0)" })
    }

    func testWritesAMultiPagePDFWithPhotosRenderedAtCellSize() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        var settings = ContactSheetSettings()
        settings.columns = 2
        settings.rows = 2
        settings.caption = .name
        let renders = FakeRenders()
        let url = scratch.url.appendingPathComponent("Trip Contact Sheet.pdf")
        var progress: [Int] = []
        try ContactSheetWriter.write(items: items(5), settings: settings, title: "Trip", to: url,
                                     renderer: renders.renderer(), preview: nil, cancel: SheetCancellation()) {
            progress.append($0)
        }
        XCTAssertEqual(progress, [1, 2, 3, 4, 5])
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, 2)
        let box = try XCTUnwrap(document.page(at: 1)?.getBoxRect(.mediaBox))
        XCTAssertEqual(box.width, 595.2, accuracy: 0.5)
        XCTAssertEqual(box.height, 841.9, accuracy: 0.5)
        // Photos are rendered for their cells at the page's 300 dpi, not at
        // full size: a 2 × 2 A4 cell is 1100 × 1454 px, and without a
        // thumbnail's shape to go by a render covers a portrait photo too.
        XCTAssertEqual(renders.requests.count, 5)
        XCTAssertTrue(renders.requests.allSatisfy { $0.longEdge == 1454 }, "\(renders.requests)")

        // Page 1 at 1 px per point: the first photo is red, where the layout puts it.
        let page = try XCTUnwrap(document.page(at: 1))
        let context = try XCTUnwrap(CGContext(data: nil, width: 595, height: 842, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.drawPDFPage(page)
        let image = try XCTUnwrap(context.makeImage())
        let cell = settings.layout(imageCount: 5, title: "Trip").cells(onPage: 0, imageCount: 5)[0]
        let scale = settings.pdfPointsPerPixel
        let red = PageLayoutPixels(image)[CGPoint(x: cell.imageArea.midX * scale, y: cell.imageArea.midY * scale)]
        XCTAssertGreaterThan(red[0], 230)
        XCTAssertLessThan(red[1], 30)
        XCTAssertEqual(PageLayoutPixels(image)[CGPoint(x: 3, y: 3)], [255, 255, 255])
        // Nothing but the sheet is left in the folder.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path), [url.lastPathComponent])
    }

    func testWritesOnePictureInTheChosenColourSpace() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        var settings = ContactSheetSettings()
        settings.format = .jpeg
        settings.colorSpace = .displayP3
        settings.pageSize = .custom
        settings.customWidth = 1200
        settings.customHeight = 900
        settings.columns = 3
        settings.margin = 20
        settings.background = .black
        let url = scratch.url.appendingPathComponent("Sheet.jpg")
        try ContactSheetWriter.write(items: items(7), settings: settings, title: nil, to: url,
                                     renderer: FakeRenders().renderer(), preview: nil, cancel: SheetCancellation()) { _ in }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 900)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertTrue((properties[kCGImagePropertyProfileName] as? String ?? "").contains("P3"))
        // Seven photos in three columns: three rows on the one picture.
        let layout = settings.layout(imageCount: 7, title: nil)
        XCTAssertEqual(layout.rowCount(forImageCount: 7), 3)
        let pixels = PageLayoutPixels(image)
        let last = layout.cells(onPage: 0, imageCount: 7)[6]
        XCTAssertGreaterThan(pixels[CGPoint(x: last.imageArea.midX, y: last.imageArea.midY)][0], 200)   // red6
        XCTAssertLessThan(pixels[CGPoint(x: 5, y: 5)][0], 20)                                           // black
    }

    /// Stopping part way writes nothing and keeps the file that was there.
    func testCancellingLeavesTheOldFileAlone() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let url = scratch.url.appendingPathComponent("Sheet.pdf")
        try Data("old".utf8).write(to: url)
        let cancel = SheetCancellation()
        var settings = ContactSheetSettings()
        settings.rows = 1
        settings.columns = 1
        XCTAssertThrowsError(try ContactSheetWriter.write(items: items(4), settings: settings, title: nil, to: url,
                                                          renderer: FakeRenders().renderer(), preview: nil,
                                                          cancel: cancel) { drawn in
            if drawn == 2 { cancel.cancel() }
        }) { error in
            guard case ContactSheetWriter.Failure.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path), ["Sheet.pdf"])

        settings.format = .png
        let png = scratch.url.appendingPathComponent("Sheet.png")
        let stopNow = SheetCancellation()
        stopNow.cancel()
        XCTAssertThrowsError(try ContactSheetWriter.write(items: items(2), settings: settings, title: nil, to: png,
                                                          renderer: FakeRenders().renderer(), preview: nil,
                                                          cancel: stopNow) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path))
    }

    /// The dialog's preview draws page 1 small from thumbnails, follows the
    /// settings, and never renders a photo.
    func testPreviewFollowsTheSettingsFromThumbnails() async throws {
        var made = 0
        let model = ContactSheetModel(items: items(6), title: "Trip", thumbnails: FakeRenders.thumbnails,
                                      previewRenderer: nil, makeRenderer: { _ in made += 1; return FakeRenders().renderer() },
                                      store: nil)
        XCTAssertEqual(model.summary, "6 photos · 1 page · 2480 × 3508 px")
        let layout = model.settings.layout(imageCount: 6, title: "Trip")
        let cell = layout.cells(onPage: 0, imageCount: 6)[0]
        let scale = model.previewScale
        func firstCell(_ image: CGImage) -> [UInt8] {
            PageLayoutPixels(image)[CGPoint(x: cell.imageArea.midX * scale, y: cell.imageArea.midY * scale)]
        }
        model.schedulePreview(after: 0)
        // Grey boxes first, then the red thumbnail once it has arrived.
        try await waitUntil { model.preview.map { firstCell($0)[0] > 200 } ?? false }
        let preview = try XCTUnwrap(model.preview)
        XCTAssertEqual(max(preview.width, preview.height), Int(ContactSheetModel.previewLongEdge))

        let drawn = model.previewsDrawn
        model.settings.columns = 1
        model.settings.rows = 2
        XCTAssertEqual(model.pageCount, 3)
        try await waitUntil { model.previewsDrawn > drawn }
        XCTAssertEqual(made, 0, "a preview never renders for the file")
        // Out of range is shown as what will be used.
        model.settings.margin = 5000
        XCTAssertEqual(model.settings.margin, 800)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
