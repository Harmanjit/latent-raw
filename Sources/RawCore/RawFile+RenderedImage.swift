import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd
import os
import Accelerate

/// What Latent knows about an ordinary picture it opened: a JPEG, HEIC,
/// TIFF, PNG, WebP or AVIF rather than a raw. Such a file was already
/// developed by a camera, phone, scanner or another editor, so it arrives
/// display-referred: its values are what a screen shows, not what the
/// sensor measured.
public struct RenderedImageInfo: Sendable, Equatable {
    /// "JPEG", "HEIC", "TIFF"…, for the status bar and the info panel.
    public let format: String
    /// Bits per colour sample as stored: 8 for most JPEGs, 16 for a
    /// scanner's TIFF, 32 for a floating-point TIFF.
    public let bitsPerComponent: Int
    /// The embedded colour profile's name, nil when the file has none (it
    /// is then read as sRGB, as every browser and viewer reads it).
    public let profileName: String?

    public init(format: String, bitsPerComponent: Int, profileName: String?) {
        self.format = format
        self.bitsPerComponent = bitsPerComponent
        self.profileName = profileName
    }
}

/// The ordinary picture formats Latent catalogs and edits beside raws, and
/// the arithmetic that lets them into a pipeline built for raws.
///
/// **Where they enter.** A raw reaches the colour stage as linear camera
/// RGB, and a LinearRaw DNG (a Photo Merge result) joins it there as a
/// `LinearPlane`. A rendered picture takes the same door: ImageIO decodes
/// it, ColorSync converts it from its embedded profile to linear Rec.2020
/// (Latent's working space), and it travels as a linear source whose
/// "camera" is Rec.2020 itself, so the camera-to-working matrix is the
/// identity and the white balance starts at unit multipliers.
///
/// **Why its tones are unrolled.** The colour stage always ends in the
/// filmic sigmoid that turns scene light into display values. Fed a JPEG's
/// values as they are, that curve would be applied a second time and the
/// photo would open darker and harsher than it is. So each channel is run
/// backwards through the sigmoid at the default Contrast and grey point:
/// the default render then gives back the file's own pixels, and every
/// slider moves from there exactly as it does on a raw (Exposure brightens
/// in light, highlights roll off softly). White itself can't be unrolled,
/// the sigmoid only reaches 1.0 at infinite light, so the brightest values
/// are capped a hair below it (`maximumDisplayValue`), well under one step
/// of an 8-bit file.
public enum RenderedImageFormat {
    /// Extension (lowercase) to the format's display name. Extensions are
    /// listed here; whether this Mac's ImageIO decodes them decides
    /// `extensions` (WebP and AVIF arrived in later macOS releases).
    public static let formatNames: [String: String] = [
        "jpg": "JPEG", "jpeg": "JPEG", "jpe": "JPEG",
        "heic": "HEIC", "heif": "HEIF", "hif": "HEIF",
        "tif": "TIFF", "tiff": "TIFF",
        "png": "PNG",
        "webp": "WebP",
        "avif": "AVIF",
    ]

    /// The extensions this Mac can open as rendered images: those above
    /// whose type ImageIO lists as readable.
    public static let extensions: Set<String> = {
        let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        return Set(formatNames.keys.filter { ext in
            guard let type = UTType(filenameExtension: ext) else { return false }
            return readable.contains(type.identifier)
        })
    }()

    /// The extensions a camera writes beside its raw in RAW+JPEG (or
    /// RAW+HEIF) mode. The library treats such a file as the raw's
    /// companion (`RawJPEGPairs` in Catalog).
    public static let pairCompanionExtensions: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif", "hif"]

    /// Whether `path` names a file this decoder reads, by its extension.
    public static func handles(path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The format name for `path`'s extension, nil when it isn't one.
    public static func formatName(path: String) -> String? {
        formatNames[(path as NSString).pathExtension.lowercased()]
    }

    // MARK: - Tone unrolling

    /// The Contrast and grey point the inverse curve is solved for. They
    /// must equal `EditParameters`' defaults (PixelEngine checks this in a
    /// test), or a picture would not open looking like itself.
    public static let defaultContrast: Float = 1.5
    public static let defaultGreyPoint: Float = 0.1845

    /// The brightest display value unrolled. The sigmoid reaches 1.0 only at
    /// infinity, so white is capped at 1 - 1/1024: it comes back from the
    /// default render at 0.9990, which an 8-bit file stores as 255 and a
    /// 16-bit file within 0.1 % of full scale.
    public static let maximumDisplayValue: Float = 1 - 1.0 / 1024

    /// The scene-linear value the default sigmoid turns into display value
    /// `y` (linear, 0…1): the inverse of y = x^c / (x^c + k^c), which is
    /// x = k (y / (1 - y))^(1/c).
    @inline(__always)
    public static func sceneValue(display y: Float) -> Float {
        let clamped = min(max(y, 0), maximumDisplayValue)
        guard clamped > 0 else { return 0 }
        return defaultGreyPoint * powf(clamped / (1 - clamped), 1 / defaultContrast)
    }

    /// The default sigmoid itself (SDR, headroom 1), for checking the inverse.
    public static func displayValue(scene x: Float) -> Float {
        let xc = powf(max(x, 0), defaultContrast)
        let kc = powf(defaultGreyPoint, defaultContrast)
        return xc / (xc + kc)
    }

    // MARK: - Colour

    /// Linear Rec.2020 -> CIE XYZ (D65), as ColorKit has it. RawCore can't
    /// import ColorKit, so the published primaries are repeated here.
    static let rec2020ToXYZ = simd_float3x3(rows: [
        SIMD3(0.6369580, 0.1446169, 0.1688810),
        SIMD3(0.2627002, 0.6779981, 0.0593017),
        SIMD3(0.0000000, 0.0280727, 1.0609851),
    ])

    /// The "camera matrix" of a rendered image, in the Adobe ColorMatrix
    /// convention the pipeline expects (XYZ -> camera RGB, row-major). The
    /// camera is linear Rec.2020, so this is XYZ -> Rec.2020 and the
    /// camera-to-working matrix ColorKit builds from it is the identity.
    public static let cameraToXYZRowMajor: [Float] = {
        let m = rec2020ToXYZ.inverse
        return (0..<3).flatMap { row in (0..<3).map { col in m[col][row] } }
    }()

    // MARK: - Orientation

    /// An EXIF orientation (1…8) as a mirror the decoder bakes into the
    /// pixels and a LibRaw `flip` (0, 3, 5, 6) left for display, which is
    /// all the rest of Latent understands. EXIF's mirrored orientations are
    /// a horizontal mirror followed by a turn: 4 (mirrored vertically) is a
    /// mirror and a half turn, 5 (transposed) a mirror and a quarter turn
    /// anticlockwise, 7 (transversed) a mirror and a quarter turn clockwise.
    public static func orientation(exif: Int) -> (mirror: Bool, flip: Int) {
        switch exif {
        case 2: (true, 0)
        case 3: (false, 3)
        case 4: (true, 3)
        case 5: (true, 5)
        case 6: (false, 6)
        case 7: (true, 6)
        case 8: (false, 5)
        default: (false, 0)
        }
    }
}

public enum RenderedImageError: Error, CustomStringConvertible {
    case unreadable(path: String)
    case decodeFailed(path: String)

    public var description: String {
        switch self {
        case .unreadable(let path): "ImageIO cannot read \((path as NSString).lastPathComponent)"
        case .decodeFailed(let path): "\((path as NSString).lastPathComponent) could not be decoded"
        }
    }
}

extension RawFile {
    /// Opens a JPEG, HEIC, TIFF, PNG, WebP or AVIF through ImageIO as a
    /// linear source (see `RenderedImageFormat`). `metadataOnly` reads the
    /// summary without decoding a pixel, as the catalog wants.
    ///
    /// Decoding runs in this process, not the raw decoder service: ImageIO
    /// is the system's own decoder, the one Finder and Quick Look already
    /// run on these files, and the service exists to keep LibRaw at arm's
    /// length.
    convenience init(renderedImageAtPath path: String, metadataOnly: Bool) throws {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw RenderedImageError.unreadable(path: path)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let exifOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let (mirror, flip) = RenderedImageFormat.orientation(exif: exifOrientation)

        if metadataOnly {
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            guard width > 0, height > 0 else { throw RenderedImageError.unreadable(path: path) }
            let info = RenderedImageInfo(
                format: RenderedImageFormat.formatName(path: path) ?? "Image",
                bitsPerComponent: (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8,
                profileName: properties[kCGImagePropertyProfileName] as? String)
            let summary = Self.renderedSummary(width: width, height: height, flip: flip, properties: properties,
                                               url: url, info: info)
            self.init(decodedSummary: summary, cameraToXYZ: RenderedImageFormat.cameraToXYZRowMajor, linearPlane: nil)
            return
        }

        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceShouldAllowFloat: true]
        guard let image = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) else {
            throw RenderedImageError.decodeFailed(path: path)
        }
        let info = RenderedImageInfo(
            format: RenderedImageFormat.formatName(path: path) ?? "Image",
            bitsPerComponent: image.bitsPerComponent,
            profileName: image.colorSpace.flatMap { $0.name as String? }
                ?? properties[kCGImagePropertyProfileName] as? String)
        guard let plane = Self.linearPlane(from: image, mirror: mirror) else {
            throw RawFileError.planeAllocationFailed
        }
        let summary = Self.renderedSummary(width: image.width, height: image.height, flip: flip,
                                           properties: properties, url: url, info: info)
        self.init(decodedSummary: summary, cameraToXYZ: RenderedImageFormat.cameraToXYZRowMajor, linearPlane: plane)
    }

    /// The summary of a rendered image: its size, its orientation as a
    /// LibRaw flip, unit white balance, white at 1.0, and what its EXIF
    /// says about the camera and exposure.
    static func renderedSummary(width: Int, height: Int, flip: Int, properties: [CFString: Any],
                                url: URL, info: RenderedImageInfo) -> RawSummary {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func number(_ dict: [CFString: Any], _ key: CFString) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let list = dict[key] as? [NSNumber], let first = list.first { return first.doubleValue }
            return 0
        }
        func text(_ dict: [CFString: Any], _ key: CFString) -> String {
            (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        // EXIF dates carry no zone; LibRaw reads a raw's as local time, so
        // the same is done here and a RAW+JPEG pair sorts together. A file
        // with no date (a scan, a screenshot) takes its modification date.
        let stamp = text(exif, kCGImagePropertyExifDateTimeOriginal).isEmpty
            ? text(tiff, kCGImagePropertyTIFFDateTime) : text(exif, kCGImagePropertyExifDateTimeOriginal)
        let captureTime = exifDate(stamp)
            ?? ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            ?? Date(timeIntervalSince1970: 0)
        let lensMake = text(exif, kCGImagePropertyExifLensMake)
        return RawSummary(
            activeArea: SensorActiveArea(left: 0, top: 0, width: width, height: height,
                                         fullWidth: width, fullHeight: height),
            cfaPattern: .linearRGB,
            cameraMultipliers: (1, 1, 1, 1),
            blackLevel: 0, whiteLevel: 1, channelBlackLevels: .zero, dataMaximum: 1,
            baselineExposure: 0, mergeInfo: nil,
            cameraMake: text(tiff, kCGImagePropertyTIFFMake), cameraModel: text(tiff, kCGImagePropertyTIFFModel),
            lensModel: text(exif, kCGImagePropertyExifLensModel),
            iso: number(exif, kCGImagePropertyExifISOSpeedRatings),
            shutter: number(exif, kCGImagePropertyExifExposureTime),
            aperture: number(exif, kCGImagePropertyExifFNumber),
            focalLength: number(exif, kCGImagePropertyExifFocalLength),
            captureTime: captureTime, orientation: flip,
            lens: LensIdentity(make: lensMake, makerNotesName: "", makerLensID: 0, nikonLensID: 0, nikonLensType: 0,
                               minFocal: 0, maxFocal: 0, maxApertureAtMinFocal: 0, maxApertureAtMaxFocal: 0,
                               cropFactor: 0),
            renderedImage: info)
    }

    /// "2026:10:31 14:05:09" in this Mac's time zone, as LibRaw reads it.
    static func exifDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }

    /// Rows drawn and converted at a time. Each band is its own small
    /// bitmap, so a 45 MP picture never needs a whole Float32 copy of itself
    /// (720 MB) on the way to its 360 MB plane.
    static let renderedBandRows = 128

    /// Converts `image` from its own colour space to linear Rec.2020 with
    /// ColorSync, unrolls each channel through the default sigmoid, and
    /// writes the result into a new plane (mirrored when the orientation
    /// asks for it). Transparent areas are composited over white, as a
    /// viewer shows them. Nil when memory can't be found.
    static func linearPlane(from image: CGImage, mirror: Bool) -> LinearPlane? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
              let white = CGColor(colorSpace: space, components: [1, 1, 1, 1]) else { return nil }
        let width = image.width, height = image.height
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        // Values from an integer file are always finite; a floating-point
        // TIFF can hold anything, and NaN would survive the vector maths.
        let mayHoldNonFinite = image.bitmapInfo.contains(.floatComponents)
        let bandRows = renderedBandRows
        let bands = (height + bandRows - 1) / bandRows
        let failed = OSAllocatedUnfairLock(initialState: false)
        // CGImage is immutable and drawing it from several threads at once
        // is safe; the compiler can't know that of a CF type.
        nonisolated(unsafe) let image = image
        let plane = LinearPlane(width: width, height: height) { destination in
            // Each band writes only its own rows of the plane.
            nonisolated(unsafe) let destination = destination
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let top = band * bandRows
                let rows = min(bandRows, height - top)
                guard let context = CGContext(data: nil, width: width, height: rows, bitsPerComponent: 32,
                                              bytesPerRow: width * 16, space: space, bitmapInfo: bitmapInfo),
                      let data = context.data else {
                    failed.withLock { $0 = true }
                    return
                }
                context.setFillColor(white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: rows))
                context.interpolationQuality = .none
                // CG's origin is bottom left: placing the image this low
                // puts its rows top..<top+rows in the band, unscaled.
                context.draw(image, in: CGRect(x: 0, y: rows + top - height, width: width, height: height))
                let pixels = data.assumingMemoryBound(to: Float.self)
                var scratch = RowScratch(count: width * 4)
                for row in 0..<rows {
                    let source = pixels + row * width * 4
                    if mayHoldNonFinite { sanitise(source, count: width * 4) }
                    let target = destination.baseAddress! + (top + row) * width * 4
                    scratch.unroll(source, into: target, width: width, mirror: mirror)
                }
            }
        }
        guard let plane, !failed.withLock({ $0 }) else { return nil }
        return plane
    }
}

/// Replaces NaN and infinities with 0, in place.
private func sanitise(_ values: UnsafeMutablePointer<Float>, count: Int) {
    for i in 0..<count where !values[i].isFinite { values[i] = 0 }
}

/// Working rows for unrolling one row of RGBA at a time with vector maths:
/// a 45 MP picture is 135 million `powf`s, which one by one take seconds.
private struct RowScratch {
    var clamped: [Float]
    var denominator: [Float]
    var exponent: [Float]
    var mirrored: [Float]

    init(count: Int) {
        clamped = [Float](repeating: 0, count: count)
        denominator = [Float](repeating: 0, count: count)
        exponent = [Float](repeating: 1 / RenderedImageFormat.defaultContrast, count: count)
        mirrored = [Float](repeating: 0, count: count)
    }

    /// `RenderedImageFormat.sceneValue` over a row of `width` RGBA pixels
    /// (alpha set to 1), written to `target` as Float16, mirrored on request.
    mutating func unroll(_ source: UnsafeMutablePointer<Float>, into target: UnsafeMutablePointer<Float16>,
                         width: Int, mirror: Bool) {
        let count = width * 4
        var n = Int32(count)
        var low: Float = 0, high = RenderedImageFormat.maximumDisplayValue
        var minusOne: Float = -1, one: Float = 1, grey = RenderedImageFormat.defaultGreyPoint
        clamped.withUnsafeMutableBufferPointer { y in
            denominator.withUnsafeMutableBufferPointer { d in
                exponent.withUnsafeBufferPointer { e in
                    // y clamped to [0, max]; d = 1 - y; y = y / d; y = y^(1/c); y *= k.
                    vDSP_vclip(source, 1, &low, &high, y.baseAddress!, 1, vDSP_Length(count))
                    vDSP_vsmsa(y.baseAddress!, 1, &minusOne, &one, d.baseAddress!, 1, vDSP_Length(count))
                    vvdivf(y.baseAddress!, y.baseAddress!, d.baseAddress!, &n)
                    vvpowf(y.baseAddress!, e.baseAddress!, y.baseAddress!, &n)
                    vDSP_vsmul(y.baseAddress!, 1, &grey, y.baseAddress!, 1, vDSP_Length(count))
                }
            }
            for x in 0..<width { y[x * 4 + 3] = 1 }
        }
        if mirror {
            for x in 0..<width {
                for c in 0..<4 { mirrored[(width - 1 - x) * 4 + c] = clamped[x * 4 + c] }
            }
            swap(&mirrored, &clamped)
        }
        clamped.withUnsafeMutableBufferPointer { y in
            var from = vImage_Buffer(data: y.baseAddress, height: 1, width: vImagePixelCount(count),
                                     rowBytes: count * MemoryLayout<Float>.size)
            var to = vImage_Buffer(data: target, height: 1, width: vImagePixelCount(count),
                                   rowBytes: count * MemoryLayout<Float16>.size)
            vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageDoNotTile))
        }
    }
}

private extension simd_float3x3 {
    init(rows: [SIMD3<Float>]) {
        self = simd_float3x3(rows: rows[0], rows[1], rows[2])
    }

    init(rows r0: SIMD3<Float>, _ r1: SIMD3<Float>, _ r2: SIMD3<Float>) {
        self = simd_float3x3(columns: (SIMD3(r0.x, r1.x, r2.x), SIMD3(r0.y, r1.y, r2.y), SIMD3(r0.z, r1.z, r2.z)))
    }
}
