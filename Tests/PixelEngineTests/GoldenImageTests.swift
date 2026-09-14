import XCTest
import Metal
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// Golden-image tests: a fixed raw file, rendered with fixed edits through
/// the same steps as an export, compared with reference images stored in
/// `Golden/`. Unit tests check that each control does roughly the right
/// thing; these check that nothing about the picture changed at all. A
/// shader tweak that warms every photo slightly passes the first kind
/// and fails this kind, which is what keeps an edit made today looking
/// the same next year.
///
/// The raw is a public-domain (CC0) Nikon D750 file from raw.pixls.us,
/// fetched by `scripts/fetch_test_assets.sh`, so anyone can reproduce
/// the references and they can be published. Each recipe checks a small
/// overview of the whole frame (the binned, resized path a small export
/// takes) and, where the edit is about fine detail, a window of the
/// full-resolution render.
///
/// When a change to the look is intended:
///
///     LATENT_UPDATE_GOLDEN=1 swift test --filter GoldenImageTests
///
/// then look at the new PNGs (GitHub diffs images side by side) and commit
/// them with the change that explains them.
///
/// Not covered: AI noise reduction (Core ML output differs between
/// compute units and takes minutes), and on-screen EDR presentation.
final class GoldenImageTests: XCTestCase {
    static let assetName = "golden_nikon_d750_cc0.nef"
    static let overviewLongEdge = 320
    static let detailSize = 192

    /// Renders on one Mac are bit-identical, so these only have to absorb
    /// floating-point differences between GPU families. Tight enough that
    /// a 1/50 EV exposure change fails (`testToleranceCatchesASmallExposureChange`)
    /// and so does vibrance made 5% stronger inside the shader, which
    /// passed at four times these limits.
    static let meanTolerance = 0.0005
    static let p999Tolerance = 0.005

    // The in-focus middle of the ball: dense, high-contrast detail (bright
    // studs, dark gaps) that shows demosaic artefacts, sharpening halos and
    // heal seams. The rest of the frame is soft by design (shallow focus).
    static let ballCentre = SIMD2<Double>(0.50, 0.55)

    // MARK: - Recipes

    /// Nothing but the image's own defaults: demosaic, as-shot white
    /// balance, camera matrix, lens profile, base tone map, sRGB encode.
    static let asShot = Recipe(name: "as-shot", detail: GoldenImageTests.ballCentre) { _ in }

    func testAsShot() throws { try check(Self.asShot) }

    func testExposureAndTone() throws {
        try check(Recipe(name: "exposure-tone") {
            $0.exposureEV = 0.8
            $0.contrast = 2.2
            $0.greyPoint = 0.16
            $0.highlightRecovery = 0.4
        })
    }

    static let whiteBalance = Recipe(name: "white-balance") {
        $0.whiteBalance = ColorKit.WhiteBalance(temperature: 3800, tint: 18)
    }

    func testWhiteBalance() throws { try check(Self.whiteBalance) }

    func testColourGrading() throws {
        try check(Recipe(name: "colour-grading") {
            $0.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.25, 0.18), SIMD2(0.75, 0.84), SIMD2(1, 1)])
            var hsl = HSLAdjustments.neutral
            hsl.hue[0] = 0.3; hsl.saturation[0] = -0.4; hsl.luminance[1] = 0.25
            hsl.saturation[2] = 0.3; hsl.hue[5] = -0.4
            $0.hsl = hsl
            $0.vibrance = 0.5
            $0.splitToning = SplitToning(shadowHue: 215, shadowSaturation: 0.3,
                                         highlightHue: 45, highlightSaturation: 0.25, balance: 0.1)
        })
    }

    /// Highlights, Shadows, Whites and Blacks, all four at once.
    func testToneRanges() throws {
        try check(Recipe(name: "tone-ranges") {
            $0.toneRanges = ToneRanges(highlights: -0.7, shadows: 0.6, whites: 0.4, blacks: -0.5)
        })
    }

    /// Red, green and blue curves over a master curve, which pins their
    /// order as well as their shape.
    func testChannelCurves() throws {
        try check(Recipe(name: "channel-curves") {
            $0.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.56), SIMD2(1, 1)])
            $0.channelCurves = RGBCurves(
                red: ToneCurve(points: [SIMD2(0, 0), SIMD2(0.55, 0.62), SIMD2(1, 1)]),
                green: ToneCurve(points: [SIMD2(0, 0.02), SIMD2(1, 0.97)]),
                blue: ToneCurve(points: [SIMD2(0, 0.06), SIMD2(0.4, 0.33), SIMD2(1, 1)]))
        })
    }

    func testPresence() throws {
        try check(Recipe(name: "presence", detail: Self.ballCentre) {
            $0.clarity = 0.6
            $0.texture = 0.5
            $0.dehaze = 0.4
        })
    }

    func testDetail() throws {
        try check(Recipe(name: "detail", detail: Self.ballCentre) {
            $0.sharpenAmount = 1.2
            $0.sharpenRadius = 1.2
            $0.denoiseLuminance = 0.5
            $0.denoiseColor = 0.6
            $0.defringePurple = 0.8
            $0.defringeGreen = 0.5
        })
    }

    func testBilinearDemosaic() throws {
        // Small exports never demosaic (they bin whole Bayer quads), so
        // only the full-resolution window can show the method.
        try check(Recipe(name: "demosaic-bilinear", overview: false, detail: Self.ballCentre) {
            $0.demosaic = .bilinear
        })
    }

    /// Crop, straighten, perspective, manual lens controls and a quarter
    /// turn: everything that moves pixels rather than recolouring them.
    func testGeometry() throws {
        try check(Recipe(name: "geometry", quarterTurns: 1, detail: SIMD2(0.5, 0.5)) {
            $0.crop = CropParameters(centre: [0.5, 0.53], size: [0.72, 0.72], angle: 4)
            $0.perspective = PerspectiveCorrection(vertical: 0.3, horizontal: -0.2)
            $0.manualDistortion = 0.04
            $0.manualVignetting = 0.4
        })
    }

    func testHealAndClone() throws {
        try check(Recipe(name: "heal-clone", detail: Self.ballCentre) {
            $0.heals = [
                HealPatch(id: Self.uuid(1), target: [0.50, 0.55], source: [0.58, 0.47], radius: 0.03, mode: .clone),
                HealPatch(id: Self.uuid(2), target: [0.47, 0.60], source: [0.15, 0.35], radius: 0.02, mode: .heal),
            ]
        })
    }

    func testLocalAdjustments() throws {
        try check(Recipe(name: "local-adjustments") {
            $0.locals = [
                LocalAdjustment(id: Self.uuid(3), name: "ball",
                                shape: .radial(centre: [0.5, 0.55], radii: [0.3, 0.3], feather: 0.5),
                                exposureEV: 0.8, saturation: 0.3),
                LocalAdjustment(id: Self.uuid(4), name: "sky",
                                shape: .linear(start: [0.5, 0.0], end: [0.5, 0.45]),
                                exposureEV: -1, contrast: 0.2, warmth: -0.4),
            ]
        })
    }

    /// The output space is chosen at export, not stored in the edit.
    func testDisplayP3Output() throws {
        try check(Recipe(name: "display-p3", outputSpace: .displayP3) { $0.vibrance = 0.4 })
    }

    /// JPEG and HEIC exports quantise to 8 bits in the exporter's GPU pass.
    func testEightBitExport() throws {
        try check(Recipe(name: "eight-bit", bitsPerComponent: 8) { $0.exposureEV = 0.3 })
    }

    // MARK: - The harness itself

    /// Same inputs, same pixels, whatever was rendered in between. Guards
    /// the demosaic stage cache and the texture pool, which reuse work
    /// across renders of one image.
    func testRenderingIsRepeatable() throws {
        let (file, gpu) = try fixture()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let first = try render(Self.asShot, session: session, pipeline: pipeline)
        _ = try render(Self.whiteBalance, session: session, pipeline: pipeline)
        let again = try render(Self.asShot, session: session, pipeline: pipeline)
        XCTAssertTrue(first.overview == again.overview, "overview changed between identical renders")
        XCTAssertTrue(first.detail == again.detail, "detail changed between identical renders")
    }

    /// The tolerances must not be so loose that a real change slips by.
    func testToleranceCatchesASmallExposureChange() throws {
        let base = try render(Recipe(name: "calibration") { _ in }).overview
        let nudged = try render(Recipe(name: "calibration") { $0.exposureEV = 0.02 }).overview
        let difference = try XCTUnwrap(GoldenDifference(base, nudged))
        print("golden: +0.02 EV moves the mean by \(difference.meanAbsolute), p99.9 by \(difference.p999)")
        XCTAssertGreaterThan(difference.meanAbsolute, Self.meanTolerance * 2,
                             "a 1/50 EV change would pass the golden tests; tighten meanTolerance")
    }

    /// References must hold a render exactly, or every comparison starts
    /// with an error of its own.
    func testReferencePNGsAreLossless() throws {
        let image = try render(Recipe(name: "round-trip") { $0.vibrance = 0.4 }).overview
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("golden-roundtrip-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try image.writePNG(to: url)
        let readBack = try GoldenImage(contentsOf: url)
        XCTAssertTrue(readBack == image)
        XCTAssertTrue(readBack.hasSameColourSpace(as: image), readBack.colourSpaceDescription)
    }

    // MARK: - Machinery

    struct Recipe {
        let name: String
        /// Extra quarter turns clockwise, as the editor's rotate buttons.
        var quarterTurns = 0
        /// Whether the whole-frame overview is checked.
        var overview = true
        var outputSpace: ColorKit.OutputSpace = .sRGB
        var bitsPerComponent = 16
        /// Centre (0...1 of the exported frame) of a full-resolution window
        /// to check as well, for edits whose effect is fine detail.
        var detail: SIMD2<Double>?
        let edit: @Sendable (inout EditParameters) -> Void

        init(name: String, quarterTurns: Int = 0, overview: Bool = true, detail: SIMD2<Double>? = nil,
             outputSpace: ColorKit.OutputSpace = .sRGB, bitsPerComponent: Int = 16,
             edit: @escaping @Sendable (inout EditParameters) -> Void) {
            self.name = name; self.quarterTurns = quarterTurns; self.overview = overview
            self.detail = detail; self.outputSpace = outputSpace; self.bitsPerComponent = bitsPerComponent
            self.edit = edit
        }
    }

    struct Rendered {
        let overview: GoldenImage
        let detail: GoldenImage?
    }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Golden")
    static let failureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/golden-failures")
    static var isUpdating: Bool { ProcessInfo.processInfo.environment["LATENT_UPDATE_GOLDEN"] == "1" }

    nonisolated(unsafe) private static var shared: (file: RawFile, gpu: GPUContext)?
    private static let sharedLock = NSLock()

    override class func setUp() {
        super.setUp()
        // Artefacts from an earlier run would read as current failures.
        try? FileManager.default.removeItem(at: failureDirectory)
    }

    /// The raw file and GPU, opened once for the whole class. Each recipe
    /// still gets a fresh session and pipeline, so test order can't matter.
    private func fixture() throws -> (RawFile, GPUContext) {
        let path = TestAssets.path(Self.assetName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "\(Self.assetName) missing; run scripts/fetch_test_assets.sh")
        Self.sharedLock.lock(); defer { Self.sharedLock.unlock() }
        if let shared = Self.shared { return shared }
        let opened = (file: try RawFile(path: path), gpu: try GPUContext())
        print("golden: rendering on \(opened.gpu.device.name)")
        Self.shared = opened
        return opened
    }

    /// An export, through the same `ExportPlan` decisions `ExportWorker`
    /// makes: the edit saved as edit-stack JSON and rebuilt over the
    /// image's defaults, the render scale, the rotation; then the
    /// exporter's GPU pass for rotation, crop, resize and quantisation.
    /// Only the file encode is left out (ImageIO's, not ours).
    private func render(_ recipe: Recipe, session existing: ImageSession? = nil,
                        pipeline existingPipeline: RenderPipeline? = nil) throws -> Rendered {
        let (file, gpu) = try fixture()
        let session = try existing ?? ImageSession(file: file, gpu: gpu)
        let pipeline = existingPipeline ?? RenderPipeline(gpu: gpu)

        // As the editor saves an untouched image: white balance "as shot".
        var edited = EditParameters()
        edited.whiteBalance = .asShot
        recipe.edit(&edited)
        let json = try EditStack(parameters: edited).encodeJSON()
        let parameters = try ExportPlan.parameters(editStackJSON: json, session: session,
                                                   colorSpace: recipe.outputSpace)
        let rotation = ExportPlan.rotation(for: file.summary, userRotation: recipe.quarterTurns)
        let exporter = Exporter(gpu: gpu)

        let small = try pipeline.render(
            session, scale: ExportPlan.scale(for: file.summary, maxLongEdge: Self.overviewLongEdge),
            parameters: parameters, output: .file(recipe.outputSpace))
        let overview = try GoldenImage(exporter.cgImage(
            from: small, colorSpace: recipe.outputSpace, rotation: rotation, crop: parameters.crop,
            bitsPerComponent: recipe.bitsPerComponent, maxLongEdge: Self.overviewLongEdge))

        var detail: GoldenImage?
        if let centre = recipe.detail {
            let full = try pipeline.render(session, scale: ExportPlan.scale(for: file.summary, maxLongEdge: nil),
                                           parameters: parameters, output: .file(recipe.outputSpace))
            let frame = try exporter.cgImage(from: full, colorSpace: recipe.outputSpace, rotation: rotation,
                                             crop: parameters.crop, bitsPerComponent: recipe.bitsPerComponent)
            let size = min(Self.detailSize, frame.width, frame.height)
            let x = min(max(Int(centre.x * Double(frame.width)) - size / 2, 0), frame.width - size)
            let y = min(max(Int(centre.y * Double(frame.height)) - size / 2, 0), frame.height - size)
            guard let window = frame.cropping(to: CGRect(x: x, y: y, width: size, height: size)) else {
                throw GoldenImageError.unreadable
            }
            detail = try GoldenImage(window)
        }
        return Rendered(overview: overview, detail: detail)
    }

    private func check(_ recipe: Recipe, file: StaticString = #filePath, line: UInt = #line) throws {
        let rendered = try render(recipe)
        if recipe.overview {
            try compare(rendered.overview, name: recipe.name, file: file, line: line)
        }
        if let detail = rendered.detail {
            try compare(detail, name: "\(recipe.name)-detail", file: file, line: line)
        }
    }

    private func compare(_ actual: GoldenImage, name: String, file: StaticString, line: UInt) throws {
        let reference = Self.goldenDirectory.appendingPathComponent("\(name).png")
        let update = "LATENT_UPDATE_GOLDEN=1 swift test --filter GoldenImageTests"
        if Self.isUpdating {
            try actual.writePNG(to: reference)
            print("golden: wrote \(reference.lastPathComponent)")
            return
        }
        guard FileManager.default.fileExists(atPath: reference.path) else {
            XCTFail("No reference image Golden/\(name).png. Create it with: \(update)", file: file, line: line)
            return
        }
        let expected = try GoldenImage(contentsOf: reference)
        guard expected.hasSameColourSpace(as: actual) else {
            XCTFail("\(name): rendered in \(actual.colourSpaceDescription), reference is \(expected.colourSpaceDescription)",
                    file: file, line: line)
            return
        }
        guard let difference = GoldenDifference(expected, actual) else {
            XCTFail("\(name): rendered \(actual.width)x\(actual.height), reference is \(expected.width)x\(expected.height)",
                    file: file, line: line)
            return
        }
        guard difference.meanAbsolute > Self.meanTolerance || difference.p999 > Self.p999Tolerance else { return }

        let actualURL = Self.failureDirectory.appendingPathComponent("\(name)-actual.png")
        let diffURL = Self.failureDirectory.appendingPathComponent("\(name)-difference-x8.png")
        try actual.writePNG(to: actualURL)
        try difference.visualisation.writePNG(to: diffURL)
        func f(_ v: Double) -> String { String(format: "%.4f", v) }
        XCTFail("""
            \(name) no longer matches Golden/\(name).png: \
            mean difference \(f(difference.meanAbsolute)) (limit \(f(Self.meanTolerance))), \
            99.9th percentile \(f(difference.p999)) (limit \(f(Self.p999Tolerance))), max \(f(difference.maximum)). \
            The render and an 8x difference image are in \(Self.failureDirectory.path). \
            If the change is intended: \(update), and commit the new references.
            """, file: file, line: line)
    }
}
