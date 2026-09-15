import XCTest
import AppKit
import PixelEngine
import MLKit
@testable import latent_app

/// Solid colours standing in for ExportWorker renders, and what was asked.
final class FakeRenders: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(name: String, longEdge: Int)] = []
    /// Width over height of every render.
    let aspect: Double

    init(aspect: Double = 1.5) {
        self.aspect = aspect
    }

    var requests: [(name: String, longEdge: Int)] { lock.withLock { log } }

    /// Red for names starting "r", blue "b", green "g", grey otherwise.
    static func colour(for name: String) -> (CGFloat, CGFloat, CGFloat) {
        switch name.first {
        case "r": (1, 0, 0)
        case "b": (0, 0, 1)
        case "g": (0, 1, 0)
        default: (0.5, 0.5, 0.5)
        }
    }

    static func solid(_ colour: (CGFloat, CGFloat, CGFloat), width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: colour.0, green: colour.1, blue: colour.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: max(width, 1), height: max(height, 1)))
        return context.makeImage()!
    }

    func renderer(budget: Int = 64 << 20) -> SheetRenderer {
        SheetRenderer(cache: SheetImageCache(byteBudget: budget)) { [self] item, longEdge in
            lock.withLock { log.append((item.name, longEdge)) }
            let width = aspect >= 1 ? longEdge : Int((Double(longEdge) * aspect).rounded())
            let height = aspect >= 1 ? Int((Double(longEdge) / aspect).rounded()) : longEdge
            return Self.solid(Self.colour(for: item.name), width: width, height: height)
        }
    }

    static func items(_ names: [String]) -> [SheetItem] {
        names.map {
            SheetItem(name: $0, sourceURL: URL(fileURLWithPath: "/tmp/latent-print-tests/\($0).nef"), editStackJSON: nil,
                      userRotation: 0, captureDate: Date(timeIntervalSince1970: 0), camera: "NIKON D750", record: nil)
        }
    }

    /// Thumbnails that arrive a moment later, as the Library's do.
    static let thumbnails: SheetThumbnailSource = { item, completion in
        let image = RenderedImage(solid(colour(for: item.name), width: 384, height: 256))
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(image.cgImage) } }
        return true
    }
}

/// A folder in the temporary directory, removed by `remove()`.
struct ScratchFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("latent-sheet-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Printing with a page layout: paper to layout, the print view's pages,
/// printing through the printing system, the accessory and its store, and
/// how large pictures are rendered.
@MainActor
final class PrintTests: XCTestCase {
    /// US Letter with a quarter-inch unprintable edge.
    let letter = PrintPaper(size: CGSize(width: 612, height: 792),
                            imageableBounds: CGRect(x: 18, y: 18, width: 576, height: 756), dotsPerInch: 300)

    func job(_ names: [String], settings: PrintLayoutSettings = PrintLayoutSettings(), paper: PrintPaper? = nil,
             renders: FakeRenders = FakeRenders(), proof: SheetProfile? = nil) -> PrintJob {
        PrintJob(items: FakeRenders.items(names), settings: settings, paper: paper ?? letter, proofProfile: proof,
                 makeRenderer: { _ in renders.renderer() },
                 makePreview: { job in
                     SheetPreviewImages(renderer: nil, thumbnail: FakeRenders.thumbnails,
                                        onReady: { [weak job] in job?.previewDidChange() })
                 })
    }

    func testPaperBecomesALayout() {
        var settings = PrintLayoutSettings()
        settings.imagesPerPage = 4
        settings.margin = 9                                   // less than the printer can reach
        settings.spacing = 12
        settings.caption = .name
        let layout = letter.layout(for: settings, imageCount: 10)
        XCTAssertEqual(layout.pageSize, CGSize(width: 612, height: 792))
        XCTAssertEqual(layout.margins, LayoutInsets(all: 18))
        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.captionHeight, CaptionContent.name.height(fontSize: PrintLayoutSettings.captionFontSize))
        XCTAssertEqual(layout.pageCount(forImageCount: 10), 3)
        XCTAssertTrue(layout.centersPartialPages)

        settings.margin = 36
        XCTAssertEqual(letter.layout(for: settings, imageCount: 1).margins, LayoutInsets(all: 36))

        // Page Setup at 50% lays out a sheet twice the size, printed at half.
        let half = PrintPaper(size: letter.size, imageableBounds: letter.imageableBounds, scale: 0.5, dotsPerInch: 300)
        XCTAssertEqual(half.pageSize, CGSize(width: 1224, height: 1584))
        XCTAssertEqual(half.unprintableInsets, LayoutInsets(all: 36))
        XCTAssertEqual(half.pixelsPerUnit, 300.0 / 72 * 0.5)
        // Resolutions are capped both ways.
        XCTAssertEqual(PrintPaper(size: letter.size, dotsPerInch: 2880).pixelsPerUnit, 360.0 / 72)
        XCTAssertEqual(PrintPaper(size: letter.size, dotsPerInch: 72).pixelsPerUnit, 150.0 / 72)

        // Landscape paper turns the grid.
        let landscape = PrintPaper(size: CGSize(width: 792, height: 612))
        settings.imagesPerPage = 6
        let turned = landscape.layout(for: settings, imageCount: 6)
        XCTAssertEqual(turned.columns, 3)
        XCTAssertEqual(turned.rows, 2)
    }

    func testPrintViewPagesFollowTheLayout() {
        var settings = PrintLayoutSettings()
        settings.imagesPerPage = 6
        let job = job((0..<13).map { "p\($0)" }, settings: settings)
        let paper = letter
        let view = PrintPageView(job: job, paperSource: { paper }, previewTest: { false })
        var range = NSRange(location: 0, length: 0)
        XCTAssertTrue(view.knowsPageRange(&range))
        XCTAssertEqual(range, NSRange(location: 1, length: 3))
        XCTAssertTrue(view.isFlipped)
        // The printable part of each sheet, in sheet points from its corner.
        XCTAssertEqual(view.rectForPage(1), NSRect(x: 18, y: 18, width: 576, height: 756))
        XCTAssertEqual(view.rectForPage(3), NSRect(x: 18, y: 2 * PrintPageView.pagePitch + 18, width: 576, height: 756))
        XCTAssertTrue(view.bounds.contains(view.rectForPage(3)))
        XCTAssertFalse(view.rectForPage(1).intersects(view.rectForPage(2)))

        // The panel's paper changes: the pages follow.
        let a5 = PrintPaper(size: CGSize(width: 420, height: 595))
        let smaller = PrintPageView(job: job, paperSource: { a5 }, previewTest: { false })
        XCTAssertTrue(smaller.knowsPageRange(&range))
        XCTAssertEqual(smaller.rectForPage(2), NSRect(x: 0, y: PrintPageView.pagePitch, width: 420, height: 595))
        let offset = PrintPaper(size: CGSize(width: 612, height: 792), imageableBounds: CGRect(x: 12, y: 30, width: 590, height: 740))
        XCTAssertEqual(offset.printableSheetRect, CGRect(x: 12, y: 22, width: 590, height: 740))
        XCTAssertEqual(offset.unprintableInsets, LayoutInsets(top: 22, left: 12, bottom: 30, right: 10))

        settings.imagesPerPage = 1
        job.update(settings: settings)
        XCTAssertTrue(smaller.knowsPageRange(&range))
        XCTAssertEqual(range.length, 13)
    }

    /// Prints `names` to a PDF the way File > Print does after the panel,
    /// without a printer: the operation asks the view for its pages and
    /// draws each into the printing system's context.
    func printToPDF(_ names: [String], settings: PrintLayoutSettings, in folder: URL, renders: FakeRenders,
                    configure: (NSPrintInfo) -> Void = { _ in }) throws -> (CGPDFDocument, PrintSession) {
        _ = NSApplication.shared
        let url = folder.appendingPathComponent("Printed \(UUID().uuidString).pdf")
        let suite = "latent.tests.print.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PrintLayoutStore(defaults: defaults)
        store.settings = settings
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.orientation = .portrait
        configure(info)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let session = PrintSession(items: FakeRenders.items(names), thumbnails: FakeRenders.thumbnails,
                                   makeRenderer: { _ in renders.renderer() }, previewRenderer: nil, proofProfile: nil,
                                   store: store, printInfo: info)
        session.operation.showsPrintPanel = false
        session.operation.showsProgressPanel = false
        XCTAssertTrue(session.operation.run())
        return (try XCTUnwrap(CGPDFDocument(url as CFURL)), session)
    }

    /// Page `number` (from 1) of `document` as sRGB pixels at 1 px per point.
    func rasterize(_ document: CGPDFDocument, page number: Int) throws -> CGImage {
        let page = try XCTUnwrap(document.page(at: number))
        let box = page.getBoxRect(.mediaBox)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: box.width, height: box.height))
        context.drawPDFPage(page)
        return try XCTUnwrap(context.makeImage())
    }

    func pixel(_ image: CGImage, _ x: Double, _ y: Double) -> [UInt8] {
        PageLayoutPixels(image)[CGPoint(x: x, y: y)]
    }

    func testPrintsEachSheetThroughThePrintingSystemAtPrintResolution() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        var settings = PrintLayoutSettings()
        settings.imagesPerPage = 2
        settings.autoRotate = false
        settings.scaling = .fill
        let renders = FakeRenders()

        let (document, session) = try printToPDF(["red", "blue", "green"], settings: settings, in: scratch.url,
                                                 renders: renders)
        XCTAssertEqual(document.numberOfPages, 2)
        let box = try XCTUnwrap(document.page(at: 1)?.getBoxRect(.mediaBox))
        XCTAssertEqual(box.width, 612, accuracy: 0.5)
        XCTAssertEqual(box.height, 792, accuracy: 0.5)
        let first = try rasterize(document, page: 1)
        let cells = session.job.currentLayout.cells(onPage: 0, imageCount: 3)
        XCTAssertEqual(pixel(first, cells[0].imageArea.midX, cells[0].imageArea.midY), [255, 0, 0])
        XCTAssertEqual(pixel(first, cells[1].imageArea.midX, cells[1].imageArea.midY), [0, 0, 255])
        XCTAssertEqual(pixel(first, 306, 4), [255, 255, 255])
        // No offset: the edges of the first picture are where the layout says.
        XCTAssertEqual(pixel(first, cells[0].imageArea.minX + 2, cells[0].imageArea.minY + 2), [255, 0, 0])
        XCTAssertEqual(pixel(first, cells[0].imageArea.minX - 3, cells[0].imageArea.minY + 20), [255, 255, 255])
        // The last sheet holds one picture, centred.
        let second = try rasterize(document, page: 2)
        XCTAssertEqual(pixel(second, 306, 396), [0, 255, 0])
        XCTAssertEqual(pixel(second, 306, 60), [255, 255, 255])

        // Every photo was rendered once, for the printer: a 3:2 photo filling
        // a 576 × 369 pt cell at the default 300 dpi is 2400 px wide, far
        // beyond a thumbnail, and never beyond the cap.
        let sizes = renders.requests
        XCTAssertEqual(sizes.map(\.name).sorted(), ["blue", "green", "red"])
        XCTAssertTrue(sizes.allSatisfy { $0.longEdge > 1500 && $0.longEdge <= PrintRenderPolicy.maxLongEdge }, "\(sizes)")

        // Landscape paper: two side by side.
        let (turned, turnedSession) = try printToPDF(["red", "blue", "green"], settings: settings, in: scratch.url,
                                                     renders: FakeRenders()) { $0.orientation = .landscape }
        let wide = try rasterize(turned, page: 1)
        XCTAssertEqual(wide.width, 792)
        XCTAssertEqual(wide.height, 612)
        let wideCells = turnedSession.job.currentLayout.cells(onPage: 0, imageCount: 3)
        XCTAssertLessThanOrEqual(wideCells[0].frame.maxX, wideCells[1].frame.minX)
        XCTAssertEqual(pixel(wide, wideCells[1].imageArea.midX, wideCells[1].imageArea.midY), [0, 0, 255])
    }

    /// The panel's preview draws from thumbnails and returns at once; it
    /// never renders at print size. The printer's pages do.
    func testPreviewUsesThumbnailsAndNeverRenders() async throws {
        let renders = FakeRenders()
        let job = job(["red", "blue"], renders: renders)
        var ready = 0
        job.onPreviewReady { ready += 1 }
        let context = try XCTUnwrap(PageRenderer.bitmapContext(pageSize: CGSize(width: 612, height: 792), scale: 1,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        job.drawPreviewPage(0, in: context)
        job.drawPreviewPage(1, in: context)
        let deadline = Date().addingTimeInterval(5)
        while ready < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(ready, 2)
        XCTAssertTrue(job.preview.isIdle)
        XCTAssertTrue(renders.requests.isEmpty)

        job.drawPreviewPage(0, in: context)
        let image = try XCTUnwrap(context.makeImage())
        let cell = job.currentLayout.cells(onPage: 0, imageCount: 2)[0]
        XCTAssertEqual(pixel(image, cell.imageArea.midX, cell.imageArea.midY), [255, 0, 0])
        XCTAssertTrue(renders.requests.isEmpty)

        // The printer gets its own render, sized from the thumbnail's shape.
        job.drawPage(0, in: context)
        XCTAssertEqual(renders.requests.count, 1)
        XCTAssertGreaterThan(renders.requests[0].longEdge, 2000)
    }

    func testMainThreadPreviewDetection() {
        // Outside a print operation nothing is a preview, so a job drawn
        // into an ordinary context (tests, a PDF) renders.
        XCTAssertFalse(PrintPageView.isPreviewDrawing())
    }

    /// A render whose shape needs more than was estimated (a panorama
    /// filling a cell) is made again once at the size it needs; a render
    /// already large enough is reused, a larger request isn't served small.
    func testRendersAreSizedToTheirShapeAndCached() {
        let renders = FakeRenders(aspect: 3)
        let renderer = renders.renderer()
        let item = FakeRenders.items(["red"])[0]
        let image = renderer.image(for: item, longEdge: 450) { size in Int(size.width / size.height * 200) }
        XCTAssertEqual(renders.requests.map(\.longEdge), [450, 600])
        XCTAssertEqual(image?.width, 600)
        _ = renderer.image(for: item, longEdge: 500) { _ in 500 }
        XCTAssertEqual(renders.requests.count, 2, "served from the cache")
        _ = renderer.image(for: item, longEdge: 2000) { _ in 2000 }
        XCTAssertEqual(renders.requests.map(\.longEdge), [450, 600, 2000])

        let cache = SheetImageCache(byteBudget: 3 * 400 * 267 * 4)
        for index in 0..<5 {
            cache.store(FakeRenders.solid((0, 0, 0), width: 400, height: 267), for: "\(index)", requested: 400)
        }
        XCTAssertLessThanOrEqual(cache.cachedCount, 3)
        XCTAssertLessThanOrEqual(cache.cachedBytes, cache.byteBudget)
        XCTAssertNotNil(cache.image(for: "4", longEdge: 300))
        XCTAssertNil(cache.image(for: "4", longEdge: 1000))
        XCTAssertNil(cache.image(for: "4", longEdge: 100), "far larger than needed")
        XCTAssertNil(cache.image(for: "0", longEdge: 400), "evicted")
        // A render that came out smaller than asked is the whole photo.
        cache.store(FakeRenders.solid((0, 0, 0), width: 300, height: 200), for: "small", requested: 1000)
        XCTAssertNotNil(cache.image(for: "small", longEdge: 4000))
    }

    /// A photo that can't be rendered leaves its cell empty, is named, and
    /// isn't tried again for the same page.
    func testUnrenderablePhotosAreNamed() throws {
        let renderer = SheetRenderer(cache: SheetImageCache(byteBudget: 1 << 20)) { item, longEdge in
            item.name == "broken" ? nil : FakeRenders.solid((1, 0, 0), width: longEdge, height: longEdge * 2 / 3)
        }
        let items = FakeRenders.items(["red", "broken"])
        let page = PageLayout(pageSize: CGSize(width: 400, height: 200), columns: 2, rows: 1)
        let context = try XCTUnwrap(PageRenderer.bitmapContext(pageSize: page.pageSize, scale: 1,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        SheetPageDrawer.drawPage(0, items: items, layout: page, style: PageStyle(background: .white), pixelsPerUnit: 1,
                                 maxLongEdge: 1000, renderer: renderer, in: context)
        XCTAssertEqual(renderer.failedNames, ["broken"])
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 100, 100), [255, 0, 0])
        XCTAssertNotEqual(pixel(image, 300, 100), [255, 0, 0])
    }

    /// Converting into a printer profile: RGB at 16 bits, CMYK at 8, tagged.
    func testRendersConvertIntoTheProofProfile() throws {
        let image = FakeRenders.solid((1, 0, 0), width: 8, height: 8)
        let rgbURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/AdobeRGB1998.icc")
        let cmykURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: rgbURL.path)
                          && FileManager.default.fileExists(atPath: cmykURL.path))
        let adobe = try XCTUnwrap(SheetProfile(url: rgbURL))
        XCTAssertEqual(adobe.name, "AdobeRGB1998")
        let rgb = try XCTUnwrap(SheetColorConversion.convert(image, to: adobe.colorSpace))
        XCTAssertEqual(rgb.bitsPerComponent, 16)
        XCTAssertEqual(rgb.colorSpace?.model, .rgb)
        XCTAssertEqual(rgb.width, 8)
        let cmyk = try XCTUnwrap(SheetColorConversion.convert(image, to: try XCTUnwrap(SheetProfile(url: cmykURL)).colorSpace))
        XCTAssertEqual(cmyk.colorSpace?.model, .cmyk)
        XCTAssertNil(SheetProfile(url: URL(fileURLWithPath: "/nonexistent.icc")))

        // The job renders through the profile only when that is the choice.
        var settings = PrintLayoutSettings()
        XCTAssertEqual(settings.color, .proofProfile)
        XCTAssertEqual(settings.profile(proof: adobe)?.url, rgbURL)
        XCTAssertNil(settings.profile(proof: nil))
        settings.color = .displayP3
        XCTAssertNil(settings.profile(proof: adobe))

        let profiles = ProfileLog()
        let job = PrintJob(items: FakeRenders.items(["red"]), settings: PrintLayoutSettings(), paper: letter,
                           proofProfile: adobe,
                           makeRenderer: { profile in profiles.append(profile?.name); return FakeRenders().renderer() },
                           makePreview: { _ in SheetPreviewImages(renderer: nil, thumbnail: FakeRenders.thumbnails, onReady: {}) })
        job.update(settings: settings)
        var margins = settings
        margins.margin = 30
        job.update(settings: margins)
        XCTAssertEqual(profiles.values, ["AdobeRGB1998", nil], "a new renderer only when the colour changes")
    }

    /// Page Setup keeps the paper and scale of the last print, never its
    /// copies, pages or destination.
    func testAPrintHandsOnOnlyItsPaperToPageSetup() {
        let shared = NSPrintInfo()
        shared.topMargin = 40
        let chosen = NSPrintInfo()
        chosen.paperSize = NSSize(width: 842, height: 595)
        chosen.orientation = .landscape
        chosen.scalingFactor = 0.8
        chosen.topMargin = 0
        chosen.jobDisposition = .save
        chosen.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: "/tmp/elsewhere.pdf")
        chosen.dictionary()[NSPrintInfo.AttributeKey.copies] = 3
        let setup = PrintSession.pageSetup(from: chosen, keeping: shared)
        XCTAssertEqual(setup.paperSize, NSSize(width: 842, height: 595))
        XCTAssertEqual(setup.orientation, .landscape)
        XCTAssertEqual(setup.scalingFactor, 0.8)
        XCTAssertEqual(setup.topMargin, 40)
        XCTAssertEqual(setup.jobDisposition, shared.jobDisposition)
        XCTAssertNil(setup.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL])
        XCTAssertEqual(setup.dictionary()[NSPrintInfo.AttributeKey.copies] as? Int ?? 1, 1)
    }

    func testStoreRoundTripsAndRepairs() throws {
        let suite = "latent.tests.print.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PrintLayoutStore(defaults: defaults)
        XCTAssertEqual(store.settings, PrintLayoutSettings())

        var settings = PrintLayoutSettings()
        settings.imagesPerPage = 12
        settings.scaling = .fill
        settings.margin = 30
        settings.spacing = 6
        settings.caption = .nameDateAndCamera
        settings.autoRotate = false
        settings.color = .displayP3
        store.settings = settings
        XCTAssertEqual(PrintLayoutStore(defaults: defaults).settings, settings)

        // An older or hand-edited value: missing fields default, strays are repaired.
        defaults.set(Data(#"{"imagesPerPage":7,"margin":500,"caption":"nameAndDimensions"}"#.utf8),
                     forKey: PrintLayoutStore.key)
        let repaired = store.settings
        XCTAssertEqual(repaired.imagesPerPage, 1)
        XCTAssertEqual(repaired.margin, 72)
        XCTAssertEqual(repaired.caption, .none)
        XCTAssertEqual(repaired.scaling, .fit)
        XCTAssertTrue(repaired.autoRotate)
        defaults.set(Data("nonsense".utf8), forKey: PrintLayoutStore.key)
        XCTAssertEqual(store.settings, PrintLayoutSettings())
    }

    func testAccessoryUpdatesTheJobThePreviewAndTheStore() throws {
        _ = NSApplication.shared
        let suite = "latent.tests.print.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PrintLayoutStore(defaults: defaults)
        let session = PrintSession(items: FakeRenders.items((0..<8).map { "p\($0)" }), thumbnails: FakeRenders.thumbnails,
                                   makeRenderer: { _ in FakeRenders().renderer() }, previewRenderer: nil,
                                   proofProfile: nil, store: store, printInfo: NSPrintInfo())
        let accessory = session.accessory
        XCTAssertEqual(accessory.keyPathsForValuesAffectingPreview(), ["layoutRevision"])
        XCTAssertTrue(session.operation.canSpawnSeparateThread)
        XCTAssertTrue(session.operation.printPanel.accessoryControllers.contains { $0 === accessory })
        XCTAssertTrue(session.operation.printPanel.options.contains(.showsPreview))
        let info = session.operation.printInfo
        XCTAssertTrue(info.leftMargin == 0 && info.topMargin == 0 && info.rightMargin == 0 && info.bottomMargin == 0)

        let revision = accessory.layoutRevision
        accessory.model.settings.imagesPerPage = 4
        XCTAssertEqual(accessory.layoutRevision, revision + 1)
        XCTAssertEqual(session.job.currentSettings.imagesPerPage, 4)
        XCTAssertEqual(session.job.pageCount, 2)
        XCTAssertEqual(store.settings.imagesPerPage, 4)

        let summary = accessory.localizedSummaryItems()
        XCTAssertEqual(summary.first?[.itemName], "Photos per Page")
        XCTAssertEqual(summary.first?[.itemDescription], "4")
        XCTAssertEqual(summary.last?[.itemDescription], "Display P3 (wide gamut)", "no proof profile set")
        XCTAssertEqual(summary.count, 7)
        _ = accessory.view                                     // the form builds
        XCTAssertEqual(PrintPresenter.jobTitle(for: FakeRenders.items(["a"])), "a")
        XCTAssertEqual(PrintPresenter.jobTitle(for: FakeRenders.items(["a", "b", "c"])), "3 Photos")
    }

    func testLengthsFollowTheLocale() {
        XCTAssertEqual(PrintLength.text(points: 18, locale: Locale(identifier: "en_US")), "0.25 in")
        XCTAssertEqual(PrintLength.text(points: 72, locale: Locale(identifier: "en_GB")), "25.4 mm")
        XCTAssertEqual(PrintLength.text(points: 0, locale: Locale(identifier: "fr_FR")), "0 mm")
    }

    /// ⌘P prints what the mode shows: the selection in Library, the open
    /// image elsewhere. Contact sheets need a selection.
    func testCommandsAreEnabledByWhatThereIsToPrint() throws {
        var state = CommandState()
        XCTAssertFalse(state.isEnabled(.print))
        XCTAssertFalse(state.isEnabled(.contactSheet))
        state.editorReady = true
        state.selectionCount = 3
        XCTAssertTrue(state.isEnabled(.print))
        XCTAssertTrue(state.isEnabled(.contactSheet))
        state.selectionCount = 0
        state.hasImage = true
        XCTAssertFalse(state.isEnabled(.print), "Library prints the selection, not the editor's image")
        state.mode = .develop
        XCTAssertTrue(state.isEnabled(.print))
        XCTAssertFalse(state.isEnabled(.contactSheet))
        let print = try XCTUnwrap(Shortcuts.shortcut(for: .print))
        XCTAssertEqual(print.glyphs, "⌘P")
        XCTAssertNil(Shortcuts.shortcut(for: .contactSheet))
    }
}

final class ProfileLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String?] = []
    var values: [String?] { lock.withLock { log } }
    func append(_ value: String?) { lock.withLock { log.append(value) } }
}

/// An image drawn once into sRGB bytes, read by page coordinates (top left).
struct PageLayoutPixels {
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

    subscript(point: CGPoint) -> [UInt8] {
        let x = min(max(Int(point.x), 0), width - 1), y = min(max(Int(point.y), 0), height - 1)
        let i = (y * width + x) * 4
        return [bytes[i], bytes[i + 1], bytes[i + 2]]
    }
}
