import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// Visualise Spots (Shaders/Dust.metal, docs/Retouch.md §6) on a synthetic
/// display texture: a flat field with one dark disc the size of the band's
/// radius. The disc must read dark, the field white, at every bin factor,
/// and the Contrast slider must decide whether a faint dip shows.
final class DustVisualiseTests: XCTestCase {
    static let size = 256

    /// A flat grey texture with a disc of `attenuation` (a factor on the
    /// luminance) and `radius` pixels at `centre`.
    private func field(dipAt centre: SIMD2<Float>, radius: Float, attenuation: Float, gpu: GPUContext) throws -> MTLTexture {
        try HealQualityTests.texture(width: Self.size, height: Self.size, gpu: gpu) { x, y in
            let d = simd_length(SIMD2(Float(x) + 0.5, Float(y) + 0.5) - centre)
            let level = d <= radius ? Double(attenuation) : 1
            return SIMD3(repeating: 0.5) * level
        }
    }

    /// Runs the kernel and returns a red-channel lookup.
    private func visualised(_ input: MTLTexture, threshold: Float, radiusSensorPx: Float, binSpan: Float,
                            gpu: GPUContext) throws -> (Int, Int) -> Float {
        let output = try XCTUnwrap(gpu.makePrivateTexture(width: input.width, height: input.height, pixelFormat: .rgba16Float))
        let cmd = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        try RenderPipeline.encodeDustVisualise(
            input: input, output: output, visualisation: SpotVisualisation(threshold: threshold, radiusSensorPx: radiusSensorPx),
            binSpan: binSpan, gpu: gpu, commandBuffer: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        XCTAssertNotEqual(cmd.status, .error)
        let px = try TextureReadback.float16Pixels(of: output, gpu: gpu)
        return { x, y in Float(px[(y * Self.size + x) * 4]) }
    }

    /// A one-stop dip of the band's radius, at binSpan 1 (a 16 px spot on
    /// the tile) and 4 (the same spot 4 px across on the preview): dark
    /// at the dip, white on the field, white at the texture's corner where
    /// every tap clamps.
    func testDipReadsDarkAndFlatReadsWhite() throws {
        let gpu = try GPUContext()
        let radiusSensorPx: Float = 16
        for binSpan: Float in [1, 4] {
            let sigma = radiusSensorPx / binSpan
            let centre = SIMD2<Float>(96, 96)
            let input = try field(dipAt: centre, radius: sigma, attenuation: 0.5, gpu: gpu)
            let out = try visualised(input, threshold: 0.5, radiusSensorPx: radiusSensorPx, binSpan: binSpan, gpu: gpu)
            XCTAssertLessThan(out(96, 96), 0.1, "binSpan \(binSpan): the dip")
            XCTAssertGreaterThan(out(200, 60), 0.9, "binSpan \(binSpan): the field")
            XCTAssertGreaterThan(out(0, 0), 0.9, "binSpan \(binSpan): the corner")
            XCTAssertGreaterThan(out(255, 255), 0.9, "binSpan \(binSpan): the far corner")
            // Well outside the outer box (3 sigma) the dip has no effect.
            XCTAssertGreaterThan(out(96 + Int(6 * sigma) + 8, 96), 0.9, "binSpan \(binSpan): beyond the reach")
        }
    }

    /// Contrast 1 shows a dip a tenth of a stop deep; Contrast 0 hides
    /// it; the one-stop dip shows at both.
    func testContrastSetsHowFaintADipShows() throws {
        let gpu = try GPUContext()
        let faint = try field(dipAt: SIMD2(96, 96), radius: 16, attenuation: 0.93, gpu: gpu)
        XCTAssertLessThan(try visualised(faint, threshold: 1, radiusSensorPx: 16, binSpan: 1, gpu: gpu)(96, 96), 0.1)
        XCTAssertGreaterThan(try visualised(faint, threshold: 0, radiusSensorPx: 16, binSpan: 1, gpu: gpu)(96, 96), 0.9)
        let deep = try field(dipAt: SIMD2(96, 96), radius: 16, attenuation: 0.5, gpu: gpu)
        XCTAssertLessThan(try visualised(deep, threshold: 0, radiusSensorPx: 16, binSpan: 1, gpu: gpu)(96, 96), 0.1)
    }

    /// Through the pipeline: the display pass runs for a viewport output
    /// and never for a file, whatever the parameters say.
    func testRunsForTheViewportOnly() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.ramp)), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var viewport = RenderOutput.edrDisplay(headroom: 1)
        viewport.spotVisualisation = SpotVisualisation(threshold: 0.5, radiusSensorPx: 8)
        let shown = try TextureReadback.float16Pixels(of: try pipeline.render(session, scale: .binned(quads: 1), output: viewport), gpu: gpu)
        // The ramp's flat patch is white in the view; its steps aren't all.
        let flat = shown[(100 * 600 + 100) * 4]
        XCTAssertGreaterThan(Float(flat), 0.9)
        let file = try TextureReadback.float16Pixels(of: try pipeline.render(session, scale: .binned(quads: 1), output: .file(.sRGB)), gpu: gpu)
        XCTAssertNotEqual(file, shown)
        XCTAssertNil(RenderOutput.file(.sRGB).spotVisualisation)
    }
}
