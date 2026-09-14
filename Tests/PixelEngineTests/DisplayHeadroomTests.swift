import XCTest
import Metal
@testable import PixelEngine

/// The viewport's EDR arithmetic, the present kernel's highlight roll-off
/// (through its Swift copy and on the GPU), and the histogram's HDR and
/// clipping counters.
final class DisplayHeadroomTests: XCTestCase {

    // MARK: - Roll-off curve (HeadroomToneMap, mirror of Present.metal)

    /// (display, content) pairs: a screen with no headroom yet showing a 4x
    /// render, a 2x screen with 4x content, content just over a screen's
    /// headroom, and a render far brighter than the screen.
    private let pairs: [(display: Float, content: Float)] = [(1, 4), (2, 4), (3, 3.97), (1.5, 16), (4, 4.5)]

    private func samples(upTo limit: Float, step: Float) -> [Float] {
        Array(stride(from: Float(0), through: limit, by: step))
    }

    func testRollOffIsMonotonicContinuousAndNeverBrighter() {
        for (display, content) in pairs {
            let step: Float = 0.001
            var previous = HeadroomToneMap.map(peak: 0, displayHeadroom: display, contentHeadroom: content)
            for x in samples(upTo: content * 1.5, step: step).dropFirst() {
                let y = HeadroomToneMap.map(peak: x, displayHeadroom: display, contentHeadroom: content)
                XCTAssertGreaterThanOrEqual(y, previous, "not monotonic at \(x) for \(display)/\(content)")
                // Slope at most 1 (plus float slack): no jumps, no added contrast.
                XCTAssertLessThanOrEqual(y - previous, step * 1.01, "jump at \(x) for \(display)/\(content)")
                XCTAssertLessThanOrEqual(y, x + 1e-5, "brighter at \(x) for \(display)/\(content)")
                XCTAssertLessThanOrEqual(y, display + 1e-5)
                previous = y
            }
        }
    }

    func testRollOffReachesTheDisplayHeadroomExactlyAtTheContentHeadroom() {
        for (display, content) in pairs {
            let top = HeadroomToneMap.map(peak: content, displayHeadroom: display, contentHeadroom: content)
            XCTAssertEqual(top, display, accuracy: 1e-4, "\(display)/\(content)")
            let below = HeadroomToneMap.map(peak: content - 0.001, displayHeadroom: display, contentHeadroom: content)
            XCTAssertLessThan(below, display)
            XCTAssertLessThan(display - below, 0.002)
        }
    }

    func testContentThatFitsPassesThrough() {
        for (display, content) in [(Float(1), Float(1)), (4, 1), (4, 3.97), (16, 4)] {
            for x in samples(upTo: content * 1.2, step: 0.01) {
                XCTAssertEqual(HeadroomToneMap.map(peak: x, displayHeadroom: display, contentHeadroom: content), x)
            }
        }
    }

    func testSDRRangeIsUntouchedWhereverTheScreenHasRoom() {
        // From 4/3 of headroom up, the knee sits at or above SDR white.
        for display in [Float(4) / 3, 2, 3, 8] {
            for x in samples(upTo: 1, step: 0.01) {
                XCTAssertEqual(HeadroomToneMap.map(peak: x, displayHeadroom: display, contentHeadroom: 16), x)
            }
        }
        // A screen with no headroom at the moment gives up its top quarter only.
        for x in samples(upTo: 0.75, step: 0.01) {
            XCTAssertEqual(HeadroomToneMap.map(peak: x, displayHeadroom: 1, contentHeadroom: 4), x)
        }
    }

    func testSlopeIsOneAtTheKnee() {
        let display: Float = 2, knee = display * 0.75, h: Float = 1e-3
        let y = HeadroomToneMap.map(peak: knee + h, displayHeadroom: display, contentHeadroom: 4)
        XCTAssertEqual((y - knee) / h, 1, accuracy: 0.01)
    }

    // MARK: - EDR decisions

    func testRenderHeadroomFollowsThePotentialHeadroomUpToTheCeiling() {
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 1, hdrDisplayEnabled: true), 1)
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 2.5, hdrDisplayEnabled: true), 2.5)
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 16, hdrDisplayEnabled: true), 4)
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 16, hdrDisplayEnabled: false), 1)
        // A screen reporting less than 1 (never expected) still renders SDR.
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 0.5, hdrDisplayEnabled: true), 1)
    }

    func testEDROnlyForHDRContentOnAnHDRScreen() {
        XCTAssertTrue(DisplayHeadroom.wantsExtendedDynamicRange(contentHeadroom: 4, potential: 16))
        XCTAssertFalse(DisplayHeadroom.wantsExtendedDynamicRange(contentHeadroom: 1, potential: 16),
                       "HDR display off or proofing renders to 1: no EDR")
        XCTAssertFalse(DisplayHeadroom.wantsExtendedDynamicRange(contentHeadroom: 4, potential: 1),
                       "moved to an SDR screen before the re-render")
    }

    func testPresentHeadroomIsOneWithoutEDR() {
        XCTAssertEqual(DisplayHeadroom.presented(current: 3, extendedDynamicRange: true), 3)
        XCTAssertEqual(DisplayHeadroom.presented(current: 3, extendedDynamicRange: false), 1)
        XCTAssertEqual(DisplayHeadroom.presented(current: 0.8, extendedDynamicRange: true), 1)
    }

    func testEveryPresentLayerIsANewGeneration() throws {
        let gpu = try GPUContext()
        let texture = try XCTUnwrap(makeTexture(gpu, width: 1, height: 1, pixels: [0, 0, 0]))
        let a = PresentLayer(texture: texture, coverage: CGRect(x: 0, y: 0, width: 1, height: 1))
        let b = PresentLayer(texture: texture, coverage: a.coverage, headroom: 0.5)
        XCTAssertNotEqual(a.generation, b.generation, "same pooled texture, new render")
        XCTAssertEqual(b.headroom, 1, "never below SDR")
    }

    // MARK: - GPU

    /// The present kernel's output against the Swift copy of its curve:
    /// content that fits the screen passes through bit for bit, and an HDR
    /// render is rolled off to the screen's current headroom with hue kept.
    func testPresentKernelMatchesTheSwiftRollOff() throws {
        let gpu = try GPUContext()
        let presenter = Presenter(gpu: gpu)
        let values: [Float] = [0.25, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0]
        // Grey ramp, then one saturated highlight whose hue must survive.
        var pixels = values.flatMap { [$0, $0, $0] }
        pixels.replaceSubrange(21..<24, with: [3.0, 1.5, 0.75])
        let size = CGSize(width: values.count, height: 1)
        let source = try XCTUnwrap(makeTexture(gpu, width: values.count, height: 1, pixels: pixels))

        func present(content: Float, display: Float) throws -> [Float] {
            let target = try XCTUnwrap(makeTexture(gpu, width: values.count, height: 1,
                                                   pixels: [Float](repeating: 0, count: pixels.count)))
            let layer = PresentLayer(texture: source, coverage: CGRect(origin: .zero, size: size),
                                     headroom: content)
            let commands = try XCTUnwrap(presenter.encode(
                base: layer, tile: nil,
                transform: .fit(imageSize: size, drawableSize: size),
                frame: CropFrame(sensorSize: size), into: target,
                backgroundLevel: 0, displayHeadroom: display))
            commands.commit()
            commands.waitUntilCompleted()
            return readRGB(target)
        }

        let passThrough = try present(content: 4, display: 4)
        XCTAssertEqual(passThrough, pixels, "content that fits the screen is untouched")

        let rolled = try present(content: 4, display: 2)
        for i in 0..<values.count {
            let rgb = Array(pixels[i * 3..<i * 3 + 3])
            let peak = rgb.max()!
            let mapped = HeadroomToneMap.map(peak: peak, displayHeadroom: 2, contentHeadroom: 4)
            for c in 0..<3 {
                // Half-float storage: about 0.002 per step between 2 and 4.
                XCTAssertEqual(rolled[i * 3 + c], rgb[c] * mapped / peak, accuracy: 0.003,
                               "pixel \(i) channel \(c)")
            }
        }
        XCTAssertEqual(rolled[21] / rolled[22], 2, accuracy: 0.01, "hue kept")
    }

    /// Luminance, above-white and shadow counts on a handful of known pixels.
    func testHistogramCountsLuminanceAboveWhiteAndShadows() throws {
        let gpu = try GPUContext()
        let calculator = try HistogramCalculator(gpu: gpu)
        let pixels: [Float] = [
            0, 0, 0,          // black: bottom bin everywhere
            2, 2, 2,          // above white
            1, 1, 1,          // exactly white: top bin, not above it
            0.18, 0.18, 0.18, // mid grey
            1, 0, 0,          // pure red
            1.5, 0.2, 0.1,    // a bright orange highlight, above white
            0.5, 0.5, 0.5,
            0.5, 0.5, 0.5,
        ]
        let texture = try XCTUnwrap(makeTexture(gpu, width: 4, height: 2, pixels: pixels))
        let histogram = try XCTUnwrap(calculator.compute(from: texture, inputIsLinear: true))

        XCTAssertEqual(histogram.totalPixels, 8)
        XCTAssertEqual(histogram.aboveSDRWhite, 2)
        XCTAssertEqual(histogram.aboveSDRWhiteFraction, 0.25, accuracy: 1e-6)
        XCTAssertEqual(histogram.red[255], 4)
        XCTAssertEqual(histogram.green[255], 2)
        XCTAssertEqual(histogram.shadowClippedFraction.red, 1.0 / 8, accuracy: 1e-6)
        XCTAssertEqual(histogram.shadowClippedFraction.green, 2.0 / 8, accuracy: 1e-6)
        XCTAssertEqual(histogram.shadowClippedFraction.blue, 2.0 / 8, accuracy: 1e-6)

        XCTAssertEqual(histogram.luminance.reduce(0, +), 8)
        // A grey's luminance is the grey itself, so it lands in the channels' bin.
        let greyBin = histogram.red.indices.first { $0 > 0 && $0 < 255 && histogram.red[$0] == 1 && histogram.green[$0] == 1 }
        let grey = try XCTUnwrap(greyBin)
        XCTAssertEqual(histogram.luminance[grey], 1)
        // Pure red looks like a mid tone, not a highlight.
        let redBin = Int((encodeSRGB(0.2289746) * 255 + 0.5).rounded(.down))
        XCTAssertEqual(histogram.luminance[redBin], 1)
        // Luminance clips like the channels do: white and brighter at the top.
        XCTAssertEqual(histogram.luminance[255], 2)
        XCTAssertEqual(histogram.luminance[0], 1)
    }

    // MARK: - Helpers

    private func makeTexture(_ gpu: GPUContext, width: Int, height: Int, pixels rgb: [Float]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { return nil }
        var half = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<width * height {
            for c in 0..<3 { half[i * 4 + c] = Float16(rgb[i * 3 + c]) }
        }
        half.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    private func readRGB(_ texture: MTLTexture) -> [Float] {
        var half = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        half.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return (0..<texture.width * texture.height).flatMap { i in (0..<3).map { Float(half[i * 4 + $0]) } }
    }

    private func encodeSRGB(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
