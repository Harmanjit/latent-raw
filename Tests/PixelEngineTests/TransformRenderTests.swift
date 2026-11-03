import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// The Transform panel on the GPU. It adds no pass of its own (it is part
/// of the lens stage's one homography), so what needs checking is that an
/// inactive transform renders bit for bit as before, and an active one
/// moves the pixels where the matrix says.
final class TransformRenderTests: XCTestCase {
    private func open() throws -> (ImageSession, RenderPipeline, GPUContext) {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: try TestAssets.d750Path()), gpu: gpu)
        return (session, RenderPipeline(gpu: gpu), gpu)
    }

    private func render(_ session: ImageSession, _ pipeline: RenderPipeline, _ gpu: GPUContext,
                        _ p: EditParameters) throws -> (pixels: [Float16], width: Int, height: Int) {
        let texture = try pipeline.render(session, scale: .binned(quads: 4), parameters: p)
        return (try TextureReadback.float16Pixels(of: texture, gpu: gpu), texture.width, texture.height)
    }

    /// An Upright mode with no result, and Constrain Crop, are tool
    /// settings: the render is exactly the untransformed one (and the
    /// lens pass isn't even run for them).
    func testInactiveTransformIsBitIdentical() throws {
        let (session, pipeline, gpu) = try open()
        var plain = EditParameters()
        plain.perspective = PerspectiveCorrection(vertical: 0.2, horizontal: -0.1)
        var tool = plain
        tool.perspective.constrainCrop = true
        tool.perspective.upright = UprightCorrection(mode: .guided)
        XCTAssertEqual(tool.perspective.inverseMatrix, plain.perspective.inverseMatrix)
        let a = try render(session, pipeline, gpu, plain), b = try render(session, pipeline, gpu, tool)
        XCTAssertEqual(a.pixels, b.pixels)

        var none = EditParameters()
        none.perspective.constrainCrop = true
        XCTAssertEqual(RenderPipeline.wantsLensCorrection(session: session, parameters: none),
                       RenderPipeline.wantsLensCorrection(session: session, parameters: EditParameters()),
                       "a preference alone doesn't start the lens pass")
    }

    /// Flip Horizontal shows the picture mirrored, pixel for pixel (within
    /// the bilinear read's rounding).
    func testFlipHorizontalMirrorsTheRender() throws {
        let (session, pipeline, gpu) = try open()
        var base = EditParameters()
        // The keystone keeps the lens pass on in both renders, so only
        // the flip differs.
        base.perspective = PerspectiveCorrection(vertical: 0.15, horizontal: 0)
        var flipped = base
        flipped.perspective.flip(horizontal: true)
        let a = try render(session, pipeline, gpu, base), b = try render(session, pipeline, gpu, flipped)
        XCTAssertEqual(a.width, b.width)
        var total: Float = 0, worst: Float = 0, n = 0
        // Away from the very edge, where the source runs out on one side.
        for y in 4..<(a.height - 4) {
            for x in 4..<(a.width - 4) {
                let i = (y * a.width + x) * 4, j = (y * a.width + (a.width - 1 - x)) * 4
                for c in 0..<3 {
                    let d = abs(Float(a.pixels[i + c]) - Float(b.pixels[j + c]))
                    total += d; worst = max(worst, d); n += 1
                }
            }
        }
        XCTAssertLessThan(total / Float(n), 0.003, "mean difference")
        XCTAssertLessThan(worst, 0.15, "largest difference")
    }

    /// Scale 1.25 shows the centre of the picture enlarged: the scaled
    /// render at a point is the plain render at 0.8 of the distance from
    /// the centre.
    func testScaleEnlargesAboutTheCentre() throws {
        let (session, pipeline, gpu) = try open()
        var base = EditParameters()
        base.perspective = PerspectiveCorrection(vertical: 0.0001, horizontal: 0)
        var scaled = base
        scaled.perspective.scale = 1.25
        let a = try render(session, pipeline, gpu, base), b = try render(session, pipeline, gpu, scaled)
        let cx = Float(a.width) / 2, cy = Float(a.height) / 2
        var total: Float = 0, n = 0
        for y in stride(from: 10, to: a.height - 10, by: 7) {
            for x in stride(from: 10, to: a.width - 10, by: 7) {
                // Pixel centre x + 0.5 in b reads from 0.8 of its offset in a.
                let sx = cx + (Float(x) + 0.5 - cx) * 0.8 - 0.5, sy = cy + (Float(y) + 0.5 - cy) * 0.8 - 0.5
                let ix = Int(sx.rounded()), iy = Int(sy.rounded())
                guard abs(sx - Float(ix)) < 0.1, abs(sy - Float(iy)) < 0.1 else { continue }
                let i = (y * a.width + x) * 4, j = (iy * a.width + ix) * 4
                for c in 0..<3 { total += abs(Float(b.pixels[i + c]) - Float(a.pixels[j + c])); n += 1 }
            }
        }
        XCTAssertGreaterThan(n, 30)
        XCTAssertLessThan(total / Float(n), 0.01)
        XCTAssertNotEqual(a.pixels, b.pixels)
    }
}
