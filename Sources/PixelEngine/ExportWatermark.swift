import Foundation
import CoreGraphics
import CoreText
import ImageIO
import ColorKit

/// A line of text stamped into a corner of an exported file ("© 2026 Ana
/// Ruiz"). An export setting, never part of an edit: the photo in the
/// catalog and on screen stays clean, and only the written file carries it.
///
/// It is drawn after the resize and before the encode, into the file's own
/// pixels, so its size is a fraction of the file's short edge whatever
/// size the export is, and every export path (the queue, Export Open
/// Image, the size estimate and the quality comparison) gets the same
/// stamp from `Exporter`. Only the text's bounding box is rasterised (Core
/// Text, on the CPU) and blended, into the bytes the encoder is about to
/// read anyway: no extra copy of the picture, and work in proportion to
/// the text, not the image. (The export sheet alone stamps a copy of a
/// render made without one, `EncodableImage.watermarked`, so trying another
/// watermark doesn't render the photo again.)
///
/// Tokens, in any letter case: `{year}` is the capture year, `{name}` the
/// original file name without its extension (as in `ExportNaming`).
public struct ExportWatermark: Sendable, Equatable, Codable {
    public enum Corner: String, Sendable, Codable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        public var title: String {
            switch self {
            case .topLeft: "Top left"
            case .topRight: "Top right"
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            }
        }
    }

    /// Text, or a picture (a logo, from a PNG with transparency).
    public enum Style: String, Sendable, Codable, CaseIterable {
        case text, graphic

        public var title: String {
            switch self {
            case .text: "Text"
            case .graphic: "Graphic"
            }
        }
    }

    public static let defaultText = "© {year}"
    public static let tokens: [(token: String, meaning: String)] = [("{year}", "capture year"), ("{name}", "original name")]
    /// Size and opacity limits, for the sheet's sliders and for values
    /// read from a hand-edited preset.
    public static let sizeRange: ClosedRange<Float> = 0.01...0.2
    public static let opacityRange: ClosedRange<Float> = 0.05...1
    /// A graphic's longer side, as a share of the picture's short edge.
    public static let imageSizeRange: ClosedRange<Float> = 0.02...0.5
    /// The largest PNG kept in a preset: a logo, not a photo.
    public static let maximumImageBytes = 4 << 20
    /// Gap between the text and the image's edges, as a fraction of the
    /// short edge, the same at every text size.
    public static let marginFraction: Double = 0.025

    public var text: String
    public var corner: Corner
    /// The font size as a fraction of the output's short edge.
    public var size: Float
    public var opacity: Float
    /// The colour, as sRGB components 0...1. Converted to the file's
    /// colour space when drawn, so it looks the same in a P3 export.
    public var red: Float
    public var green: Float
    public var blue: Float
    /// Text (the default, and what presets saved before graphics hold) or
    /// the PNG in `imageData`.
    public var style: Style = .text
    /// The text's font family; nil is the system font, as before.
    public var fontName: String?
    /// Quarter turns clockwise: 0, 90, 180 or 270 degrees. Text running up
    /// the side of a picture is 270.
    public var rotation: Int = 0
    /// The graphic's PNG bytes, kept in the preset itself so it still
    /// stamps after the original file moves (and no folder access is
    /// needed to read it again).
    public var imageData: Data?
    /// The graphic's longer side as a share of the picture's short edge.
    public var imageSize: Float = 0.15

    public init(text: String = ExportWatermark.defaultText, corner: Corner = .bottomRight, size: Float = 0.03,
                opacity: Float = 0.7, red: Float = 1, green: Float = 1, blue: Float = 1) {
        self.text = text; self.corner = corner; self.size = size; self.opacity = opacity
        self.red = red; self.green = green; self.blue = blue
    }

    // Lenient decoding, as ExportPreset's: a field missing from an older or
    // hand-edited preset takes its default, and numbers are held in range.
    enum CodingKeys: String, CodingKey {
        case text, corner, size, opacity, red, green, blue, style, fontName, rotation, imageData, imageSize
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportWatermark()
        func number(_ key: CodingKeys, _ fallback: Float, _ range: ClosedRange<Float>) -> Float {
            let value = (try? c.decodeIfPresent(Float.self, forKey: key)) ?? fallback
            return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? d.text
        corner = (try? c.decodeIfPresent(Corner.self, forKey: .corner)) ?? d.corner
        size = number(.size, d.size, Self.sizeRange)
        opacity = number(.opacity, d.opacity, Self.opacityRange)
        red = number(.red, d.red, 0...1)
        green = number(.green, d.green, 0...1)
        blue = number(.blue, d.blue, 0...1)
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? .text
        fontName = (try? c.decodeIfPresent(String.self, forKey: .fontName)) ?? nil
        rotation = Self.normalisedRotation((try? c.decodeIfPresent(Int.self, forKey: .rotation)) ?? 0)
        let png = (try? c.decodeIfPresent(Data.self, forKey: .imageData)) ?? nil
        imageData = (png?.count ?? 0) <= Self.maximumImageBytes ? png : nil
        imageSize = number(.imageSize, d.imageSize, Self.imageSizeRange)
    }

    // Written by hand so a preset without the new settings stays as it
    // was: only what differs from the defaults is added.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text); try c.encode(corner, forKey: .corner)
        try c.encode(size, forKey: .size); try c.encode(opacity, forKey: .opacity)
        try c.encode(red, forKey: .red); try c.encode(green, forKey: .green); try c.encode(blue, forKey: .blue)
        if style != .text { try c.encode(style, forKey: .style) }
        try c.encodeIfPresent(fontName, forKey: .fontName)
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
        try c.encodeIfPresent(imageData, forKey: .imageData)
        if imageSize != ExportWatermark().imageSize { try c.encode(imageSize, forKey: .imageSize) }
    }

    /// 0, 90, 180 or 270: the nearest quarter turn, clockwise.
    public static func normalisedRotation(_ degrees: Int) -> Int {
        let quarter = Int((Double(degrees) / 90).rounded())
        return ((quarter % 4) + 4) % 4 * 90
    }

    /// Whether there is anything to draw.
    public var isEmpty: Bool {
        switch style {
        case .text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .graphic: imageData.flatMap(Self.graphicImage) == nil
        }
    }

    /// The graphic's picture, when `data` is an image ImageIO reads.
    public static func graphicImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// This watermark with its tokens filled in for one image. Dates use the
    /// Gregorian calendar, so a Buddhist-calendar Mac still writes 2026.
    public func resolved(fileName: String, captureDate: Date, timeZone: TimeZone = .current) -> ExportWatermark {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = String(calendar.component(.year, from: captureDate))
        var copy = self
        copy.text = text
            .replacingOccurrences(of: "{year}", with: year, options: .caseInsensitive)
            .replacingOccurrences(of: "{name}", with: fileName, options: .caseInsensitive)
        return copy
    }

    /// Where the text's top-left corner goes in an image of the given size
    /// (origin top left, y down), for text of the given size.
    public func origin(textWidth: Int, textHeight: Int, imageWidth: Int, imageHeight: Int) -> (x: Int, y: Int) {
        let margin = Int((Double(min(imageWidth, imageHeight)) * Self.marginFraction).rounded())
        let left = margin, top = margin
        let right = imageWidth - margin - textWidth, bottom = imageHeight - margin - textHeight
        switch corner {
        case .topLeft: return (left, top)
        case .topRight: return (right, top)
        case .bottomLeft: return (left, bottom)
        case .bottomRight: return (right, bottom)
        }
    }

    /// The font size in pixels for an image of the given size.
    public func fontPixelSize(imageWidth: Int, imageHeight: Int) -> CGFloat {
        CGFloat(max(1, Double(min(imageWidth, imageHeight)) * Double(size)))
    }
}

/// A watermark rasterised and placed for one image: 8-bit coverage over
/// its box, where it goes, and its colour in the file's encoding (one
/// colour for text, a colour per pixel for a graphic).
struct PlacedWatermark {
    let width: Int
    let height: Int
    /// Row-major coverage, top row first, 0 (none) to 255 (solid).
    let coverage: [UInt8]
    let x: Int
    let y: Int
    /// The colour as the file's encoded components, 0...1.
    let color: SIMD3<Float>
    /// A graphic's own colours, RGB per pixel in the file's encoding (not
    /// premultiplied), row-major like `coverage`; nil for text.
    let pixels: [UInt8]?
    let opacity: Float

    init?(_ watermark: ExportWatermark, imageWidth: Int, imageHeight: Int, colorSpace: ColorKit.OutputSpace) {
        let name: CFString
        switch colorSpace {
        case .sRGB: name = CGColorSpace.sRGB
        case .displayP3: name = CGColorSpace.displayP3
        case .rec2020: name = CGColorSpace.itur_2020
        }
        guard let space = CGColorSpace(name: name) else { return nil }
        self.init(watermark, imageWidth: imageWidth, imageHeight: imageHeight, space: space)
    }

    /// Placed for pixels encoded in `space`, the file's colour space.
    init?(_ watermark: ExportWatermark, imageWidth: Int, imageHeight: Int, space: CGColorSpace) {
        guard !watermark.isEmpty, imageWidth > 0, imageHeight > 0 else { return nil }
        let raster: (width: Int, height: Int, coverage: [UInt8], pixels: [UInt8]?)
        switch watermark.style {
        case .text:
            guard let text = Self.rasterise(watermark.text, fontName: watermark.fontName,
                                            fontSize: watermark.fontPixelSize(imageWidth: imageWidth,
                                                                              imageHeight: imageHeight))
            else { return nil }
            raster = (text.width, text.height, text.coverage, nil)
        case .graphic:
            let longSide = max(1, Int((Double(min(imageWidth, imageHeight)) * Double(watermark.imageSize)).rounded()))
            guard let data = watermark.imageData, let image = ExportWatermark.graphicImage(data),
                  let graphic = Self.rasterise(image, longSide: longSide, space: space) else { return nil }
            raster = (graphic.width, graphic.height, graphic.coverage, graphic.pixels)
        }
        let turned = Self.rotated(raster, quarterTurns: watermark.rotation / 90)
        width = turned.width; height = turned.height; coverage = turned.coverage; pixels = turned.pixels
        (x, y) = watermark.origin(textWidth: width, textHeight: height, imageWidth: imageWidth, imageHeight: imageHeight)
        color = Self.encodedColor(watermark, in: space)
        opacity = min(max(watermark.opacity, 0), 1)
    }

    /// The text as coverage: one line, the chosen font (the system font
    /// when none is, or the one named isn't installed), grey-scale
    /// antialiasing (no subpixel smoothing, which would tint the edges).
    static func rasterise(_ text: String, fontName: String? = nil,
                          fontSize: CGFloat) -> (width: Int, height: Int, coverage: [UInt8])? {
        let font = fontName.flatMap { Self.font(named: $0, size: fontSize) }
            ?? CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        // One line: a pasted line break would otherwise draw on top of itself.
        let oneLine = text.components(separatedBy: .newlines).joined(separator: " ")
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: oneLine, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        // A pixel of room around the ink for antialiased edges.
        let pad = 1
        let width = Int(ceil(advance)) + 2 * pad, height = Int(ceil(ascent + descent)) + 2 * pad
        guard advance > 0, width > 2 * pad, height > 2 * pad, width < 1 << 15, height < 1 << 15 else { return nil }
        var coverage = [UInt8](repeating: 0, count: width * height)
        let drawn = coverage.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.setAllowsFontSmoothing(false)
            context.setShouldAntialias(true)
            context.setFillColor(gray: 1, alpha: 1)
            context.textPosition = CGPoint(x: CGFloat(pad), y: CGFloat(pad) + descent)
            CTLineDraw(line, context)
            return true
        }
        return drawn ? (width, height, coverage) : nil
    }

    /// The installed font of that family (or full or PostScript name), or
    /// nil when there is none: Core Text would otherwise quietly substitute
    /// Helvetica for a name it doesn't know.
    static func font(named name: String, size: CGFloat) -> CTFont? {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let family = CTFontCopyFamilyName(font) as String
        let full = CTFontCopyFullName(font) as String
        let postScript = CTFontCopyPostScriptName(font) as String
        return [family, full, postScript].contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? font : nil
    }

    /// A graphic scaled so its longer side is `longSide` pixels and drawn in
    /// `space`, as coverage (its alpha) and its colours unpremultiplied.
    static func rasterise(_ image: CGImage, longSide: Int,
                          space: CGColorSpace) -> (width: Int, height: Int, coverage: [UInt8], pixels: [UInt8])? {
        guard image.width > 0, image.height > 0, longSide < 1 << 15 else { return nil }
        let scale = Double(longSide) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        // RGBA needs an RGB space; a file in a grey or odd space draws in sRGB.
        let drawSpace = space.model == .rgb ? space : (CGColorSpace(name: CGColorSpace.sRGB) ?? space)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: drawSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var coverage = [UInt8](repeating: 0, count: width * height)
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            let a = rgba[i * 4 + 3]
            coverage[i] = a
            guard a > 0 else { continue }
            for k in 0..<3 {
                let unpremultiplied = (Int(rgba[i * 4 + k]) * 255 + Int(a) / 2) / Int(a)
                pixels[i * 3 + k] = UInt8(min(unpremultiplied, 255))
            }
        }
        return (width, height, coverage, pixels)
    }

    /// A raster turned clockwise by quarter turns.
    static func rotated(_ raster: (width: Int, height: Int, coverage: [UInt8], pixels: [UInt8]?),
                        quarterTurns: Int) -> (width: Int, height: Int, coverage: [UInt8], pixels: [UInt8]?) {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return raster }
        let w = raster.width, h = raster.height
        let (ow, oh) = turns == 2 ? (w, h) : (h, w)
        var coverage = [UInt8](repeating: 0, count: ow * oh)
        var pixels = raster.pixels.map { _ in [UInt8](repeating: 0, count: ow * oh * 3) }
        for sy in 0..<h {
            for sx in 0..<w {
                let (dx, dy): (Int, Int)
                switch turns {
                case 1: (dx, dy) = (h - 1 - sy, sx)            // clockwise
                case 2: (dx, dy) = (w - 1 - sx, h - 1 - sy)
                default: (dx, dy) = (sy, w - 1 - sx)           // counter-clockwise
                }
                let s = sy * w + sx, d = dy * ow + dx
                coverage[d] = raster.coverage[s]
                if let source = raster.pixels {
                    pixels![d * 3] = source[s * 3]; pixels![d * 3 + 1] = source[s * 3 + 1]
                    pixels![d * 3 + 2] = source[s * 3 + 2]
                }
            }
        }
        return (ow, oh, coverage, pixels)
    }

    /// `encodedColor` for one of the render's own spaces.
    static func encodedColor(_ watermark: ExportWatermark, in space: ColorKit.OutputSpace) -> SIMD3<Float> {
        let name: CFString
        switch space {
        case .sRGB: return SIMD3<Float>(watermark.red, watermark.green, watermark.blue)
        case .displayP3: name = CGColorSpace.displayP3
        case .rec2020: name = CGColorSpace.itur_2020
        }
        guard let target = CGColorSpace(name: name) else { return SIMD3<Float>(watermark.red, watermark.green, watermark.blue) }
        return encodedColor(watermark, in: target)
    }

    /// The sRGB colour in the file's space, as the components of the
    /// profile `Exporter` tags the file with.
    static func encodedColor(_ watermark: ExportWatermark, in target: CGColorSpace) -> SIMD3<Float> {
        let fallback = SIMD3<Float>(watermark.red, watermark.green, watermark.blue)
        guard (target.name as String?) != (CGColorSpace.sRGB as String) else { return fallback }
        guard let source = CGColorSpace(name: CGColorSpace.sRGB),
              let color = CGColor(colorSpace: source, components: [CGFloat(watermark.red), CGFloat(watermark.green),
                                                                    CGFloat(watermark.blue), 1]),
              let converted = color.converted(to: target, intent: .relativeColorimetric, options: nil),
              let c = converted.components, c.count >= 3 else { return fallback }
        return SIMD3<Float>(Float(c[0]), Float(c[1]), Float(c[2])).clamped(lowerBound: .zero, upperBound: .one)
    }

    /// The part of the text's box inside an image, in image pixels.
    func clipped(toWidth imageWidth: Int, height imageHeight: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        let x0 = max(x, 0), y0 = max(y, 0)
        let x1 = min(x + width, imageWidth), y1 = min(y + height, imageHeight)
        return x0 < x1 && y0 < y1 ? (x0, y0, x1, y1) : nil
    }

    /// A graphic's colour at index `i` of its box, 0...1; nil for text.
    @inline(__always) func colour(at i: Int) -> SIMD3<Float>? {
        guard let pixels else { return nil }
        return SIMD3<Float>(Float(pixels[i * 3]), Float(pixels[i * 3 + 1]), Float(pixels[i * 3 + 2])) / 255
    }

    /// Blends the text into RGBX pixels (8 or 16 bits per channel, native
    /// byte order, as `Exporter` packs them), in the file's encoding.
    func composite(into bytes: UnsafeMutableRawBufferPointer, imageWidth: Int, imageHeight: Int, bitsPerComponent: Int) {
        guard let box = clipped(toWidth: imageWidth, height: imageHeight) else { return }
        let bytesPerPixel = bitsPerComponent / 8 * 4
        guard bytes.count >= imageWidth * imageHeight * bytesPerPixel else { return }
        let alphaScale = opacity / 255
        if bitsPerComponent == 16 {
            let pixels = bytes.bindMemory(to: UInt16.self)
            let target = color * 65535
            for iy in box.y0..<box.y1 {
                let coverageRow = (iy - y) * width - x
                for ix in box.x0..<box.x1 {
                    let c = coverage[coverageRow + ix]
                    guard c > 0 else { continue }
                    let a = Float(c) * alphaScale, i = (iy * imageWidth + ix) * 4
                    let own = colour(at: coverageRow + ix).map { $0 * 65535 } ?? target
                    for k in 0..<3 {
                        let v = Float(pixels[i + k]) * (1 - a) + own[k] * a
                        pixels[i + k] = UInt16(min(max(v.rounded(), 0), 65535))
                    }
                }
            }
        } else {
            let target = color * 255
            for iy in box.y0..<box.y1 {
                let coverageRow = (iy - y) * width - x
                for ix in box.x0..<box.x1 {
                    let c = coverage[coverageRow + ix]
                    guard c > 0 else { continue }
                    let a = Float(c) * alphaScale, i = (iy * imageWidth + ix) * 4
                    let own = colour(at: coverageRow + ix).map { $0 * 255 } ?? target
                    for k in 0..<3 {
                        let v = Float(bytes[i + k]) * (1 - a) + own[k] * a
                        bytes[i + k] = UInt8(min(max(v.rounded(), 0), 255))
                    }
                }
            }
        }
    }

    /// A gain map with no gain where the text is solid, blended by its
    /// coverage. The text is drawn at SDR colour into the base image only,
    /// so without this an HDR screen would brighten it with whatever it
    /// covers. The map is half the image's size; each of its pixels takes
    /// the mean coverage of the 2x2 image pixels it stands for.
    func neutralising(_ map: GainMap, imageWidth: Int, imageHeight: Int) -> GainMap {
        guard let box = clipped(toWidth: imageWidth, height: imageHeight), map.maximumLog2 > map.minimumLog2 else { return map }
        let neutral = Float(255) * (0 - map.minimumLog2) / (map.maximumLog2 - map.minimumLog2)
        var pixels = map.pixels
        pixels.withUnsafeMutableBytes { bytes in
            for gy in (box.y0 / 2)..<min(map.height, (box.y1 + 1) / 2) {
                for gx in (box.x0 / 2)..<min(map.width, (box.x1 + 1) / 2) {
                    var sum = 0, count = 0
                    for iy in (gy * 2)..<min(gy * 2 + 2, imageHeight) {
                        for ix in (gx * 2)..<min(gx * 2 + 2, imageWidth) {
                            count += 1
                            let cx = ix - x, cy = iy - y
                            if cx >= 0, cy >= 0, cx < width, cy < height { sum += Int(coverage[cy * width + cx]) }
                        }
                    }
                    guard sum > 0, count > 0 else { continue }
                    let a = Float(sum) / Float(count) / 255 * opacity
                    let i = (gy * map.width + gx) * 4
                    for k in 0..<3 {
                        let v = Float(bytes[i + k]) * (1 - a) + neutral * a
                        bytes[i + k] = UInt8(min(max(v.rounded(), 0), 255))
                    }
                }
            }
        }
        return GainMap(width: map.width, height: map.height, pixels: pixels, headroom: map.headroom,
                       minimumLog2: map.minimumLog2, maximumLog2: map.maximumLog2)
    }
}

extension Exporter.EncodableImage {
    /// These pixels with `watermark` stamped in (its tokens already filled
    /// in), exactly as `Exporter.encodableImage` stamps it, gain map
    /// included; `colorSpace` is the one they were packed in. For the export
    /// sheet, which keeps one render made without a watermark and stamps a
    /// copy of it for each watermark tried, rather than rendering again.
    public func watermarked(_ watermark: ExportWatermark?, colorSpace: ColorKit.OutputSpace) throws -> Self {
        let w = image.width, h = image.height, bitsPerComponent = image.bitsPerComponent
        // The file's own space (a converted export's profile, say), which
        // is the render's for the others.
        guard let watermark,
              let placed = image.colorSpace.flatMap({ PlacedWatermark(watermark, imageWidth: w, imageHeight: h, space: $0) })
                ?? PlacedWatermark(watermark, imageWidth: w, imageHeight: h, colorSpace: colorSpace)
        else { return self }
        guard image.bitsPerPixel == bitsPerComponent * 4, image.bytesPerRow == w * bitsPerComponent / 2,
              let space = image.colorSpace, let source = image.dataProvider?.data else {
            throw ExportError.imageCreationFailed
        }
        // A copy made here: the provider's data can be the render's own
        // buffer, which bridging to `Data` doesn't copy before writing.
        guard let bytes = CFDataGetBytePtr(source) else { throw ExportError.imageCreationFailed }
        var data = Data(bytes: bytes, count: CFDataGetLength(source))
        data.withUnsafeMutableBytes { bytes in
            placed.composite(into: bytes, imageWidth: w, imageHeight: h, bitsPerComponent: bitsPerComponent)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let stamped = CGImage(width: w, height: h, bitsPerComponent: bitsPerComponent,
                                    bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: space,
                                    bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent) else {
            throw ExportError.imageCreationFailed
        }
        return Self(image: stamped, gainMap: gainMap.map { placed.neutralising($0, imageWidth: w, imageHeight: h) })
    }
}
