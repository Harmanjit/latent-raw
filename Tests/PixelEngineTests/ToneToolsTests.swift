import XCTest
import Metal
import simd
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// The tone and colour tools: the region (parametric) curve, point-curve
/// presets, Refine Saturation, white balance presets and the selector,
/// the pointer readout and the clipping overlay.
final class ToneToolsTests: XCTestCase {

    // MARK: - Region curve

    func testNeutralRegionCurveIsTheStraightLine() {
        XCTAssertEqual(ParametricCurve.neutral.lookupTable(), ToneCurve.identity.lookupTable())
        // Moving only the splits changes nothing.
        var moved = ParametricCurve.neutral
        moved.setSplit(1, to: 0.3)
        XCTAssertTrue(moved.isNeutral)
        XCTAssertEqual(moved.lookupTable(), ToneCurve.identity.lookupTable())
    }

    func testNeutralRegionCurveLeavesThePointCurveTableAlone() {
        let curve = ToneCurve.Preset.strongContrast.curve
        XCTAssertEqual(curve.masterLookupTable(parametric: .neutral), curve.lookupTable(),
                       "the kernel's table is the point curve's own, value for value")
    }

    func testEachRegionMovesItsOwnTones() {
        let lut = { (c: ParametricCurve) in c.lookupTable() }
        let at = { (table: [Float], x: Float) in ToneCurve.sample(table, at: x) }
        let shadows = lut(ParametricCurve(shadows: 1))
        XCTAssertGreaterThan(at(shadows, 0.125), 0.2, "Shadows +100 lifts its region")
        XCTAssertEqual(at(shadows, 0.9), 0.9, accuracy: 0.002, "and leaves the highlights")
        let highlights = lut(ParametricCurve(highlights: -1))
        XCTAssertLessThan(at(highlights, 0.875), 0.8, "Highlights −100 darkens its region")
        XCTAssertEqual(at(highlights, 0.2), 0.2, accuracy: 0.002, "and leaves the shadows")
        let darks = lut(ParametricCurve(darks: 1))
        XCTAssertGreaterThan(at(darks, 0.375), 0.43)
        let lights = lut(ParametricCurve(lights: -1))
        XCTAssertLessThan(at(lights, 0.625), 0.57)
        // Moving the split moves where a region acts.
        let wide = lut(ParametricCurve(shadows: 1, shadowSplit: 0.45, midSplit: 0.6, highlightSplit: 0.8))
        XCTAssertGreaterThan(at(wide, 0.3) - 0.3, at(shadows, 0.3) - 0.3)
    }

    func testRegionCurveNeverReversesTonesAndKeepsItsEnds() {
        for amounts in [[1, -1, 1, -1], [-1, -1, -1, -1], [1, 1, 1, 1], [-1, 1, -1, 1]] as [[Float]] {
            var c = ParametricCurve(shadowSplit: 0.1, midSplit: 0.15, highlightSplit: 0.95)
            c.amounts = amounts
            let lut = c.lookupTable()
            for i in 1..<lut.count { XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1], "\(amounts) at \(i)") }
            XCTAssertEqual(lut.first!, 0, accuracy: 1e-6)
            XCTAssertEqual(lut.last!, 1, accuracy: 1e-6)
        }
    }

    func testSplitsStayInOrder() {
        var c = ParametricCurve.neutral
        c.setSplit(0, to: 0.9)
        XCTAssertLessThan(c.shadowSplit, c.midSplit)
        c.setSplit(2, to: 0)
        XCTAssertGreaterThan(c.highlightSplit, c.midSplit)
        let messy = ParametricCurve(shadows: 7, shadowSplit: 0.9, midSplit: .nan, highlightSplit: -2).sanitized
        XCTAssertEqual(messy.shadows, 1)
        XCTAssertLessThan(messy.shadowSplit, messy.midSplit)
        XCTAssertLessThan(messy.midSplit, messy.highlightSplit)
        XCTAssertGreaterThan(messy.shadowSplit, 0)
        XCTAssertLessThan(messy.highlightSplit, 1)
    }

    func testRegionsFollowTheSplits() {
        let c = ParametricCurve.neutral
        XCTAssertEqual(c.region(containing: 0.1), .shadows)
        XCTAssertEqual(c.region(containing: 0.3), .darks)
        XCTAssertEqual(c.region(containing: 0.6), .lights)
        XCTAssertEqual(c.region(containing: 0.99), .highlights)
    }

    func testRegionCurveAppliesBeforeThePoints() {
        let points = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.25), SIMD2(1, 1)])
        let region = ParametricCurve(darks: 1)
        let combined = points.masterLookupTable(parametric: region)
        let x: Float = 0.375
        let expected = ToneCurve.sample(points.lookupTable(), at: ToneCurve.sample(region.lookupTable(), at: x))
        XCTAssertEqual(ToneCurve.sample(combined, at: x), expected, accuracy: 0.004)
    }

    // MARK: - Point curve presets and the inverse

    func testPointCurvePresets() {
        XCTAssertEqual(ToneCurve.Preset.linear.curve, .identity)
        for preset in [ToneCurve.Preset.mediumContrast, .strongContrast] {
            let lut = preset.curve.lookupTable()
            for i in 1..<lut.count { XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1]) }
            XCTAssertLessThan(ToneCurve.sample(lut, at: 0.2), 0.2, "\(preset.title) darkens the shadows")
            XCTAssertGreaterThan(ToneCurve.sample(lut, at: 0.8), 0.8, "and lightens the highlights")
            XCTAssertEqual(ToneCurve.Preset.matching(preset.curve), preset)
        }
        let strong = ToneCurve.Preset.strongContrast.curve.lookupTable()
        let medium = ToneCurve.Preset.mediumContrast.curve.lookupTable()
        XCTAssertLessThan(ToneCurve.sample(strong, at: 0.2), ToneCurve.sample(medium, at: 0.2))
        XCTAssertNil(ToneCurve.Preset.matching(ToneCurve(points: [SIMD2(0, 0.1), SIMD2(1, 1)])))
    }

    func testInverseFindsTheInputTone() {
        let lut = ToneCurve.Preset.strongContrast.curve.lookupTable()
        for x in stride(from: Float(0.05), through: 0.95, by: 0.1) {
            XCTAssertEqual(ToneCurve.inverse(lut, at: ToneCurve.sample(lut, at: x)), x, accuracy: 0.01)
        }
        // A flat run answers its middle.
        let crushed = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.2, 0), SIMD2(1, 1)]).lookupTable()
        XCTAssertEqual(ToneCurve.inverse(crushed, at: 0), 0)
        XCTAssertEqual(ToneCurve.inverse(ToneCurve.identity.lookupTable(), at: 0.5), 0.5, accuracy: 0.003)
    }

    // MARK: - Persistence

    func testUntouchedEditsEncodeAsBefore() throws {
        let stack = EditStack(parameters: EditParameters())
        XCTAssertFalse(try stack.encodeJSON().contains("parametric"))
        XCTAssertNil(stack.modules.curve?.saturation, "no Refine Saturation key at zero")
        XCTAssertNil(stack.modules.curve?.parametric)
        var p = EditParameters()
        p.toneCurve = ToneCurve.Preset.mediumContrast.curve
        let curveOnly = try EditStack(parameters: p).encodeJSON()
        XCTAssertFalse(curveOnly.contains("parametric"))
    }

    func testRegionCurveAndRefineSaturationRoundTrip() throws {
        var p = EditParameters()
        p.parametricCurve = ParametricCurve(shadows: 0.3, darks: -0.2, lights: 0.1, highlights: -0.4,
                                            shadowSplit: 0.2, midSplit: 0.45, highlightSplit: 0.8)
        p.curveSaturation = -0.5
        p.toneCurve = ToneCurve.Preset.strongContrast.curve
        let json = try EditStack(parameters: p).encodeJSON()
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.parametricCurve, p.parametricCurve)
        XCTAssertEqual(back.curveSaturation, p.curveSaturation)
        XCTAssertEqual(back, p)
        // And the stack written back is the same again.
        XCTAssertEqual(try EditStack(parameters: back).encodeJSON(), json)
    }

    func testOldAndPartialStacksDecode() throws {
        let old = #"{"schema":1,"process":"1.0","modules":{"curve":{"points":[[0,0],[0.5,0.6],[1,1]]}}}"#
        let p = try EditStack.decode(json: old).parameters()
        XCTAssertEqual(p.parametricCurve, .neutral)
        XCTAssertEqual(p.curveSaturation, 0)
        let partial = #"{"schema":1,"process":"1.0","modules":{"curve":{"points":[[0,0],[1,1]],"parametric":{"darks":0.5},"saturation":9}}}"#
        let q = try EditStack.decode(json: partial).parameters()
        XCTAssertEqual(q.parametricCurve.darks, 0.5)
        XCTAssertEqual(q.parametricCurve.shadowSplit, 0.25)
        XCTAssertEqual(q.curveSaturation, 1, "clamped")
    }

    func testHistoryAndCopyPasteCarryThem() {
        let a = EditParameters()
        var b = a; b.parametricCurve.lights = 0.4
        var c = a; c.curveSaturation = 0.3
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: a), to: EditStack(parameters: b)), "Curve")
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: a), to: EditStack(parameters: c)), "Curve")
        let pasted = EditStack(parameters: a).merged(with: EditStack(parameters: b), groups: [.toneCurve]).parameters()
        XCTAssertEqual(pasted.parametricCurve.lights, 0.4)
        XCTAssertFalse(EditStack.isDefault(b, relativeTo: a))
        XCTAssertFalse(EditStack.isDefault(c, relativeTo: a))
    }

    // MARK: - White balance

    /// Adobe's D750 colour matrix, as LibRaw gives it (XYZ to camera).
    private let d750 = ColorKit.CameraColorProfile(cameraToXYZRowMajor: [
        0.9020, -0.2890, -0.0715, -0.4535, 1.2436, 0.2348, -0.0934, 0.1919, 0.7086,
    ])!

    func testPresetsMatchTheirSettings() {
        let asShot = ColorKit.WhiteBalance(temperature: 5120, tint: 3)
        XCTAssertEqual(WhiteBalancePreset.matching(asShot, asShot: asShot), .asShot)
        XCTAssertEqual(WhiteBalancePreset.matching(.asShot, asShot: asShot), .asShot)
        XCTAssertEqual(WhiteBalancePreset.matching(WhiteBalancePreset.tungsten.fixed!, asShot: asShot), .tungsten)
        XCTAssertEqual(WhiteBalancePreset.matching(WhiteBalancePreset.flash.fixed!, asShot: asShot), .daylight)
        let auto = ColorKit.WhiteBalance(temperature: 4321, tint: -2)
        XCTAssertEqual(WhiteBalancePreset.matching(auto, asShot: asShot, auto: auto), .auto)
        XCTAssertNil(WhiteBalancePreset.matching(.init(temperature: 4000, tint: 0), asShot: asShot))
        for preset in WhiteBalancePreset.allCases {
            if let wb = preset.fixed {
                XCTAssertTrue(ColorKit.WhiteBalance.temperatureRange.contains(wb.temperature), preset.title)
            }
        }
    }

    func testFluorescentLeansMagenta() {
        let plain = d750.multipliers(for: .init(temperature: 3800, tint: 0))
        let fluorescent = d750.multipliers(for: WhiteBalancePreset.fluorescent.fixed!)
        // Multipliers are relative to green: more red and blue is less green.
        XCTAssertGreaterThan(fluorescent.x, plain.x)
        XCTAssertGreaterThan(fluorescent.z, plain.z)
    }

    func testSelectorNeutralisesThePickedColour() throws {
        let current = d750.multipliers(for: .init(temperature: 5500, tint: 0))
        // A grey card under 3200 K light, as the camera saw it, then
        // multiplied by the current setting.
        let light = ColorKit.xyzFromChromaticity(ColorKit.chromaticity(.init(temperature: 3200, tint: 0)))
        let response = d750.xyzToCamera * light * 0.2
        let mean = response * SIMD3(current.x, current.y, current.z)
        let clip = SIMD3<Float>(current.x, current.y, current.z)
        guard case .balanced(let wb) = WhiteBalancePicker.outcome(mean: mean, peak: mean, clip: clip,
                                                                  multipliers: current, profile: d750) else {
            return XCTFail("a mid grey should balance")
        }
        XCTAssertEqual(wb.temperature, 3200, accuracy: 40)
        XCTAssertEqual(wb.tint, 0, accuracy: 2)

        XCTAssertEqual(WhiteBalancePicker.outcome(mean: mean, peak: clip, clip: clip,
                                                  multipliers: current, profile: d750), .clipped)
        XCTAssertEqual(WhiteBalancePicker.outcome(mean: mean * 0.001, peak: mean * 0.001, clip: clip,
                                                  multipliers: current, profile: d750), .tooDark)
    }

    // MARK: - Readout

    func testReadoutOfWhiteBlackAndGrey() {
        let white = PixelReadout(linearDisplayP3: SIMD3(1, 1, 1))
        for c in 0..<3 { XCTAssertEqual(white.percent[c], 100, accuracy: 1e-3) }
        XCTAssertEqual(white.lab.x, 100, accuracy: 0.1)
        XCTAssertEqual(white.lab.y, 0, accuracy: 0.3)
        XCTAssertEqual(white.lab.z, 0, accuracy: 0.3)
        let black = PixelReadout(linearDisplayP3: .zero)
        XCTAssertEqual(black.lab.x, 0, accuracy: 0.01)
        let grey = PixelReadout(linearDisplayP3: SIMD3(repeating: 0.18))
        XCTAssertEqual(grey.lab.x, 49.5, accuracy: 0.5, "18 % grey is L* 50")
        XCTAssertEqual(grey.percent.x, 46.1, accuracy: 0.2)
        let red = PixelReadout(linearDisplayP3: SIMD3(1, 0, 0))
        XCTAssertGreaterThan(red.lab.y, 60, "P3 red has a large positive a*")
        XCTAssertGreaterThan(HSLAdjustments.bandWeights(hue: red.gradingCoordinates().hue)[0], 0.4,
                             "and sits mostly in the Red band")
    }

    func testBandWeightsMatchTheKernel() {
        XCTAssertEqual(HSLAdjustments.bandWeights(hue: 0), [1, 0, 0, 0, 0, 0, 0, 0])
        let orangeYellow = HSLAdjustments.bandWeights(hue: 45)
        XCTAssertEqual(orangeYellow[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(orangeYellow[2], 0.5, accuracy: 1e-6)
        let wrap = HSLAdjustments.bandWeights(hue: 330)
        XCTAssertEqual(wrap[7], 0.5, accuracy: 1e-6)
        XCTAssertEqual(wrap[0], 0.5, accuracy: 1e-6)
        for hue in stride(from: Float(0), to: 360, by: 7) {
            XCTAssertEqual(HSLAdjustments.bandWeights(hue: hue).reduce(0, +), 1, accuracy: 1e-5)
        }
    }

    // MARK: - GPU

    func testRegionReadbackReadsThePixelsAsked() throws {
        let gpu = try GPUContext()
        let pixels: [Float] = (0..<12).flatMap { i in [Float(i) / 16, 0.5, 0.25] }
        let texture = try XCTUnwrap(makeTexture(gpu, width: 4, height: 3, pixels: pixels))
        let one = try TextureReadback.float16Pixels(of: texture, x: 2, y: 1, width: 1, height: 1, gpu: gpu)
        XCTAssertEqual(Float(one[0]), 6.0 / 16, accuracy: 1e-3)
        // Asking past the edge is clipped to the texture, not an error.
        let edge = try TextureReadback.float16Pixels(of: texture, x: 3, y: 2, width: 5, height: 5, gpu: gpu)
        XCTAssertEqual(edge.count, 4)
        XCTAssertEqual(Float(edge[0]), 11.0 / 16, accuracy: 1e-3)
    }

    /// Off, the overlay changes nothing; on, a clipped pixel turns red and
    /// a black one blue, and nothing else moves.
    func testClippingOverlay() throws {
        let gpu = try GPUContext()
        let presenter = Presenter(gpu: gpu)
        let pixels: [Float] = [1, 0.4, 0.2,  0.5, 0.5, 0.5,  0, 0, 0,  0.001, 0, 0]
        let size = CGSize(width: 4, height: 1)
        let source = try XCTUnwrap(makeTexture(gpu, width: 4, height: 1, pixels: pixels))

        func present(_ clipping: ClippingIndicators) throws -> [Float] {
            let target = try XCTUnwrap(makeTexture(gpu, width: 4, height: 1,
                                                   pixels: [Float](repeating: 0, count: pixels.count)))
            let layer = PresentLayer(texture: source, coverage: CGRect(origin: .zero, size: size))
            let commands = try XCTUnwrap(presenter.encode(
                base: layer, tile: nil, transform: .fit(imageSize: size, drawableSize: size),
                frame: CropFrame(sensorSize: size), into: target,
                backgroundLevel: 0, displayHeadroom: 1, clipping: clipping))
            commands.commit()
            commands.waitUntilCompleted()
            return readRGB(target)
        }

        let plain = try present([])
        XCTAssertEqual(plain, pixels.map { Float(Float16($0)) })
        let both = try present(.both)
        XCTAssertEqual(Array(both[0..<3]), [1, 0, 0], "a channel at the top: red")
        XCTAssertEqual(Array(both[3..<6]), Array(plain[3..<6]), "a midtone is untouched")
        XCTAssertEqual(both[8], 1, "black: blue")
        XCTAssertEqual(Array(both[9..<12]), Array(plain[9..<12]), "a pixel with any light isn't crushed")
        let highlightsOnly = try present(.highlights)
        XCTAssertEqual(Array(highlightsOnly[6..<9]), [0, 0, 0], "shadows off: black stays black")
    }

    /// On a real raw: an untouched region curve and Refine Saturation at
    /// zero render bit for bit as before; the region sliders and Refine
    /// Saturation do what they say.
    func testEffectsOnARealImage() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        func pixels(_ p: EditParameters) throws -> [Float] {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
            return try TextureReadback.float16Pixels(of: tex, gpu: gpu).map { Float($0) }
        }
        func meanLuma(_ px: [Float]) -> Float {
            var t: Float = 0
            for i in stride(from: 0, to: px.count, by: 4) { t += 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2] }
            return t / Float(px.count / 4)
        }
        func meanChroma(_ px: [Float]) -> Float {
            var t: Float = 0
            for i in stride(from: 0, to: px.count, by: 4) { t += max(px[i], px[i + 1], px[i + 2]) - min(px[i], px[i + 1], px[i + 2]) }
            return t / Float(px.count / 4)
        }

        let plain = try pixels(EditParameters())
        var inert = EditParameters()
        inert.parametricCurve = ParametricCurve(shadowSplit: 0.3, midSplit: 0.4, highlightSplit: 0.9)
        inert.curveSaturation = 0.7   // no curve, so nothing to refine
        XCTAssertTrue(try pixels(inert) == plain, "inactive: bit for bit")

        var contrast = EditParameters()
        contrast.toneCurve = ToneCurve.Preset.strongContrast.curve
        let curved = try pixels(contrast)
        var zeroRefine = contrast; zeroRefine.curveSaturation = 0
        XCTAssertTrue(try pixels(zeroRefine) == curved)

        var lifted = EditParameters(); lifted.parametricCurve.shadows = 1
        XCTAssertGreaterThan(meanLuma(try pixels(lifted)), meanLuma(plain) + 0.01, "Shadows +100 lightens")
        var darkened = EditParameters(); darkened.parametricCurve.lights = -1
        XCTAssertLessThan(meanLuma(try pixels(darkened)), meanLuma(plain) - 0.005, "Lights −100 darkens")

        var muted = contrast; muted.curveSaturation = -1
        var boosted = contrast; boosted.curveSaturation = 1
        let chroma = meanChroma(curved)
        XCTAssertLessThan(meanChroma(try pixels(muted)), chroma, "−100 takes back the curve's colour")
        XCTAssertGreaterThan(meanChroma(try pixels(boosted)), chroma, "+100 adds to it")
        XCTAssertEqual(meanLuma(try pixels(muted)), meanLuma(curved), accuracy: 0.02, "brightness stays")
    }

    /// The selector on a real raw: picking a spot gives a setting, and
    /// picking it again with that setting barely moves it.
    func testSelectorOnARealImageSettles() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        p.whiteBalance = session.asShotWhiteBalance ?? .init(temperature: 5500, tint: 0)
        var found: ColorKit.WhiteBalance?
        for point in [SIMD2<Float>(0.5, 0.5), SIMD2(0.3, 0.4), SIMD2(0.7, 0.6), SIMD2(0.5, 0.2)] {
            if case .balanced(let wb) = try WhiteBalancePicker.whiteBalance(at: point, session: session, pipeline: pipeline,
                                                                          gpu: gpu, parameters: p) {
                p.whiteBalance = wb
                guard case .balanced(let again) = try WhiteBalancePicker.whiteBalance(
                    at: point, session: session, pipeline: pipeline, gpu: gpu, parameters: p) else {
                    return XCTFail("the same spot should balance again")
                }
                XCTAssertEqual(again.temperature, wb.temperature, accuracy: wb.temperature * 0.02)
                XCTAssertEqual(again.tint, wb.tint, accuracy: 1.5)
                found = wb
                break
            }
        }
        XCTAssertNotNil(found, "some spot in the frame is neither black nor clipped")
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
}
