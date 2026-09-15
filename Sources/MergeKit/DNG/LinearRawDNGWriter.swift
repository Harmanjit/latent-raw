// Writes a merge's result: a half-float LinearRaw DNG.

import CoreGraphics
import Foundation
import PixelEngine

/// How the main image's tiles are stored.
public enum DNGTileCompression: Sendable, Equatable {
    /// Raw half floats. The v1 default: a 45 MP merge is about 270 MB and
    /// writes in a fraction of a second.
    case none
    /// zlib deflate after a floating-point predictor (`FloatDeflate`).
    /// Smaller and much slower to write; tiles only, never strips.
    case deflate(FloatPredictor)
}

/// What a finished write produced.
public struct MergeDNGWriteResult: Sendable, Equatable {
    /// Where the file is, symbolic links resolved.
    public let url: URL
    public let byteCount: Int
    /// How far the pixels were divided to fit under 1.0.
    public let normalisation: ExposureNormalisation
    /// The recipe as stored in the file: `clipLevel` and `baselineShift`
    /// describe the stored pixels. Write this one to the sidecar.
    public let recipe: MergeRecipe
    /// The BaselineExposure written: the metadata's plus the shift.
    public let baselineExposure: Double
}

/// Writes a merged image as a DNG that Latent (through LibRaw), Apple's
/// RAW engine and other raw converters open like a camera raw.
///
/// **The file** (see docs/PhotoMerge.md, "shared contract"):
/// - IFD0: an 8-bit RGB thumbnail, plus the camera, colour and exposure
///   tags (`MergeDNGMetadata`), the XMP packet holding the `latent:Merge`
///   recipe, and pointers to the SubIFDs and the EXIF IFD.
/// - SubIFD 0: the image. *LinearRaw* (photometric interpretation 34892)
///   means already demosaiced, three samples per pixel, linear in light.
///   Each sample is a 16-bit IEEE half float (SampleFormat 3), cut into
///   512 x 512 tiles.
/// - SubIFD 1: a JPEG preview, about 1600 px on the long edge.
///
/// **Why tiles.** The image is split into squares, each written as one run
/// of bytes, and the directory lists where every tile starts. A reader can
/// decode tiles independently (in parallel, or only the ones it needs), and
/// the writer only ever holds one: tiles along the right and bottom edges
/// are padded with zeros to full size, as TIFF requires.
///
/// **Why WhiteLevel is 1 and values stay at or below 1.0.** WhiteLevel
/// tells a reader which value is "fully exposed". Float data is already in
/// those units, so 1 is the honest value; without the tag, Apple's reader
/// rendered the spike's files black. And Apple's engine clips any sample
/// above 1.0, so the writer divides the pixels by a power of two and adds
/// the stops back as BaselineExposure (`ExposureNormalisation`).
///
/// **Safety.** The file is written under a temporary name and only moved
/// into place once complete (`SafeFileWriter`), so a crash, a thrown pixel
/// source or a cancelled task never leaves a half-written DNG under the
/// real name. Free disk space is checked first.
public struct LinearRawDNGWriter: Sendable {
    /// Tile edge in pixels: a multiple of 16.
    public var tileSize: Int
    public var compression: DNGTileCompression
    /// Long edge of the JPEG preview.
    public var previewLongEdge: Int
    /// Long edge of the IFD0 thumbnail.
    public var thumbnailLongEdge: Int
    /// Bytes that must still be free on the volume after the file is
    /// written, so a merge never fills the disk to the last byte.
    public var freeSpaceMargin: Int64
    /// Free space on the volume holding a URL; replaceable for tests.
    var availableCapacity: @Sendable (URL) -> Int64? = LinearRawDNGWriter.volumeAvailableCapacity

    public init(tileSize: Int = 512, compression: DNGTileCompression = .none,
                previewLongEdge: Int = 1600, thumbnailLongEdge: Int = 256,
                freeSpaceMargin: Int64 = 64_000_000) {
        self.tileSize = tileSize
        self.compression = compression
        self.previewLongEdge = previewLongEdge
        self.thumbnailLongEdge = thumbnailLongEdge
        self.freeSpaceMargin = freeSpaceMargin
    }

    /// Writes the DNG to `url`.
    ///
    /// - Parameters:
    ///   - pixels: the merged image, in the merge's own units.
    ///   - maximum: the largest red, green or blue value in `pixels`, which
    ///     the merge knows (or `ExposureNormalisation.maximum(of:)` measures).
    ///     A sample still above 1.0 after dividing stops the write.
    ///   - metadata: the reference frame's camera and colour tags.
    ///   - recipe: in the merge's units; the writer rescales `clipLevel` and
    ///     sets `baselineShift` (see `MergeRecipe.normalised(by:)`).
    ///   - preview: the merge rendered for display, unrotated; the JPEG
    ///     preview and the thumbnail are resampled from it.
    ///   - replacingExisting: false (a merge's usual case) makes a file that
    ///     appears under the name meanwhile throw
    ///     `SafeFileWriter.DestinationExists`, so the caller picks another name.
    public func write(_ pixels: LinearRawPixelSource, maximum: Float, metadata: MergeDNGMetadata,
                      recipe: MergeRecipe, preview: CGImage, to url: URL,
                      replacingExisting: Bool = false) throws -> MergeDNGWriteResult {
        let normalisation = try ExposureNormalisation(maximum: maximum)
        // Half floats top out at 65504, under 2^16: a larger maximum can't
        // describe these pixels, and dividing by more would round them to 0.
        guard normalisation.shift <= 16 else { throw MergeDNGError.invalidMaximum(maximum) }
        let storedRecipe = recipe.normalised(by: normalisation)
        var layout = try TIFFLayout(topLevel: [
            try makeFile(pixels, normalisation: normalisation, metadata: metadata,
                         recipe: storedRecipe, preview: preview),
        ])
        try checkFreeSpace(needed: Int64(layout.maximumFileSize), at: url)

        let pending = try SafeFileWriter.begin(url)
        defer { pending.discard() }
        let byteCount = try Self.write(&layout, toNewFileAt: pending.url)
        try pending.commit(replacingExisting: replacingExisting)
        return MergeDNGWriteResult(url: pending.destination, byteCount: byteCount, normalisation: normalisation,
                                   recipe: storedRecipe,
                                   baselineExposure: normalisation.storedBaselineExposure(metadata.baselineExposure))
    }

    /// Creates `url` (it must not exist) and writes the laid-out file into it.
    static func write(_ layout: inout TIFFLayout, toNewFileAt url: URL) throws -> Int {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var sink = FileSink(descriptor: descriptor)
        return try layout.write(to: &sink)
    }

    // MARK: - Free space

    func checkFreeSpace(needed fileBytes: Int64, at url: URL) throws {
        guard let available = availableCapacity(url) else { return } // unknown: let the write find out
        let needed = fileBytes + freeSpaceMargin
        guard available >= needed else { throw MergeDNGError.insufficientDiskSpace(needed: needed, available: available) }
    }

    /// The space macOS would free up for something the user asked for
    /// ("important usage": purgeable caches count as free), falling back to
    /// the plain figure on volumes that don't report it.
    static func volumeAvailableCapacity(at url: URL) -> Int64? {
        let folder = url.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: - Building the directories

    /// IFD0 with everything under it.
    func makeFile(_ pixels: LinearRawPixelSource, normalisation: ExposureNormalisation,
                  metadata: MergeDNGMetadata, recipe: MergeRecipe, preview: CGImage) throws -> TIFFDirectory {
        guard pixels.width > 0, pixels.height > 0,
              pixels.width <= Int(UInt32.max), pixels.height <= Int(UInt32.max) else {
            throw MergeDNGError.invalidDimensions(width: pixels.width, height: pixels.height)
        }
        guard tileSize >= 16, tileSize % 16 == 0, tileSize <= 1 << 15 else {
            throw MergeDNGError.invalidTileSize(tileSize)
        }
        let tags = try DNGTagValues(metadata: metadata, normalisation: normalisation,
                                    width: pixels.width, height: pixels.height)
        let previews = try DNGPreviewImages(image: preview, thumbnailLongEdge: thumbnailLongEdge,
                                            previewLongEdge: previewLongEdge)
        let xmp = try MergeXMP.packet(for: recipe)

        var ifd0 = TIFFDirectory()
        ifd0.set(TIFFTag.newSubfileType, long: 1) // 1: a reduced-size version of the main image
        let thumb = previews.thumbnail
        ifd0.set(TIFFTag.imageWidth, long: UInt32(thumb.width))
        ifd0.set(TIFFTag.imageLength, long: UInt32(thumb.height))
        ifd0.set(TIFFTag.bitsPerSample, .shorts([8, 8, 8]))
        ifd0.set(TIFFTag.compression, short: 1)
        ifd0.set(TIFFTag.photometricInterpretation, short: 2) // RGB
        ifd0.set(TIFFTag.samplesPerPixel, short: 3)
        ifd0.set(TIFFTag.planarConfiguration, short: 1)       // RGBRGB..., not all reds then all greens
        ifd0.set(TIFFTag.rowsPerStrip, long: UInt32(thumb.height))
        ifd0.set(TIFFTag.stripOffsets, .imageChunkOffsets)
        ifd0.set(TIFFTag.stripByteCounts, .imageChunkByteCounts)
        ifd0.imageData = Self.singleChunk(thumb.rgb)

        ifd0.set(TIFFTag.make, ascii: tags.make)
        ifd0.set(TIFFTag.model, ascii: tags.model)
        ifd0.set(TIFFTag.orientation, short: metadata.orientation)
        ifd0.set(TIFFTag.software, ascii: tags.software)
        ifd0.set(TIFFTag.dateTime, ascii: tags.modificationDate)
        ifd0.set(TIFFTag.subIFDs, .directories([
            makeRawImage(pixels, normalisation: normalisation, defaultCrop: tags.defaultCrop),
            Self.makePreview(previews.jpeg),
        ]))
        ifd0.set(TIFFTag.xmp, .bytes(Array(xmp.utf8)))
        ifd0.set(TIFFTag.exifIFD, .directories([Self.makeExif(tags)]))

        // DNG 1.4 is the first version with floating-point samples, so no
        // older reader is told it can open the file.
        ifd0.set(TIFFTag.dngVersion, .bytes([1, 4, 0, 0]))
        ifd0.set(TIFFTag.dngBackwardVersion, .bytes([1, 4, 0, 0]))
        ifd0.set(TIFFTag.uniqueCameraModel, ascii: tags.uniqueCameraModel)
        ifd0.set(TIFFTag.colorMatrix1, .srationals(tags.colorMatrix1))
        ifd0.set(TIFFTag.asShotNeutral, .rationals(tags.asShotNeutral))
        ifd0.set(TIFFTag.baselineExposure, .srationals([tags.baselineExposure]))
        ifd0.set(TIFFTag.calibrationIlluminant1, short: 21) // D65: the light ColorMatrix1 was measured under
        return ifd0
    }

    /// SubIFD 0: the tiled half-float image.
    func makeRawImage(_ pixels: LinearRawPixelSource, normalisation: ExposureNormalisation,
                      defaultCrop: PixelRegion) -> TIFFDirectory {
        var ifd = TIFFDirectory()
        ifd.set(TIFFTag.newSubfileType, long: 0) // 0: the main image
        ifd.set(TIFFTag.imageWidth, long: UInt32(pixels.width))
        ifd.set(TIFFTag.imageLength, long: UInt32(pixels.height))
        ifd.set(TIFFTag.bitsPerSample, .shorts([16, 16, 16]))
        ifd.set(TIFFTag.sampleFormat, .shorts([3, 3, 3]))            // 3: IEEE floating point
        ifd.set(TIFFTag.photometricInterpretation, short: 34892)     // LinearRaw
        ifd.set(TIFFTag.samplesPerPixel, short: 3)
        ifd.set(TIFFTag.planarConfiguration, short: 1)
        // One value per sample, as DNG specifies. Black is 0 because the
        // merge already subtracted each frame's black level.
        ifd.set(TIFFTag.blackLevel, .rationals(Array(repeating: TIFFRational(0, 1), count: 3)))
        ifd.set(TIFFTag.whiteLevel, .longs([1, 1, 1]))
        ifd.set(TIFFTag.defaultCropOrigin, .longs([UInt32(defaultCrop.x), UInt32(defaultCrop.y)]))
        ifd.set(TIFFTag.defaultCropSize, .longs([UInt32(defaultCrop.width), UInt32(defaultCrop.height)]))
        switch compression {
        case .none:
            ifd.set(TIFFTag.compression, short: 1)
        case .deflate(let predictor):
            ifd.set(TIFFTag.compression, short: 8)
            ifd.set(TIFFTag.predictor, short: predictor.rawValue)
        }
        ifd.set(TIFFTag.tileWidth, long: UInt32(tileSize))
        ifd.set(TIFFTag.tileLength, long: UInt32(tileSize))
        ifd.set(TIFFTag.tileOffsets, .imageChunkOffsets)
        ifd.set(TIFFTag.tileByteCounts, .imageChunkByteCounts)
        ifd.imageData = DNGTileStream(pixels: pixels, tileSize: tileSize, normalisation: normalisation,
                                      compression: compression).imageData
        return ifd
    }

    /// SubIFD 1: the JPEG preview.
    static func makePreview(_ jpeg: DNGPreviewImages.JPEG) -> TIFFDirectory {
        var ifd = TIFFDirectory()
        ifd.set(TIFFTag.newSubfileType, long: 1)
        ifd.set(TIFFTag.imageWidth, long: UInt32(jpeg.width))
        ifd.set(TIFFTag.imageLength, long: UInt32(jpeg.height))
        ifd.set(TIFFTag.bitsPerSample, .shorts([8, 8, 8]))
        ifd.set(TIFFTag.compression, short: 7)                // JPEG
        ifd.set(TIFFTag.photometricInterpretation, short: 6)  // YCbCr, as JPEG stores colour
        ifd.set(TIFFTag.samplesPerPixel, short: 3)
        ifd.set(TIFFTag.planarConfiguration, short: 1)
        ifd.set(TIFFTag.rowsPerStrip, long: UInt32(jpeg.height))
        ifd.set(TIFFTag.stripOffsets, .imageChunkOffsets)
        ifd.set(TIFFTag.stripByteCounts, .imageChunkByteCounts)
        ifd.set(TIFFTag.previewColorSpace, long: 1)           // sRGB
        ifd.imageData = singleChunk(Array(jpeg.data))
        return ifd
    }

    /// The EXIF IFD: how the reference frame was exposed.
    static func makeExif(_ tags: DNGTagValues) -> TIFFDirectory {
        var ifd = TIFFDirectory()
        ifd.set(TIFFTag.exifVersion, .undefined(Array("0231".utf8)))
        if let date = tags.captureDate { ifd.set(TIFFTag.dateTimeOriginal, ascii: date) }
        if let v = tags.exposureTime { ifd.set(TIFFTag.exposureTime, .rationals([v])) }
        if let v = tags.fNumber { ifd.set(TIFFTag.fNumber, .rationals([v])) }
        if let v = tags.iso { ifd.set(TIFFTag.isoSpeedRatings, short: v) }
        if let v = tags.focalLength { ifd.set(TIFFTag.focalLength, .rationals([v])) }
        if let v = tags.lensSpecification { ifd.set(TIFFTag.lensSpecification, .rationals(v)) }
        if let v = tags.lensMake { ifd.set(TIFFTag.lensMake, ascii: v) }
        if let v = tags.lensModel { ifd.set(TIFFTag.lensModel, ascii: v) }
        return ifd
    }

    static func singleChunk(_ bytes: [UInt8]) -> TIFFImageData {
        TIFFImageData(chunkCount: 1, maximumByteCount: bytes.count) { emit in
            try bytes.withUnsafeBytes { try emit($0) }
        }
    }
}

/// The metadata turned into tag values, with everything that could make an
/// invalid file checked, so a bad value becomes an error before any byte is written.
struct DNGTagValues {
    let make, model, uniqueCameraModel, software, modificationDate: String
    let colorMatrix1: [TIFFSRational]
    let asShotNeutral: [TIFFRational]
    let baselineExposure: TIFFSRational
    let defaultCrop: PixelRegion
    let captureDate: String?
    let exposureTime, fNumber, focalLength: TIFFRational?
    let iso: UInt16?
    let lensSpecification: [TIFFRational]?
    let lensMake, lensModel: String?

    init(metadata m: MergeDNGMetadata, normalisation: ExposureNormalisation, width: Int, height: Int) throws {
        func invalid(_ why: String) -> MergeDNGError { .invalidMetadata(why) }

        for prefix in MergeDNGMetadata.softwarePrefixesLibRawRejects where m.software.hasPrefix(prefix) {
            throw invalid("Software may not start with “\(prefix)”: LibRaw would refuse the file")
        }
        guard (1...8).contains(m.orientation) else { throw invalid("orientation \(m.orientation) isn't 1 to 8") }

        make = Self.ascii(m.make)
        model = Self.ascii(m.model)
        let unique = Self.ascii(m.uniqueCameraModel)
        uniqueCameraModel = unique.isEmpty ? MergeDNGMetadata.uniqueCameraModel(make: make, model: model) : unique
        software = Self.ascii(m.software)
        modificationDate = Self.exifDate(m.modificationDate, in: m.timeZone)

        // Adobe writes matrices over 10000; LibRaw's cam_xyz values are
        // exactly those numbers divided back, so nothing is rounded.
        guard m.colorMatrix1.count == 9 else { throw invalid("ColorMatrix1 needs 9 values, not \(m.colorMatrix1.count)") }
        colorMatrix1 = try m.colorMatrix1.map {
            guard let r = TIFFSRational($0, denominator: 10_000) else { throw invalid("ColorMatrix1 value \($0)") }
            return r
        }
        guard m.asShotNeutral.count == 3 else { throw invalid("AsShotNeutral needs 3 values, not \(m.asShotNeutral.count)") }
        asShotNeutral = try m.asShotNeutral.map {
            guard $0 > 0, let r = TIFFRational($0, denominator: 1_000_000) else { throw invalid("AsShotNeutral value \($0)") }
            return r
        }
        let baseline = normalisation.storedBaselineExposure(m.baselineExposure)
        guard let b = TIFFSRational(baseline, denominator: 1_000_000) else { throw invalid("BaselineExposure \(baseline)") }
        baselineExposure = b

        let crop = m.defaultCrop ?? PixelRegion(x: 0, y: 0, width: width, height: height)
        guard crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
              crop.x + crop.width <= width, crop.y + crop.height <= height else {
            throw invalid("the default crop \(crop) isn't inside the \(width) x \(height) image")
        }
        defaultCrop = crop

        captureDate = m.captureDate.map { Self.exifDate($0, in: m.timeZone) }
        exposureTime = try m.exposureTime.map {
            guard let r = Self.exposureTimeRational($0) else { throw invalid("exposure time \($0)") }
            return r
        }
        fNumber = try m.fNumber.map {
            guard $0 > 0, let r = TIFFRational($0, denominator: 100) else { throw invalid("f-number \($0)") }
            return r
        }
        focalLength = try m.focalLength.map {
            guard $0 > 0, let r = TIFFRational($0, denominator: 100) else { throw invalid("focal length \($0)") }
            return r
        }
        // EXIF's ISO tag is a SHORT; anything past 65535 is recorded as 65535.
        iso = try m.iso.map {
            guard $0.isFinite, $0 > 0 else { throw invalid("ISO \($0)") }
            return UInt16(min($0.rounded(), 65535))
        }
        lensSpecification = try m.lensSpecification.map { spec in
            try [spec.minFocalLength, spec.maxFocalLength, spec.maxApertureAtMinFocal, spec.maxApertureAtMaxFocal].map {
                guard let r = TIFFRational($0, denominator: 100) else { throw invalid("lens specification value \($0)") }
                return r
            }
        }
        lensMake = m.lensMake.map(Self.ascii).flatMap { $0.isEmpty ? nil : $0 }
        lensModel = m.lensModel.map(Self.ascii).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// TIFF text ends at the first NUL, so any inside are dropped rather
    /// than cutting the text short. (Strictly TIFF text is 7-bit ASCII;
    /// UTF-8, which ImageIO and LibRaw read, keeps non-English names intact.)
    static func ascii(_ text: String) -> String {
        text.contains("\0") ? text.replacingOccurrences(of: "\0", with: "") : text
    }

    /// EXIF's "2026:09:15 14:03:59", in `timeZone`.
    static func exifDate(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Shutter speeds are written as photographers read them: 1/250 as 1/250,
    /// not 4000/1000000. Other times get a fine fixed denominator.
    static func exposureTimeRational(_ seconds: Double) -> TIFFRational? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 1 {
            let inverse = 1 / seconds
            if abs(inverse - inverse.rounded()) <= inverse * 1e-3, inverse.rounded() <= Double(UInt32.max) {
                return TIFFRational(1, UInt32(inverse.rounded()))
            }
            return TIFFRational(seconds, denominator: 1_000_000)
        }
        return TIFFRational(seconds, denominator: 1000)
    }
}
