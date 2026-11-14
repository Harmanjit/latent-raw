import Foundation
import CoreGraphics

/// Borders and enlarge canvas, darktable's "framing": an export step after
/// the resize and before the watermark that pads the picture.
///
/// The border is a size (a percentage of the picture's long edge, or
/// pixels) on every side. With an aspect ratio the canvas then grows on
/// the short sides until it has that shape, never cutting into the border,
/// and the picture sits where `positionX` and `positionY` say in the room
/// left over. An inner line (a width, a colour and a gap from the picture)
/// can frame the picture inside the border. Every colour is an sRGB value
/// that Core Graphics converts into the file's own colour space.
///
/// The pixels of the picture itself are copied unchanged; only the canvas
/// around them is drawn, so nothing about how an edit renders changes.
public struct ExportBorder: Sendable, Hashable, Codable {
    public enum SizeUnit: String, Sendable, Codable, CaseIterable {
        case percent, pixels

        public var title: String {
            switch self {
            case .percent: "% of long edge"
            case .pixels: "px"
            }
        }
    }

    /// The canvas's shape. `none` keeps the picture's own shape, plus the
    /// border.
    public enum Aspect: String, Sendable, Codable, CaseIterable {
        case none, square, fourFive, threeTwo, sixteenNine, custom

        public var title: String {
            switch self {
            case .none: "Picture's own"
            case .square: "1:1"
            case .fourFive: "4:5"
            case .threeTwo: "3:2"
            case .sixteenNine: "16:9"
            case .custom: "Custom"
            }
        }

        /// Width over height as written; nil for `none` and `custom`.
        var ratio: Double? {
            switch self {
            case .none, .custom: nil
            case .square: 1
            case .fourFive: 4.0 / 5
            case .threeTwo: 3.0 / 2
            case .sixteenNine: 16.0 / 9
            }
        }
    }

    /// Which way an aspect ratio is turned.
    public enum Orientation: String, Sendable, Codable, CaseIterable {
        /// The canvas's long side runs the way the picture's does.
        case matchPicture
        case portrait, landscape

        public var title: String {
            switch self {
            case .matchPicture: "Match picture"
            case .portrait: "Portrait"
            case .landscape: "Landscape"
            }
        }
    }

    public var size: Double = 5
    public var unit: SizeUnit = .percent
    public var aspect: Aspect = .none
    public var orientation: Orientation = .matchPicture
    /// The custom ratio's width and height (any units).
    public var customWidth: Double = 5
    public var customHeight: Double = 4
    /// Where the picture sits in the room the canvas leaves: 0 left or
    /// top, 1 right or bottom, 0.5 centred.
    public var positionX: Double = 0.5
    public var positionY: Double = 0.5
    public var color: SheetColor = .white
    /// The inner line's width in pixels; 0 draws none.
    public var lineWidth: Double = 0
    public var lineColor: SheetColor = .black
    /// The gap between the picture's edge and the line, in pixels.
    public var lineOffset: Double = 0

    public init() {}

    /// Whether there is anything to draw.
    public var isActive: Bool { size > 0 || aspect != .none || lineWidth > 0 }

    /// The largest side a bordered canvas may have, to keep a mistyped
    /// size from asking for gigabytes.
    public static let maximumSide = 65_000

    /// Where the picture goes on the canvas: the canvas's size, and the
    /// picture's top-left corner on it, in pixels.
    public struct Layout: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var imageX: Int
        public var imageY: Int
    }

    /// The canvas for a picture `width` × `height` pixels.
    public func layout(width w: Int, height h: Int) -> Layout {
        let longEdge = Double(max(w, h))
        let raw = unit == .percent ? longEdge * min(max(size, 0), 100) / 100 : min(max(size, 0), 20_000)
        let border = raw.isFinite ? raw.rounded() : 0
        var cw = Double(w) + 2 * border, ch = Double(h) + 2 * border
        if let ratio = canvasRatio(pictureIsLandscape: w >= h), ratio.isFinite, ratio > 0 {
            if cw / ch < ratio { cw = ch * ratio } else { ch = cw / ratio }
        }
        let width = min(max(Int(cw.rounded()), w), Self.maximumSide)
        let height = min(max(Int(ch.rounded()), h), Self.maximumSide)
        let px = min(max(positionX.isFinite ? positionX : 0.5, 0), 1)
        let py = min(max(positionY.isFinite ? positionY : 0.5, 0), 1)
        return Layout(width: width, height: height,
                      imageX: max(0, Int((Double(width - w) * px).rounded())),
                      imageY: max(0, Int((Double(height - h) * py).rounded())))
    }

    /// The canvas's width over height, turned as `orientation` says; nil
    /// when the canvas keeps the picture's shape.
    func canvasRatio(pictureIsLandscape: Bool) -> Double? {
        let written: Double?
        if aspect == .custom {
            written = customWidth > 0 && customHeight > 0 ? customWidth / customHeight : nil
        } else {
            written = aspect.ratio
        }
        guard let written else { return nil }
        let wide = max(written, 1 / written), tall = min(written, 1 / written)
        switch orientation {
        case .matchPicture: return pictureIsLandscape ? wide : tall
        case .portrait: return tall
        case .landscape: return wide
        }
    }

    /// `image` (8 or 16 bits per channel, RGBX, as the exporter makes it)
    /// on its bordered canvas, in the same colour space and layout.
    public func apply(to image: CGImage) throws -> CGImage {
        guard isActive else { return image }
        let w = image.width, h = image.height
        let bits = image.bitsPerComponent == 16 ? 16 : 8
        guard let space = image.colorSpace else { throw ExportError.imageCreationFailed }
        let l = layout(width: w, height: h)
        var info = CGImageAlphaInfo.noneSkipLast.rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let bytesPerPixel = bits / 2
        let bytesPerRow = l.width * bytesPerPixel
        var data = Data(count: bytesPerRow * l.height)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(data: base, width: l.width, height: l.height, bitsPerComponent: bits,
                                          bytesPerRow: bytesPerRow, space: space, bitmapInfo: info) else { return false }
            context.setShouldAntialias(false)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: l.width, height: l.height))
            // Core Graphics counts up from the bottom.
            let picture = CGRect(x: l.imageX, y: l.height - l.imageY - h, width: w, height: h)
            let line = max(0, lineWidth.isFinite ? lineWidth.rounded() : 0)
            if line > 0 {
                let gap = max(0, lineOffset.isFinite ? lineOffset.rounded() : 0)
                context.setFillColor(lineColor.cgColor)
                context.fill(picture.insetBy(dx: -(gap + line), dy: -(gap + line)))
                context.setFillColor(color.cgColor)
                context.fill(picture.insetBy(dx: -gap, dy: -gap))
            }
            // The picture's own pixels, copied row by row when its layout is
            // the exporter's, so not one changes; drawn otherwise.
            if image.bitsPerComponent == bits, image.bitsPerPixel == bits * 4, image.bytesPerRow == w * bytesPerPixel,
               let source = image.dataProvider?.data, let pixels = CFDataGetBytePtr(source),
               CFDataGetLength(source) >= w * bytesPerPixel * h {
                for row in 0..<h {
                    let to = base.advanced(by: (l.imageY + row) * bytesPerRow + l.imageX * bytesPerPixel)
                    to.copyMemory(from: pixels.advanced(by: row * w * bytesPerPixel), byteCount: w * bytesPerPixel)
                }
            } else {
                context.interpolationQuality = .none
                context.draw(image, in: picture)
            }
            return true
        }
        guard drawn, let provider = CGDataProvider(data: data as CFData),
              let result = CGImage(width: l.width, height: l.height, bitsPerComponent: bits,
                                   bitsPerPixel: bits * 4, bytesPerRow: bytesPerRow, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent) else {
            throw ExportError.imageCreationFailed
        }
        return result
    }

    // Lenient decoding: a field missing or unreadable in a saved preset
    // takes its default, so presets from later or earlier builds load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportBorder()
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? d.size
        unit = (try? c.decodeIfPresent(SizeUnit.self, forKey: .unit)) ?? d.unit
        aspect = (try? c.decodeIfPresent(Aspect.self, forKey: .aspect)) ?? d.aspect
        orientation = (try? c.decodeIfPresent(Orientation.self, forKey: .orientation)) ?? d.orientation
        customWidth = (try? c.decodeIfPresent(Double.self, forKey: .customWidth)) ?? d.customWidth
        customHeight = (try? c.decodeIfPresent(Double.self, forKey: .customHeight)) ?? d.customHeight
        positionX = (try? c.decodeIfPresent(Double.self, forKey: .positionX)) ?? d.positionX
        positionY = (try? c.decodeIfPresent(Double.self, forKey: .positionY)) ?? d.positionY
        color = (try? c.decodeIfPresent(SheetColor.self, forKey: .color)) ?? d.color
        lineWidth = (try? c.decodeIfPresent(Double.self, forKey: .lineWidth)) ?? d.lineWidth
        lineColor = (try? c.decodeIfPresent(SheetColor.self, forKey: .lineColor)) ?? d.lineColor
        lineOffset = (try? c.decodeIfPresent(Double.self, forKey: .lineOffset)) ?? d.lineOffset
    }
}
