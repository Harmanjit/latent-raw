import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// Distraction Removal › Reflections: the stored form, the gain map, the
/// stage on a synthetic texture, and the pipeline skipping it without a
/// map (no model installed).
final class ReflectionRemovalTests: XCTestCase {
    func testStoredFormAbsentWhileOff() throws {
        XCTAssertNil(EditStack(parameters: EditParameters()).modules.reflections)
        XCTAssertFalse(try EditStack(parameters: EditParameters()).encodeJSON().contains("reflections"))
        var p = EditParameters()
        p.reflections = ReflectionRemoval(amount: 60, model: "dereflect@1")
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"reflections\""))
        XCTAssertEqual(try EditStack.decode(json: json).parameters().reflections, p.reflections)
        XCTAssertNotEqual(p, EditParameters())
        XCTAssertTrue(EditStack(parameters: p).presentGroups.contains(.heal))
        XCTAssertEqual(EditStack().merged(with: EditStack(parameters: p), groups: [.heal]).modules.reflections,
                       p.reflections)
        XCTAssertTrue(EditHistory.describeChange(from: EditStack(), to: EditStack(parameters: p)).contains("Reflections"))
        // Hand-edited numbers come back in range.
        let wild = try EditStack.decode(json: #"{"schema":1,"process":"1.0","modules":{"reflections":{"amount":1e9}}}"#)
        XCTAssertEqual(try wild.parameters().reflections.amount, 100)
        // Back to zero is off, and absent again.
        p.reflections.amount = 0
        XCTAssertNil(EditStack(parameters: p).modules.reflections)
    }

    func testGainBytes() {
        XCTAssertEqual(ReflectionMap.gain(forByte: ReflectionMap.byte(forGain: 1)), 1, accuracy: 0.005)
        XCTAssertEqual(ReflectionMap.byte(forGain: .nan), ReflectionMap.byte(forGain: 1))
        XCTAssertEqual(ReflectionMap.byte(forGain: 9), 255)
        XCTAssertEqual(ReflectionMap.byte(forGain: -1), 0)
        let map = ReflectionMap(width: 2, height: 1, gains: [64, 128, 255, 255, 0, 0, 0, 255], source: "t@1")
        XCTAssertTrue(map.isValid)
        XCTAssertFalse(ReflectionMap(width: 2, height: 2, gains: [1], source: "t@1").isValid)
    }

    /// A map whose left half halves the light and whose right half leaves
    /// it alone.
    static func halfMap() -> ReflectionMap {
        let w = 8, h = 4
        var gains = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let b = x < w / 2 ? ReflectionMap.byte(forGain: 0.5) : ReflectionMap.byte(forGain: 1)
                for k in 0..<3 { gains[(y * w + x) * 4 + k] = b }
            }
        }
        return ReflectionMap(width: w, height: h, gains: gains, source: "t@1")
    }

    func testStageMultipliesByTheGainsMixedByTheAmount() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.plain)), gpu: gpu)
        XCTAssertNil(session.reflectionTexture())
        session.setReflectionMap(Self.halfMap())
        let gains = try XCTUnwrap(session.reflectionTexture())
        let w = 64, h = 32
        let input = try HealQualityTests.texture(width: w, height: h, gpu: gpu) { _, _ in SIMD3(0.8, 0.6, 0.4) }
        func run(_ amount: Float, linear: Bool) throws -> [Float16] {
            let output = try XCTUnwrap(gpu.makePrivateTexture(width: w, height: h, pixelFormat: .rgba16Float))
            let cmd = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
            let geometry = LensBlurStage.Geometry(tileOrigin: .zero, sensorSize: SIMD2(Float(w), Float(h)),
                                                  binSpan: 1, isLinear: linear, headroom: 1)
            try ReflectionStage.encode(input: input, output: output, gains: gains,
                                       removal: ReflectionRemoval(amount: amount), geometry: geometry,
                                       gpu: gpu, commandBuffer: cmd)
            cmd.commit(); cmd.waitUntilCompleted()
            return try TextureReadback.float16Pixels(of: output, gpu: gpu)
        }
        func red(_ px: [Float16], _ x: Int) -> Double { Double(px[(16 * w + x) * 4]) }
        let full = try run(100, linear: true)
        XCTAssertEqual(red(full, 4), 0.4, accuracy: 0.01, "left: half the light")
        XCTAssertEqual(red(full, 60), 0.8, accuracy: 0.005, "right: unchanged")
        let half = try run(50, linear: true)
        XCTAssertEqual(red(half, 4), 0.6, accuracy: 0.01, "half the amount, half way")
        let encoded = try run(100, linear: false)
        XCTAssertEqual(red(encoded, 4), 0.8 * pow(0.5, 1 / 2.2), accuracy: 0.01, "through the 2.2 power")
    }

    func testPipelineSkipsTheStageWithoutAMap() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.ramp)), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        func render(_ p: EditParameters) throws -> [Float16] {
            try TextureReadback.float16Pixels(of: pipeline.render(session, scale: .fitting(maxDimension: 400),
                                                                  parameters: p), gpu: gpu)
        }
        let plain = try render(EditParameters())
        var on = EditParameters()
        on.reflections = ReflectionRemoval(amount: 100, model: "t@1")
        XCTAssertEqual(try render(on), plain, "no model, no map: nothing changes")
        session.setReflectionMap(Self.halfMap())
        XCTAssertNotEqual(try render(on), plain, "with a map the stage runs")
    }
}
