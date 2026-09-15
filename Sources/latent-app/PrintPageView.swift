import AppKit
import PixelEngine

/// Everything a print needs while it runs, shared by the print panel's
/// preview (drawn on the main thread) and the job itself (drawn on the
/// print operation's own thread), so it is locked rather than isolated.
final class PrintJob: @unchecked Sendable {
    let items: [SheetItem]
    /// The printer or paper profile chosen for Soft Proof, if any.
    let proofProfile: SheetProfile?

    private let lock = NSLock()
    private var settings: PrintLayoutSettings
    private var paper: PrintPaper
    private var layout: PageLayout
    private var renderer: SheetRenderer
    private let makeRenderer: @Sendable (SheetProfile?) -> SheetRenderer
    private(set) var preview: SheetPreviewImages!
    private var previewReady: (@MainActor @Sendable () -> Void)?

    /// `makeRenderer` builds the renderer for a colour choice (the proof
    /// profile or none); `preview` supplies the panel's small pictures.
    init(items: [SheetItem], settings: PrintLayoutSettings, paper: PrintPaper, proofProfile: SheetProfile?,
         makeRenderer: @escaping @Sendable (SheetProfile?) -> SheetRenderer,
         makePreview: (_ job: PrintJob) -> SheetPreviewImages) {
        self.items = items
        self.proofProfile = proofProfile
        self.settings = settings.validated
        self.paper = paper
        self.makeRenderer = makeRenderer
        layout = paper.layout(for: self.settings, imageCount: items.count)
        renderer = makeRenderer(self.settings.profile(proof: proofProfile))
        preview = makePreview(self)
    }

    /// Called on the main actor as preview pictures arrive, so the panel
    /// can draw its preview again.
    func onPreviewReady(_ handler: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { previewReady = handler }
    }

    /// For `SheetPreviewImages`.
    @MainActor func previewDidChange() {
        lock.withLock { previewReady }?()
    }

    var currentSettings: PrintLayoutSettings { lock.withLock { settings } }
    var currentLayout: PageLayout { lock.withLock { layout } }
    var currentPaper: PrintPaper { lock.withLock { paper } }

    func update(settings newValue: PrintLayoutSettings) {
        let newValue = newValue.validated
        let profileChanged = lock.withLock { newValue.profile(proof: proofProfile)?.url != settings.profile(proof: proofProfile)?.url }
        // Renders made for one colour choice mustn't print for another.
        let fresh = profileChanged ? makeRenderer(newValue.profile(proof: proofProfile)) : nil
        lock.withLock {
            settings = newValue
            layout = paper.layout(for: settings, imageCount: items.count)
            if let fresh { renderer = fresh }
        }
    }

    /// Lays the pictures out again for `newPaper` (the panel's paper size,
    /// orientation or printer changed) and returns the layout.
    @discardableResult
    func update(paper newPaper: PrintPaper) -> PageLayout {
        lock.withLock {
            if newPaper != paper {
                paper = newPaper
                layout = paper.layout(for: settings, imageCount: items.count)
            }
            return layout
        }
    }

    var pageCount: Int { max(1, currentLayout.pageCount(forImageCount: items.count)) }

    /// Draws `page` (from 0) for the printer, rendering its pictures at the
    /// printer's resolution. Blocks the calling thread, which is the print
    /// operation's own.
    func drawPage(_ page: Int, in context: CGContext) {
        let (layout, settings, paper, renderer) = lock.withLock { (self.layout, self.settings, self.paper, self.renderer) }
        SheetPageDrawer.drawPage(page, items: items, layout: layout, style: settings.style,
                                 pixelsPerUnit: paper.pixelsPerUnit, maxLongEdge: PrintRenderPolicy.maxLongEdge,
                                 renderer: renderer, preview: preview, in: context)
    }

    /// Draws `page` for the print panel's preview from thumbnails, without
    /// waiting for anything: missing ones are asked for, and arrive through
    /// `onPreviewReady`.
    func drawPreviewPage(_ page: Int, in context: CGContext) {
        let (layout, settings) = lock.withLock { (self.layout, self.settings) }
        SheetPageDrawer.drawPreviewPage(page, items: items, layout: layout, style: settings.style,
                                        preview: preview, in: context)
    }
}

/// The view a print operation prints: one page rectangle per sheet of
/// paper, each drawn from the layout when the printing system asks.
///
/// Its drawing methods are `nonisolated`: with `canSpawnSeparateThread` the
/// print job calls them on a thread of its own while the app stays
/// responsive, and the print panel's preview calls them on the main thread.
/// They touch only the locked `PrintJob`, never the view's own state.
///
/// Pages are stacked downwards at a fixed pitch larger than any sheet, so
/// a page's rectangle never depends on the view's frame, which may not be
/// changed off the main thread. Ported from minivu, whose print-to-PDF
/// tests measured AppKit's pagination behaviour this relies on.
final class PrintPageView: NSView {
    nonisolated let job: PrintJob
    /// The paper in use: the running operation's print info (which the
    /// panel changes in place), or a fixed paper in tests.
    nonisolated let paperSource: @Sendable () -> PrintPaper?
    /// Whether the drawing in progress is the panel's preview.
    nonisolated let previewTest: @Sendable () -> Bool

    /// Taller than any sheet of paper a printer takes.
    nonisolated static let pagePitch: CGFloat = 100_000

    init(job: PrintJob, paperSource: @escaping @Sendable () -> PrintPaper? = PrintPageView.currentOperationPaper,
         previewTest: @escaping @Sendable () -> Bool = PrintPageView.isPreviewDrawing) {
        self.job = job
        self.paperSource = paperSource
        self.previewTest = previewTest
        super.init(frame: NSRect(x: 0, y: 0, width: Self.pagePitch,
                                 height: Self.pagePitch * CGFloat(max(1, job.items.count))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    nonisolated override var isFlipped: Bool { true }

    nonisolated override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let paper = paperSource() { job.update(paper: paper) }
        range.pointee = NSRange(location: 1, length: job.pageCount)
        return true
    }

    /// `page` counts from 1, as AppKit does. The rectangle is the part of
    /// the sheet the printer can mark, in points, offset from the sheet's
    /// corner by the unprintable edge: with a view's own pagination AppKit
    /// puts each page rectangle's corner at the printable area's corner, at
    /// 100% whatever Page Setup's scale (measured in minivu by printing to
    /// PDF). So the rectangle is exactly the printable area, which lands
    /// where it is on paper, and `draw` applies the scale.
    nonisolated override func rectForPage(_ page: Int) -> NSRect {
        let printable = job.currentPaper.printableSheetRect
        return printable.offsetBy(dx: 0, dy: CGFloat(max(page, 1) - 1) * Self.pagePitch)
    }

    nonisolated override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let paper = job.currentPaper
        let preview = previewTest()
        let first = max(0, Int((dirtyRect.minY / Self.pagePitch).rounded(.down)))
        let last = min(job.pageCount - 1, Int((max(dirtyRect.maxY - 1, dirtyRect.minY) / Self.pagePitch).rounded(.down)))
        guard first <= last else { return }
        for page in first...last {
            context.saveGState()
            // The view is flipped: turn this sheet's rectangle into a y-up
            // space with its origin at the sheet's bottom-left corner, in
            // layout units (points at Page Setup's scale).
            context.translateBy(x: 0, y: CGFloat(page) * Self.pagePitch + paper.size.height)
            context.scaleBy(x: 1, y: -1)
            context.clip(to: CGRect(origin: .zero, size: paper.size))
            context.scaleBy(x: paper.scale, y: paper.scale)
            if preview {
                job.drawPreviewPage(page, in: context)
            } else {
                job.drawPage(page, in: context)
            }
            context.restoreGState()
        }
    }

    // MARK: The running operation

    /// `NSPrintOperation.current` is the operation running on the calling
    /// thread. The Swift overlay marks the class main-actor only, but the
    /// print thread must ask too, so it is looked up through the
    /// Objective-C runtime, which is what the property does anyway.
    nonisolated static func currentOperation() -> NSObject? {
        guard let type = NSClassFromString("NSPrintOperation") as? NSObject.Type,
              type.responds(to: NSSelectorFromString("currentOperation")) else { return nil }
        return type.perform(NSSelectorFromString("currentOperation"))?.takeUnretainedValue() as? NSObject
    }

    nonisolated static let currentOperationPaper: @Sendable () -> PrintPaper? = {
        guard let info = currentOperation()?.value(forKey: "printInfo") as? NSPrintInfo else { return nil }
        return PrintPaper(printInfo: info)
    }

    /// The print panel draws its preview through a proxy graphics context
    /// of its own (`NSPrintPreviewGraphicsContext`, on the main thread),
    /// while the job draws into the printer's. The operation says so too:
    /// its preferred rendering quality is `.responsive` while it makes the
    /// panel's preview and `.best` for the output. Either sign makes the
    /// drawing a preview, so a renamed class on a later macOS still never
    /// renders full-size pictures on the main thread.
    nonisolated static let isPreviewDrawing: @Sendable () -> Bool = {
        if let quality = currentOperation()?.value(forKey: "preferredRenderingQuality") as? Int,
           quality == NSPrintOperation.RenderingQuality.responsive.rawValue {
            return true
        }
        guard let context = NSGraphicsContext.current else { return false }
        return NSStringFromClass(type(of: context)).contains("PrintPreview")
    }
}
