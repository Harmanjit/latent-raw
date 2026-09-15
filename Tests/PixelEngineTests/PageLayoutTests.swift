import XCTest
import CoreGraphics
@testable import PixelEngine

/// The page geometry and drawing shared by Print and Contact Sheet.
final class PageLayoutTests: XCTestCase {
    /// A 1000 × 1400 page with 100 margins leaves an 800 × 1200 printable
    /// area, which divides evenly with 20 spacing.
    func layout(columns: Int = 2, rows: Int? = 3, spacing: Double = 20, caption: Double = 0) -> PageLayout {
        PageLayout(pageSize: CGSize(width: 1000, height: 1400), margins: LayoutInsets(all: 100),
                   columns: columns, rows: rows, spacing: spacing, captionHeight: caption)
    }

    func testCellsTileTheContentInReadingOrder() {
        let page = layout()
        XCTAssertEqual(page.cellSize(forImageCount: 6), CGSize(width: 390, height: 386.6666666666667))
        let cells = page.cells(onPage: 0, imageCount: 6)
        XCTAssertEqual(cells.map(\.index), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(cells[0].frame.origin, CGPoint(x: 100, y: 100))
        XCTAssertEqual(cells[1].frame.minX, 510)                  // 100 + 390 + 20
        XCTAssertEqual(cells[2].frame.minY, 506.6666666666667, accuracy: 1e-9)
        XCTAssertEqual(cells[5].frame.maxX, 900, accuracy: 1e-9)
        XCTAssertEqual(cells[5].frame.maxY, 1300, accuracy: 1e-9)
        XCTAssertTrue(cells.allSatisfy { $0.captionRect == nil && $0.imageArea == $0.frame })
    }

    func testMarginsHeaderAndFooterShrinkTheContent() {
        var page = PageLayout(pageSize: CGSize(width: 600, height: 800),
                              margins: LayoutInsets(top: 10, left: 20, bottom: 30, right: 40))
        XCTAssertEqual(page.printableRect, CGRect(x: 20, y: 10, width: 540, height: 760))
        XCTAssertNil(page.headerRect)
        XCTAssertNil(page.footerRect)
        page.headerHeight = 50
        page.footerHeight = 25
        XCTAssertEqual(page.contentRect, CGRect(x: 20, y: 60, width: 540, height: 685))
        XCTAssertEqual(page.headerRect, CGRect(x: 20, y: 10, width: 540, height: 50))
        XCTAssertEqual(page.footerRect, CGRect(x: 20, y: 745, width: 540, height: 25))

        // Margins wider than the page leave nothing, never a negative size.
        let squeezed = PageLayout(pageSize: CGSize(width: 100, height: 100), margins: LayoutInsets(all: 80))
        XCTAssertEqual(squeezed.contentRect.size, .zero)
        XCTAssertEqual(squeezed.cellSize(forImageCount: 1), .zero)
    }

    func testCaptionsTakeTheBottomOfEachCell() throws {
        let page = layout(columns: 1, rows: 1, caption: 40)
        let cell = try XCTUnwrap(page.cells(onPage: 0, imageCount: 1).first)
        XCTAssertEqual(cell.frame, CGRect(x: 100, y: 100, width: 800, height: 1200))
        XCTAssertEqual(cell.imageArea, CGRect(x: 100, y: 100, width: 800, height: 1160))
        XCTAssertEqual(cell.captionRect, CGRect(x: 100, y: 1260, width: 800, height: 40))
    }

    func testPaginates() {
        let page = layout()                                  // 6 per page
        XCTAssertEqual(page.pageCount(forImageCount: 0), 0)
        XCTAssertEqual(page.pageCount(forImageCount: 1), 1)
        XCTAssertEqual(page.pageCount(forImageCount: 6), 1)
        XCTAssertEqual(page.pageCount(forImageCount: 7), 2)
        XCTAssertEqual(page.pageCount(forImageCount: 1000), 167)
        XCTAssertEqual(page.indices(onPage: 1, imageCount: 14), 6..<12)
        XCTAssertEqual(page.indices(onPage: 2, imageCount: 14), 12..<14)
        XCTAssertTrue(page.indices(onPage: 3, imageCount: 14).isEmpty)
        XCTAssertEqual(page.cells(onPage: 2, imageCount: 14).map(\.index), [12, 13])
        // The last page's cells are the same size and place as a full page's.
        XCTAssertEqual(page.cells(onPage: 2, imageCount: 14)[1].frame, page.cells(onPage: 0, imageCount: 14)[1].frame)
    }

    func testAutomaticRowsPutEverythingOnOnePage() {
        let page = layout(columns: 4, rows: nil)
        XCTAssertEqual(page.rowCount(forImageCount: 10), 3)
        XCTAssertEqual(page.pageCount(forImageCount: 10), 1)
        XCTAssertEqual(page.cells(onPage: 0, imageCount: 10).count, 10)
        XCTAssertEqual(page.rowCount(forImageCount: 0), 1)
        XCTAssertEqual(page.pageCount(forImageCount: 1000), 1)
    }

    func testCentresAPartialPage() {
        var page = layout()                                  // 2 × 3
        page.centersPartialPages = true
        let cells = page.cells(onPage: 1, imageCount: 9)     // 3 images: a full row and one alone
        let size = page.cellSize(forImageCount: 9)
        let usedHeight = 2 * size.height + 20
        XCTAssertEqual(cells[0].frame.minY, 100 + (1200 - usedHeight) / 2, accuracy: 1e-9)
        XCTAssertEqual(cells[0].frame.minX, 100)
        XCTAssertEqual(cells[1].frame.minX, 510)
        XCTAssertEqual(cells[2].frame.midX, 500, accuracy: 1e-9)       // alone in its row, centred
        // A full page doesn't move.
        XCTAssertEqual(page.cells(onPage: 0, imageCount: 9)[0].frame.origin, CGPoint(x: 100, y: 100))
    }

    func testFitKeepsTheWholeImageCentred() {
        let page = PageLayout(pageSize: CGSize(width: 1000, height: 1000))
        let area = CGRect(x: 0, y: 0, width: 400, height: 400)
        let wide = page.placement(for: CGSize(width: 6000, height: 4000), in: area)
        XCTAssertEqual(wide.drawRect.minX, 0)
        XCTAssertEqual(wide.drawRect.width, 400)
        XCTAssertEqual(wide.drawRect.height, 800.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(wide.drawRect.midY, 200, accuracy: 1e-9)
        XCTAssertEqual(wide.visibleRect, wide.drawRect)
        XCTAssertFalse(wide.isRotated)
        XCTAssertEqual(wide.pixelsNeeded(pixelsPerUnit: 300.0 / 72), 1667)
    }

    func testFillCoversTheAreaAndCropsEvenly() {
        let page = PageLayout(pageSize: CGSize(width: 1000, height: 1000), scaling: .fill)
        let area = CGRect(x: 50, y: 50, width: 400, height: 400)
        let wide = page.placement(for: CGSize(width: 6000, height: 4000), in: area)
        XCTAssertEqual(wide.visibleRect, area)
        XCTAssertEqual(wide.drawRect, CGRect(x: -50, y: 50, width: 600, height: 400))
        XCTAssertEqual(wide.drawRect.midX, area.midX)
        XCTAssertEqual(wide.pixelsNeeded(pixelsPerUnit: 1), 600)
    }

    func testAutoRotateTurnsImagesThatCoverMoreOnTheirSide() {
        var page = PageLayout(pageSize: CGSize(width: 1000, height: 1000), autoRotate: true)
        let tall = CGRect(x: 0, y: 0, width: 200, height: 300)
        let landscape = page.placement(for: CGSize(width: 3000, height: 2000), in: tall)
        XCTAssertTrue(landscape.isRotated)
        XCTAssertEqual(landscape.drawRect, tall)                  // 3:2 turned is exactly 2:3
        XCTAssertFalse(page.placement(for: CGSize(width: 2000, height: 3000), in: tall).isRotated)
        XCTAssertFalse(page.placement(for: CGSize(width: 500, height: 500), in: tall).isRotated)

        page.scaling = .fill
        let filled = page.placement(for: CGSize(width: 4000, height: 2000), in: tall)
        XCTAssertTrue(filled.isRotated)
        XCTAssertEqual(filled.visibleRect, tall)
        XCTAssertEqual(filled.drawRect.size, CGSize(width: 200, height: 400))

        page.autoRotate = false
        XCTAssertFalse(page.placement(for: CGSize(width: 3000, height: 2000), in: tall).isRotated)
    }

    func testEmptyImagesAndAreasPlaceNothing() {
        let page = PageLayout(pageSize: CGSize(width: 100, height: 100))
        let area = CGRect(x: 10, y: 10, width: 50, height: 50)
        XCTAssertEqual(page.placement(for: .zero, in: area).drawRect.size, .zero)
        XCTAssertEqual(page.placement(for: CGSize(width: 10, height: 10), in: CGRect(x: 5, y: 5, width: 0, height: 20))
            .visibleRect.size, .zero)
    }

    func testImagesPerPagePresetsMakeNearlySquareCells() {
        let portrait = CGSize(width: 595, height: 842)
        let expected: [Int: (Int, Int)] = [1: (1, 1), 2: (1, 2), 4: (2, 2), 6: (2, 3), 9: (3, 3), 12: (3, 4),
                                           20: (4, 5), 30: (5, 6)]
        for count in PageLayout.imagesPerPageChoices {
            let grid = PageLayout.grid(imagesPerPage: count, pageSize: portrait)
            XCTAssertEqual(grid.columns, expected[count]!.0, "\(count)")
            XCTAssertEqual(grid.rows, expected[count]!.1, "\(count)")
            let turned = PageLayout.grid(imagesPerPage: count, pageSize: CGSize(width: 842, height: 595))
            XCTAssertEqual(turned.columns, expected[count]!.1, "\(count) landscape")
            XCTAssertEqual(turned.rows, expected[count]!.0, "\(count) landscape")
        }
    }

    func testFlipsForCoreGraphics() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(PageLayout.flipped(rect, pageHeight: 100), CGRect(x: 10, y: 40, width: 30, height: 40))
        XCTAssertEqual(PageLayout.flipped(PageLayout.flipped(rect, pageHeight: 100), pageHeight: 100), rect)
    }

    // MARK: - Render sizes

    /// A render is asked for at the size its cell shows it: a fit is never
    /// larger than the cell's long side at the device's density, a fill of
    /// a known shape is as large as its crop needs, and without a shape the
    /// usual photo's needs either way up.
    func testRenderLongEdgeFollowsTheCellAndTheShape() {
        var page = PageLayout(pageSize: CGSize(width: 1000, height: 1000))
        let cell = CGRect(x: 0, y: 0, width: 300, height: 200)
        // 300 × 200 points at 300 dpi.
        let ppu = 300.0 / 72
        XCTAssertEqual(page.renderLongEdge(for: cell, aspect: 1.5, pixelsPerUnit: ppu, maximum: 10_000), 1250)
        XCTAssertEqual(page.renderLongEdge(for: cell, aspect: 2.0 / 3, pixelsPerUnit: ppu, maximum: 10_000), 834)
        XCTAssertEqual(page.renderLongEdge(for: cell, aspect: nil, pixelsPerUnit: ppu, maximum: 10_000), 1250)
        page.scaling = .fill
        // A panorama filling the cell keeps its height: 200 × 3 = 600 wide.
        XCTAssertEqual(page.renderLongEdge(for: cell, aspect: 3, pixelsPerUnit: 1, maximum: 10_000), 600)
        // A portrait photo filling a landscape cell: 300 wide, 450 tall.
        XCTAssertEqual(page.renderLongEdge(for: cell, aspect: nil, pixelsPerUnit: 1, maximum: 10_000), 450)
        XCTAssertEqual(page.renderLongEdge(for: cell, aspect: 3, pixelsPerUnit: 1, maximum: 500), 500)
        XCTAssertEqual(page.renderLongEdge(for: CGRect(x: 0, y: 0, width: 2, height: 2), aspect: 1,
                                           pixelsPerUnit: 1, maximum: 500), 16)
    }

    // MARK: - Captions and style

    func testCaptionsSayWhatWasChosen() {
        let date = Date(timeIntervalSince1970: 0)
        let format: (Date) -> String = { _ in "1 Jan 1970" }
        XCTAssertEqual(CaptionContent.none.lines(name: "A.nef", date: date, camera: "D750", formatDate: format), [])
        XCTAssertEqual(CaptionContent.name.lines(name: "A.nef", date: date, camera: "D750", formatDate: format), ["A.nef"])
        XCTAssertEqual(CaptionContent.nameAndDate.lines(name: "A.nef", date: date, camera: "D750", formatDate: format),
                       ["A.nef", "1 Jan 1970"])
        XCTAssertEqual(CaptionContent.nameAndCamera.lines(name: "A.nef", date: date, camera: "D750", formatDate: format),
                       ["A.nef", "D750"])
        XCTAssertEqual(CaptionContent.nameDateAndCamera.lines(name: "A.nef", date: date, camera: "D750",
                                                              formatDate: format), ["A.nef", "1 Jan 1970 · D750"])
        // What a photo doesn't have is left out, and an empty line dropped.
        XCTAssertEqual(CaptionContent.nameDateAndCamera.lines(name: "A.nef", date: nil, camera: "D750",
                                                              formatDate: format), ["A.nef", "D750"])
        XCTAssertEqual(CaptionContent.nameAndCamera.lines(name: "A.nef", date: date, camera: "", formatDate: format),
                       ["A.nef"])
        // Two lines' room either way, so every cell of a page is alike.
        XCTAssertEqual(CaptionContent.name.height(fontSize: 10), 17.5)
        XCTAssertEqual(CaptionContent.nameAndCamera.height(fontSize: 10), 30)
        XCTAssertEqual(CaptionContent.none.height(fontSize: 10), 0)
    }

    func testTextStaysReadableOnTheBackground() {
        XCTAssertLessThan(PageStyle(background: nil).textColor.luminance, 0.5)
        XCTAssertLessThan(PageStyle(background: .white).textColor.luminance, 0.5)
        XCTAssertGreaterThan(PageStyle(background: .black).textColor.luminance, 0.5)
        XCTAssertEqual(PageStyle.pageNumberText(page: 1, of: 3), "Page 2 of 3")
    }

    // MARK: - Drawing

    static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 300, height: Int = 200) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The RGB bytes at `point`, in page coordinates (top-left origin).
    static func pixel(_ image: CGImage, at point: CGPoint) -> [UInt8] {
        SRGBPixels(image)[point]
    }

    /// An image drawn once into sRGB bytes, read by page coordinates.
    struct SRGBPixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            buffer.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            bytes = buffer
        }

        /// Row 0 of the buffer is the top of the image.
        subscript(point: CGPoint) -> [UInt8] {
            let x = min(max(Int(point.x), 0), width - 1), y = min(max(Int(point.y), 0), height - 1)
            let i = (y * width + x) * 4
            return [bytes[i], bytes[i + 1], bytes[i + 2]]
        }
    }

    func testDrawsEachImageInItsCellOnTheBackground() throws {
        let page = PageLayout(pageSize: CGSize(width: 400, height: 300), margins: LayoutInsets(all: 20),
                              columns: 2, rows: 1, spacing: 20, captionHeight: 30, headerHeight: 40)
        let style = PageStyle(background: .black, caption: .name, captionFontSize: 12, header: "Trip")
        let context = try XCTUnwrap(PageRenderer.bitmapContext(pageSize: page.pageSize, scale: 1,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        PageRenderer.drawChrome(layout: page, style: style, page: 0, pageCount: 1, in: context)
        let cells = page.cells(onPage: 0, imageCount: 3)
        XCTAssertEqual(cells.count, 2)
        PageRenderer.drawCell(cells[0], image: Self.solid(1, 0, 0), caption: ["A.nef"], layout: page, style: style,
                              in: context)
        PageRenderer.drawCell(cells[1], image: nil, caption: ["B.nef"], layout: page, style: style, in: context)
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(Self.pixel(image, at: CGPoint(x: cells[0].imageArea.midX, y: cells[0].imageArea.midY)), [255, 0, 0])
        // A 3:2 photo fitted in a taller area leaves the background above it.
        XCTAssertEqual(Self.pixel(image, at: CGPoint(x: cells[0].imageArea.midX, y: cells[0].imageArea.minY + 2)), [0, 0, 0])
        XCTAssertEqual(Self.pixel(image, at: CGPoint(x: 5, y: 150)), [0, 0, 0])
        // A missing photo is a faint box, not the background and not black.
        let missing = Self.pixel(image, at: CGPoint(x: cells[1].imageArea.midX, y: cells[1].imageArea.midY))
        XCTAssertGreaterThan(missing[0], 5)
        XCTAssertLessThan(missing[0], 60)
        // The caption and title are drawn in light text on black.
        let captionRect = try XCTUnwrap(cells[0].captionRect)
        XCTAssertTrue(Self.anyPixel(image, in: captionRect) { $0[0] > 128 }, "caption text")
        XCTAssertTrue(Self.anyPixel(image, in: try XCTUnwrap(page.headerRect)) { $0[0] > 128 }, "title text")
    }

    /// A landscape picture turned to fill a tall cell is turned clockwise:
    /// its top edge faces the right of the page.
    func testAutoRotatedPicturesTurnClockwise() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))            // bottom half blue
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 100, width: 300, height: 100))          // top half red
        let picture = try XCTUnwrap(context.makeImage())
        let page = PageLayout(pageSize: CGSize(width: 200, height: 300), autoRotate: true)
        let bitmap = try XCTUnwrap(PageRenderer.bitmapContext(pageSize: page.pageSize, scale: 1,
                                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let cell = try XCTUnwrap(page.cells(onPage: 0, imageCount: 1).first)
        PageRenderer.drawCell(cell, image: picture, caption: [], layout: page, style: PageStyle(), in: bitmap)
        let image = try XCTUnwrap(bitmap.makeImage())
        XCTAssertEqual(Self.pixel(image, at: CGPoint(x: 150, y: 150)), [255, 0, 0])
        XCTAssertEqual(Self.pixel(image, at: CGPoint(x: 50, y: 150)), [0, 0, 255])
    }

    /// A bitmap page at a fraction of its size is drawn in page units.
    func testBitmapPagesScaleToLayoutUnits() throws {
        let context = try XCTUnwrap(PageRenderer.bitmapContext(pageSize: CGSize(width: 2480, height: 3508), scale: 0.1,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!))
        XCTAssertEqual(context.width, 248)
        XCTAssertEqual(context.height, 351)
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 1240, y: 0, width: 1240, height: 3508))       // right half, in page units
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertGreaterThan(Self.pixel(image, at: CGPoint(x: 200, y: 100))[1], 200)
        XCTAssertEqual(Self.pixel(image, at: CGPoint(x: 40, y: 100)), [255, 255, 255])
    }

    static func anyPixel(_ image: CGImage, in rect: CGRect, where test: ([UInt8]) -> Bool) -> Bool {
        let pixels = SRGBPixels(image)
        return stride(from: rect.minX, to: rect.maxX, by: 1).contains { x in
            stride(from: rect.minY, to: rect.maxY, by: 1).contains { y in test(pixels[CGPoint(x: x, y: y)]) }
        }
    }
}
