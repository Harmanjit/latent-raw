import XCTest
import Metal
import ImageIO
import CoreGraphics
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// HDR gain-map exports, read back with ImageIO: the map is there, the
/// main image is the ordinary SDR export, and an HDR decode rebuilds the
/// HDR render, brighter than SDR white where the highlights are.
final class GainMapTests: XCTestCase {
    func testGainRangeFollowsTheToneCurve() {
        let range = GainMap.log2Range(headroom: 4)
        XCTAssertEqual(range.maximum, 2, accuracy: 1e-6)
        XCTAssertEqual(range.minimum, log2(4 / 7), accuracy: 1e-6)
        XCTAssertEqual(GainMap.size(forImageWidth: 641, height: 427).width, 321)
        XCTAssertEqual(GainMap.size(forImageWidth: 1, height: 1).height, 1)
        XCTAssertFalse(ExportSettings(format: .png, hdrGainMap: true).writesGainMap)
        XCTAssertFalse(ExportSettings(format: .tiff, hdrGainMap: true).writesGainMap)
        XCTAssertTrue(ExportSettings(format: .heic, hdrGainMap: true).writesGainMap)
        XCTAssertFalse(ExportSettings(format: .jpeg).writesGainMap, "off unless asked for")
    }

    func testJPEGAndHEICGainMapsRebuildTheHDRRender() throws {
        let path = TestAssets.path("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let exporter = Exporter(gpu: gpu)

        var parameters = EditParameters()
        parameters.whiteBalance = session.asShotWhiteBalance
        parameters.exposureEV = 1
        parameters.outputSpace = .displayP3
        let longEdge = 640
        let scale = ExportPlan.scale(for: file.summary, maxLongEdge: longEdge)
        let rotation = ExportPlan.rotation(for: file.summary, userRotation: 0)
        func render(_ output: RenderOutput) throws -> MTLTexture {
            try pipeline.render(session, scale: scale, parameters: parameters, output: output)
        }

        // What an HDR screen should show: the HDR render, resampled to the
        // export's size like the file's own pixels.
        let hdr = try render(.hdrFile(.displayP3, headroom: GainMap.exportHeadroom))
        let frame = CropFrame(sensorSize: CGSize(width: hdr.width, height: hdr.height), rotation: rotation)
        let (w, h) = Exporter.outputSize(frame: frame, maxLongEdge: longEdge)
        let truthTexture = try XCTUnwrap(gpu.makePrivateTexture(width: w, height: h, pixelFormat: .rgba16Float))
        try exporter.resample(hdr, frame: frame, into: truthTexture, sourceIsEncoded: false, encode: false)
        let truth = try TextureReadback.float16Pixels(of: truthTexture, gpu: gpu).map(Float.init)

        for format in [ExportSettings.Format.jpeg, .heic] {
            let directory = FileManager.default.temporaryDirectory
            let plainURL = directory.appendingPathComponent("latent-sdr-\(UUID()).\(format.fileExtension)")
            let hdrURL = directory.appendingPathComponent("latent-hdr-\(UUID()).\(format.fileExtension)")
            defer {
                try? FileManager.default.removeItem(at: plainURL)
                try? FileManager.default.removeItem(at: hdrURL)
            }
            try exporter.write(try render(.file(.displayP3)), to: plainURL,
                               settings: ExportSettings(format: format, quality: 0.9),
                               colorSpace: .displayP3, rotation: rotation, maxLongEdge: longEdge)
            let size = try exporter.write(try render(.file(.displayP3)), to: hdrURL,
                                          settings: ExportSettings(format: format, quality: 0.9, hdrGainMap: true),
                                          colorSpace: .displayP3, rotation: rotation, maxLongEdge: longEdge,
                                          hdrRender: render)
            XCTAssertEqual(size.width, w)
            XCTAssertEqual(size.height, h)

            let plain = try XCTUnwrap(CGImageSourceCreateWithURL(plainURL as CFURL, nil))
            let withMap = try XCTUnwrap(CGImageSourceCreateWithURL(hdrURL as CFURL, nil))
            XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(plain, 0, kCGImageAuxiliaryDataTypeISOGainMap))
            let aux = try XCTUnwrap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                withMap, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any], "\(format): no gain map")
            let description = try XCTUnwrap(aux[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
            XCTAssertEqual(description[kCGImagePropertyWidth] as? Int, (w + 1) / 2)

            // The main image is the SDR export's pixels. HEIC stores them
            // exactly as a plain export does. For JPEG, ImageIO writes files
            // with a gain map through a different encoder (other
            // quantisation tables), so the same pixels decode a little
            // differently; measured mean difference 0.002 linear.
            let plainImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(plain, 0, nil))
            let baseImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(withMap, 0, nil))
            let plainPixels = linearPixels(plainImage), base = linearPixels(baseImage)
            XCTAssertEqual(plainPixels.count, base.count)
            var baseDifference = 0.0
            for i in 0..<min(plainPixels.count, base.count) { baseDifference += Double(abs(plainPixels[i] - base[i])) }
            baseDifference /= Double(plainPixels.count)
            XCTAssertLessThanOrEqual(baseDifference, format == .heic ? 0 : 0.005,
                                     "\(format): the main image isn't the SDR export")

            // Decoded for HDR: well past SDR white in the highlights, and
            // close to the HDR render everywhere. Not exact: the map is
            // half size and both images are lossy, which mostly shows as
            // the smallest specular points coming back a little dimmer.
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
                withMap, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
            XCTAssertEqual(decoded.contentHeadroom, GainMap.exportHeadroom, accuracy: 0.05)
            let rebuilt = linearPixels(decoded)
            XCTAssertEqual(rebuilt.count, truth.count)
            var brightest: Float = 0, brightestSDR: Float = 0, error = 0.0, truthSum = 0.0
            for i in stride(from: 0, to: min(rebuilt.count, truth.count, base.count), by: 4) {
                for c in 0..<3 {
                    brightest = max(brightest, rebuilt[i + c])
                    brightestSDR = max(brightestSDR, base[i + c])
                    error += Double(abs(rebuilt[i + c] - truth[i + c]))
                    truthSum += Double(truth[i + c])
                }
            }
            let relativeError = error / truthSum
            print(String(format: "gain map %@: brightest %.2f (SDR %.2f, HDR render %.2f), mean error %.1f%%, base %.4f from the plain export",
                         format.displayName, brightest, brightestSDR, truth.max() ?? 0, relativeError * 100, baseDifference))
            XCTAssertLessThanOrEqual(brightestSDR, 1.001)
            XCTAssertGreaterThan(brightest, 3, "\(format): the HDR decode doesn't reach the highlights")
            XCTAssertLessThan(relativeError, 0.1, "\(format): the HDR decode is far from the HDR render")
        }
    }

    /// Any image as linear extended Display P3 floats, RGBA per pixel.
    private func linearPixels(_ image: CGImage) -> [Float] {
        let w = image.width, h = image.height
        var pixels = [Float](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pixels
    }
}
