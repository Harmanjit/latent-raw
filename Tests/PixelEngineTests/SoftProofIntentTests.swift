import XCTest
import CoreGraphics
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// Rendering intents, paper and ink, the monitor gamut warning and the
/// ICC image conversion printing uses.
final class SoftProofIntentTests: XCTestCase {
    static let cmykURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")
    static let sRGBURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")

    private func requireProfiles() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.cmykURL.path)
                          && FileManager.default.fileExists(atPath: Self.sRGBURL.path))
    }

    func testBlackPointOfPrinterAndDisplayProfiles() throws {
        try requireProfiles()
        let cmyk = try XCTUnwrap(ICCProfile(url: Self.cmykURL))
        let srgb = try XCTUnwrap(ICCProfile(url: Self.sRGBURL))
        XCTAssertEqual(cmyk.channels, 4)
        // Ink on paper can't make the black a screen can.
        XCTAssertGreaterThan(ICCTransform.blackPoint(of: cmyk), 0.001)
        XCTAssertLessThan(ICCTransform.blackPoint(of: srgb), 0.001)
        // Compensation maps black to the black point and keeps white.
        XCTAssertEqual(ICCTransform.compressBlack(0, blackPoint: 0.01), 0.01, accuracy: 1e-6)
        XCTAssertEqual(ICCTransform.compressBlack(1, blackPoint: 0.01), 1, accuracy: 1e-6)
        XCTAssertEqual(ICCTransform.expandBlack(ICCTransform.compressBlack(0.3, blackPoint: 0.02), blackPoint: 0.02),
                       0.3, accuracy: 1e-6)
    }

    func testIntentsShareTheGamutWarningButNotTheColours() throws {
        try requireProfiles()
        let perceptual = try SoftProofLUT.build(.icc(Self.cmykURL), options: SoftProofOptions(intent: .perceptual))
        let relative = try SoftProofLUT.build(.icc(Self.cmykURL), options: SoftProofOptions(intent: .relativeColorimetric))
        XCTAssertEqual(perceptual.options.intent, .perceptual)
        // Which colours are flagged is a property of the gamut, not the intent.
        XCTAssertEqual(perceptual.outOfGamutFraction, relative.outOfGamutFraction, accuracy: 1e-9)
        XCTAssertGreaterThan(relative.outOfGamutFraction, 0.1, "Rec.2020 is far wider than press CMYK")
        // A mid grey prints as itself, whatever the intent.
        for lut in [perceptual, relative] {
            let grey = lut.lookup(SIMD3(0.2, 0.2, 0.2))
            XCTAssertEqual(grey.color.y, 0.2, accuracy: 0.03)
            XCTAssertFalse(grey.clipped)
            // Without paper simulation the paper is screen white, the ink screen black.
            XCTAssertEqual(lut.lookup(SIMD3(1, 1, 1)).color.y, 1, accuracy: 0.03)
            XCTAssertEqual(lut.lookup(SIMD3(0, 0, 0)).color.y, 0, accuracy: 0.01)
        }
        // Saturated green leaves CMYK's gamut and is flagged and moved.
        let green = relative.lookup(SIMD3(0.0, 0.8, 0.0))
        XCTAssertTrue(green.clipped)
        XCTAssertGreaterThan(green.color.x + green.color.z, 0.02)
    }

    func testSimulatePaperAndInkDullsWhiteAndLiftsBlack() throws {
        try requireProfiles()
        let plain = try SoftProofLUT.build(.icc(Self.cmykURL))
        let paper = try SoftProofLUT.build(.icc(Self.cmykURL), options: SoftProofOptions(simulatePaperAndInk: true))
        let white = paper.lookup(SIMD3(1, 1, 1)).color
        let black = paper.lookup(SIMD3(0, 0, 0)).color
        XCTAssertLessThan(white.x + white.y + white.z, 2.9, "paper is duller than the screen's white")
        XCTAssertGreaterThan(black.y, plain.lookup(SIMD3(0, 0, 0)).color.y + 0.001, "ink black is lifted")
        // Paper simulation moves every colour but flags none extra.
        XCTAssertEqual(paper.outOfGamutFraction, plain.outOfGamutFraction, accuracy: 1e-9)
        XCTAssertFalse(paper.lookup(SIMD3(1, 1, 1)).clipped)
    }

    func testMatrixTargetsIgnoreIntentAndICCProfilesFromMemoryWork() throws {
        try requireProfiles()
        XCTAssertFalse(SoftProofTarget.sRGB.isICC)
        XCTAssertTrue(SoftProofTarget.icc(Self.sRGBURL).isICC)
        let a = try SoftProofLUT.build(.sRGB, options: SoftProofOptions(intent: .perceptual))
        let b = try SoftProofLUT.build(.sRGB, options: SoftProofOptions(intent: .relativeColorimetric, simulatePaperAndInk: true))
        XCTAssertEqual(a.entries, b.entries)
        let data = try Data(contentsOf: Self.sRGBURL)
        let fromMemory = try SoftProofLUT.build(.profile(name: "Screen", data: data))
        XCTAssertEqual(fromMemory.target.displayName, "Screen")
        XCTAssertTrue(fromMemory.lookup(SIMD3(0, 0.8, 0)).clipped)
    }

    func testGamutCheckPassesColoursThroughAndFlagsOnly() throws {
        let check = try SoftProofLUT.gamutCheck(.displayP3)
        let colour = SIMD3<Float>(0.3, 0.5, 0.1)
        let looked = check.lookup(colour)
        XCTAssertEqual(looked.color.x, colour.x, accuracy: 0.002)
        XCTAssertEqual(looked.color.y, colour.y, accuracy: 0.002)
        XCTAssertFalse(check.lookup(SIMD3(0.2, 0.2, 0.2)).clipped)
        XCTAssertTrue(check.lookup(SIMD3(0, 0.8, 0)).clipped, "Rec.2020 green is outside P3")
    }

    func testOptionsDecodeWithMissingFields() throws {
        let decoded = try JSONDecoder().decode(SoftProofOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, SoftProofOptions())
        let full = SoftProofOptions(intent: .relativeColorimetric, simulatePaperAndInk: true)
        XCTAssertEqual(try JSONDecoder().decode(SoftProofOptions.self, from: JSONEncoder().encode(full)), full)
    }

    // MARK: - Image conversion (printing)

    /// A 2×1 Display P3 image: a mid grey and a saturated red.
    private func sampleImage() throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        var pixels: [UInt8] = [128, 128, 128, 255, 250, 20, 20, 255]
        let context = try XCTUnwrap(pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        })
        return context
    }

    func testImageConversionIntoCMYKWithEachIntent() throws {
        try requireProfiles()
        let image = try sampleImage()
        let space = try XCTUnwrap(ICCProfile(url: Self.cmykURL)?.colorSpace)
        let perceptual = try XCTUnwrap(ICCImageConversion.convert(image, to: space, intent: .perceptual))
        let relative = try XCTUnwrap(ICCImageConversion.convert(image, to: space, intent: .relativeColorimetric))
        for converted in [perceptual, relative] {
            XCTAssertEqual(converted.width, 2)
            XCTAssertEqual(converted.height, 1)
            XCTAssertEqual(converted.colorSpace?.model, .cmyk)
            XCTAssertEqual(converted.bitsPerComponent, 8)
        }
        // Black point compensation changes the conversion.
        XCTAssertNotEqual(bytes(perceptual), bytes(relative))
    }

    func testImageConversionIntoRGBKeepsInGamutColours() throws {
        try requireProfiles()
        let image = try sampleImage()
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let converted = try XCTUnwrap(ICCImageConversion.convert(image, to: space, intent: .relativeColorimetric))
        XCTAssertEqual(converted.bitsPerComponent, 16)
        let values = bytes(converted).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        // Grey 128 is the same in P3 and sRGB (same curve, same white).
        for c in 0..<3 { XCTAssertEqual(Double(values[c]) / 65535, 128.0 / 255, accuracy: 0.01) }
        // The red sits beyond sRGB and is clipped to its edge.
        XCTAssertGreaterThan(values[4], 65000)
    }

    /// Converting a tall image goes strip by strip: rows must come out in
    /// order, the top row on top.
    func testImageConversionKeepsRowOrderAcrossStrips() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let height = ICCImageConversion.stripRows * 2 + 7
        var pixels = [UInt8](repeating: 0, count: height * 4)
        for row in 0..<height { pixels[row * 4] = UInt8(row % 256); pixels[row * 4 + 3] = 255 }
        let image = try XCTUnwrap(pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        })
        let converted = try XCTUnwrap(ICCImageConversion.convert(image, to: space, intent: .perceptual))
        let values = bytes(converted).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        let rowWords = converted.bytesPerRow / 2
        for row in [0, 1, 127, 128, 200, height - 1] {
            XCTAssertEqual(Double(values[row * rowWords]) / 65535, Double(row % 256) / 255, accuracy: 0.01, "row \(row)")
        }
    }

    private func bytes(_ image: CGImage) -> Data {
        (image.dataProvider?.data as Data?) ?? Data()
    }

    // MARK: - Rendering

    func testMonitorWarningPaintsBlueAndNeedsAProof() throws {
        let path = TestAssets.path("HSB_6548.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        p.hsl.saturation = Array(repeating: 1, count: 8)
        func render(_ output: RenderOutput) throws -> [Float16] {
            try TextureReadback.float16Pixels(of: try pipeline.render(session, scale: .binned(quads: 4),
                                                                      parameters: p, output: output), gpu: gpu)
        }
        let plain = RenderOutput.file(.sRGB)
        let baseline = try render(plain)
        // Inactive: a monitor table without a proof changes nothing.
        var inactive = plain
        inactive.monitorGamut = try SoftProofLUT.gamutCheck(.sRGB)
        XCTAssertEqual(try render(inactive), baseline)

        // Proofing to Display P3 with the monitor taken as sRGB: colours P3
        // keeps but sRGB can't show are painted blue.
        var proofed = plain
        proofed.proof = try SoftProofLUT.build(.displayP3)
        proofed.monitorGamut = try SoftProofLUT.gamutCheck(.sRGB)
        let pixels = try render(proofed)
        var blues = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if Float(pixels[i]) < 0.02 && Float(pixels[i + 1]) < 0.02 && Float(pixels[i + 2]) > 0.99 { blues += 1 }
        }
        XCTAssertGreaterThan(blues, 100, "monitor warning should paint blue")
    }
}
