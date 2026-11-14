import Foundation
import CoreGraphics

/// PDF export: each photo on a page of its own, drawn with the same
/// helpers Print and Contact Sheet use (PageRenderer, in layout
/// coordinates with the origin top left). The page is the picture's own
/// size at the export's resolution, or A4, US Letter or A3 turned the way
/// the picture is, with a margin and an optional one-line caption below.
public struct ExportPDFOptions: Sendable, Hashable, Codable {
    public enum PageSize: String, Sendable, Codable, CaseIterable {
        case fitImage, a4, letter, a3

        public var title: String {
            switch self {
            case .fitImage: "Fit to image"
            case .a4: "A4"
            case .letter: "US Letter"
            case .a3: "A3"
            }
        }

        /// Portrait size in points; nil for `fitImage`.
        public var portraitPoints: CGSize? {
            switch self {
            case .fitImage: nil
            case .a4: CGSize(width: 595.276, height: 841.89)
            case .letter: CGSize(width: 612, height: 792)
            case .a3: CGSize(width: 841.89, height: 1190.551)
            }
        }
    }

    public var pageSize: PageSize = .fitImage
    /// The margin on every side, in millimetres.
    public var marginMM: Double = 10
    /// The caption, in the file-name template's tokens ({name}, {date}…);
    /// empty for none.
    public var captionTemplate = ""
    public var captionFontSize: Double = 10

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageSize = (try? c.decodeIfPresent(PageSize.self, forKey: .pageSize)) ?? .fitImage
        marginMM = min(max((try? c.decodeIfPresent(Double.self, forKey: .marginMM)) ?? 10, 0), 100)
        captionTemplate = (try? c.decodeIfPresent(String.self, forKey: .captionTemplate)) ?? ""
        captionFontSize = min(max((try? c.decodeIfPresent(Double.self, forKey: .captionFontSize)) ?? 10, 4), 72)
    }

    static let pointsPerMM = 72 / 25.4

    /// Where things go on a page for a picture `pixelWidth` × `pixelHeight`
    /// at `ppi`: the page's size, the picture's rectangle and the caption's,
    /// in points with the origin top left.
    public func layout(pixelWidth: Int, pixelHeight: Int, ppi: Double,
                       hasCaption: Bool) -> (page: CGSize, image: CGRect, caption: CGRect?) {
        let margin = min(max(marginMM, 0), 100) * Self.pointsPerMM
        let captionHeight = hasCaption ? captionFontSize * 2 : 0
        let resolution = ppi.isFinite && ppi > 0 ? ppi : 300
        let natural = CGSize(width: Double(max(pixelWidth, 1)) * 72 / resolution,
                             height: Double(max(pixelHeight, 1)) * 72 / resolution)
        let page: CGSize
        if let portrait = pageSize.portraitPoints {
            page = pixelWidth > pixelHeight ? CGSize(width: portrait.height, height: portrait.width) : portrait
        } else {
            page = CGSize(width: natural.width + 2 * margin, height: natural.height + 2 * margin + captionHeight)
        }
        let area = CGRect(x: margin, y: margin, width: max(page.width - 2 * margin, 1),
                          height: max(page.height - 2 * margin - captionHeight, 1))
        let scale = min(area.width / natural.width, area.height / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        let image = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                           width: size.width, height: size.height)
        let caption = hasCaption ? CGRect(x: margin, y: image.maxY + captionFontSize * 0.5,
                                          width: area.width, height: captionFontSize * 1.5) : nil
        return (page, image, caption)
    }
}

extension Exporter {
    /// Writes `image` as a one-page PDF laid out by `options`, under a
    /// temporary name moved into place when complete.
    public static func writePDF(_ image: CGImage, options: ExportPDFOptions, caption: String?, ppi: Double,
                                to url: URL, replacingExisting: Bool = true) throws {
        let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCaption = !(caption ?? "").isEmpty
        let l = options.layout(pixelWidth: image.width, pixelHeight: image.height, ppi: ppi, hasCaption: hasCaption)
        let pending = try SafeFileWriter.begin(url)
        defer { pending.discard() }
        var box = CGRect(origin: .zero, size: l.page)
        let info = [kCGPDFContextCreator: "Latent"] as CFDictionary
        guard let context = CGContext(pending.url as CFURL, mediaBox: &box, info) else {
            throw ExportError.destinationCreationFailed(url)
        }
        context.beginPDFPage(nil)
        PageRenderer.drawImage(image, placement: ImagePlacement(drawRect: l.image, visibleRect: l.image, isRotated: false),
                               pageHeight: l.page.height, in: context)
        if let caption, hasCaption, let rect = l.caption {
            PageRenderer.drawLine(caption, font: PageRenderer.font(size: options.captionFontSize, bold: false),
                                  color: SheetColor.black.cgColor, in: rect, pageHeight: l.page.height,
                                  context: context)
        }
        context.endPDFPage()
        context.closePDF()
        try pending.commit(replacingExisting: replacingExisting)
    }
}
