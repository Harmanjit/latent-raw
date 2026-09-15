import XCTest
import Accelerate
import Metal
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// The most important test of linear sources: the seam round trip.
///
/// The golden NEF is demosaiced as usual, and the camera-RGB texture it
/// hands the rest of the pipeline is turned back into what a linear DNG of
/// the same photo would hold: divided by the white balance multipliers it
/// was rendered with (unit white balance), with the plane's contract
/// applied. That is injected as a linear source carrying the NEF's own
/// metadata (colour matrix, multipliers, orientation, lens), and the golden
/// recipes are rendered from it through `ExportPlan`, as `GoldenImageTests`
/// renders them from the NEF.
///
/// Demosaic happens before the seam, so wherever the pipeline really is
/// the same on both sides of it the results must match the golden PNGs
/// within the golden tolerances. That is every full-resolution window.
/// What legitimately differs is listed in `expectedToDiffer`, with why.
final class LinearSeamRoundTripTests: XCTestCase {
    typealias Recipe = GoldenImageTests.Recipe

    /// The recipes, exactly as GoldenImageTests defines them.
    static let recipes: [Recipe] = [
        GoldenImageTests.asShot,
        Recipe(name: "exposure-tone") {
            $0.exposureEV = 0.8; $0.contrast = 2.2; $0.greyPoint = 0.16; $0.highlightRecovery = 0.4
        },
        GoldenImageTests.whiteBalance,
        Recipe(name: "colour-grading") {
            $0.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.25, 0.18), SIMD2(0.75, 0.84), SIMD2(1, 1)])
            var hsl = HSLAdjustments.neutral
            hsl.hue[0] = 0.3; hsl.saturation[0] = -0.4; hsl.luminance[1] = 0.25
            hsl.saturation[2] = 0.3; hsl.hue[5] = -0.4
            $0.hsl = hsl
            $0.vibrance = 0.5
            $0.splitToning = SplitToning(shadowHue: 215, shadowSaturation: 0.3,
                                         highlightHue: 45, highlightSaturation: 0.25, balance: 0.1)
        },
        Recipe(name: "channel-curves") {
            $0.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.56), SIMD2(1, 1)])
            $0.channelCurves = RGBCurves(
                red: ToneCurve(points: [SIMD2(0, 0), SIMD2(0.55, 0.62), SIMD2(1, 1)]),
                green: ToneCurve(points: [SIMD2(0, 0.02), SIMD2(1, 0.97)]),
                blue: ToneCurve(points: [SIMD2(0, 0.06), SIMD2(0.4, 0.33), SIMD2(1, 1)]))
        },
        Recipe(name: "tone-ranges") {
            $0.toneRanges = ToneRanges(highlights: -0.7, shadows: 0.6, whites: 0.4, blacks: -0.5)
        },
        Recipe(name: "presence", detail: GoldenImageTests.ballCentre) {
            $0.clarity = 0.6; $0.texture = 0.5; $0.dehaze = 0.4
        },
        Recipe(name: "detail", detail: GoldenImageTests.ballCentre) {
            $0.sharpenAmount = 1.2; $0.sharpenRadius = 1.2
            $0.denoiseLuminance = 0.5; $0.denoiseColor = 0.6
            $0.defringePurple = 0.8; $0.defringeGreen = 0.5
        },
        Recipe(name: "demosaic-bilinear", overview: false, detail: GoldenImageTests.ballCentre) {
            $0.demosaic = .bilinear
        },
        Recipe(name: "geometry", quarterTurns: 1, detail: SIMD2(0.5, 0.5)) {
            $0.crop = CropParameters(centre: [0.5, 0.53], size: [0.72, 0.72], angle: 4)
            $0.perspective = PerspectiveCorrection(vertical: 0.3, horizontal: -0.2)
            $0.manualDistortion = 0.04
            $0.manualVignetting = 0.4
        },
        Recipe(name: "heal-clone", detail: GoldenImageTests.ballCentre) {
            $0.heals = [
                HealPatch(id: GoldenImageTests.uuid(1), target: [0.50, 0.55], source: [0.58, 0.47], radius: 0.03, mode: .clone),
                HealPatch(id: GoldenImageTests.uuid(2), target: [0.47, 0.60], source: [0.15, 0.35], radius: 0.02, mode: .heal),
            ]
        },
        Recipe(name: "heal-field", overview: false, detail: GoldenImageTests.ballCentre) {
            $0.heals = [HealPatch(id: GoldenImageTests.uuid(5), target: [0.50, 0.55], source: [0.44, 0.50],
                                  radius: 0.02, mode: .heal)]
        },
        Recipe(name: "heal-stroke", overview: false, detail: GoldenImageTests.ballCentre) {
            $0.heals = [HealPatch(id: GoldenImageTests.uuid(6), target: [0.4998, 0.551], source: [0.4998, 0.541],
                                  radius: 0.002, mode: .heal,
                                  stroke: [[0, 0], [0.0058, -0.00125], [0.0133, -0.00375]])]
        },
        Recipe(name: "red-eye", detail: SIMD2(0.86, 0.78)) {
            $0.redEyes = [RedEyeSpot(id: GoldenImageTests.uuid(7), centre: [0.86, 0.78], radius: 0.05),
                          RedEyeSpot(id: GoldenImageTests.uuid(8), centre: [0.1, 0.35], radius: 0.08, strength: 0.6)]
        },
        Recipe(name: "local-adjustments") {
            $0.locals = [
                LocalAdjustment(id: GoldenImageTests.uuid(3), name: "ball",
                                shape: .radial(centre: [0.5, 0.55], radii: [0.3, 0.3], feather: 0.5),
                                exposureEV: 0.8, saturation: 0.3),
                LocalAdjustment(id: GoldenImageTests.uuid(4), name: "sky",
                                shape: .linear(start: [0.5, 0.0], end: [0.5, 0.45]),
                                exposureEV: -1, contrast: 0.2, warmth: -0.4),
            ]
        },
        Recipe(name: "display-p3", outputSpace: .displayP3) { $0.vibrance = 0.4 },
        Recipe(name: "eight-bit", bitsPerComponent: 8) { $0.exposureEV = 0.3 },
    ]

    /// Comparisons that are not expected to meet the golden tolerances, and
    /// why. Every other comparison must.
    ///
    /// - Overviews (the whole frame at 320 px) of every recipe. A small
    ///   export never demosaics a Bayer raw: it averages each colour's
    ///   photosites over a block of Bayer quads (18 x 18 photosites here).
    ///   The linear source averages the demosaiced pixels over the same
    ///   block instead, and a demosaiced pixel's missing colours are
    ///   estimates from its neighbours. Where detail is finer than the
    ///   Bayer pattern (the ball's studs), red and blue photosites can miss
    ///   a bright feature that demosaicing fills in from green, so the two
    ///   averages differ. Measured at the seam: median 0.13%, 99th
    ///   percentile 6%, and not concentrated in clipped highlights. Both are
    ///   correct reductions of the same photo; they aren't the same numbers.
    /// - demosaic-bilinear's window: the linear source was made from the
    ///   RCD seam, and nothing after the seam can re-demosaic it.
    static func expectedToDiffer(_ name: String) -> String? {
        if !name.hasSuffix("-detail") {
            return "overview: Bayer binning averages photosites, the linear source averages demosaiced pixels"
        }
        if name == "demosaic-bilinear-detail" { return "the linear source was demosaiced with RCD" }
        return nil
    }

    func testGoldenRecipesMatchThroughTheLinearSeam() throws {
        let path = TestAssets.path(GoldenImageTests.assetName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "\(GoldenImageTests.assetName) missing; run scripts/fetch_test_assets.sh")
        let gpu = try GPUContext()
        let linear = try autoreleasepool { try Self.linearSource(fromRawAt: path, gpu: gpu) }
        let session = try ImageSession(file: linear, gpu: gpu)
        XCTAssertEqual(session.sourceKind, .linearRGB)
        XCTAssertNotNil(session.lensCorrection, "the NEF's lens identity matches its profile as before")

        var report: [String] = []
        for recipe in Self.recipes {
            let rendered = try GoldenRender.render(recipe, file: linear, session: session, gpu: gpu)
            var comparisons: [(String, GoldenImage)] = []
            if recipe.overview { comparisons.append((recipe.name, rendered.overview)) }
            if let detail = rendered.detail { comparisons.append(("\(recipe.name)-detail", detail)) }
            for (name, image) in comparisons {
                let reference = try GoldenImage(contentsOf: GoldenImageTests.goldenDirectory
                    .appendingPathComponent("\(name).png"))
                let difference = try XCTUnwrap(GoldenDifference(reference, image), name)
                let within = difference.meanAbsolute <= GoldenImageTests.meanTolerance
                    && difference.p999 <= GoldenImageTests.p999Tolerance
                let line = String(format: "%-26@ mean %.5f  p99.9 %.5f  max %.4f  %@", name as NSString,
                                  difference.meanAbsolute, difference.p999, difference.maximum,
                                  within ? "within tolerance" : "OUTSIDE tolerance")
                report.append(line)
                if let reason = Self.expectedToDiffer(name) {
                    // Still close: the same photo, reduced two correct ways.
                    XCTAssertLessThan(difference.meanAbsolute, 0.005, "\(name) (\(reason))")
                } else {
                    XCTAssertTrue(within, "\(name): \(line)")
                }
            }
        }
        print("seam round trip, linear source vs golden PNGs:\n" + report.joined(separator: "\n"))
    }

    /// GPU memory an edit session holds per full-resolution pixel of a
    /// linear source, the number Photo Merge's panorama size rule needs
    /// (`bytesPerEditPixel`, docs/PhotoMerge.md §4). Measured on the golden
    /// NEF turned linear (24 MP): the device's allocated size after the
    /// editor's preview plus a full-resolution render, less before the
    /// session existed, over the pixel count; plus the plane itself, which
    /// is IOSurface memory Metal only wraps. Once with nothing but the
    /// defaults (lens profile on), once with the detail modules that each
    /// keep full-size textures of their own. Reports both, and checks the
    /// figure stays inside a sane range.
    func testMeasureBytesPerEditPixel() throws {
        let path = TestAssets.path(GoldenImageTests.assetName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let linear = try autoreleasepool { try Self.linearSource(fromRawAt: path, gpu: gpu) }
        let pixels = linear.summary.rawWidth * linear.summary.rawHeight
        let plane = linear.linearPlane?.byteCount ?? 0
        let before = gpu.device.currentAllocatedSize
        let session = try ImageSession(file: linear, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        func measure(_ label: String, _ edit: EditParameters) throws -> Double {
            let json = try EditStack(parameters: edit).encodeJSON()
            let parameters = try ExportPlan.parameters(editStackJSON: json, session: session, colorSpace: .sRGB)
            // The editor's preview (binned) and a full-resolution render.
            _ = try pipeline.render(session, scale: .fitting(maxDimension: 2560), parameters: parameters,
                                    output: .edrDisplay(headroom: 1))
            _ = try pipeline.render(session, scale: .full, parameters: parameters, output: .edrDisplay(headroom: 1))
            let textures = gpu.device.currentAllocatedSize - before
            let perPixel = Double(textures + plane) / Double(pixels)
            print(String(format: "bytesPerEditPixel, %@ (linear source, %.1f MP): %.1f = textures %.1f + plane %.1f",
                         label, Double(pixels) / 1e6, perPixel, Double(textures) / Double(pixels),
                         Double(plane) / Double(pixels)))
            return perPixel
        }

        let minimal = try measure("defaults, lens profile", EditParameters())
        var edit = EditParameters()
        edit.denoiseLuminance = 0.3; edit.denoiseColor = 0.3
        edit.sharpenAmount = 0.8
        edit.clarity = 0.3; edit.texture = 0.2
        edit.heals = [HealPatch(target: [0.3, 0.3], source: [0.6, 0.6], radius: 0.03, mode: .heal)]
        edit.locals = [LocalAdjustment(name: "radial", shape: .radial(centre: [0.5, 0.5], radii: [0.3, 0.3], feather: 0.5),
                                       exposureEV: 0.5)]
        let typical = try measure("denoise, heal, lens, presence, local, sharpen", edit)
        XCTAssertGreaterThan(minimal, 16)
        XCTAssertGreaterThanOrEqual(typical, minimal)
        XCTAssertLessThan(typical, 160)
    }

    // MARK: - Making the linear source

    /// The raw at `path` turned into a linear source through its own seam:
    /// the full-resolution camera RGB of an as-shot export, at unit white
    /// balance, with the NEF's metadata. The Bayer session is gone by the
    /// time this returns, so its RCD textures don't count against the
    /// linear session's memory.
    static func linearSource(fromRawAt path: String, gpu: GPUContext) throws -> RawFile {
        let raw = try RawFile(path: path)
        let session = try ImageSession(file: raw, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        // The golden recipes' white balance: "as shot", as ExportPlan reads it.
        let json = try EditStack(parameters: EditParameters()).encodeJSON()
        let parameters = try ExportPlan.parameters(editStackJSON: json, session: session, colorSpace: .sRGB)
        let multipliers = session.multipliers(for: parameters.whiteBalance)
        let seam = try pipeline.renderCameraRGB(session, scale: .full, parameters: parameters)
        let width = seam.width, height = seam.height
        var samples = try TextureReadback.float16Pixels(of: seam, gpu: gpu)

        // Float16 -> Float, divide each channel by its multiplier and clamp
        // at 0 (the plane's contract), -> Float16. vDSP runs over the
        // interleaved channels with a stride of 4.
        let count = width * height
        var floats = [Float](repeating: 0, count: count * 4)
        samples.withUnsafeMutableBytes { src in
            floats.withUnsafeMutableBytes { dst in
                var from = vImage_Buffer(data: src.baseAddress, height: 1, width: vImagePixelCount(count * 4),
                                         rowBytes: count * 4 * 2)
                var to = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(count * 4),
                                       rowBytes: count * 4 * 4)
                vImageConvert_Planar16FtoPlanarF(&from, &to, 0)
            }
        }
        floats.withUnsafeMutableBufferPointer { buffer in
            for c in 0..<3 {
                let channel = buffer.baseAddress! + c
                var scale = 1 / multipliers[c]
                var low: Float = 0, high = LinearPlane.maximumValue
                vDSP_vsmul(channel, 4, &scale, channel, 4, vDSP_Length(count))
                vDSP_vclip(channel, 4, &low, &high, channel, 4, vDSP_Length(count))
            }
        }
        guard let plane = LinearPlane(width: width, height: height, fill: { destination in
            floats.withUnsafeMutableBytes { src in
                var from = vImage_Buffer(data: src.baseAddress, height: 1, width: vImagePixelCount(count * 4),
                                         rowBytes: count * 4 * 4)
                var to = vImage_Buffer(data: destination.baseAddress, height: 1, width: vImagePixelCount(count * 4),
                                       rowBytes: count * 4 * 2)
                vImageConvert_PlanarFtoPlanar16F(&from, &to, 0)
            }
        }) else { throw RawFileError.planeAllocationFailed }

        // Only what makes it a linear source changes; everything the rest
        // of the pipeline reads (matrix, multipliers, orientation, lens)
        // stays the NEF's.
        let summary = raw.summary.replacing(cfaPattern: .linearRGB, blackLevel: 0, whiteLevel: 1,
                                            channelBlackLevels: SIMD4(repeating: 0), dataMaximum: 1,
                                            baselineExposure: 0, mergeInfo: .some(nil))
        return RawFile(summary: summary, cameraToXYZ: raw.cameraToXYZMatrixRaw, linearPlane: plane)
    }
}

/// `GoldenImageTests`' export render, for any file and session.
enum GoldenRender {
    static func render(_ recipe: GoldenImageTests.Recipe, file: RawFile, session: ImageSession,
                       gpu: GPUContext) throws -> GoldenImageTests.Rendered {
        let pipeline = RenderPipeline(gpu: gpu)
        var edited = EditParameters()
        edited.whiteBalance = .asShot
        recipe.edit(&edited)
        let json = try EditStack(parameters: edited).encodeJSON()
        let parameters = try ExportPlan.parameters(editStackJSON: json, session: session,
                                                   colorSpace: recipe.outputSpace)
        let rotation = ExportPlan.rotation(for: file.summary, userRotation: recipe.quarterTurns)
        let exporter = Exporter(gpu: gpu)

        let small = try pipeline.render(
            session, scale: ExportPlan.scale(for: file.summary, crop: parameters.crop,
                                             maxLongEdge: GoldenImageTests.overviewLongEdge),
            parameters: parameters, output: .file(recipe.outputSpace))
        let overview = try GoldenImage(exporter.cgImage(
            from: small, colorSpace: recipe.outputSpace, rotation: rotation, crop: parameters.crop,
            bitsPerComponent: recipe.bitsPerComponent, maxLongEdge: GoldenImageTests.overviewLongEdge))

        var detail: GoldenImage?
        if let centre = recipe.detail {
            let full = try pipeline.render(session, scale: ExportPlan.scale(for: file.summary, maxLongEdge: nil),
                                           parameters: parameters, output: .file(recipe.outputSpace))
            let frame = try exporter.cgImage(from: full, colorSpace: recipe.outputSpace, rotation: rotation,
                                             crop: parameters.crop, bitsPerComponent: recipe.bitsPerComponent)
            let size = min(GoldenImageTests.detailSize, frame.width, frame.height)
            let x = min(max(Int(centre.x * Double(frame.width)) - size / 2, 0), frame.width - size)
            let y = min(max(Int(centre.y * Double(frame.height)) - size / 2, 0), frame.height - size)
            guard let window = frame.cropping(to: CGRect(x: x, y: y, width: size, height: size)) else {
                throw GoldenImageError.unreadable
            }
            detail = try GoldenImage(window)
        }
        return GoldenImageTests.Rendered(overview: overview, detail: detail)
    }
}
