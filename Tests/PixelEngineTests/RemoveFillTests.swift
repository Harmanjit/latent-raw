import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// Content-aware Remove: the synthesis on synthetic scenes, its planning,
/// and the stored patch.
final class RemoveFillTests: XCTestCase {
    typealias Q = HealQualityTests
    static let width = 256, height = 192

    /// A sky-like gradient with fine grain, and a dark object on it.
    static func clean(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let shade = 0.25 + 0.35 * Double(y) / Double(height)
        let grain = 1 + 0.06 * Q.noise(x, y, cell: 2, seed: 5)
        return SIMD3(0.35, 0.5, 0.8) * shade * grain
    }
    static let object = (x: 120, y: 90, r: 11.0)
    static func scene(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let dx = Double(x - object.x), dy = Double(y - object.y)
        return (dx * dx + dy * dy).squareRoot() <= object.r ? SIMD3(0.05, 0.04, 0.03) : clean(x, y)
    }

    static var size: SIMD2<Float> { SIMD2(Float(width), Float(height)) }

    static func removal(radius: Float = 14) -> HealPatch {
        HealPatch(id: UUID(uuidString: "6F9F3B0A-5C1E-4C55-9A57-2B7D2C1E0F11")!,
                  target: SIMD2(Float(object.x) + 0.5, Float(object.y) + 0.5) / size,
                  source: SIMD2(Float(object.x) + 0.5, Float(object.y) + 0.5) / size,
                  radius: radius / Float(height), mode: .remove)
    }

    /// RMS difference from the clean scene (8-bit sRGB levels) over `points`.
    static func rms(_ image: (Int, Int) -> SIMD3<Double>, over points: [(Int, Int)]) -> Double {
        var sum = 0.0
        for (x, y) in points {
            let a = image(x, y), b = clean(x, y)
            let d = SIMD3(Q.encode(a.x) - Q.encode(b.x), Q.encode(a.y) - Q.encode(b.y), Q.encode(a.z) - Q.encode(b.z))
            sum += simd_length_squared(d) / 3
        }
        return (sum / Double(max(points.count, 1))).squareRoot()
    }

    static func disc(radius: Double) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for y in 0..<height { for x in 0..<width {
            let dx = Double(x) + 0.5 - Double(object.x) - 0.5, dy = Double(y) + 0.5 - Double(object.y) - 0.5
            if (dx * dx + dy * dy).squareRoot() <= radius { out.append((x, y)) }
        } }
        return out
    }

    func testRemoveFillsTheObjectFromItsSurroundings() throws {
        let gpu = try GPUContext()
        let input = try Q.texture(width: Self.width, height: Self.height, gpu: gpu) { Self.scene($0, $1) }
        let out = try Q.healed(input, patches: [Self.removal()], sensorSize: Self.size, gpu: gpu)
        let inside = Self.disc(radius: 13)
        let before = Self.rms({ Self.scene($0, $1) }, over: inside)
        let after = Self.rms(out, over: inside)
        print("remove: object rms \(before) -> \(after)")
        XCTAssertLessThan(after, before / 8, "the object is gone")
        XCTAssertLessThan(after, 6, "and the fill looks like the sky around it")
        // The darkest fill pixel is sky, not object.
        let darkest = inside.map { simd_reduce_min(out($0.0, $0.1)) }.min() ?? 0
        XCTAssertGreaterThan(darkest, 0.06)
        // Nothing outside the brush changes at all.
        var worst = 0.0
        for y in 0..<Self.height { for x in 0..<Self.width {
            let dx = Double(x) - Double(Self.object.x), dy = Double(y) - Double(Self.object.y)
            guard (dx * dx + dy * dy).squareRoot() > 16 else { continue }
            worst = max(worst, simd_reduce_max(simd_abs(out(x, y) - Self.scene(x, y))))
        } }
        XCTAssertLessThan(worst, 1e-3)
    }

    /// Structure continues through the fill: vertical stripes stay stripes.
    func testRemoveContinuesStripes() throws {
        let gpu = try GPUContext()
        let stripes: (Int, Int) -> SIMD3<Double> = { x, _ in (x / 4) % 2 == 0 ? SIMD3(0.6, 0.6, 0.6) : SIMD3(0.1, 0.1, 0.1) }
        let input = try Q.texture(width: Self.width, height: Self.height, gpu: gpu) { x, y in
            let dx = Double(x - Self.object.x), dy = Double(y - Self.object.y)
            return (dx * dx + dy * dy).squareRoot() <= Self.object.r ? SIMD3(0.9, 0.1, 0.1) : stripes(x, y)
        }
        let out = try Q.healed(input, patches: [Self.removal()], sensorSize: Self.size, gpu: gpu)
        var wrong = 0
        let inside = Self.disc(radius: 12)
        for (x, y) in inside {
            let expected = stripes(x, y).x, got = out(x, y)
            if abs(got.x - expected) > 0.15 || abs(got.y - expected) > 0.15 { wrong += 1 }
        }
        print("remove stripes: \(wrong) of \(inside.count) pixels off the stripe pattern")
        XCTAssertLessThan(Double(wrong) / Double(inside.count), 0.1)
    }

    func testRemoveIsDeterministic() throws {
        let gpu = try GPUContext()
        let input = try Q.texture(width: Self.width, height: Self.height, gpu: gpu) { Self.scene($0, $1) }
        let a = try Q.healed(input, patches: [Self.removal()], sensorSize: Self.size, gpu: gpu)
        let b = try Q.healed(input, patches: [Self.removal()], sensorSize: Self.size, gpu: gpu)
        for (x, y) in Self.disc(radius: 16) { XCTAssertEqual(a(x, y), b(x, y)) }
        // Another patch id draws other random numbers; still a good fill.
        var other = Self.removal()
        other.id = UUID()
        let c = try Q.healed(input, patches: [other], sensorSize: Self.size, gpu: gpu)
        XCTAssertLessThan(Self.rms(c, over: Self.disc(radius: 13)), 6)
    }

    /// A tile grown by `regionIncludingSources` fills exactly as the frame.
    func testTileMatchesTheWholeFrame() throws {
        let gpu = try GPUContext()
        let w = Self.width, h = Self.height
        let sensor = CGSize(width: w, height: h)
        let patch = Self.removal()
        let full = try Q.healed(try Q.texture(width: w, height: h, gpu: gpu) { Self.scene($0, $1) },
                                patches: [patch], sensorSize: Self.size, gpu: gpu)
        let visible = CGRect(x: 118, y: 80, width: 30, height: 20)
        let grown = HealPatch.regionIncludingSources(visible, patches: [patch], sensorSize: sensor)
            .intersection(CGRect(origin: .zero, size: sensor))
        XCTAssertTrue(grown.contains(patch.removeContextBounds(sensorSize: sensor).intersection(CGRect(origin: .zero, size: sensor))))
        XCTAssertTrue(HealPatch.isSelfContained(grown, patches: [patch], sensorSize: sensor))
        let tx = Int(grown.minX.rounded(.down)), ty = Int(grown.minY.rounded(.down))
        let tw = Int(grown.maxX.rounded(.up)) - tx, th = Int(grown.maxY.rounded(.up)) - ty
        XCTAssertLessThan(tw, w, "the region around the patch, not the frame")
        let tile = try Q.healed(try Q.texture(width: tw, height: th, gpu: gpu) { Self.scene($0 + tx, $1 + ty) },
                                patches: [patch], sensorSize: Self.size, tileOrigin: SIMD2(Float(tx), Float(ty)), gpu: gpu)
        var worst = 0.0
        for y in Int(visible.minY)..<Int(visible.maxY) {
            for x in Int(visible.minX)..<Int(visible.maxX) {
                worst = max(worst, simd_reduce_max(simd_abs(tile(x - tx, y - ty) - full(x, y))))
            }
        }
        XCTAssertEqual(worst, 0, "tile agrees with the whole frame")
        // A far patch leaves the region alone.
        XCTAssertEqual(HealPatch.regionIncludingSources(CGRect(x: 0, y: 0, width: 20, height: 20),
                                                        patches: [patch], sensorSize: sensor),
                       CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    /// A 2 x 2 binned render predicts the full-resolution fill's tone.
    func testBinnedRenderPredictsFullResolution() throws {
        let gpu = try GPUContext()
        let w = Self.width, h = Self.height
        let binned = try Q.healed(try Q.texture(width: w / 2, height: h / 2, gpu: gpu) { x, y in
            (Self.scene(2 * x, 2 * y) + Self.scene(2 * x + 1, 2 * y) + Self.scene(2 * x, 2 * y + 1) + Self.scene(2 * x + 1, 2 * y + 1)) / 4
        }, patches: [Self.removal()], sensorSize: Self.size, binSpan: 2, gpu: gpu)
        var worst = 0.0
        for (x, y) in Self.disc(radius: 10) where x % 2 == 0 && y % 2 == 0 {
            let b = binned(x / 2, y / 2), c = Self.clean(x, y)
            worst = max(worst, abs(Q.encode(b.y) - Q.encode(c.y)))
        }
        print("remove binned: worst green difference from the clean sky \(worst)")
        XCTAssertLessThan(worst, 25)
    }

    /// With an object outline the fill covers the outline, not the brush.
    func testObjectMaskReplacesTheBrush() throws {
        let gpu = try GPUContext()
        var patch = Self.removal(radius: 40)
        // A 30 x 30 texel square outline centred on the object.
        let cells = [Bool](repeating: true, count: 16 * 16)
        patch.objectMask = RemoveObjectMask(cells: cells, width: 16, height: 16,
                                            origin: SIMD2(-15, -15) / Self.size, size: SIMD2(30, 30) / Self.size)
        let input = try Q.texture(width: Self.width, height: Self.height, gpu: gpu) { Self.scene($0, $1) }
        let out = try Q.healed(input, patches: [patch], sensorSize: Self.size, gpu: gpu)
        XCTAssertLessThan(Self.rms(out, over: Self.disc(radius: 12)), 6)
        // Inside the brush, outside the outline: untouched.
        for (x, y) in [(Self.object.x + 25, Self.object.y), (Self.object.x - 25, Self.object.y + 10)] {
            XCTAssertEqual(simd_reduce_max(simd_abs(out(x, y) - Self.scene(x, y))), 0, accuracy: 1e-3)
        }
        let box = patch.targetBounds(sensorSize: CGSize(width: Self.width, height: Self.height))
        XCTAssertEqual(box.minX, 105.5, accuracy: 1e-3)
        XCTAssertEqual(box.minY, 75.5, accuracy: 1e-3)
        XCTAssertEqual(box.width, 30, accuracy: 1e-3)
    }

    /// Patches still apply in order around a Remove: a clone after it
    /// copies the filled pixels, and one before it is filled over.
    func testRemoveTakesItsPlaceInTheOrder() throws {
        let gpu = try GPUContext()
        let input = try Q.texture(width: Self.width, height: Self.height, gpu: gpu) { Self.scene($0, $1) }
        let target = SIMD2<Float>(200.5, 90.5) / Self.size
        let clone = HealPatch(target: target, source: SIMD2(Float(Self.object.x) + 0.5, Float(Self.object.y) + 0.5) / Self.size,
                              radius: 6 / Float(Self.height), feather: 0, mode: .clone)
        let out = try Q.healed(input, patches: [Self.removal(), clone], sensorSize: Self.size, gpu: gpu)
        XCTAssertEqual(out(200, 90), out(Self.object.x, Self.object.y))
        XCTAssertGreaterThan(simd_reduce_min(out(200, 90)), 0.06, "the clone copied sky, not the object")
        let reversed = try Q.healed(input, patches: [clone, Self.removal()], sensorSize: Self.size, gpu: gpu)
        XCTAssertLessThan(simd_reduce_max(reversed(200, 90)), 0.06, "a clone first copies the object")
    }

    func testPlanHalvesUntilTheHoleIsSmall() throws {
        let patch = Self.removal(radius: 14)
        let plan = try XCTUnwrap(RemoveStage.plan(patch, width: Self.width, height: Self.height, sensorSize: Self.size,
                                                  tileOrigin: .zero, binSpan: 1))
        XCTAssertGreaterThan(plan.levels.count, 1)
        let coarsest = try XCTUnwrap(plan.levels.last)
        XCTAssertLessThanOrEqual(coarsest.nnfSize.max() - 2 * RemoveStage.patchRadius, RemoveStage.coarsestHole + 2)
        // The region covers the hole and the margin around it.
        XCTAssertGreaterThan(plan.region.size.x, plan.holeHi.x - plan.holeLo.x)
        // A patch off the texture has no plan.
        var far = patch
        far.target = SIMD2(5, 5)
        XCTAssertNil(RemoveStage.plan(far, width: Self.width, height: Self.height, sensorSize: Self.size,
                                      tileOrigin: .zero, binSpan: 1))
        // The seed comes from the id alone.
        XCTAssertEqual(patch.removeSeed, Self.removal().removeSeed)
    }

    /// An object across a horizon: the fill keeps the line where it was,
    /// sky above and ground below.
    func testRemoveKeepsAHorizon() throws {
        let gpu = try GPUContext()
        let horizon = Self.object.y
        let land: (Int, Int) -> SIMD3<Double> = { x, y in
            let grain = 1 + 0.05 * Q.noise(x, y, cell: 2, seed: 9)
            return (y < horizon ? SIMD3(0.4, 0.55, 0.85) : SIMD3(0.25, 0.3, 0.1)) * grain
        }
        let input = try Q.texture(width: Self.width, height: Self.height, gpu: gpu) { x, y in
            let dx = Double(x - Self.object.x), dy = Double(y - Self.object.y)
            return (dx * dx + dy * dy).squareRoot() <= Self.object.r ? SIMD3(0.9, 0.9, 0.9) : land(x, y)
        }
        let out = try Q.healed(input, patches: [Self.removal()], sensorSize: Self.size, gpu: gpu)
        var wrong = 0
        let inside = Self.disc(radius: 12).filter { abs($0.1 - horizon) > 2 }
        for (x, y) in inside {
            let isSky = out(x, y).z > 0.5
            if isSky != (y < horizon) { wrong += 1 }
        }
        print("remove horizon: \(wrong) of \(inside.count) pixels on the wrong side")
        XCTAssertLessThan(Double(wrong) / Double(inside.count), 0.05)
    }

    /// A large removal at export size finishes in reasonable time.
    func testLargeRemovalTiming() throws {
        let gpu = try GPUContext()
        let w = 3000, h = 2000
        let input = try Q.texture(width: w, height: h, gpu: gpu) { x, y in
            let dx = Double(x - 1500), dy = Double(y - 1000)
            return (dx * dx + dy * dy).squareRoot() < 280 ? SIMD3(0.05, 0.05, 0.05)
                : SIMD3(0.3, 0.4, 0.6) * (1 + 0.05 * Q.noise(x, y, cell: 3, seed: 2))
        }
        let patch = HealPatch(target: [0.5, 0.5], source: [0.5, 0.5], radius: 300 / Float(h), mode: .remove)
        let start = Date()
        let out = try Q.healed(input, patches: [patch], sensorSize: SIMD2(Float(w), Float(h)), gpu: gpu)
        let seconds = Date().timeIntervalSince(start)
        print("remove 600 px hole on 6 MP: \(seconds) s")
        XCTAssertGreaterThan(simd_reduce_min(out(1500, 1000)), 0.15)
        XCTAssertLessThan(seconds, 20)
    }

    /// Through the whole pipeline: a Remove patch changes its area only,
    /// the heal cache keeps the fill, and an outline is part of the key.
    func testPipelineRendersARemovalAndCachesIt() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.plain)), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        func render(_ p: EditParameters) throws -> (pixels: [Float16], cached: Bool, width: Int) {
            var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: false)
            let t = try pipeline.render(session, scale: .full, parameters: p, output: .file(.sRGB), info: &info)
            return (try TextureReadback.float16Pixels(of: t, gpu: gpu), info.healWasCached, t.width)
        }
        let plain = try render(EditParameters())
        var p = EditParameters()
        p.heals = [HealPatch(target: [0.5, 0.5], source: [0.5, 0.5], radius: 0.1, mode: .remove)]
        let removed = try render(p)
        XCTAssertFalse(removed.cached)
        XCTAssertEqual(try render(p).cached, true, "the fill is cached")
        // Far from the patch nothing changes.
        let w = plain.width
        for (x, y) in [(2, 2), (w - 3, 3), (4, 44)] {
            for c in 0..<3 { XCTAssertEqual(plain.pixels[(y * w + x) * 4 + c], removed.pixels[(y * w + x) * 4 + c]) }
        }
        var outlined = p
        outlined.heals[0].objectMask = RemoveObjectMask(cells: [true, true, true, true], width: 2, height: 2,
                                                        origin: [-0.05, -0.05], size: [0.1, 0.1])
        XCTAssertFalse(try render(outlined).cached, "a new outline fills again")
    }

    // MARK: - Stored patch

    func testObjectMaskBitsRoundTrip() throws {
        var cells = [Bool](repeating: false, count: 13 * 7)
        for i in stride(from: 0, to: cells.count, by: 3) { cells[i] = true }
        let mask = try XCTUnwrap(RemoveObjectMask(cells: cells, width: 13, height: 7, origin: [0, 0], size: [0.1, 0.1]))
        XCTAssertEqual(mask.bits.count, (13 * 7 + 7) / 8)
        for y in 0..<7 { for x in 0..<13 { XCTAssertEqual(mask.contains(x: x, y: y), cells[y * 13 + x]) } }
        XCTAssertEqual(mask.cellBytes.filter { $0 == 255 }.count, cells.filter { $0 }.count)
        XCTAssertNil(RemoveObjectMask(cells: cells, width: 12, height: 7, origin: [0, 0], size: [0.1, 0.1]))
    }

    /// An edit with Remove patches saves and loads, outline and all; a
    /// patch with a broken outline loads as a brush; heal patches encode
    /// as they always did, with no new keys.
    func testEditStackRoundTrip() throws {
        var p = EditParameters()
        var removal = Self.removal()
        removal.objectMask = RemoveObjectMask(cells: (0..<64).map { $0 % 5 != 0 }, width: 8, height: 8,
                                              origin: [-0.05, -0.05], size: [0.1, 0.1])
        var stroke = HealPatch(target: [0.3, 0.3], source: [0.3, 0.3], radius: 0.02, mode: .remove,
                               stroke: [.zero, [0.05, 0.01]])
        stroke.id = UUID()
        p.heals = [removal, stroke, HealPatch(target: [0.7, 0.7], source: [0.8, 0.7], radius: 0.02)]
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"remove\""))
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.heals, p.heals)
        XCTAssertEqual(try EditStack(parameters: back).encodeJSON(), json)

        let heal = HealPatch(target: [0.7, 0.7], source: [0.8, 0.7], radius: 0.02)
        let healJSON = String(decoding: try JSONEncoder().encode(heal), as: UTF8.self)
        XCTAssertFalse(healJSON.contains("objectMask"))

        var broken = removal
        broken.objectMask?.width = 9
        XCTAssertNil(broken.sanitized?.objectMask)
        XCTAssertEqual(broken.sanitized?.mode, .remove)
    }

    func testContextMarginFollowsTheSensor() {
        let s = CGSize(width: 6000, height: 4000)
        let small = HealPatch(target: [0.5, 0.5], source: [0.5, 0.5], radius: 0.002, mode: .remove)
        XCTAssertEqual(small.removeContextMarginPixels(sensorSize: s), 120, accuracy: 0.5)
        let big = HealPatch(target: [0.5, 0.5], source: [0.5, 0.5], radius: 0.2, mode: .remove)
        XCTAssertEqual(big.removeContextMarginPixels(sensorSize: s), 320, accuracy: 0.5)
        XCTAssertFalse(big.removeFitsLimit(sensorSize: s))
        XCTAssertTrue(small.removeFitsLimit(sensorSize: s))
    }
}
