import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// The second round of tone and colour tools: the rest of Auto (Highlights,
/// Shadows, Whites, Blacks, Vibrance, Saturation, and Shift-double-click
/// per slider), Match Total Exposures, the Colour Mixer's hue isolation,
/// Visualise HDR Ranges and the HDR readout.
final class ToneColourAdditionsTests: XCTestCase {
    private let grey: Float = 0.1845
    private let contrast: Float = 1.5

    /// Luminances whose tones t run evenly from `low` to `high`.
    private func luminances(t low: Float, _ high: Float, count: Int = 4000) -> [Float] {
        (0..<count).map { i in
            let t = low + (high - low) * Float(i) / Float(count - 1)
            return grey * pow(2, t / contrast)
        }
    }

    // MARK: - Auto tone

    /// Whites and Blacks are solved so the end points land on their targets
    /// (to the slider's hundredth), unless the slider would have to pass
    /// Auto's limit.
    func testWhitesAndBlacksPlaceTheEndPoints() {
        let ys = luminances(t: -8, 5)
        let ranges = AutoTone.toneRanges(luminances: ys, contrast: contrast, greyPoint: grey)
        let ts = ys.map { contrast * log2($0 / grey) }.sorted()
        let black = ts[Int(Float(ts.count - 1) * AutoTone.endPercentile)]
        let white = ts[Int(Float(ts.count - 1) * (1 - AutoTone.endPercentile))]
        XCTAssertGreaterThan(ranges.whites, 0, "the brightest tones sit below the target: Whites up")
        XCTAssertLessThan(ranges.blacks, 0, "the darkest sit above it: Blacks down")
        XCTAssertLessThan(abs(ranges.whites), AutoTone.limit)
        XCTAssertLessThan(abs(ranges.blacks), AutoTone.limit)
        XCTAssertEqual(ranges.remap(white), AutoTone.whitesTarget, accuracy: 0.05)
        XCTAssertEqual(ranges.remap(black), AutoTone.blacksTarget, accuracy: 0.05)
    }

    /// A wide scene gets its highlights pulled down and shadows lifted; a
    /// flat one neither. Nothing to measure is neutral.
    func testHighlightsAndShadowsFollowTheRange() {
        let wide = AutoTone.toneRanges(luminances: luminances(t: -9, 8), contrast: contrast, greyPoint: grey)
        XCTAssertLessThan(wide.highlights, 0)
        XCTAssertGreaterThan(wide.shadows, 0)
        XCTAssertGreaterThanOrEqual(wide.highlights, -0.5)
        XCTAssertLessThanOrEqual(wide.shadows, 0.5)
        let flat = AutoTone.toneRanges(luminances: luminances(t: -1, 1), contrast: contrast, greyPoint: grey)
        XCTAssertEqual(flat.highlights, 0)
        XCTAssertEqual(flat.shadows, 0)
        XCTAssertEqual(AutoTone.toneRanges(luminances: [0.1, 0.2], contrast: contrast, greyPoint: grey), .neutral)
        XCTAssertEqual(AutoTone.toneRanges(luminances: [], contrast: contrast, greyPoint: grey), .neutral)
    }

    func testPresenceLiftsOnlyMutedPictures() {
        let muted = AutoTone.presence(colourfulness: 0.05)
        XCTAssertEqual(muted.vibrance, 0.25)
        XCTAssertEqual(muted.saturation, 0.05)
        let colourful = AutoTone.presence(colourfulness: 0.6)
        XCTAssertEqual(colourful.vibrance, 0)
        XCTAssertEqual(colourful.saturation, 0)
        XCTAssertEqual(AutoTone.presence(colourfulness: .nan).vibrance, 0)
    }

    /// Shift-double-click on Whites solves again on top of the sliders as
    /// they are, so the white point still lands on target.
    func testSingleSliderAutoKeepsTheOthers() {
        let ys = luminances(t: -8, 5)
        let ts = ys.map { contrast * log2($0 / grey) }.sorted()
        let measured = AutoTone.measure(luminances: ys, contrast: contrast, greyPoint: grey)
        let suggestion = AutoTone.Suggestion(toneRanges: measured.ranges, blackPoint: measured.black,
                                             whitePoint: measured.white)
        var current = ToneRanges(highlights: 0.5, shadows: -0.3)
        current.whites = AutoTone.value(for: .whites, in: suggestion, current: current)
        let white = ts[Int(Float(ts.count - 1) * (1 - AutoTone.endPercentile))]
        XCTAssertEqual(current.remap(white), AutoTone.whitesTarget, accuracy: 0.05)
        XCTAssertEqual(current.highlights, 0.5)
        XCTAssertEqual(AutoTone.value(for: .shadows, in: suggestion, current: current), measured.ranges.shadows)
    }

    /// On the real raw: every value is finite and within Auto's limits.
    func testSuggestionOnARealImage() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: try TestAssets.d750Path()), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var params = EditParameters()
        params.whiteBalance = session.asShotWhiteBalance
        let first = try AutoAdjust.suggest(for: session, pipeline: pipeline, gpu: gpu, current: params)
        params.exposureEV = first.exposureEV
        params.contrast = first.contrast
        let tone = try AutoTone.suggest(for: session, pipeline: pipeline, gpu: gpu, parameters: params)
        for v in [tone.toneRanges.highlights, tone.toneRanges.shadows, tone.toneRanges.whites, tone.toneRanges.blacks] {
            XCTAssertTrue(v.isFinite)
            XCTAssertLessThanOrEqual(abs(v), AutoTone.limit)
        }
        XCTAssertTrue((0...0.25).contains(tone.vibrance))
        XCTAssertTrue((0...0.05).contains(tone.saturation))
        XCTAssertNotNil(tone.whitePoint)
        XCTAssertNotNil(tone.blackPoint)
        // Measured with the tone ranges reset: the same whatever they were.
        var moved = params
        moved.toneRanges = ToneRanges(highlights: -1, shadows: 1, whites: 1, blacks: -1)
        XCTAssertEqual(try AutoTone.suggest(for: session, pipeline: pipeline, gpu: gpu, parameters: moved), tone)
    }

    // MARK: - Match Total Exposures

    func testCameraExposureAndMatching() throws {
        // 1/100 s, f/4, ISO 100.
        let base = try XCTUnwrap(ExposureMatching.cameraExposure(shutter: 0.01, aperture: 4, iso: 100))
        // A stop more light three ways: twice the time, ISO 200, f/2.8.
        let longer = try XCTUnwrap(ExposureMatching.cameraExposure(shutter: 0.02, aperture: 4, iso: 100))
        let faster = try XCTUnwrap(ExposureMatching.cameraExposure(shutter: 0.01, aperture: 4, iso: 200))
        let wider = try XCTUnwrap(ExposureMatching.cameraExposure(shutter: 0.01, aperture: 2.8284271, iso: 100))
        XCTAssertEqual(longer - base, 1, accuracy: 1e-6)
        XCTAssertEqual(faster - base, 1, accuracy: 1e-6)
        XCTAssertEqual(wider - base, 1, accuracy: 1e-5)
        XCTAssertNil(ExposureMatching.cameraExposure(shutter: nil, aperture: 4, iso: 100))
        XCTAssertNil(ExposureMatching.cameraExposure(shutter: 0.01, aperture: 0, iso: 100))

        // A bracket at -2, 0, +2 matched to the middle frame with +0.5 on it.
        let target = base + 0.5
        XCTAssertEqual(ExposureMatching.matchedExposure(target: target, camera: base - 2), 2.5)
        XCTAssertEqual(ExposureMatching.matchedExposure(target: target, camera: base + 2), -1.5)
        XCTAssertEqual(ExposureMatching.matchedExposure(target: target, camera: base - 9), 5, "held to the slider")
    }

    /// Only Exposure changes; every other module is kept.
    func testSettingExposureKeepsTheRestOfTheEdit() throws {
        var p = EditParameters()
        p.contrast = 1.8
        p.toneRanges = ToneRanges(highlights: -0.4)
        p.vibrance = 0.3
        let json = try EditStack(parameters: p).encodeJSON()
        let changed = try ExposureMatching.settingExposure(1.25, inEditJSON: json)
        var expected = try EditStack.decode(json: json).parameters()
        expected.exposureEV = 1.25
        XCTAssertEqual(try EditStack.decode(json: changed).parameters(), expected)
        XCTAssertEqual(try ExposureMatching.exposure(inEditJSON: changed), 1.25)
        XCTAssertEqual(try ExposureMatching.exposure(inEditJSON: nil), 0)
        let fresh = try ExposureMatching.settingExposure(-0.5, inEditJSON: nil)
        XCTAssertEqual(try EditStack.decode(json: fresh).parameters().exposureEV, -0.5)
    }

    // MARK: - Hue isolation

    /// The red band keeps red and turns blue and grey grey; the blue band
    /// the other way round.
    func testHueIsolationKeepsOnlyTheBand() throws {
        let gpu = try GPUContext()
        let pixels: [Float] = [0.8, 0.05, 0.05,  0.05, 0.1, 0.8,  0.4, 0.4, 0.4]
        let source = try XCTUnwrap(makeTexture(gpu, width: 3, height: 1, pixels: pixels))
        func isolate(_ band: Int) throws -> [Float] {
            let target = try XCTUnwrap(makeTexture(gpu, width: 3, height: 1, pixels: [Float](repeating: 0, count: 9)))
            let commands = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
            try RenderPipeline.encodeHueIsolation(input: source, output: target, band: band, gpu: gpu,
                                                  commandBuffer: commands)
            commands.commit()
            commands.waitUntilCompleted()
            return readRGB(target)
        }
        func isGrey(_ p: ArraySlice<Float>) -> Bool { p.max()! - p.min()! < 0.01 }
        let red = try isolate(0)
        XCTAssertGreaterThan(red[0] - red[1], 0.5, "red stays red")
        XCTAssertTrue(isGrey(red[3..<6]), "blue goes grey")
        XCTAssertTrue(isGrey(red[6..<9]), "grey stays grey")
        let blue = try isolate(5)
        XCTAssertTrue(isGrey(blue[0..<3]), "red goes grey")
        XCTAssertGreaterThan(blue[5] - blue[3], 0.5, "blue stays blue")
    }

    // MARK: - HDR ranges and readout

    /// SDR turns grey; each stop above white its own colour; the ceiling
    /// magenta. Off, nothing changes.
    func testVisualiseHDRRanges() throws {
        let gpu = try GPUContext()
        let presenter = Presenter(gpu: gpu)
        let pixels: [Float] = [0.5, 0.5, 0.5,  1.5, 1.4, 1.3,  3, 3, 3,  6, 5, 5,  8, 8, 8]
        let size = CGSize(width: 5, height: 1)
        let source = try XCTUnwrap(makeTexture(gpu, width: 5, height: 1, pixels: pixels))
        func present(_ clipping: ClippingIndicators) throws -> [Float] {
            let target = try XCTUnwrap(makeTexture(gpu, width: 5, height: 1,
                                                   pixels: [Float](repeating: 0, count: pixels.count)))
            let layer = PresentLayer(texture: source, coverage: CGRect(origin: .zero, size: size), headroom: 8)
            let commands = try XCTUnwrap(presenter.encode(
                base: layer, tile: nil, transform: .fit(imageSize: size, drawableSize: size),
                frame: CropFrame(sensorSize: size), into: target,
                backgroundLevel: 0, displayHeadroom: 8, clipping: clipping))
            commands.commit()
            commands.waitUntilCompleted()
            return readRGB(target)
        }
        XCTAssertEqual(try present([]), pixels.map { Float(Float16($0)) })
        let shown = try present(.hdrRanges)
        XCTAssertEqual(shown[0], 0.25, accuracy: 0.01, "SDR: a dimmed grey")
        XCTAssertEqual(shown[0], shown[2], accuracy: 1e-3)
        func assertColour(_ at: Int, _ expected: [Float], _ message: String) {
            for c in 0..<3 { XCTAssertEqual(shown[at * 3 + c], expected[c], accuracy: 0.002, message) }
        }
        assertColour(1, [0.1, 0.4, 1.0], "under a stop: blue")
        assertColour(2, [0.2, 0.85, 0.3], "one to two: green")
        assertColour(3, [1.0, 0.9, 0.1], "two to three: yellow")
        assertColour(4, [1, 0, 1], "at the ceiling: magenta")
    }

    func testReadoutStopsAboveWhite() throws {
        XCTAssertNil(PixelReadout(linearDisplayP3: SIMD3(0.9, 1, 0.5)).stopsAboveSDRWhite)
        let hdr = try XCTUnwrap(PixelReadout(linearDisplayP3: SIMD3(4, 2, 1)).stopsAboveSDRWhite)
        XCTAssertEqual(hdr, 2, accuracy: 1e-5)
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
        var rgb: [Float] = []
        for i in 0..<texture.width * texture.height {
            for c in 0..<3 { rgb.append(Float(half[i * 4 + c])) }
        }
        return rgb
    }
}
