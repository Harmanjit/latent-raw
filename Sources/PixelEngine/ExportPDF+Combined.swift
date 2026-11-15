import Foundation
import CoreGraphics

/// How Export › PDF › Combine into one PDF arranges the photos.
public enum CombinedPDFLayout: String, Sendable, Codable, CaseIterable {
    /// One photo per page, each page laid out exactly as a single-photo PDF
    /// export lays out its page (`ExportPDFOptions.layout`).
    case onePerPage
    /// A contact sheet: `photosPerPage` photos in a grid on paper pages,
    /// each with its file name underneath.
    case contactSheet

    public var title: String {
        switch self {
        case .onePerPage: "One photo per page"
        case .contactSheet: "Contact sheet"
        }
    }
}

extension ExportPDFOptions {
    /// The photos-per-page counts the export sheet offers.
    public static let photosPerPageChoices = [2, 4, 6, 9, 12, 16, 20]

    /// The space between contact-sheet cells, in points (4 mm).
    static let sheetGutter = 4 * pointsPerMM

    /// The contact-sheet grid for `photosPerPage`: as square as it can be,
    /// wider than tall when it can't (2 → 2 × 1, 6 → 3 × 2, 12 → 4 × 3).
    public var sheetGrid: (columns: Int, rows: Int) {
        let count = min(max(photosPerPage, 1), 100)
        let columns = Int(Double(count).squareRoot().rounded(.up))
        return (columns, (count + columns - 1) / columns)
    }

    /// A contact sheet's page in points: the chosen paper (A4 for Fit to
    /// image, which has no paper size), turned landscape when the grid is
    /// wider than tall.
    public var sheetPageSize: CGSize {
        let portrait = pageSize.portraitPoints ?? CGSize(width: 595.276, height: 841.89)
        let grid = sheetGrid
        return grid.columns > grid.rows ? CGSize(width: portrait.height, height: portrait.width) : portrait
    }

    /// The rectangle of cell `slot` (0 at the top left, row by row) on a
    /// contact-sheet page, in points with the origin top left, caption
    /// strip included.
    public func sheetCell(_ slot: Int) -> CGRect {
        let page = sheetPageSize
        let grid = sheetGrid
        let margin = min(max(marginMM, 0), 100) * Self.pointsPerMM
        let gutter = Self.sheetGutter
        let width = max((page.width - 2 * margin - gutter * Double(grid.columns - 1)) / Double(grid.columns), 1)
        let height = max((page.height - 2 * margin - gutter * Double(grid.rows - 1)) / Double(grid.rows), 1)
        let column = slot % grid.columns
        let row = (slot / grid.columns) % grid.rows
        return CGRect(x: margin + Double(column) * (width + gutter), y: margin + Double(row) * (height + gutter),
                      width: width, height: height)
    }

    /// Where a picture `pixelWidth` × `pixelHeight` and its caption go in
    /// cell `slot`: the picture fitted, centred, above a one-line caption.
    public func sheetPlacement(slot: Int, pixelWidth: Int, pixelHeight: Int,
                               hasCaption: Bool) -> (image: CGRect, caption: CGRect?) {
        let cell = sheetCell(slot)
        let captionHeight = hasCaption ? captionFontSize * 1.8 : 0
        let area = CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: max(cell.height - captionHeight, 1))
        let w = Double(max(pixelWidth, 1)), h = Double(max(pixelHeight, 1))
        let scale = min(area.width / w, area.height / h)
        let size = CGSize(width: w * scale, height: h * scale)
        let image = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                           width: size.width, height: size.height)
        let caption = hasCaption ? CGRect(x: cell.minX, y: area.maxY + captionFontSize * 0.3,
                                          width: cell.width, height: captionFontSize * 1.5) : nil
        return (image, caption)
    }

    /// The longest edge, in pixels, a photo needs to be rendered at for a
    /// combined PDF at `ppi`: a contact-sheet cell's longer side, the
    /// paper's for a paper page, nil (full size) for Fit to image.
    public func combinedMaxLongEdge(ppi: Double) -> Int? {
        let resolution = ppi.isFinite && ppi > 0 ? ppi : 300
        switch combinedLayout {
        case .contactSheet:
            let cell = sheetCell(0)
            return max(Int((max(cell.width, cell.height) / 72 * resolution).rounded(.up)), 1)
        case .onePerPage:
            return pageSize.portraitPoints.map { Int((max($0.width, $0.height) / 72 * resolution).rounded(.up)) }
        }
    }

    /// How many pages a combined PDF of `photos` photos has.
    public func combinedPageCount(photos: Int) -> Int {
        guard photos > 0 else { return 0 }
        switch combinedLayout {
        case .onePerPage: return photos
        case .contactSheet:
            let perPage = sheetGrid.columns * sheetGrid.rows
            return (photos + perPage - 1) / perPage
        }
    }
}

/// Writes one PDF from many photos, a page (or a contact-sheet cell) at a
/// time, so an export of hundreds never holds more than one rendered photo:
/// each is drawn into the PDF as it arrives and can be released. The file
/// is built under a temporary name (SafeFileWriter) and only moved into
/// place by `finish`, so a cancelled or failed export leaves nothing behind.
///
/// Not reentrant: the export queue adds photos one after another, from
/// whichever task renders them, awaiting each. The lock only guards against
/// misuse; it is never contended.
public final class CombinedPDFWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let options: ExportPDFOptions
    private let pending: SafeFileWriter.PendingWrite
    private let context: CGContext
    /// The next free cell of the open contact-sheet page.
    private var slot = 0
    private var pageOpen = false
    private var closed = false
    public private(set) var pageCount = 0
    public private(set) var photoCount = 0

    /// Starts the file that will end up at `url`.
    public init(url: URL, options: ExportPDFOptions, title: String? = nil) throws {
        self.options = options
        pending = try SafeFileWriter.begin(url)
        var box = CGRect(origin: .zero, size: options.combinedLayout == .contactSheet
                         ? options.sheetPageSize : CGSize(width: 595.276, height: 841.89))
        var info: [CFString: Any] = [kCGPDFContextCreator: "Latent"]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(pending.url as CFURL, mediaBox: &box, info as CFDictionary) else {
            pending.discard()
            throw ExportError.destinationCreationFailed(url)
        }
        self.context = context
    }

    deinit {
        if !closed { pending.discard() }
    }

    /// Adds a photo: a page of its own, or the next cell of a contact sheet
    /// (a new page when the last one is full). `caption` is drawn under it.
    public func add(_ image: CGImage, caption: String?, ppi: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCaption = !(caption ?? "").isEmpty
        let font = PageRenderer.font(size: options.captionFontSize, bold: false)
        switch options.combinedLayout {
        case .onePerPage:
            let l = options.layout(pixelWidth: image.width, pixelHeight: image.height, ppi: ppi, hasCaption: hasCaption)
            beginPage(size: l.page)
            PageRenderer.drawImage(image, placement: ImagePlacement(drawRect: l.image, visibleRect: l.image,
                                                                    isRotated: false),
                                   pageHeight: l.page.height, in: context)
            if let caption, hasCaption, let rect = l.caption {
                PageRenderer.drawLine(caption, font: font, color: SheetColor.black.cgColor, in: rect,
                                      pageHeight: l.page.height, context: context)
            }
            endPage()
        case .contactSheet:
            let page = options.sheetPageSize
            if !pageOpen {
                beginPage(size: page)
                slot = 0
            }
            let l = options.sheetPlacement(slot: slot, pixelWidth: image.width, pixelHeight: image.height,
                                           hasCaption: hasCaption)
            PageRenderer.drawImage(image, placement: ImagePlacement(drawRect: l.image, visibleRect: l.image,
                                                                    isRotated: false),
                                   pageHeight: page.height, in: context)
            if let caption, hasCaption, let rect = l.caption {
                PageRenderer.drawLine(caption, font: font, color: SheetColor.black.cgColor, in: rect,
                                      pageHeight: page.height, context: context)
            }
            slot += 1
            if slot >= options.sheetGrid.columns * options.sheetGrid.rows { endPage() }
        }
        photoCount += 1
    }

    /// Closes the PDF and moves it into place; returns where it landed.
    /// Throws if no photo was added (an empty PDF is no export), if the
    /// writer was already finished or discarded, or if the name was taken
    /// meanwhile and `replacingExisting` is false.
    @discardableResult
    public func finish(replacingExisting: Bool) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw ExportError.destinationCreationFailed(pending.destination) }
        if pageOpen { endPage() }
        context.closePDF()
        closed = true
        guard photoCount > 0 else {
            pending.discard()
            throw ExportError.destinationCreationFailed(pending.destination)
        }
        do {
            try pending.commit(replacingExisting: replacingExisting)
        } catch {
            pending.discard()
            throw error
        }
        return pending.destination
    }

    /// Abandons the file: nothing is left at the destination.
    public func discard() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if pageOpen { endPage() }
        context.closePDF()
        closed = true
        pending.discard()
    }

    private func beginPage(size: CGSize) {
        var box = CGRect(origin: .zero, size: size)
        let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
        pageOpen = true
        pageCount += 1
    }

    private func endPage() {
        context.endPDFPage()
        pageOpen = false
    }
}
