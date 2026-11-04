import XCTest
import simd
@testable import PixelEngine

/// Per-patch Opacity, for Heal, Clone and Remove: the stored field and what
/// the render does with it.
final class HealOpacityTests: XCTestCase {
    typealias Q = HealQualityTests
    typealias R = RemoveFillTests

    /// A clone at half opacity lands halfway between the target and the
    /// source; at none it changes nothing; fully, or with no opacity
    /// stored, it copies exactly as before.
    func testCloneOpacityMixesWithTheImageBeneath() throws {
        let gpu = try GPUContext()
        let w = 96, h = 64
        let size = SIMD2<Float>(Float(w), Float(h))
        let input = try Q.texture(width: w, height: h, gpu: gpu) { x, _ in
            x < 48 ? SIMD3(0.6, 0.1, 0.1) : SIMD3(0.1, 0.6, 0.1)
        }
        func clone(_ opacity: Float?) -> HealPatch {
            HealPatch(target: SIMD2(72, 32) / size, source: SIMD2(24, 32) / size,
                      radius: 10.0 / 64, feather: 0, mode: .clone, opacity: opacity)
        }
        let full = try Q.healed(input, patches: [clone(nil)], sensorSize: size, gpu: gpu)
        let one = try Q.healed(input, patches: [clone(1)], sensorSize: size, gpu: gpu)
        let half = try Q.healed(input, patches: [clone(0.5)], sensorSize: size, gpu: gpu)
        let none = try Q.healed(input, patches: [clone(0)], sensorSize: size, gpu: gpu)
        XCTAssertEqual(full(72, 32).x, 0.6, accuracy: 1e-3)
        XCTAssertEqual(one(72, 32), full(72, 32))
        XCTAssertEqual(half(72, 32).x, 0.35, accuracy: 2e-3)
        XCTAssertEqual(half(72, 32).y, 0.35, accuracy: 2e-3)
        XCTAssertEqual(none(72, 32).y, 0.6, accuracy: 1e-3)
        XCTAssertEqual(none(72, 32).x, 0.1, accuracy: 1e-3)
    }

    /// A heal at half opacity keeps half the blemish.
    func testHealOpacityKeepsSomeOfTheBlemish() throws {
        let gpu = try GPUContext()
        let w = 96, h = 64
        let size = SIMD2<Float>(Float(w), Float(h))
        let input = try Q.texture(width: w, height: h, gpu: gpu) { x, y in
            let d = simd_length(SIMD2(Double(x - 64), Double(y - 32)))
            return d < 4 ? SIMD3(0.05, 0.05, 0.05) : SIMD3(0.4, 0.4, 0.4)
        }
        func heal(_ opacity: Float?) -> HealPatch {
            HealPatch(target: SIMD2(64, 32) / size, source: SIMD2(24, 32) / size,
                      radius: 8.0 / 64, feather: 0.2, mode: .heal, opacity: opacity)
        }
        let full = try Q.healed(input, patches: [heal(nil)], sensorSize: size, gpu: gpu)(64, 32).x
        let half = try Q.healed(input, patches: [heal(0.5)], sensorSize: size, gpu: gpu)(64, 32).x
        XCTAssertEqual(full, 0.4, accuracy: 0.01)
        XCTAssertEqual(half, (0.05 + full) / 2, accuracy: 0.01)
    }

    /// A Remove at no opacity leaves the object; at half, the result is
    /// halfway between the object and the full fill, in linear light.
    func testRemoveOpacityMixesTheFill() throws {
        let gpu = try GPUContext()
        let input = try Q.texture(width: R.width, height: R.height, gpu: gpu) { R.scene($0, $1) }
        func removal(_ opacity: Float?) -> HealPatch {
            var p = R.removal()
            p.opacity = opacity
            return p
        }
        let full = try Q.healed(input, patches: [removal(nil)], sensorSize: R.size, gpu: gpu)
        let half = try Q.healed(input, patches: [removal(0.5)], sensorSize: R.size, gpu: gpu)
        let none = try Q.healed(input, patches: [removal(0)], sensorSize: R.size, gpu: gpu)
        for (x, y) in R.disc(radius: 8) {
            let object = R.scene(x, y)
            XCTAssertEqual(simd_reduce_max(simd_abs(none(x, y) - object)), 0, accuracy: 2e-3)
            let expected = (object + full(x, y)) / 2
            XCTAssertEqual(simd_reduce_max(simd_abs(half(x, y) - expected)), 0, accuracy: 4e-3)
        }
    }

    /// No opacity is absent from the JSON, so patches encode as before;
    /// one below full round-trips; a sidecar's nonsense is made safe.
    func testOpacityEncodesOnlyWhenSetAndIsSanitised() throws {
        let plain = HealPatch(target: [0.5, 0.5], source: [0.6, 0.5], radius: 0.02)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("opacity"))
        XCTAssertEqual(plain.effectiveOpacity, 1)

        var faded = plain
        faded.opacity = 0.4
        var p = EditParameters()
        p.heals = [faded, plain]
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"opacity\""))
        XCTAssertEqual(try EditStack.decode(json: json).parameters().heals, p.heals)

        var wild = plain
        wild.opacity = 1.7
        XCTAssertEqual(wild.sanitized?.opacity, 1)
        wild.opacity = -2
        XCTAssertEqual(wild.sanitized?.opacity, 0)
        wild.opacity = .nan
        XCTAssertEqual(wild.sanitized?.opacity, 1)
        XCTAssertNil(plain.sanitized?.opacity)
    }
}
