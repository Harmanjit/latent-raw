import XCTest
import Metal
@testable import PixelEngine
@testable import RawCore

final class GradingTests: XCTestCase {
    func testIdentityCurveLUTIsLinearAndMonotone() {
        let lut = ToneCurve.identity.lookupTable()
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut[0], 0, accuracy: 1e-6)
        XCTAssertEqual(lut[255], 1, accuracy: 1e-6)
        XCTAssertEqual(lut[128], 128.0 / 255.0, accuracy: 1e-4)

        // An S-curve stays monotone (no overshoot between points) and
        // passes through its control points.
        let s = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.25, 0.15), SIMD2(0.75, 0.85), SIMD2(1, 1)])
        let l = s.lookupTable()
        for i in 1..<256 { XCTAssertGreaterThanOrEqual(l[i], l[i - 1] - 1e-6) }
        XCTAssertEqual(l[Int(0.25 * 255)], 0.15, accuracy: 0.01)
        XCTAssertEqual(l[Int(0.75 * 255)], 0.85, accuracy: 0.01)
        XCTAssertLessThan(l[64], 64.0 / 255.0, "S-curve darkens the quarter tone")
    }

    func testEditStackRoundTripsGrading() throws {
        var p = EditParameters()
        p.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.4), SIMD2(1, 1)])
        p.hsl.saturation[5] = 0.6
        p.hsl.hue[1] = -0.3
        p.splitToning = SplitToning(shadowHue: 210, shadowSaturation: 0.3, highlightHue: 40,
                                    highlightSaturation: 0.2, balance: 0.1)
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"splittoning\""))
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back, p)
        XCTAssertFalse(EditStack.isDefault(p, relativeTo: EditParameters()))
    }

    func testGradingEffectsOnARealImage() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        struct Stats { var meanLuma: Double; var meanChroma: Double; var brightWarmth: Double }
        func stats(_ p: EditParameters) throws -> Stats {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            var luma = 0.0, chroma = 0.0, warm = 0.0, bright = 0
            let n = px.count / 4
            for i in stride(from: 0, to: px.count, by: 4) {
                let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luma += l
                chroma += max(r, g, b) - min(r, g, b)
                if l > 0.6 { warm += r - b; bright += 1 }
            }
            return Stats(meanLuma: luma / Double(n), meanChroma: chroma / Double(n),
                         brightWarmth: bright > 0 ? warm / Double(bright) : 0)
        }

        let plain = try stats(EditParameters())

        // Neutral grading is bit-for-bit the same as no grading (it's skipped).
        var neutral = EditParameters()
        neutral.hsl = .neutral; neutral.splitToning = .neutral; neutral.toneCurve = .identity
        let n = try stats(neutral)
        XCTAssertEqual(n.meanLuma, plain.meanLuma, accuracy: 1e-9)

        // A curve pulled down darkens.
        var dark = EditParameters()
        dark.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.3), SIMD2(1, 1)])
        XCTAssertLessThan(try stats(dark).meanLuma, plain.meanLuma * 0.9)

        // Desaturating every band removes nearly all chroma.
        var grey = EditParameters()
        grey.hsl.saturation = Array(repeating: -1, count: 8)
        XCTAssertLessThan(try stats(grey).meanChroma, plain.meanChroma * 0.15)

        // Warm highlights: bright pixels get redder than bluer.
        var toned = EditParameters()
        toned.splitToning = SplitToning(shadowHue: 215, shadowSaturation: 0, highlightHue: 40,
                                        highlightSaturation: 1, balance: 0)
        XCTAssertGreaterThan(try stats(toned).brightWarmth, plain.brightWarmth + 0.02)
    }

    /// Vibrance spares skin: hues of about 7 to 58 degrees get at most
    /// about a third of the boost other muted colours get. The guard once
    /// compared a hue in degrees with band edges in turns and spared
    /// nothing. Runs the shipped `applyVibrance` (and its HSV helpers),
    /// cut from ColorPipeline.metal, in a small kernel of its own.
    func testVibranceSparesSkinHues() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let shaderURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PixelEngine/Shaders/ColorPipeline.metal")
        let shader = try String(contentsOf: shaderURL, encoding: .utf8)
        func function(_ signature: String) throws -> String {
            let start = try XCTUnwrap(shader.range(of: signature), signature)
            let end = try XCTUnwrap(shader.range(of: "\n}\n", range: start.lowerBound..<shader.endIndex))
            return String(shader[start.lowerBound..<end.upperBound])
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        \(try function("inline float3 rgbToHSV"))
        \(try function("inline float3 hsvToRGB"))
        \(try function("inline float3 applyVibrance"))
        kernel void vibranceProbe(device const float3 *input [[buffer(0)]], device float *saturation [[buffer(1)]],
                                  constant float &amount [[buffer(2)]], uint i [[thread_position_in_grid]]) {
            saturation[i] = rgbToHSV(applyVibrance(input[i], amount)).y;
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pso = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "vibranceProbe")))

        // Equal saturation (0.4375) and value; hue about 26 (skin) and 220 (blue) degrees.
        let skin = SIMD3<Float>(0.8, 0.6, 0.45)
        let blue = SIMD3<Float>(0.45, 0.58, 0.8)
        var inputs = [skin, blue]
        var amount: Float = 1
        let inBuffer = try XCTUnwrap(device.makeBuffer(bytes: &inputs, length: MemoryLayout<SIMD3<Float>>.stride * 2))
        let outBuffer = try XCTUnwrap(device.makeBuffer(length: 8))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(inBuffer, offset: 0, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        encoder.setBytes(&amount, length: 4, index: 2)
        encoder.dispatchThreads(MTLSize(width: 2, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 2, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let out = outBuffer.contents().bindMemory(to: Float.self, capacity: 2)
        let s0: Float = 0.4375
        let skinGain = out[0] - s0, blueGain = out[1] - s0
        XCTAssertGreaterThan(blueGain, 0.2, "a muted blue gets the full boost")
        XCTAssertGreaterThan(skinGain, 0, "skin still gets some")
        XCTAssertLessThanOrEqual(skinGain, 0.4 * blueGain, "skin gets at most about a third of it")
    }
}
