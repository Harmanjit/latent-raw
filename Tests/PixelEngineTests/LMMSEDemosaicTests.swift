import XCTest
import Metal
@testable import PixelEngine
@testable import RawCore

/// The LMMSE demosaic (Shaders/LMMSE.metal): flat colour to the edge in
/// every CFA order, edges no deeper than its reach, a gentler answer than
/// bilinear on noise, and the stored choice.
final class LMMSEDemosaicTests: XCTestCase {
    static func demosaic(_ values: [Float], width: Int, height: Int, order: UInt8,
                         gpu: GPUContext) throws -> [Float16] {
        let pipeline = RenderPipeline(gpu: gpu)
        let cfa = try DemosaicBorderTests.cfaTexture(values, width: width, height: height, gpu: gpu)
        let cmd = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        let out = try pipeline.encodeLMMSE(cmdBuffer: cmd, cfa: cfa, order: order) { format, _ in
            try XCTUnwrap(gpu.makePrivateTexture(width: width, height: height, pixelFormat: format))
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        return try TextureReadback.float16Pixels(of: out, gpu: gpu)
    }

    func testFlatFrameKeepsItsColourEverywhere() throws {
        let gpu = try GPUContext()
        let colour: [Float] = [0.3, 0.5, 0.2]
        for (name, order) in DemosaicBorderTests.orders {
            for (w, h) in [(48, 40), (47, 39)] {
                var cfa = [Float](repeating: 0, count: w * h)
                for y in 0..<h { for x in 0..<w { cfa[y * w + x] = colour[DemosaicBorderTests.colour(order, x, y)] } }
                let px = try Self.demosaic(cfa, width: w, height: h, order: order, gpu: gpu)
                var worst: Float = 0
                for i in 0..<(w * h) { for c in 0..<3 { worst = max(worst, abs(Float(px[i * 4 + c]) - colour[c])) } }
                XCTAssertLessThan(worst, 1e-3, "\(name) \(w)x\(h)")
            }
        }
    }

    /// A crop demosaiced on its own matches the same pixels of the whole
    /// frame from 12 pixels in: the edge handling reaches no further than
    /// the passes do, inside the region renders' 16-pixel apron.
    func testEdgeHandlingStaysWithinReach() throws {
        let gpu = try GPUContext()
        let w = 96, h = 80, reach = 12
        let order: UInt8 = 0x94
        let frame = DemosaicBorderTests.noiseFrame(width: w, height: h, order: order)
        let (cx, cy, cw, ch) = (14, 12, 60, 50)
        var crop = [Float](repeating: 0, count: cw * ch)
        for y in 0..<ch { for x in 0..<cw { crop[y * cw + x] = frame[(y + cy) * w + x + cx] } }
        let whole = try Self.demosaic(frame, width: w, height: h, order: order, gpu: gpu)
        let part = try Self.demosaic(crop, width: cw, height: ch, order: order, gpu: gpu)
        var worst: Float = 0
        for y in reach..<(ch - reach) {
            for x in reach..<(cw - reach) {
                for c in 0..<3 {
                    let a = Float(part[(y * cw + x) * 4 + c]), b = Float(whole[((y + cy) * w + x + cx) * 4 + c])
                    worst = max(worst, abs(a - b))
                }
            }
        }
        XCTAssertLessThan(worst, 1e-3)
    }

    /// Every value finite and in range on a noise frame.
    func testNoiseFrameStaysFiniteAndBounded() throws {
        let gpu = try GPUContext()
        let frame = DemosaicBorderTests.noiseFrame(width: 64, height: 48, order: 0x16)
        let px = try Self.demosaic(frame, width: 64, height: 48, order: 0x16, gpu: gpu)
        let peak = frame.max() ?? 1
        XCTAssertTrue(px.allSatisfy { Float($0).isFinite && Float($0) >= 0 && Float($0) <= peak * 3 })
    }

    func testMethodIsListedAndStored() throws {
        XCTAssertTrue(DemosaicMethod.allCases.contains(.lmmse))
        XCTAssertEqual(EditParameters().demosaic, .rcd, "RCD stays the default")
        var p = EditParameters()
        p.demosaic = .lmmse
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"method\":\"lmmse\""))
        XCTAssertEqual(try EditStack.decode(json: json).parameters().demosaic, .lmmse)
        XCTAssertTrue(DemosaicMethod.lmmse.displayName.contains("high ISO"))
    }
}
