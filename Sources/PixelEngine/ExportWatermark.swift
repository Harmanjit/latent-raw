import Foundation
import CoreGraphics
import CoreText
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
/// the text, not the image.
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

    public static let defaultText = "© {year}"
    public static let tokens: [(token: String, meaning: String)] = [("{year}", "capture year"), ("{name}", "original name")]
    /// Size and opacity limits, for the sheet's sliders and for values
    /// read from a hand-edited preset.
    public static let sizeRange: ClosedRange<Float> = 0.01...0.2
    public static let opacityRange: ClosedRange<Float> = 0.05...1
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

    public init(text: String = ExportWatermark.defaultText, corner: Corner = .bottomRight, size: Float = 0.03,
                opacity: Float = 0.7, red: Float = 1, green: Float = 1, blue: Float = 1) {
        self.text = text; self.corner = corner; self.size = size; self.opacity = opacity
        self.red = red; self.green = green; self.blue = blue
    }

    // Lenient decoding, as ExportPreset's: a field missing from an older or
    // hand-edited preset takes its default, and numbers are held in range.
    enum CodingKeys: String, CodingKey { case text, corner, size, opacity, red, green, blue }
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
    }

    /// Whether there is anything to draw.
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
/// the text's box, where it goes, and its colour in the file's encoding.
struct PlacedWatermark {
    let width: Int
    let height: Int
    /// Row-major coverage, top row first, 0 (none) to 255 (solid).
    let coverage: [UInt8]
    let x: Int
    let y: Int
    /// The colour as the file's encoded components, 0...1.
    let color: SIMD3<Float>
    let opacity: Float

    init?(_ watermark: ExportWatermark, imageWidth: Int, imageHeight: Int, colorSpace: ColorKit.OutputSpace) {
        guard !watermark.isEmpty, imageWidth > 0, imageHeight > 0,
              let raster = Self.rasterise(watermark.text,
                                          fontSize: watermark.fontPixelSize(imageWidth: imageWidth, imageHeight: imageHeight))
        else { return nil }
        width = raster.width; height = raster.height; coverage = raster.coverage
        (x, y) = watermark.origin(textWidth: width, textHeight: height, imageWidth: imageWidth, imageHeight: imageHeight)
        color = Self.encodedColor(watermark, in: colorSpace)
        opacity = min(max(watermark.opacity, 0), 1)
    }

    /// The text as coverage: one line, the system font, grey-scale
    /// antialiasing (no subpixel smoothing, which would tint the edges).
    static func rasterise(_ text: String, fontSize: CGFloat) -> (width: Int, height: Int, coverage: [UInt8])? {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
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

    /// The sRGB colour in the file's space, as the components of the
    /// profile `Exporter` tags the file with.
    static func encodedColor(_ watermark: ExportWatermark, in space: ColorKit.OutputSpace) -> SIMD3<Float> {
        let fallback = SIMD3<Float>(watermark.red, watermark.green, watermark.blue)
        let name: CFString
        switch space {
        case .sRGB: return fallback
        case .displayP3: name = CGColorSpace.displayP3
        case .rec2020: name = CGColorSpace.itur_2020
        }
        guard let source = CGColorSpace(name: CGColorSpace.sRGB), let target = CGColorSpace(name: name),
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
                    for k in 0..<3 {
                        let v = Float(pixels[i + k]) * (1 - a) + target[k] * a
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
                    for k in 0..<3 {
                        let v = Float(bytes[i + k]) * (1 - a) + target[k] * a
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
