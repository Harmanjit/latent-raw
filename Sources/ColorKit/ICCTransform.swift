import Foundation
import ColorSync
import CoreGraphics

/// An ICC profile read once: its bytes, ColorSync's handle on them and
/// the number of channels its device space has (3 for RGB, 4 for CMYK,
/// 1 for grey).
public struct ICCProfile: @unchecked Sendable {
    public let data: Data
    public let colorSpace: CGColorSpace
    public let channels: Int
    let profile: ColorSyncProfile

    public init?(data: Data) {
        guard let space = CGColorSpace(iccData: data as CFData),
              let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue() else { return nil }
        self.data = data
        colorSpace = space
        channels = space.numberOfComponents
        self.profile = profile
    }

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    public init?(colorSpace: CGColorSpace) {
        guard let data = colorSpace.copyICCData() as Data? else { return nil }
        self.init(data: data)
    }

    /// Latent's working space, linear Rec.2020, as a profile ColorSync can
    /// chain with a printer's. The non-extended form: an extended-range
    /// profile confuses ColorSync's handling of black and white.
    public static let linearRec2020: ICCProfile? = CGColorSpace(name: CGColorSpace.linearITUR_2020)
        .flatMap { ICCProfile(colorSpace: $0) }
}

/// Colour conversions between ICC profiles through ColorSync, with the
/// rendering intent chosen per conversion.
///
/// Black point compensation is done here rather than by ColorSync: its
/// own BPC flag, tried with Latent's linear working profile, moved white
/// as well as black. The working space's black is exactly zero, so BPC
/// into a destination reduces to one linear rescale of linear light,
/// `k + (1 - k) v`, where `k` is the luminance of the deepest black the
/// destination can make. That is the Adobe BPC algorithm for a source
/// whose black point is zero, with the black point taken as neutral.
public enum ICCTransform {
    /// The intents a single conversion can use. Absolute colorimetric
    /// keeps the destination's paper white as a colour of its own, which
    /// is what simulating paper on screen needs.
    public enum Intent: Sendable {
        case perceptual, relativeColorimetric, absoluteColorimetric

        public init(_ intent: RenderingIntent) {
            switch intent {
            case .perceptual: self = .perceptual
            case .relativeColorimetric: self = .relativeColorimetric
            }
        }

        var colorSync: CFString {
            switch self {
            case .perceptual: ICCTransform.constant("kColorSyncRenderingIntentPerceptual")
            case .relativeColorimetric: ICCTransform.constant("kColorSyncRenderingIntentRelative")
            case .absoluteColorimetric: ICCTransform.constant("kColorSyncRenderingIntentAbsolute")
            }
        }
    }

    public enum TransformError: Error, CustomStringConvertible {
        case transformUnavailable
        case conversionFailed
        public var description: String {
            switch self {
            case .transformUnavailable: "ColorSync could not build a transform between the profiles"
            case .conversionFailed: "ColorSync could not convert the colours"
            }
        }
    }

    /// One of ColorSync's CFString constants, looked up by symbol name.
    /// Swift 6 refuses to read imported C globals declared as `var`, which
    /// these are; the symbol's value is the same string either way. Each
    /// constant's value is its own name without the leading "k", the
    /// fallback should the lookup ever fail.
    static func constant(_ symbol: String) -> CFString {
        // RTLD_DEFAULT: search every image loaded into the process.
        if let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) {
            return address.load(as: Unmanaged<CFString>.self).takeUnretainedValue()
        }
        return String(symbol.dropFirst()) as CFString
    }

    static func makeTransform(from source: ICCProfile, to destination: ICCProfile,
                              intent: Intent) throws -> ColorSyncTransform {
        let profileKey = constant("kColorSyncProfile") as String
        let intentKey = constant("kColorSyncRenderingIntent") as String
        let tagKey = constant("kColorSyncTransformTag") as String
        let sequence: [[String: Any]] = [
            [profileKey: source.profile, intentKey: intent.colorSync,
             tagKey: constant("kColorSyncTransformDeviceToPCS")],
            [profileKey: destination.profile, intentKey: intent.colorSync,
             tagKey: constant("kColorSyncTransformPCSToDevice")],
        ]
        guard let transform = ColorSyncTransformCreate(sequence as CFArray, nil)?.takeRetainedValue() else {
            throw TransformError.transformUnavailable
        }
        return transform
    }

    /// Converts packed float pixels (`source.channels` values each, no
    /// alpha) into `destination`'s device values.
    public static func convert(_ pixels: [Float], from source: ICCProfile, to destination: ICCProfile,
                               intent: Intent) throws -> [Float] {
        let transform = try makeTransform(from: source, to: destination, intent: intent)
        let count = pixels.count / max(source.channels, 1)
        guard count > 0 else { return [] }
        var input = pixels
        var output = [Float](repeating: 0, count: count * destination.channels)
        let layout = kColorSyncAlphaNone.rawValue | UInt32(kColorSyncByteOrderDefault)
        let ok = input.withUnsafeMutableBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                ColorSyncTransformConvert(transform, count, 1,
                                          outBytes.baseAddress!, kColorSync32BitFloat, layout,
                                          count * destination.channels * 4,
                                          inBytes.baseAddress!, kColorSync32BitFloat, layout,
                                          count * source.channels * 4, nil)
            }
        }
        guard ok else { throw TransformError.conversionFailed }
        return output
    }

    /// The luminance, in linear working-space units (white = 1), of the
    /// deepest black `profile` can reproduce: working black sent into it
    /// and back relative colorimetrically. Zero for a display space.
    public static func blackPoint(of profile: ICCProfile) -> Float {
        guard let working = ICCProfile.linearRec2020,
              let device = try? convert([0, 0, 0], from: working, to: profile, intent: .relativeColorimetric),
              let back = try? convert(device.map { min(max($0, 0), 1) }, from: profile, to: working,
                                      intent: .relativeColorimetric),
              back.count == 3 else { return 0 }
        let y = 0.2627 * back[0] + 0.6780 * back[1] + 0.0593 * back[2]
        // A profile claiming a black brighter than a fifth of white is
        // broken, not a paper; don't let it wash the image out.
        return min(max(y, 0), 0.2)
    }

    /// Black point compensation into a destination whose black is `k`:
    /// working black lands on the destination's black, white stays white.
    @inline(__always)
    public static func compressBlack(_ v: Float, blackPoint k: Float) -> Float { k + (1 - k) * v }

    /// The inverse, from a destination whose black is `k` back to the
    /// working space, so the destination's black shows as screen black.
    @inline(__always)
    public static func expandBlack(_ v: Float, blackPoint k: Float) -> Float { k >= 1 ? v : (v - k) / (1 - k) }
}

/// Whole images converted into an ICC profile with a chosen intent: what
/// printing into a printer or paper profile uses.
public enum ICCImageConversion {
    /// Rows converted at a time. A sheet-sized print render is tens of
    /// megapixels; one float copy of it would be hundreds of megabytes.
    public static let stripRows = 128

    /// `image` converted into `space` with `intent`: 16 bits for RGB and
    /// grey profiles, 8 for CMYK (all Core Graphics draws CMYK at). Nil for
    /// a space a bitmap can't use or a profile ColorSync can't chain.
    ///
    /// The image is first drawn into linear Rec.2020 (a colorimetric step
    /// that loses nothing: the working space contains any render), where
    /// black point compensation is a rescale; ColorSync then makes the
    /// one conversion that applies the intent.
    public static func convert(_ image: CGImage, to space: CGColorSpace, intent: RenderingIntent) -> CGImage? {
        let bits: Int
        let info: CGBitmapInfo
        let depth: ColorSyncDataDepth
        let layout: ColorSyncDataLayout
        switch space.model {
        case .rgb:
            bits = 16
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            depth = kColorSync16BitInteger
            layout = kColorSyncAlphaNoneSkipLast.rawValue | UInt32(kColorSyncByteOrder16Little)
        case .monochrome:
            bits = 16
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            depth = kColorSync16BitInteger
            layout = kColorSyncAlphaNone.rawValue | UInt32(kColorSyncByteOrder16Little)
        case .cmyk:
            bits = 8
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            depth = kColorSync8BitInteger
            layout = kColorSyncAlphaNone.rawValue | UInt32(kColorSyncByteOrderDefault)
        default:
            return nil
        }
        guard let working = ICCProfile.linearRec2020,
              let workingSpace = CGColorSpace(name: CGColorSpace.linearITUR_2020),
              let destination = ICCProfile(colorSpace: space),
              let transform = try? ICCTransform.makeTransform(from: working, to: destination,
                                                              intent: ICCTransform.Intent(intent)) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let output = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits,
                                     bytesPerRow: 0, space: space, bitmapInfo: info.rawValue),
              let outputBase = output.data else { return nil }
        let outputRowBytes = output.bytesPerRow
        let stripInfo = CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue
                                     | CGImageAlphaInfo.noneSkipLast.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        let rows = min(stripRows, height)
        guard let strip = CGContext(data: nil, width: width, height: rows, bitsPerComponent: 32,
                                    bytesPerRow: width * 16, space: workingSpace,
                                    bitmapInfo: stripInfo.rawValue),
              let stripBase = strip.data else { return nil }
        strip.interpolationQuality = .none
        let blackPoint = intent.usesBlackPointCompensation ? ICCTransform.blackPoint(of: destination) : 0
        let floats = stripBase.bindMemory(to: Float.self, capacity: width * rows * 4)
        let floatLayout = kColorSyncAlphaNoneSkipLast.rawValue | UInt32(kColorSyncByteOrderDefault)

        var top = 0
        while top < height {
            let count = min(rows, height - top)
            strip.clear(CGRect(x: 0, y: 0, width: width, height: rows))
            // Bitmap row 0 is the top of the context: place the image so its
            // row `top` lands there.
            strip.draw(image, in: CGRect(x: 0, y: CGFloat(rows - (height - top)), width: CGFloat(width),
                                         height: CGFloat(height)))
            if blackPoint > 0 {
                for i in 0..<(width * count * 4) where i % 4 != 3 {
                    floats[i] = ICCTransform.compressBlack(max(floats[i], 0), blackPoint: blackPoint)
                }
            }
            let ok = ColorSyncTransformConvert(transform, width, count,
                                               outputBase.advanced(by: top * outputRowBytes), depth, layout,
                                               outputRowBytes,
                                               stripBase, kColorSync32BitFloat, floatLayout, width * 16, nil)
            guard ok else { return nil }
            top += count
        }
        return output.makeImage()
    }
}
