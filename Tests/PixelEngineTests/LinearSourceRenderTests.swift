import XCTest
import Metal
import simd
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// A linear source through the render pipeline: what the seam kernels
/// produce, the BaselineExposure gain, highlight clip levels, lens
/// matching, AI denoise, and every stage after the seam running on it.
final class LinearSourceRenderTests: XCTestCase {
    nonisolated(unsafe) private static var sharedGPU: GPUContext?
    private static let lock = NSLock()

    private func gpu() throws -> GPUContext {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let gpu = Self.sharedGPU { return gpu }
        let gpu = try GPUContext()
        Self.sharedGPU = gpu
        return gpu
    }

    private func open(_ name: String) throws -> (RawFile, ImageSession, RenderPipeline) {
        let gpu = try gpu()
        let file = try RawFile(path: LinearFixtures.path(name))
        return (file, try ImageSession(file: file, gpu: gpu), RenderPipeline(gpu: gpu))
    }

    private func pixels(_ texture: MTLTexture) throws -> [Float16] {
        try TextureReadback.float16Pixels(of: texture, gpu: try gpu())
    }

    /// `got` equals `want` to the precision of a Float16 texture.
    private func assertClose(_ got: Float, _ want: Float, _ message: @autoclosure () -> String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got, want, accuracy: abs(want) * 1e-3 + 1e-4, message(), file: file, line: line)
    }

    // MARK: - The seam

    /// Full resolution: the plane times the multipliers, and nothing else.
    func testFullResolutionSeamIsThePlaneTimesTheMultipliers() throws {
        let (file, session, pipeline) = try open(LinearFixtures.ramp)
        XCTAssertEqual(session.sourceGain, 1)
        for whiteBalance in [ColorKit.WhiteBalance.asShot, ColorKit.WhiteBalance(temperature: 3800, tint: 18)] {
            var parameters = EditParameters()
            parameters.whiteBalance = whiteBalance
            var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 0, isFullResolution: false)
            _ = try pipeline.render(session, scale: .full, parameters: parameters, info: &info)
            XCTAssertTrue(info.isFullResolution)
            XCTAssertNil(info.demosaicUsed, "nothing is demosaiced")
            let camera = try pixels(pipeline.renderCameraRGB(session, scale: .full, parameters: parameters))
            let m = session.multipliers(for: whiteBalance)
            let plane = try XCTUnwrap(file.linearPlane).samples
            XCTAssertEqual(camera.count, plane.count)
            for i in stride(from: 0, to: plane.count, by: 4 * 997) {   // a spread of pixels
                for c in 0..<3 {
                    assertClose(Float(camera[i + c]), Float(plane[i + c]) * m[c], "sample \(i + c), \(whiteBalance)")
                }
            }
        }
    }

    /// Reduced resolution: a box average over the plan's span.
    func testBinnedSeamIsABoxAverage() throws {
        let (file, session, pipeline) = try open(LinearFixtures.ramp)
        let parameters = EditParameters()
        let quads = 3, span = 6
        let camera = try pipeline.renderCameraRGB(session, scale: .binned(quads: quads), parameters: parameters)
        XCTAssertEqual(camera.width, 1200 / span)
        XCTAssertEqual(camera.height, 800 / span)
        let got = try pixels(camera)
        let m = session.multipliers(for: parameters.whiteBalance)
        for (ox, oy) in [(0, 0), (16, 16), (40, 30), (199, 132), (60, 100)] {
            var sum = SIMD3<Float>()
            for y in (oy * span)..<(oy * span + span) {
                for x in (ox * span)..<(ox * span + span) {
                    let v = LinearFixtures.ramp(x: x, y: y)
                    sum += SIMD3(Float(v.0), Float(v.1), Float(v.2))
                }
            }
            let mean = sum / Float(span * span)
            let i = (oy * camera.width + ox) * 4
            for c in 0..<3 {
                assertClose(Float(got[i + c]), mean[c] * m[c], "(\(ox), \(oy)) channel \(c)")
            }
        }
        _ = file
    }

    /// A 100% zoom tile is exactly that part of the full render.
    func testRegionIsACropOfTheFullRender() throws {
        let (_, session, pipeline) = try open(LinearFixtures.ramp)
        let parameters = EditParameters()
        let full = try pixels(pipeline.renderCameraRGB(session, scale: .full, parameters: parameters))
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 0, isFullResolution: false)
        let tileTexture = try pipeline.render(session, scale: .region(x: 301, y: 99, width: 256, height: 128),
                                              parameters: parameters, info: &info)
        XCTAssertEqual(info.sensorRect, CGRect(x: 300, y: 98, width: 256, height: 128))
        let tile = try pixels(pipeline.renderCameraRGB(session, scale: .region(x: 301, y: 99, width: 256, height: 128),
                                                       parameters: parameters))
        XCTAssertEqual(tileTexture.width, 256)
        for y in 0..<128 {
            for x in 0..<256 {
                let t = (y * 256 + x) * 4, f = ((y + 98) * 1200 + x + 300) * 4
                XCTAssertEqual(tile[t..<(t + 3)], full[f..<(f + 3)], "(\(x), \(y))")
            }
        }
    }

    /// BaselineExposure is a gain at the seam, for linear sources only.
    func testBaselineExposureIsAGainAtTheSeam() throws {
        for (name, gain) in [(LinearFixtures.mergeHDR, Float(4)), (LinearFixtures.plain, powf(2, -0.5))] {
            let (file, session, pipeline) = try open(name)
            XCTAssertEqual(session.sourceGain, gain, accuracy: 1e-6, name)
            let parameters = EditParameters()
            let camera = try pixels(pipeline.renderCameraRGB(session, scale: .full, parameters: parameters))
            let plane = try XCTUnwrap(file.linearPlane).samples
            let m = session.multipliers(for: parameters.whiteBalance)
            // Skip the plain fixture's cleaned first pixels, which hold 65504.
            for i in stride(from: 8, to: plane.count, by: 4 * 13) {
                for c in 0..<3 {
                    assertClose(Float(camera[i + c]), Float(plane[i + c]) * m[c] * gain, "\(name) sample \(i + c)")
                }
            }
        }
        // A Bayer raw's BaselineExposure is not applied.
        let path = TestAssets.path("nikon_d750_sample.nef")
        if FileManager.default.fileExists(atPath: path) {
            let session = try ImageSession(file: try RawFile(path: path), gpu: try gpu())
            XCTAssertEqual(session.sourceGain, 1)
            XCTAssertEqual(session.highlightClipScale, 1)
        }
    }

    /// The gain is what makes Exposure 0 look like the reference frame: a
    /// file with BaselineExposure -0.5 renders as the same pixels with
    /// BaselineExposure 0 and the Exposure slider at -0.5.
    func testBaselineExposureLooksLikeTheExposureSlider() throws {
        let (file, session, pipeline) = try open(LinearFixtures.plain)
        let withoutBaseline = RawFile(summary: file.summary.replacing(baselineExposure: 0),
                                      cameraToXYZ: file.cameraToXYZMatrixRaw, linearPlane: try XCTUnwrap(file.linearPlane))
        let plainSession = try ImageSession(file: withoutBaseline, gpu: try gpu())
        var parameters = EditParameters()
        parameters.highlightRecovery = 0
        // No lens profile: its resampling would smear the fixture's 65504
        // corner pixels into their neighbours.
        parameters.lensDistortion = false; parameters.lensTCA = false; parameters.lensVignetting = false
        let viaBaseline = try pixels(pipeline.render(session, parameters: parameters, output: .sceneLinear))
        parameters.exposureEV = -0.5
        let viaSlider = try pixels(RenderPipeline(gpu: try gpu()).render(plainSession, parameters: parameters,
                                                                         output: .sceneLinear))
        // The two differ only by where a Float16 rounds: the seam stores
        // the gained value in one and the plain one in the other, and the
        // camera matrix's large coefficients of both signs can magnify a
        // rounding of 1e-4 at the seam a few times in a small result.
        for i in stride(from: 8, to: viaBaseline.count, by: 4 * 7) {
            for c in 0..<3 {
                let got = Float(viaBaseline[i + c]), want = Float(viaSlider[i + c])
                XCTAssertEqual(got, want, accuracy: abs(want) * 2e-3 + 5e-4, "sample \(i + c)")
            }
        }
    }

    // MARK: - Highlights

    func testHighlightClipLevelIsMultipliersTimesClipLevelTimesGain() throws {
        let (_, merge, _) = try open(LinearFixtures.mergeHDR)
        let m = SIMD4<Float>(2, 1, 1.5, 1)
        // Clip level 0.5 (stored), BaselineExposure +2: the stored 0.5
        // arrives at the seam as 0.5 x 4 x multiplier.
        XCTAssertEqual(merge.highlightClipScale, 2)
        XCTAssertEqual(merge.highlightClipLevel(multipliers: m), SIMD3(4, 2, 3))
        // No recipe: the file's white, 1.0, times the gain.
        let (_, plain, _) = try open(LinearFixtures.plain)
        XCTAssertEqual(plain.highlightClipScale, powf(2, -0.5), accuracy: 1e-6)
    }

    /// A grey stored at 0.49 sits just under the merge's clip level of 0.5
    /// and is left alone; one at 0.51 is over it, and its channels, which
    /// white balance spread apart, are pulled back to neutral. Were the clip
    /// level ignored (1.0 x gain) neither would be touched; were the gain
    /// ignored (0.5 alone) both would.
    func testHighlightReconstructionStartsAtTheMergeClipLevel() throws {
        let (_, session, pipeline) = try open(LinearFixtures.mergeHDR)
        var on = EditParameters()
        on.highlightThreshold = 1     // no soft ramp below the clip level
        on.highlightRecovery = 1
        var off = on
        off.highlightRecovery = 0
        let reconstructed = try pixels(pipeline.render(session, parameters: on, output: .sceneLinear))
        let untouched = try pixels(pipeline.render(session, parameters: off, output: .sceneLinear))
        func rgb(_ px: [Float16], _ p: (x: Int, y: Int)) -> SIMD3<Float> {
            let i = (p.y * 64 + p.x) * 4
            return SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2]))
        }
        let below = LinearFixtures.belowClipPatch, above = LinearFixtures.aboveClipPatch
        XCTAssertEqual(rgb(reconstructed, below), rgb(untouched, below), "just under the clip level: untouched")
        XCTAssertNotEqual(rgb(reconstructed, above), rgb(untouched, above), "just over: reconstructed")
        // Reconstructed means neutral: every channel lifted to the brightest.
        let fixed = rgb(reconstructed, above)
        XCTAssertEqual(fixed.x, fixed.y, accuracy: fixed.x * 0.01)
        XCTAssertEqual(fixed.z, fixed.y, accuracy: fixed.x * 0.01)
    }

    // MARK: - Lens, denoise, cache

    func testLensProfileIsSkippedWhenTheMergeAlreadyAppliedIt() throws {
        let (_, hdr, _) = try open(LinearFixtures.mergeHDR)
        XCTAssertFalse(hdr.lensCorrectionAlreadyApplied)
        XCTAssertNotNil(hdr.lensCorrection, "lensApplied false: matched from the EXIF lens")
        let (_, plain, _) = try open(LinearFixtures.plain)
        XCTAssertNotNil(plain.lensCorrection, "no recipe: matched from the EXIF lens")
        let (_, panorama, _) = try open(LinearFixtures.mergePanorama)
        XCTAssertTrue(panorama.lensCorrectionAlreadyApplied)
        XCTAssertNil(panorama.lensCorrection, "same EXIF lens, but lensApplied true")
    }

    /// An edit carrying an AI denoise strength (copied from a raw, say)
    /// blends nothing into a linear source.
    func testAIDenoiseIsNeverBlendedIntoALinearSource() throws {
        let (_, session, pipeline) = try open(LinearFixtures.mergeHDR)
        XCTAssertFalse(session.supportsAIDenoise)
        let gpu = try gpu()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 48,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        let bogus = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))   // all zero
        session.setAIDenoised(bogus, model: "test")
        var parameters = EditParameters()
        let plain = try pixels(pipeline.render(session, parameters: parameters))
        parameters.aiDenoise = 1
        let withDenoise = try pixels(pipeline.render(session, parameters: parameters))
        XCTAssertEqual(plain, withDenoise)
    }

    func testStageCacheKeyIncludesTheSourceKind() {
        let plan = RenderPlan.fullResolution(origin: (0, 0), size: (64, 48))
        let m = SIMD4<Float>(2, 1, 1.5, 1)
        let bayer = RenderPipeline.stageKey(plan: plan, source: .bayer, multipliers: m, demosaic: .rcd)
        let linear = RenderPipeline.stageKey(plan: plan, source: .linearRGB, multipliers: m, demosaic: .rcd)
        XCTAssertNotEqual(bayer, linear)
        // The demosaic method can't change a linear source's pixels.
        XCTAssertEqual(linear, RenderPipeline.stageKey(plan: plan, source: .linearRGB, multipliers: m, demosaic: .bilinear))
    }

    func testLinearKernelsCompileAsMetal3AndBuildOnce() throws {
        let gpu = try gpu()
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        let (library, _) = try GPUContext.loadShaderLibrary(device: gpu.device, compileOptions: options)
        for kernel in GPUContext.LazyKernel.allCases {
            XCTAssertNotNil(library.makeFunction(name: kernel.rawValue), kernel.rawValue)
            XCTAssertTrue(try gpu.lazyPipeline(kernel) === gpu.lazyPipeline(kernel), "built once: \(kernel)")
        }
    }

    // MARK: - After the seam

    /// Every module after the seam, on a linear source, through the export
    /// path: finite pixels, the geometry the export asked for.
    func testEveryStageAfterTheSeamRuns() throws {
        let (file, session, pipeline) = try open(LinearFixtures.ramp)
        let gpu = try gpu()
        var edit = EditParameters()
        edit.whiteBalance = ColorKit.WhiteBalance(temperature: 5200, tint: 5)
        edit.exposureEV = 0.4
        edit.denoiseLuminance = 0.4; edit.denoiseColor = 0.4
        edit.sharpenAmount = 1
        edit.texture = 0.3; edit.clarity = 0.3; edit.dehaze = 0.2; edit.vibrance = 0.3
        edit.defringePurple = 0.5
        edit.manualDistortion = 0.03; edit.manualVignetting = 0.3
        edit.perspective = PerspectiveCorrection(vertical: 0.2, horizontal: 0)
        edit.toneRanges = ToneRanges(highlights: -0.5, shadows: 0.4, whites: 0.1, blacks: -0.1)
        edit.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.6), SIMD2(1, 1)])
        edit.heals = [HealPatch(target: [0.4, 0.4], source: [0.6, 0.6], radius: 0.05, mode: .heal)]
        edit.redEyes = [RedEyeSpot(centre: [0.2, 0.7], radius: 0.05)]
        edit.locals = [LocalAdjustment(name: "radial", shape: .radial(centre: [0.5, 0.5], radii: [0.3, 0.3], feather: 0.5),
                                       exposureEV: 0.5, saturation: 0.2)]
        edit.crop = CropParameters(centre: [0.5, 0.5], size: [0.8, 0.8], angle: 3)
        let json = try EditStack(parameters: edit).encodeJSON()
        let parameters = try ExportPlan.parameters(editStackJSON: json, session: session, colorSpace: .displayP3)
        let exporter = Exporter(gpu: gpu)
        let rotation = ExportPlan.rotation(for: file.summary, userRotation: 0)

        for maxLongEdge in [nil, 300] {
            let scale = ExportPlan.scale(for: file.summary, crop: parameters.crop, maxLongEdge: maxLongEdge)
            let texture = try pipeline.render(session, scale: scale, parameters: parameters, output: .file(.displayP3))
            let values = try pixels(texture)
            XCTAssertTrue(values.allSatisfy { $0.isFinite }, "\(scale)")
            XCTAssertGreaterThan(values.lazy.map { Float($0) }.reduce(0, +), 0, "\(scale)")
            let image = try exporter.cgImage(from: texture, colorSpace: .displayP3, rotation: rotation,
                                             crop: parameters.crop, bitsPerComponent: 16, maxLongEdge: maxLongEdge)
            if let maxLongEdge { XCTAssertEqual(max(image.width, image.height), maxLongEdge) }
        }

        // Scopes, soft proofing and Auto work from the same renders.
        let histogram = try HistogramCalculator(gpu: gpu)
        XCTAssertNotNil(histogram.compute(from: try pipeline.render(session, scale: .binned(quads: 2), parameters: parameters)))
        var proofed = RenderOutput.file(.sRGB)
        proofed.proof = try SoftProofLUT.build(.sRGB)
        proofed.gamutWarning = true
        XCTAssertTrue(try pixels(pipeline.render(session, scale: .binned(quads: 2), parameters: parameters, output: proofed))
            .allSatisfy { $0.isFinite })
        _ = try AutoAdjust.suggest(for: session, pipeline: pipeline, gpu: gpu, current: parameters)
    }

    /// The camera's orientation turns the export as it does for a raw.
    func testOrientationTurnsTheExport() throws {
        let (file, session, pipeline) = try open(LinearFixtures.orientation6)
        let texture = try pipeline.render(session, parameters: EditParameters())
        let image = try Exporter(gpu: try gpu()).cgImage(
            from: texture, colorSpace: .sRGB, rotation: ExportPlan.rotation(for: file.summary, userRotation: 0))
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 64)
    }
}

extension RawSummary {
    /// This summary with some fields changed, for tests that build a
    /// linear source in memory.
    func replacing(cfaPattern: CFAPattern? = nil, blackLevel: Float? = nil, whiteLevel: Float? = nil,
                   channelBlackLevels: SIMD4<Float>? = nil, dataMaximum: Float? = nil,
                   baselineExposure: Float? = nil, mergeInfo: LinearMergeInfo?? = nil) -> RawSummary {
        RawSummary(activeArea: activeArea, cfaPattern: cfaPattern ?? self.cfaPattern,
                   cameraMultipliers: cameraMultipliers,
                   blackLevel: blackLevel ?? self.blackLevel, whiteLevel: whiteLevel ?? self.whiteLevel,
                   channelBlackLevels: channelBlackLevels ?? self.channelBlackLevels,
                   dataMaximum: dataMaximum ?? self.dataMaximum,
                   baselineExposure: baselineExposure ?? self.baselineExposure,
                   mergeInfo: mergeInfo ?? self.mergeInfo,
                   cameraMake: cameraMake, cameraModel: cameraModel, lensModel: lensModel,
                   iso: iso, shutter: shutter, aperture: aperture, focalLength: focalLength,
                   captureTime: captureTime, orientation: orientation, lens: lens)
    }
}
