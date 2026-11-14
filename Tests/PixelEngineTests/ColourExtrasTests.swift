import XCTest
import Metal
import simd
import CoreGraphics
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// Calibration's Adaptation, the Channel Mixer, Gamut Compression,
/// Highlight Purity, Colour Grading's per-range saturation and hue shift,
/// Black Offset and the exposure tools (ChromaticAdaptation.swift,
/// ChannelMixer.swift, ExposurePicking.swift, ColourGradingRanges.swift).
final class ColourExtrasTests: XCTestCase {
    static func everything() -> EditParameters {
        var p = EditParameters()
        p.blackOffset = 0.01
        p.colour.adaptation = ChromaticAdaptation(method: .bradford, illuminant: .a, hue: 10, chroma: -0.2)
        p.colour.channelMixer = ChannelMixer(red: [1.2, -0.1, -0.1], green: [0, 1, 0], blue: [0.1, 0, 0.9],
                                             normalise: true)
        p.colour.gamutCompression = 0.6
        p.colour.purity = 0.4
        p.colour.grading.shadowSaturation = -0.3
        p.colour.grading.midtoneSaturation = 0.2
        p.colour.grading.highlightSaturation = 0.5
        p.colour.grading.hueShift = 25
        return p
    }

    static let newKeys = ["blackOffset", "adaptation", "channelmixer", "gamutcompression", "purity",
                          "shadowSaturation", "midtoneSaturation", "highlightSaturation", "hueShift"]

    // MARK: - Stored form

    func testRoundTripThroughJSON() throws {
        let p = Self.everything()
        let json = try EditStack(parameters: p).encodeJSON()
        for key in Self.newKeys { XCTAssertTrue(json.contains("\"\(key)\""), key) }
        let stack = try EditStack.decode(json: json)
        XCTAssertEqual(stack.schema, EditStack.schemaVersion)
        XCTAssertEqual(stack.parameters(), p)
        XCTAssertFalse(EditStack.isDefault(p, relativeTo: EditParameters()))
    }

    /// Old edits, the existing colour controls included, encode byte for
    /// byte as before: none of the new keys appear and a stored stack
    /// reads back and writes out unchanged.
    func testOldEditsEncodeExactlyAsBefore() throws {
        for p in [EditParameters(), ColourControlsTests.everything()] {
            let json = try EditStack(parameters: p).encodeJSON()
            // Split Toning and Point Colour have keys of the same names, so
            // look inside the modules the new fields live in.
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let modules = try XCTUnwrap(object["modules"] as? [String: Any])
            for key in ["adaptation", "channelmixer", "gamutcompression", "purity"] { XCTAssertNil(modules[key], key) }
            XCTAssertNil((modules["exposure"] as? [String: Any])?["blackOffset"])
            if let grading = modules["colorgrading"] as? [String: Any] {
                XCTAssertEqual(Set(grading.keys), ["midtones", "global", "shadowLuminance", "highlightLuminance", "blending"])
            }
            XCTAssertEqual(try EditStack.decode(json: json).encodeJSON(), json)
            XCTAssertEqual(try EditStack(parameters: EditStack.decode(json: json).parameters()).encodeJSON(), json)
        }
        let old = """
        {"modules":{"colorgrading":{"blending":0.7,"global":{"hue":40,"luminance":0,"saturation":0.1},\
        "highlightLuminance":0,"midtones":{"hue":120,"luminance":0,"saturation":0.3},"shadowLuminance":0},\
        "exposure":{"ev":0.5}},"process":"1.0","schema":1}
        """
        let stack = try EditStack.decode(json: old)
        XCTAssertEqual(try stack.encodeJSON(), old)
        let p = stack.parameters()
        XCTAssertEqual(p.blackOffset, 0)
        XCTAssertFalse(p.colour.grading.hasRangeExtras)
        XCTAssertEqual(p.colour.adaptation, .neutral)
        XCTAssertEqual(p.colour.channelMixer, .identity)
    }

    func testLenientAndSanitisedDecoding() throws {
        let json = """
        {"schema":1,"process":"1.0","modules":{"exposure":{"ev":0,"blackOffset":3},\
        "adaptation":{"method":"nonsense","illuminant":"custom","x":9,"y":0.3,"hue":900},\
        "channelmixer":{"red":[5,0],"blue":[0,-9,1]},"gamutcompression":{"amount":4},"purity":{"amount":-1},\
        "colorgrading":{"hueShift":400,"shadowSaturation":-7}}}
        """
        let p = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(p.blackOffset, 0.05)
        XCTAssertEqual(p.colour.adaptation.method, .cat16)
        XCTAssertEqual(p.colour.adaptation.illuminant, .custom)
        XCTAssertEqual(p.colour.adaptation.x, 0.6)
        XCTAssertEqual(p.colour.adaptation.hue, 180)
        XCTAssertEqual(p.colour.channelMixer.red, [1, 0, 0], "a row of the wrong length is the identity's")
        XCTAssertEqual(p.colour.channelMixer.blue, [0, -2, 1])
        XCTAssertEqual(p.colour.gamutCompression, 1)
        XCTAssertEqual(p.colour.purity, 0)
        XCTAssertEqual(p.colour.grading.hueShift, 180)
        XCTAssertEqual(p.colour.grading.shadowSaturation, -1)
    }

    /// The new modules travel with Calibration; Black Offset with Tone.
    func testGroupsAndHistory() throws {
        let source = EditStack(parameters: Self.everything())
        let merged = EditStack().merged(with: source, groups: [.calibration])
        XCTAssertNotNil(merged.modules.adaptation)
        XCTAssertNotNil(merged.modules.channelmixer)
        XCTAssertNotNil(merged.modules.gamutcompression)
        XCTAssertNotNil(merged.modules.purity)
        XCTAssertTrue(source.presentGroups.contains(.calibration))
        XCTAssertEqual(EditStack().merged(with: source, groups: [.tone]).modules.exposure?.blackOffset, 0.01)
        let names = EditHistory.colourChanges(from: EditStack().modules, to: source.modules)
        for name in ["Adaptation", "Channel Mixer", "Gamut Compression", "Highlight Purity"] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    func testPresetAmountBlendsTheSliders() {
        let full = Self.everything()
        let half = full.blended(from: EditParameters(), amount: 0.5)
        XCTAssertEqual(half.blackOffset, 0.005, accuracy: 1e-6)
        XCTAssertEqual(half.colour.gamutCompression, 0.3, accuracy: 1e-6)
        XCTAssertEqual(half.colour.purity, 0.2, accuracy: 1e-6)
        XCTAssertEqual(half.colour.grading.hueShift, 12.5, accuracy: 1e-5)
        XCTAssertEqual(half.colour.channelMixer.red[0], 1.1, accuracy: 1e-6)
        XCTAssertEqual(half.colour.grading.highlightSaturation, 0.25, accuracy: 1e-6)
    }

    /// Black Offset is kept when Match Total Exposures sets Exposure.
    func testSettingExposureKeepsBlackOffset() throws {
        var p = EditParameters()
        p.blackOffset = -0.02
        let json = try ExposureMatching.settingExposure(1, inEditJSON: try EditStack(parameters: p).encodeJSON())
        XCTAssertEqual(try EditStack.decode(json: json).parameters().blackOffset, -0.02)
    }

    // MARK: - Matrices

    func testAdaptationCarriesTheLightToD65() {
        XCTAssertEqual(ChromaticAdaptation.neutral.matrix, matrix_identity_float3x3)
        XCTAssertEqual(ChromaticAdaptation(method: .bradford, illuminant: .d65).matrix, matrix_identity_float3x3)
        let toWorking = ColorKit.rec2020ToXYZ.inverse
        let d65 = toWorking * ColorKit.d65XYZ
        for method in ChromaticAdaptation.Method.allCases {
            for light in [ChromaticAdaptation.Illuminant.a, .f11, .ledB1, .d50, .e] {
                let a = ChromaticAdaptation(method: method, illuminant: light)
                let white = toWorking * ChromaticAdaptation.xyz(a.sourceXY)
                let carried = a.matrix * white
                XCTAssertEqual(simd_distance(carried, d65), 0, accuracy: 1e-3, "\(method) \(light)")
            }
        }
        // Tungsten adapted to daylight: a neutral grey under D65 turns blue.
        let grey = ChromaticAdaptation(illuminant: .a).matrix * SIMD3<Float>(0.5, 0.5, 0.5)
        XCTAssertGreaterThan(grey.z, grey.x)
        // Fine-tuning moves the light; Chroma −1 brings it to D65.
        XCTAssertNotEqual(ChromaticAdaptation(illuminant: .a, hue: 30).sourceXY, ChromaticAdaptation(illuminant: .a).sourceXY)
        XCTAssertTrue(ChromaticAdaptation(illuminant: .a, chroma: -1).isIdentity)
    }

    func testChannelMixer() {
        XCTAssertEqual(ChannelMixer.identity.matrix, matrix_identity_float3x3)
        let mono = ChannelMixer.monochrome.matrix * SIMD3<Float>(0.8, 0.2, 0.1)
        XCTAssertEqual(mono.x, mono.y); XCTAssertEqual(mono.y, mono.z)
        let swap = ChannelMixer(red: [0, 1, 0], green: [1, 0, 0]).matrix * SIMD3<Float>(0.8, 0.2, 0.1)
        XCTAssertEqual(swap, SIMD3(0.2, 0.8, 0.1))
        // Normalise keeps a grey the grey it was.
        let boosted = ChannelMixer(red: [2, 0.5, 0], green: [0, 1, 0], blue: [0, 0, 1], normalise: true)
        let g = boosted.matrix * SIMD3<Float>(0.3, 0.3, 0.3)
        XCTAssertEqual(g.x, 0.3, accuracy: 1e-6)
    }

    /// With neither Adaptation nor the mixer the matrix is exactly the one
    /// existing edits used; with them, they fold in around Calibration.
    func testCalibratedMatrix() {
        let camera = simd_float3x3(rows: [SIMD3(1.6, -0.4, -0.2), SIMD3(-0.2, 1.5, -0.3), SIMD3(0.05, -0.5, 1.45)])
        var c = ColourControls()
        XCTAssertEqual(RenderPipeline.calibrated(camera, c), camera)
        c.calibration.redHue = 0.4
        XCTAssertEqual(RenderPipeline.calibrated(camera, c), RenderPipeline.calibrated(camera, c.calibration))
        c.channelMixer = .monochrome
        c.adaptation = ChromaticAdaptation(illuminant: .d50)
        let expected = ChannelMixer.monochrome.matrix * (c.calibration.matrix * (c.adaptation.matrix * camera))
        let got = RenderPipeline.calibrated(camera, c)
        for i in 0..<3 { XCTAssertLessThan(simd_distance(got[i], expected[i]), 1e-5) }
    }

    func testGPUPacking() {
        var c = ColourControls()
        XCTAssertEqual(c.gpuFlags, 0)
        c.gamutCompression = 0.5
        c.purity = 0.25
        XCTAssertEqual(c.gpuFlags, ColourControls.flagGamutCompression | ColourControls.flagPurity)
        XCTAssertEqual(c.gpuFlags & ColourControls.gradingStageFlags, 0, "the grading stage stays skipped")
        let gpu = ColourExtrasGPU(c, splitBalance: 0)
        XCTAssertEqual(Float(bitPattern: gpu.info.z), 0.5)
        XCTAssertEqual(Float(bitPattern: gpu.info.w), 0.25)
        var g = ColourControls()
        g.grading.hueShift = 30
        g.grading.midtoneSaturation = 0.5
        XCTAssertNotEqual(g.gpuFlags & ColourControls.flagColourGrading, 0)
        let packed = ColourExtrasGPU(g, splitBalance: 0)
        XCTAssertEqual(packed.global.w, 30)
        XCTAssertEqual(packed.midtones.w, 0.5)
    }

    // MARK: - Grading ranges

    func testGradingRangeWeights() {
        let dark = ColourGradingRanges.weights(luminance: 0, balance: 0, blending: 0.5)
        let mid = ColourGradingRanges.weights(luminance: 0.5, balance: 0, blending: 0.5)
        let bright = ColourGradingRanges.weights(luminance: 1, balance: 0, blending: 0.5)
        XCTAssertEqual(dark.x, 1); XCTAssertEqual(bright.z, 1)
        XCTAssertEqual(mid.y, 1, accuracy: 1e-6)
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-6)
        for l in stride(from: Float(0), through: 1, by: 0.1) {
            let w = ColourGradingRanges.weights(luminance: l, balance: 0.3, blending: 0.2)
            XCTAssertEqual(w.x + w.z, 1, accuracy: 1e-6)
        }
        // Balance below zero counts more of the picture as shadow.
        let lower = ColourGradingRanges.weights(luminance: 0.5, balance: -0.5, blending: 0.5)
        XCTAssertGreaterThan(lower.x, mid.x)
    }

    func testGradingRangePreviewKernel() throws {
        let gpu = try GPUContext()
        let pixels: [Float] = [0.001, 0.001, 0.001,  0.2, 0.2, 0.2,  1, 1, 1]
        let source = try XCTUnwrap(makeTexture(gpu, width: 3, height: 1, pixels: pixels))
        func view(_ range: Int) throws -> [Float] {
            let target = try XCTUnwrap(makeTexture(gpu, width: 3, height: 1, pixels: [Float](repeating: 0, count: 9)))
            let commands = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
            try RenderPipeline.encodeGradingRangePreview(input: source, output: target, range: range, balance: 0,
                                                         blending: 0.5, headroom: 1, gpu: gpu, commandBuffer: commands)
            commands.commit()
            commands.waitUntilCompleted()
            return readRGB(target)
        }
        let shadows = try view(0), highlights = try view(2)
        XCTAssertGreaterThan(shadows[0], 0.9, "black is all shadow")
        XCTAssertLessThan(shadows[6], 0.05, "white is no shadow")
        XCTAssertGreaterThan(highlights[6], 0.9)
        XCTAssertEqual(shadows[0], shadows[2], accuracy: 1e-3, "grey")
    }

    // MARK: - Exposure tools

    func testExposureSolve() {
        XCTAssertEqual(ExposurePicking.exposure(patch: 0.09, target: 0.18), 1)
        XCTAssertEqual(ExposurePicking.exposure(patch: 0.72, target: 0.18), -2)
        XCTAssertEqual(ExposurePicking.exposure(patch: 0.0001, target: 0.18), 5, "held to the slider")
        XCTAssertNil(ExposurePicking.exposure(patch: 0, target: 0.18))
        XCTAssertNil(ExposurePicking.exposure(patch: .nan, target: 0.18))
        XCTAssertEqual(ExposurePicking.Target.middleGrey.luminance(greyPoint: 0.1845), 0.18)
        XCTAssertEqual(ExposurePicking.Target.displayHalf.luminance(greyPoint: 0.25), 0.25)
        XCTAssertEqual(ExposurePicking.Target.custom(5).luminance(greyPoint: 0.18), 1)
    }

    func testAreaMeanAndPercentile() {
        // 10 × 10, left half 0.1, right half 0.4.
        let l = (0..<100).map { $0 % 10 < 5 ? Float(0.1) : 0.4 }
        let click = ExposurePicking.meanLuminance(in: CGRect(x: 0.2, y: 0.5, width: 0, height: 0),
                                                  width: 10, height: 10, luminances: l)
        XCTAssertEqual(click ?? 0, 0.1, accuracy: 1e-6, "a click reads a small patch round it")
        let all = ExposurePicking.meanLuminance(in: CGRect(x: 0, y: 0, width: 1, height: 1), width: 10, height: 10, luminances: l)
        XCTAssertEqual(all ?? 0, 0.25, accuracy: 1e-6)
        XCTAssertNil(ExposurePicking.meanLuminance(in: CGRect(x: 2, y: 2, width: 0, height: 0), width: 10, height: 10, luminances: l))
        XCTAssertEqual(ExposurePicking.percentileLuminance(l, percentile: 0.25), 0.1)
        XCTAssertEqual(ExposurePicking.percentileLuminance(l, percentile: 0.9), 0.4)
        XCTAssertNil(ExposurePicking.percentileLuminance([], percentile: 0.5))
    }

    // MARK: - Renders

    func testRendersOnARealImage() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        func pixels(_ p: EditParameters) throws -> [SIMD3<Float>] {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            return stride(from: 0, to: px.count, by: 4).map { SIMD3(Float(px[$0]), Float(px[$0 + 1]), Float(px[$0 + 2])) }
        }
        func meanChroma(_ px: [SIMD3<Float>]) -> Float { px.reduce(0) { $0 + ($1.max() - $1.min()) } / Float(px.count) }
        func meanLuma(_ px: [SIMD3<Float>]) -> Float {
            px.reduce(0) { $0 + 0.2126 * $1.x + 0.7152 * $1.y + 0.0722 * $1.z } / Float(px.count)
        }
        let plain = try pixels(EditParameters())

        // Neutral new controls render bit for bit as without them.
        var neutral = EditParameters()
        neutral.colour.adaptation = ChromaticAdaptation(method: .bradford, illuminant: .d65)
        XCTAssertEqual(try pixels(neutral), plain)

        // Black Offset: above zero darkens, below lifts.
        var deeper = EditParameters(); deeper.blackOffset = 0.02
        var lifted = EditParameters(); lifted.blackOffset = -0.02
        XCTAssertLessThan(meanLuma(try pixels(deeper)), meanLuma(plain))
        XCTAssertGreaterThan(meanLuma(try pixels(lifted)), meanLuma(plain))

        // Adaptation from tungsten: bluer.
        var tungsten = EditParameters(); tungsten.colour.adaptation = ChromaticAdaptation(illuminant: .a)
        let t = try pixels(tungsten)
        XCTAssertGreaterThan(t.reduce(0) { $0 + $1.z - $1.x }, plain.reduce(0) { $0 + $1.z - $1.x })

        // Channel Mixer: monochrome takes the colour out.
        var mono = EditParameters(); mono.colour.channelMixer = .monochrome
        XCTAssertLessThan(meanChroma(try pixels(mono)), 2e-3)

        // Gamut compression never adds colour and changes something.
        var squeezed = EditParameters(); squeezed.colour.gamutCompression = 1
        let s = try pixels(squeezed)
        XCTAssertLessThanOrEqual(meanChroma(s), meanChroma(plain) + 1e-4)

        // Highlight Purity only ever gives colour back.
        var pure = EditParameters(); pure.colour.purity = 1
        XCTAssertGreaterThanOrEqual(meanChroma(try pixels(pure)), meanChroma(plain) - 1e-4)

        // Per-range saturation and the hue shift.
        var dull = EditParameters()
        dull.colour.grading.shadowSaturation = -1
        dull.colour.grading.midtoneSaturation = -1
        dull.colour.grading.highlightSaturation = -1
        XCTAssertLessThan(meanChroma(try pixels(dull)), meanChroma(plain) * 0.6)
        var turned = EditParameters(); turned.colour.grading.hueShift = 120
        let h = try pixels(turned)
        XCTAssertNotEqual(h, plain)
        let greys = plain.indices.filter { plain[$0].max() - plain[$0].min() < 0.01 }
        if greys.count > 100 {
            XCTAssertLessThan(meanChroma(greys.map { h[$0] }), 0.02, "greys stay grey")
        }
    }

    /// The eyedropper's and Match by Histogram's measure follows Exposure
    /// out: the same area gives the same answer whatever the slider says.
    func testMeasureIgnoresExposure() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var a = EditParameters(); a.whiteBalance = session.asShotWhiteBalance
        var b = a; b.exposureEV = 2; b.blackOffset = 0.03
        let la = try XCTUnwrap(ExposurePicking.percentileLuminance(session: session, pipeline: pipeline, gpu: gpu,
                                                                   parameters: a, percentile: 0.5))
        let lb = try XCTUnwrap(ExposurePicking.percentileLuminance(session: session, pipeline: pipeline, gpu: gpu,
                                                                   parameters: b, percentile: 0.5))
        XCTAssertEqual(la, lb, accuracy: la * 1e-3)
        XCTAssertGreaterThan(la, 0)
        let ev = try XCTUnwrap(ExposurePicking.exposure(patch: la, target: 0.18))
        // Rendered at that exposure the median lands on 18% grey.
        var c = a; c.exposureEV = ev
        let analysis = try ExposurePicking.analysisLuminances(session: session, pipeline: pipeline, gpu: gpu, parameters: c)
        XCTAssertEqual(ExposurePicking.percentileLuminance(analysis.luminances, percentile: 0.5) ?? 0, la, accuracy: la * 0.05,
                       "the analysis render is before exposure")
        XCTAssertEqual(la * exp2(ev), 0.18, accuracy: 0.18 * 0.01)
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
