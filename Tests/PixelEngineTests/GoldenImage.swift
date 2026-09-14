import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A 16-bit RGB image as plain numbers, so two renders can be compared
/// sample by sample. Golden references are stored as 16-bit PNGs: exact
/// for this data, and GitHub shows PNG changes side by side in a diff.
struct GoldenImage: Equatable {
    let width: Int
    let height: Int
    /// R, G, B per pixel, row-major.
    var samples: [UInt16]
    let colorSpace: CGColorSpace

    /// Pixels only; the colour space is checked separately, so a failure
    /// can say which of the two is wrong.
    static func == (a: GoldenImage, b: GoldenImage) -> Bool {
        a.width == b.width && a.height == b.height && a.samples == b.samples
    }

    /// Same numbers in a different colour space are a different picture:
    /// a P3 export tagged sRGB looks wrong everywhere. A PNG read back has
    /// an ICC-based space with no name, so profiles are compared by bytes.
    func hasSameColourSpace(as other: GoldenImage) -> Bool {
        if let a = colorSpace.name, let b = other.colorSpace.name, a == b { return true }
        guard let a = colorSpace.copyICCData(), let b = other.colorSpace.copyICCData() else { return false }
        return (a as Data) == (b as Data)
    }

    var colourSpaceDescription: String {
        colorSpace.name.map { $0 as String } ?? (colorSpace.copyICCData().map { "ICC profile, \(CFDataGetLength($0)) bytes" } ?? "unknown")
    }

    init(width: Int, height: Int, samples: [UInt16], colorSpace: CGColorSpace) {
        self.width = width; self.height = height; self.samples = samples; self.colorSpace = colorSpace
    }

    /// Reads any CGImage by drawing it, unscaled, into a 16-bit context in
    /// the image's own colour space, so no colour conversion happens.
    init(_ image: CGImage) throws {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let w = image.width, h = image.height
        var rgbx = [UInt16](repeating: 0, count: w * h * 4)
        let drawn = rgbx.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw GoldenImageError.unreadable }
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = UInt16(littleEndian: rgbx[i * 4])
            rgb[i * 3 + 1] = UInt16(littleEndian: rgbx[i * 4 + 1])
            rgb[i * 3 + 2] = UInt16(littleEndian: rgbx[i * 4 + 2])
        }
        self.init(width: w, height: h, samples: rgb, colorSpace: space)
    }

    init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GoldenImageError.unreadable
        }
        try self.init(image)
    }

    func cgImage() throws -> CGImage {
        var rgbx = [UInt16](repeating: 0xFFFF, count: width * height * 4)
        for i in 0..<(width * height) {
            rgbx[i * 4] = samples[i * 3].littleEndian
            rgbx[i * 4 + 1] = samples[i * 3 + 1].littleEndian
            rgbx[i * 4 + 2] = samples[i * 3 + 2].littleEndian
        }
        let data = rgbx.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                         | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw GoldenImageError.unwritable }
        return image
    }

    func writePNG(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw GoldenImageError.unwritable }
        CGImageDestinationAddImage(destination, try cgImage(), nil)
        guard CGImageDestinationFinalize(destination) else { throw GoldenImageError.unwritable }
    }
}

enum GoldenImageError: Error { case unreadable, unwritable }

/// How far one render is from another, in fractions of full scale.
struct GoldenDifference {
    /// Mean absolute difference over every sample. Catches broad shifts:
    /// exposure, white balance, a tone curve.
    let meanAbsolute: Double
    /// The 99.9th percentile of each pixel's largest channel difference.
    /// Catches local changes (a heal patch, a mask edge, sharpening) too
    /// small to move the mean, while ignoring a handful of stray pixels.
    let p999: Double
    let maximum: Double
    /// |expected - actual|, amplified so small drifts are visible.
    let visualisation: GoldenImage

    init?(_ expected: GoldenImage, _ actual: GoldenImage, amplification: Double = 8) {
        guard expected.width == actual.width, expected.height == actual.height else { return nil }
        let pixels = expected.width * expected.height
        guard pixels > 0 else { return nil }
        var total = 0.0
        var perPixel = [UInt16](repeating: 0, count: pixels)
        var vis = [UInt16](repeating: 0, count: pixels * 3)
        for p in 0..<pixels {
            var largest: UInt16 = 0
            for c in 0..<3 {
                let a = expected.samples[p * 3 + c], b = actual.samples[p * 3 + c]
                let d = a > b ? a - b : b - a
                total += Double(d)
                largest = max(largest, d)
                vis[p * 3 + c] = UInt16(min(Double(d) * amplification, 65535))
            }
            perPixel[p] = largest
        }
        perPixel.sort()
        meanAbsolute = total / Double(pixels * 3) / 65535
        p999 = Double(perPixel[min(pixels - 1, Int(Double(pixels) * 0.999))]) / 65535
        maximum = Double(perPixel.last ?? 0) / 65535
        visualisation = GoldenImage(width: expected.width, height: expected.height, samples: vis,
                                    colorSpace: expected.colorSpace)
    }
}
