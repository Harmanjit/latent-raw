import Foundation
import CoreGraphics
import CoreText

// Drawing pages of pictures with Core Graphics, shared by Print (into the
// printer's context) and Contact Sheet (into a bitmap or a PDF). Nothing
// here decodes or renders a photo: callers hand over finished images
// (ExportWorker renders, or thumbnails for a preview). Everything runs on
// whatever thread draws the page. Ported from minivu's LayoutRendering.

/// An opaque sRGB colour a page is filled with.
public struct SheetColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = SheetColor(red: 1, green: 1, blue: 1)
    public static let black = SheetColor(red: 0, green: 0, blue: 0)

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])
            ?? CGColor(red: red, green: green, blue: blue, alpha: 1)
    }

    /// Rec. 709 weights on the encoded values: plenty to pick a text colour.
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

/// What the caption under each picture says. The name is always the first
/// line; the date and camera share a second, smaller one.
public enum CaptionContent: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, name, nameAndDate, nameAndCamera, nameDateAndCamera

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "None"
        case .name: "File Name"
        case .nameAndDate: "File Name and Date"
        case .nameAndCamera: "File Name and Camera"
        case .nameDateAndCamera: "File Name, Date and Camera"
        }
    }

    public var lineCount: Int {
        switch self {
        case .none: 0
        case .name: 1
        case .nameAndDate, .nameAndCamera, .nameDateAndCamera: 2
        }
    }

    /// The space a caption takes under a cell's image: the lines plus half a
    /// line of air between the picture and the text.
    public func height(fontSize: Double) -> Double {
        lineCount == 0 ? 0 : fontSize * (0.5 + 1.25 * Double(lineCount))
    }

    /// The caption's lines. A detail the image doesn't have is left out; a
    /// second line with nothing on it is dropped, but still takes its space
    /// (`height`), so every cell of a page is the same size.
    public func lines(name: String, date: Date?, camera: String?,
                      formatDate: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> [String] {
        guard self != .none else { return [] }
        var details: [String] = []
        if self == .nameAndDate || self == .nameDateAndCamera, let date { details.append(formatDate(date)) }
        if self == .nameAndCamera || self == .nameDateAndCamera, let camera, !camera.isEmpty { details.append(camera) }
        return details.isEmpty ? [name] : [name, details.joined(separator: " · ")]
    }
}

/// How a page looks beyond its geometry.
public struct PageStyle: Sendable, Equatable {
    /// Nil leaves the page as it is (paper white when printing).
    public var background: SheetColor?
    public var caption: CaptionContent
    public var captionFontSize: Double
    /// A title across the top, in the layout's header band.
    public var header: String?
    public var headerFontSize: Double
    /// "Page 2 of 5" in the layout's footer band.
    public var showsPageNumbers: Bool

    public init(background: SheetColor? = nil, caption: CaptionContent = .none, captionFontSize: Double = 10,
                header: String? = nil, headerFontSize: Double = 16, showsPageNumbers: Bool = false) {
        self.background = background
        self.caption = caption
        self.captionFontSize = captionFontSize
        self.header = header
        self.headerFontSize = headerFontSize
        self.showsPageNumbers = showsPageNumbers
    }

    /// Dark grey on light backgrounds and paper, near-white on dark ones.
    public var textColor: SheetColor {
        guard let background, background.luminance <= 0.5 else { return SheetColor(red: 0.12, green: 0.12, blue: 0.12) }
        return SheetColor(red: 0.92, green: 0.92, blue: 0.92)
    }

    public static func pageNumberText(page: Int, of pageCount: Int) -> String {
        "Page \(page + 1) of \(max(pageCount, 1))"
    }
}

/// Draws pages. The context's user space is the page in layout units with
/// y growing upwards from the bottom-left corner, as Core Graphics has it;
/// callers set the transform (a printer's flipped view, a bitmap's scale).
public enum PageRenderer {
    /// Background, header and footer.
    public static func drawChrome(layout: PageLayout, style: PageStyle, page: Int, pageCount: Int,
                                  in context: CGContext) {
        let height = layout.pageSize.height
        if let background = style.background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(origin: .zero, size: layout.pageSize))
        }
        let color = style.textColor.cgColor
        if let header = style.header, !header.isEmpty, let rect = layout.headerRect {
            drawLine(header, font: font(size: style.headerFontSize, bold: true), color: color,
                     in: rect, pageHeight: height, context: context)
        }
        if style.showsPageNumbers, let rect = layout.footerRect {
            drawLine(PageStyle.pageNumberText(page: page, of: pageCount),
                     font: font(size: style.captionFontSize, bold: false),
                     color: color, in: rect, pageHeight: height, context: context)
        }
    }

    /// One cell: its picture placed by the layout's rules, or a quiet grey
    /// box while (or when) there is none, and the caption under it.
    public static func drawCell(_ cell: LayoutCell, image: CGImage?, caption: [String], layout: PageLayout,
                                style: PageStyle, in context: CGContext) {
        let height = layout.pageSize.height
        if let image {
            let placement = layout.placement(for: CGSize(width: image.width, height: image.height), in: cell.imageArea)
            drawImage(image, placement: placement, pageHeight: height, in: context)
        } else if !cell.imageArea.isEmpty {
            context.setFillColor(CGColor(gray: 0.5, alpha: 0.15))
            context.fill(PageLayout.flipped(cell.imageArea, pageHeight: height))
        }
        guard let rect = cell.captionRect, !caption.isEmpty else { return }
        let size = style.captionFontSize
        let color = style.textColor.cgColor
        let top = rect.minY + size * 0.5
        for (number, line) in caption.enumerated() where !line.isEmpty {
            let lineRect = CGRect(x: rect.minX, y: top + Double(number) * size * 1.25, width: rect.width,
                                  height: size * 1.25)
            guard lineRect.maxY <= rect.maxY + 0.5 else { break }
            let lineColor = number == 0 ? color : color.copy(alpha: 0.65) ?? color
            drawLine(line, font: font(size: number == 0 ? size : size * 0.9, bold: false), color: lineColor,
                     in: lineRect, pageHeight: height, context: context)
        }
    }

    /// `placement` is in layout coordinates (top-left origin).
    public static func drawImage(_ image: CGImage, placement: ImagePlacement, pageHeight: Double,
                                 in context: CGContext) {
        let visible = PageLayout.flipped(placement.visibleRect, pageHeight: pageHeight)
        let rect = PageLayout.flipped(placement.drawRect, pageHeight: pageHeight)
        context.saveGState()
        context.clip(to: visible)
        context.interpolationQuality = .high
        if placement.isRotated {
            // A quarter turn clockwise about the rectangle's centre: the
            // picture's top ends up facing right.
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -.pi / 2)
            context.draw(image, in: CGRect(x: -rect.height / 2, y: -rect.width / 2, width: rect.height, height: rect.width))
        } else {
            context.draw(image, in: rect)
        }
        context.restoreGState()
    }

    public static func font(size: Double, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, max(size, 1), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, max(size, 1), nil)
    }

    /// One line of text centred in `rect` (layout coordinates), shortened in
    /// the middle with an ellipsis when too wide, as Finder shortens names.
    public static func drawLine(_ text: String, font: CTFont, color: CGColor, in rect: CGRect, pageHeight: Double,
                                context: CGContext) {
        guard rect.width > 1, rect.height > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let line = CTLineCreateTruncatedLine(full, rect.width, .middle, token) ?? token
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let flipped = PageLayout.flipped(rect, pageHeight: pageHeight)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: flipped.midX - width / 2,
                                       y: flipped.minY + (flipped.height - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// An opaque bitmap for a page drawn at `scale` times its layout size,
    /// its user space set to layout units. Nil when it can't be made (too
    /// large for memory).
    public static func bitmapContext(pageSize: CGSize, scale: Double, colorSpace: CGColorSpace) -> CGContext? {
        let width = max(1, Int((pageSize.width * scale).rounded()))
        let height = max(1, Int((pageSize.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(SheetColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / pageSize.width, y: CGFloat(height) / pageSize.height)
        return context
    }
}

extension PageLayout {
    /// The long edge, in pixels, to render an image of `aspect` (width over
    /// height, as it will be drawn) at, to fill `area` at `pixelsPerUnit`.
    /// With an unknown aspect, the larger of a 3:2 landscape and portrait
    /// photo's needs, which covers fit for any shape and fill for the usual
    /// ones. At least 16 pixels, at most `maximum`.
    public func renderLongEdge(for area: CGRect, aspect: Double?, pixelsPerUnit: Double, maximum: Int) -> Int {
        let shapes: [CGSize]
        if let aspect, aspect > 0, aspect.isFinite {
            shapes = [CGSize(width: aspect, height: 1)]
        } else {
            shapes = [CGSize(width: 3, height: 2), CGSize(width: 2, height: 3)]
        }
        let needed = shapes.map { placement(for: $0, in: area).pixelsNeeded(pixelsPerUnit: pixelsPerUnit) }.max() ?? 16
        return min(max(needed, 16), max(maximum, 16))
    }
}
