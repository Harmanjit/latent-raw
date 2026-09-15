import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PixelEngine

/// Makes contact sheets: one PDF with every page, or one JPEG or PNG
/// picture. Blocking; run on a GCD worker, never the main thread.
///
/// Photos are rendered at the size of their cell through `ExportWorker`
/// (`SheetRenderer`) one at a time and drawn as each arrives, so memory
/// holds a page and a photo however many the sheet has. The file is written
/// through `SafeFileWriter`: a cancelled or failed sheet leaves nothing
/// behind and never costs the file the save panel agreed to replace.
enum ContactSheetWriter {
    enum Failure: Error, LocalizedError {
        case cannotCreatePage
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotCreatePage: "The page couldn’t be created. It may be too large for the memory available."
            case .cancelled: "The contact sheet was cancelled."
            }
        }
    }

    /// Writes the sheet to `url`. `progress` is called with the number of
    /// photos drawn so far, on the calling thread.
    static func write(items: [SheetItem], settings: ContactSheetSettings, title: String?, to url: URL,
                      renderer: SheetRenderer, preview: SheetPreviewImages?, cancel: SheetCancellation,
                      progress: (Int) -> Void) throws {
        let settings = settings.validated
        if settings.format == .pdf {
            try writePDF(items: items, settings: settings, title: title, to: url, renderer: renderer, preview: preview,
                         cancel: cancel, progress: progress)
        } else {
            try writeImage(items: items, settings: settings, title: title, to: url, renderer: renderer,
                           preview: preview, cancel: cancel, progress: progress)
        }
    }

    /// Page `page` at `scale` times its pixel size, drawn by `draw`.
    static func pageImage(settings: ContactSheetSettings, imageCount: Int, title: String?, scale: Double,
                          draw: (PageLayout, PageStyle, CGContext) -> Void) -> CGImage? {
        let layout = settings.layout(imageCount: imageCount, title: title)
        guard let context = PageRenderer.bitmapContext(pageSize: layout.pageSize, scale: scale,
                                                       colorSpace: settings.colorSpace.cgColorSpace) else { return nil }
        draw(layout, settings.style(title: title), context)
        return context.makeImage()
    }

    private static func writeImage(items: [SheetItem], settings: ContactSheetSettings, title: String?, to url: URL,
                                   renderer: SheetRenderer, preview: SheetPreviewImages?, cancel: SheetCancellation,
                                   progress: (Int) -> Void) throws {
        var drawn = 0
        let image = pageImage(settings: settings, imageCount: items.count, title: title, scale: 1) { layout, style, context in
            SheetPageDrawer.drawPage(0, items: items, layout: layout, style: style, pixelsPerUnit: 1,
                                     maxLongEdge: ContactSheetSettings.maxRenderLongEdge, renderer: renderer,
                                     preview: preview, cancel: cancel,
                                     didDraw: { drawn += 1; progress(drawn) }, in: context)
        }
        guard !cancel.isCancelled else { throw Failure.cancelled }
        guard let image else { throw Failure.cannotCreatePage }
        let format: ExportSettings.Format = settings.format == .png ? .png : .jpeg
        // The save panel asked before replacing a file that was there.
        try Exporter.write(cgImage: image, to: url, settings: ExportSettings(format: format, quality: 0.9))
    }

    private static func writePDF(items: [SheetItem], settings: ContactSheetSettings, title: String?, to url: URL,
                                 renderer: SheetRenderer, preview: SheetPreviewImages?, cancel: SheetCancellation,
                                 progress: (Int) -> Void) throws {
        let layout = settings.layout(imageCount: items.count, title: title)
        let style = settings.style(title: title)
        let pointsPerPixel = settings.pdfPointsPerPixel
        var mediaBox = CGRect(x: 0, y: 0, width: layout.pageSize.width * pointsPerPixel,
                              height: layout.pageSize.height * pointsPerPixel)
        let pending = try SafeFileWriter.begin(url)
        defer { pending.discard() }
        let info: [CFString: Any] = [kCGPDFContextCreator: "Latent",
                                     kCGPDFContextTitle: style.header ?? "Contact Sheet"]
        guard let context = CGContext(pending.url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw Failure.cannotCreatePage
        }
        var drawn = 0
        for page in 0..<layout.pageCount(forImageCount: items.count) where !cancel.isCancelled {
            context.beginPDFPage(nil)
            context.saveGState()
            context.scaleBy(x: pointsPerPixel, y: pointsPerPixel)
            SheetPageDrawer.drawPage(page, items: items, layout: layout, style: style, pixelsPerUnit: 1,
                                     maxLongEdge: ContactSheetSettings.maxRenderLongEdge, renderer: renderer,
                                     preview: preview, cancel: cancel,
                                     prepare: { jpegBacked($0) },
                                     didDraw: { drawn += 1; progress(drawn) }, in: context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        guard !cancel.isCancelled else { throw Failure.cancelled }
        // The save panel asked before replacing a file that was there.
        try pending.commit(replacingExisting: true)
    }

    /// `image` re-encoded as a high-quality JPEG and read back without
    /// decoding. A PDF context stores such an image's JPEG data as it is,
    /// where a decoded bitmap would be stored losslessly: measured in
    /// minivu on six photos on a 4K sheet, 15.8 MB became 3 MB. The JPEG
    /// keeps the image's colour profile.
    static func jpegBacked(_ image: CGImage) -> CGImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return image }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil),
              let jpeg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return image }
        return jpeg
    }
}
