import CoreImage
import ImageIO
import XCTest
@testable import MergeKit

/// What Apple's readers make of the file: ImageIO's properties and XMP, and
/// Core Image's RAW engine rendering it.
final class AppleReaderTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws { folder = try Fixtures.temporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A uniform image: camera RGB of a neutral grey at `grey` (after
    /// normalisation) under the as-shot white balance.
    private func writeGrey(_ grey: Float, maximumScale: Float = 1, baselineExposure: Double = 0,
                           name: String) throws -> MergeDNGWriteResult {
        let (width, height) = (256, 192)
        let neutral = try MergeDNGMetadata.asShotNeutral(fromCameraMultipliers: Fixtures.d750Multipliers).map(Float.init)
        var pixels = [Float16](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            for c in 0..<3 { pixels[i * 3 + c] = Float16(neutral[c] * grey * maximumScale) }
        }
        var metadata = try Fixtures.metadata(baselineExposure: baselineExposure)
        metadata.orientation = 1
        var writer = LinearRawDNGWriter(tileSize: 128)
        writer.availableCapacity = { _ in nil }
        return try writer.write(.buffer(pixels, width: width, height: height),
                                maximum: ExposureNormalisation.maximum(of: pixels), metadata: metadata,
                                recipe: Fixtures.recipe(), preview: Fixtures.previewImage(width: 256, height: 192),
                                to: folder.appendingPathComponent(name))
    }

    func testImageIOReadsTheDNGAndEXIFProperties() throws {
        let result = try writeGrey(0.5, maximumScale: 8, baselineExposure: -1, name: "props.dng")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 256)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 192)

        let dng = try XCTUnwrap(props[kCGImagePropertyDNGDictionary as String] as? [String: Any])
        XCTAssertEqual(dng[kCGImagePropertyDNGUniqueCameraModel as String] as? String, "Nikon D750")
        XCTAssertEqual((dng[kCGImagePropertyDNGVersion as String] as? [Int])?.prefix(2), [1, 4])
        XCTAssertEqual(dng[kCGImagePropertyDNGBaselineExposure as String] as? Double, 1, "-1 plus the 2-stop shift")
        XCTAssertEqual(dng[kCGImagePropertyDNGCalibrationIlluminant1 as String] as? Int, 21)
        let matrix = try XCTUnwrap(dng[kCGImagePropertyDNGColorMatrix1 as String] as? [Double])
        XCTAssertEqual(matrix.count, 9)
        XCTAssertEqual(matrix[0], 0.902, accuracy: 1e-6)
        let neutral = try XCTUnwrap(dng[kCGImagePropertyDNGAsShotNeutral as String] as? [Double])
        XCTAssertEqual(neutral[0], 0.481203, accuracy: 1e-6)
        XCTAssertEqual(neutral[1], 1)
        XCTAssertEqual((dng[kCGImagePropertyDNGWhiteLevel as String] as? [Int])?.first, 1)

        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifExposureTime as String] as? Double, 0.004)
        XCTAssertEqual(exif[kCGImagePropertyExifFNumber as String] as? Double, 8)
        XCTAssertEqual(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], [100])
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLength as String] as? Double, 35)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:09:15 19:00:00")
        XCTAssertEqual(exif[kCGImagePropertyExifLensModel as String] as? String, "AF-S NIKKOR 24-70mm f/2.8E ED VR")
        XCTAssertEqual(exif[kCGImagePropertyExifLensMake as String] as? String, "Nikon")
        let lens = try XCTUnwrap(exif[kCGImagePropertyExifLensSpecification as String] as? [Double])
        XCTAssertEqual(lens.count, 4)
        for (read, written) in zip(lens, [24, 70, 2.8, 2.8]) { XCTAssertEqual(read, written, accuracy: 1e-6) }

        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake as String] as? String, "Nikon")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel as String] as? String, "D750")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFSoftware as String] as? String, "Latent 0.9")
    }

    func testImageIOSeesTheMergeRecipeInTheXMP() throws {
        let result = try writeGrey(0.5, maximumScale: 8, name: "xmp.dng")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let tags = try XCTUnwrap(CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag])
        let merge = try XCTUnwrap(tags.first {
            CGImageMetadataTagCopyNamespace($0) as String? == MergeXMP.namespaceURI
                && CGImageMetadataTagCopyName($0) as String? == "Merge"
        }, "a latent:Merge tag among \(tags.compactMap { CGImageMetadataTagCopyName($0) as String? })")
        let json = try XCTUnwrap(CGImageMetadataTagCopyValue(merge) as? String)
        let recipe = try MergeRecipe(jsonData: Data(json.utf8))
        XCTAssertEqual(recipe, result.recipe)
        XCTAssertEqual(recipe.baselineShift, 2)
        XCTAssertEqual(recipe.clipLevel, 2, "8 / 2^2")
    }

    func testImageIOCreatesAThumbnailFromThePreview() throws {
        let result = try writeGrey(0.5, name: "thumb.dng")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary)
        XCTAssertEqual(thumbnail?.width, 256)
    }

    /// Apple's RAW engine renders mid-grey near mid-grey: colour matrix,
    /// neutral, WhiteLevel and the normalised BaselineExposure all agree.
    func testCIRAWFilterRendersMidGreyNearMidGrey() throws {
        // Grey at 0.18 x 8 = 1.44 is stored halved (0.72, one stop of
        // shift), and the file asks for 3 stops darker: BaselineExposure
        // -3 + 1 = -2, so it should render as 0.72 / 4 = 0.18.
        let result = try writeGrey(0.18, maximumScale: 8, baselineExposure: -3, name: "grey.dng")
        XCTAssertEqual(result.normalisation.shift, 1)
        guard let filter = CIRAWFilter(imageURL: result.url) else {
            throw XCTSkip("CIRAWFilter can't open DNGs on this machine")
        }
        filter.boostAmount = 0
        guard let output = filter.outputImage else { throw XCTSkip("CIRAWFilter produced no image on this machine") }
        XCTAssertEqual(output.extent.size, CGSize(width: 256, height: 192))

        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: space])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: output.extent.midX, y: output.extent.midY, width: 1, height: 1),
                       format: .RGBAf, colorSpace: space)
        for c in 0..<3 {
            XCTAssertEqual(pixel[c], 0.18, accuracy: 0.02, "channel \(c) of \(pixel)")
        }
        XCTAssertEqual(pixel[0], pixel[1], accuracy: 0.01, "neutral stays neutral: \(pixel)")
        XCTAssertEqual(pixel[2], pixel[1], accuracy: 0.01, "neutral stays neutral: \(pixel)")
    }
}
