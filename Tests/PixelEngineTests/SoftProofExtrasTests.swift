import XCTest
import CoreGraphics
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// Black point compensation as a proof option, and gamut warnings painted
/// in colours of the user's choosing.
final class SoftProofExtrasTests: XCTestCase {
    static let cmykURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")

    // MARK: - Black point compensation

    func testTurningBlackPointCompensationOffDarkensShadows() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.cmykURL.path))
        let on = try SoftProofLUT.build(.icc(Self.cmykURL), options: SoftProofOptions(intent: .relativeColorimetric))
        let off = try SoftProofLUT.build(.icc(Self.cmykURL),
                                         options: SoftProofOptions(intent: .relativeColorimetric,
                                                                   blackPointCompensation: false))
        // A deep shadow just above the first grid step: compensated, it
        // comes back about where it was; uncompensated, it was squeezed
        // towards the paper's black and comes back darker.
        let shadow = SIMD3<Float>(repeating: 1.0 / 32)
        let a = on.lookup(shadow).color, b = off.lookup(shadow).color
        XCTAssertLessThan(b.y, a.y - 0.002, "without compensation, shadows block up")
        // Which colours are flagged depends on the gamut only.
        XCTAssertEqual(on.outOfGamutFraction, off.outOfGamutFraction, accuracy: 1e-9)
        // Perceptual ignores the option.
        let perceptualOn = try SoftProofLUT.build(.icc(Self.cmykURL), options: SoftProofOptions())
        let perceptualOff = try SoftProofLUT.build(.icc(Self.cmykURL),
                                                   options: SoftProofOptions(blackPointCompensation: false))
        XCTAssertEqual(perceptualOn.entries, perceptualOff.entries)
    }

    func testBlackPointOptionDecodesAsOnWhenMissing() throws {
        let old = Data(#"{"intent":"relativeColorimetric","simulatePaperAndInk":false}"#.utf8)
        let options = try JSONDecoder().decode(SoftProofOptions.self, from: old)
        XCTAssertTrue(options.blackPointCompensation)
        XCTAssertTrue(options.compensatesBlack)
        XCTAssertFalse(SoftProofOptions(intent: .perceptual).compensatesBlack)
        XCTAssertFalse(SoftProofOptions(intent: .relativeColorimetric, blackPointCompensation: false).compensatesBlack)
    }

    // MARK: - Warning colours

    func testStandardColoursPackToLightroomsRedAndBlue() {
        func half(_ word: UInt32, high: Bool) -> Float {
            Float(Float16(bitPattern: UInt16(truncatingIfNeeded: high ? word >> 16 : word)))
        }
        let w = GamutWarningColours.standard.packedWords
        let red = SIMD3(half(w.x, high: false), half(w.x, high: true), half(w.y, high: false))
        let blue = SIMD3(half(w.y, high: true), half(w.z, high: false), half(w.z, high: true))
        // The colours the kernel painted before they could be changed.
        XCTAssertEqual(red.x, 0.6274, accuracy: 0.002)
        XCTAssertEqual(red.y, 0.0691, accuracy: 0.002)
        XCTAssertEqual(red.z, 0.0164, accuracy: 0.002)
        XCTAssertEqual(blue.x, 0.0433, accuracy: 0.002)
        XCTAssertEqual(blue.y, 0.0113, accuracy: 0.002)
        XCTAssertEqual(blue.z, 0.8956, accuracy: 0.002)
    }

    func testColoursDecodeWithMissingFields() throws {
        let colours = try JSONDecoder().decode(GamutWarningColours.self, from: Data(#"{"monitor":[0,1,0]}"#.utf8))
        XCTAssertEqual(colours.destination, GamutWarningColours.standard.destination)
        XCTAssertEqual(colours.monitor, SIMD3(0, 1, 0))
    }

    func testDestinationWarningPaintsTheChosenColour() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: try TestAssets.d750Path()), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        p.hsl.saturation = Array(repeating: 1, count: 8)
        p.vibrance = 1
        func render(_ output: RenderOutput) throws -> [Float16] {
            try TextureReadback.float16Pixels(of: try pipeline.render(session, scale: .binned(quads: 4),
                                                                      parameters: p, output: output), gpu: gpu)
        }
        func count(_ pixels: [Float16], _ match: (Float, Float, Float) -> Bool) -> Int {
            stride(from: 0, to: pixels.count, by: 4).filter {
                match(Float(pixels[$0]), Float(pixels[$0 + 1]), Float(pixels[$0 + 2]))
            }.count
        }
        let isRed: (Float, Float, Float) -> Bool = { $0 > 0.98 && $1 < 0.03 && $2 < 0.03 }
        let isGreen: (Float, Float, Float) -> Bool = { $0 < 0.03 && $1 > 0.98 && $2 < 0.03 }
        var output = RenderOutput.file(.sRGB)
        output.proof = try SoftProofLUT.build(.sRGB)
        output.gamutWarning = true
        let standard = try render(output)
        let reds = count(standard, isRed)
        XCTAssertGreaterThan(reds, 50, "a saturated render has colours sRGB can't hold")

        output.gamutWarningColours.destination = SIMD3(0, 1, 0)
        let green = try render(output)
        XCTAssertGreaterThan(count(green, isGreen), reds / 2, "the warning takes the chosen colour")
        XCTAssertLessThan(count(green, isRed), reds / 2)
    }
}
