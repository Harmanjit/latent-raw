import XCTest
import Metal
import simd
@testable import PixelEngine

/// Brush-stroke spot removal: the stored form, the geometry that places a
/// stroke and its source, and the heal kernels run piece by piece on a
/// synthetic wire across a sky (the helpers are HealQualityTests').
final class HealStrokeTests: XCTestCase {
    typealias Q = HealQualityTests

    // MARK: - Stored form

    func testCirclesEncodeAsBeforeAndStrokesRoundTrip() throws {
        let circle = HealPatch(id: GoldenIDs.uuid(1), target: [0.2, 0.3], source: [0.4, 0.5], radius: 0.02)
        let circleJSON = String(decoding: try JSONEncoder().encode(circle), as: UTF8.self)
        XCTAssertFalse(circleJSON.contains("stroke"), "a circle's JSON has no stroke key: \(circleJSON)")
        // A patch stored before strokes existed still decodes, as a circle.
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","target":[0.2,0.3],"source":[0.4,0.5],"radius":0.02,"feather":0.35,"mode":"heal"}"#
        XCTAssertEqual(try JSONDecoder().decode(HealPatch.self, from: Data(old.utf8)), circle)

        var p = EditParameters()
        p.heals = [circle, HealPatch(target: [0.5, 0.5], source: [0.5, 0.6], radius: 0.01, mode: .clone,
                                     stroke: [[0, 0], [0.1, 0.02], [0.2, -0.01]])]
        let json = try EditStack(parameters: p).encodeJSON()
        let back = try EditStack.decode(json: json).parameters().heals
        XCTAssertEqual(back, p.heals)
        XCTAssertTrue(back[1].isStroke)
        XCTAssertEqual(back[1].pathPoints(atSource: true).last!, SIMD2(0.7, 0.59), accuracy: 1e-6)
    }

    /// A sidecar edited by hand, or written by something else, can't give
    /// the render coordinates that overflow its pixel arithmetic or a
    /// stroke long enough to take minutes; what the app writes loads as is.
    func testGeometryFromASidecarIsSanitized() throws {
        let fine = HealPatch(target: [0.5, 0.5], source: [0.5, 0.6], radius: 0.01, stroke: [[0, 0], [0.1, 0.02]])
        let far = HealPatch(target: [0.2, 0.2], source: [0.3, 0.3], radius: 0.01, stroke: [[0, 0], [0.1, 0], [1e16, 0]])
        let long = HealPatch(target: [0.1, 0.1], source: [0.1, 0.2], radius: 0.01,
                             stroke: (0..<100_000).map { SIMD2(Float($0) * 8e-6, 0) })
        let huge = HealPatch(target: [1e20, -1e20], source: [0.5, 0.5], radius: 1e16, feather: -3)
        var p = EditParameters()
        p.heals = [fine, far, long, huge]
        p.redEyes = [RedEyeSpot(centre: [0.4, 0.4]), RedEyeSpot(centre: [0.5, 9], radius: 1e16, strength: 7)]
        let back = try EditStack.decode(json: EditStack(parameters: p).encodeJSON()).parameters()

        XCTAssertEqual(back.heals[0], fine)
        XCTAssertEqual(back.heals[1].stroke?[1], far.stroke?[1], "points in range keep their offsets")
        XCTAssertEqual(back.heals[1].pathPoints().last!, SIMD2(2, 0.2), accuracy: 1e-6)
        XCTAssertEqual(back.heals[2].stroke?.count, HealPatch.maximumStrokePoints)
        XCTAssertEqual(back.heals[2].stroke?.last, long.stroke?.last)
        XCTAssertEqual(back.heals[3].target, SIMD2(2, -1))
        XCTAssertEqual(back.heals[3].radius, 0.5)
        XCTAssertEqual(back.heals[3].feather, 0)
        XCTAssertEqual(back.redEyes[0], p.redEyes[0])
        XCTAssertEqual(back.redEyes[1].centre, SIMD2(0.5, 2))
        XCTAssertEqual(back.redEyes[1].radius, 0.5)
        XCTAssertEqual(back.redEyes[1].strength, 1)

        // The render places what loads, and clamps before it converts to
        // whole pixels even when something unchecked gets there.
        let size = SIMD2<Float>(6000, 4000)
        for patch in back.heals {
            _ = HealStage.placements(patch, width: 1500, height: 1000, sensorSize: size, tileOrigin: .zero, binSpan: 4)
        }
        XCTAssertNil(HealStage.place(huge, width: 1500, height: 1000, sensorSize: size, tileOrigin: .zero, binSpan: 4))
        let spot = try XCTUnwrap(RedEyeStage.place(RedEyeSpot(centre: [0.5, 0.5], radius: 1e16), width: 1500, height: 1000,
                                                   sensorSize: size, tileOrigin: .zero, binSpan: 4))
        XCTAssertEqual(spot.boxSize, SIMD2(1500, 1000))
    }

    // MARK: - Geometry

    func testSimplifiedStrokeKeepsCornersAndRespectsTheLimit() {
        let s = CGSize(width: 6000, height: 4000)
        // A straight line painted as 200 dabs is two points.
        let line = (0...199).map { SIMD2<Float>(0.1 + 0.004 * Float($0), 0.5) }
        XCTAssertEqual(HealPatch.simplifiedStroke(line, radius: 0.002, sensorSize: s).count, 2)
        // An L keeps its corner.
        let ell = (0...50).map { SIMD2<Float>(0.2, 0.2 + 0.004 * Float($0)) }
            + (1...50).map { SIMD2<Float>(0.2 + 0.004 * Float($0), 0.4) }
        let simplified = HealPatch.simplifiedStroke(ell, radius: 0.002, sensorSize: s)
        XCTAssertEqual(simplified.count, 3)
        XCTAssertEqual(simplified[1], SIMD2(0.2, 0.4))
        // A scribble beyond the limit is simplified harder to fit.
        let scribble = (0..<2000).map { i -> SIMD2<Float> in
            let sign: Float = i % 2 == 0 ? 1 : -1
            let x: Float = 0.1 + 0.0004 * Float(i)
            let y: Float = 0.5 + sign * 0.01 * Float(1 + i % 7)
            return SIMD2(x, y)
        }
        let fitted = HealPatch.simplifiedStroke(scribble, radius: 0.001, sensorSize: s)
        XCTAssertLessThanOrEqual(fitted.count, HealPatch.maximumStrokePoints)
        XCTAssertEqual(fitted.first, scribble.first)
        XCTAssertEqual(fitted.last, scribble.last)
    }

    func testAutomaticSourceGoesAcrossTheStrokeAndStaysOnTheSensor() throws {
        let s = CGSize(width: 6000, height: 4000)
        let radius: Float = 10.0 / 4000
        // A horizontal wire: the source moves vertically, past the width.
        let wire: [SIMD2<Float>] = [[0.2, 0.5], [0.8, 0.5]]
        let offset = HealPatch.automaticStrokeOffset(wire, radius: radius, sensorSize: s) * SIMD2(6000, 4000)
        XCTAssertEqual(offset.x, 0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(abs(offset.y), 30 - 0.01)
        // Near the top edge it goes down, not off the sensor.
        let top = [SIMD2<Float>(0.2, 4 / 4000), SIMD2<Float>(0.8, 6 / 4000)]
        XCTAssertGreaterThan(HealPatch.automaticStrokeOffset(top, radius: radius, sensorSize: s).y, 0)
        // A vertical hair near the right edge: the source goes left.
        let hair = [SIMD2<Float>(5990 / 6000, 0.2), SIMD2<Float>(5992 / 6000, 0.6)]
        XCTAssertLessThan(HealPatch.automaticStrokeOffset(hair, radius: radius, sensorSize: s).x, 0)

        // The stored patch: path relative to the target, source beside it,
        // bounds around the whole path.
        let patch = try XCTUnwrap(HealPatch.stroke(path: wire, radius: radius, feather: 0.2, mode: .heal, sensorSize: s))
        XCTAssertEqual(patch.target, wire[0])
        XCTAssertEqual(patch.stroke?.first, .zero)
        let bounds = patch.targetBounds(sensorSize: s)
        XCTAssertEqual(bounds.minX, 1200 - 10, accuracy: 0.1)
        XCTAssertEqual(bounds.maxX, 4800 + 10, accuracy: 0.1)
        XCTAssertEqual(bounds.height, 20, accuracy: 0.1)
        XCTAssertFalse(patch.sourceBounds(sensorSize: s).intersects(bounds), "the source clears the stroke")
        XCTAssertEqual(patch.distancePixels(from: SIMD2(0.5, 0.5 + 5 / 4000), sensorSize: s), 5, accuracy: 0.01)
    }

    func testStrokeIsCutIntoShortPieces() {
        let pieces = HealPatch.strokeSegments([[0, 0], [100, 0], [100, 30]], radius: 10)
        XCTAssertEqual(pieces.count, 5 + 2)
        XCTAssertTrue(pieces.allSatisfy { simd_length($0.1 - $0.0) <= 20 + 1e-4 })
        XCTAssertEqual(pieces.last!.1, SIMD2(100, 30))
        // However long, a bounded number of pieces.
        XCTAssertLessThanOrEqual(HealPatch.strokeSegments([[0, 0], [100_000, 0]], radius: 1).count, 512)
    }

    /// A wire across the frame widens a tile only by its pieces near the
    /// view: a view inside the stroke's bounding box but away from the
    /// stroke needs nothing more, and one on it a few radii, not the box.
    func testRegionTakesOnlyTheStrokePiecesNearIt() throws {
        let s = CGSize(width: 6000, height: 4000)
        let wire = try XCTUnwrap(HealPatch.stroke(path: [[0.1, 0.1], [0.9, 0.9]], radius: 0.004, feather: 0.35,
                                                  mode: .heal, sensorSize: s))
        let box = wire.targetBounds(sensorSize: s)
        let away = CGRect(x: 4050, y: 300, width: 1500, height: 1000)
        XCTAssertTrue(box.intersects(away))
        XCTAssertEqual(HealPatch.regionIncludingSources(away, patches: [wire], sensorSize: s), away)
        XCTAssertTrue(HealPatch.isSelfContained(away, patches: [wire], sensorSize: s))

        let on = CGRect(x: 2600, y: 1700, width: 400, height: 300)   // the wire crosses (2800, 1867)
        let grown = HealPatch.regionIncludingSources(on, patches: [wire], sensorSize: s)
        XCTAssertTrue(grown.contains(on))
        XCTAssertGreaterThan(grown.width, on.width, "the pieces in view read their surroundings and source")
        XCTAssertLessThan(grown.width, 2 * on.width, "not the stroke's box, \(box.width) wide")
        XCTAssertLessThan(grown.height, 2 * on.height)
        XCTAssertFalse(HealPatch.isSelfContained(on, patches: [wire], sensorSize: s))
    }

    // MARK: - Rendering

    static let width = Q.width, height = Q.height
    static let wirePath: [SIMD2<Float>] = [[30, 70], [120, 100], [210, 112], [300, 96], [360, 80]]

    /// Sky with grain, brightening downwards, crossed by a thin dark wire.
    static func sky(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let level = 0.25 + 1.2 * pow(Double(y) / Double(height - 1), 2)
        return SIMD3(0.14, 0.3, 0.72) * level * (1 + 0.04 * Q.noise(x, y, cell: 2, seed: 9))
    }

    static func wireDistance(_ x: Int, _ y: Int, path: [SIMD2<Float>] = wirePath) -> Float {
        let q = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
        return (1..<path.count).map { HealPatch.segmentDistance(q, path[$0 - 1], path[$0]) }.min()!
    }

    static func wired(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        let w = 1 - Q.smoothstep(1, 2.5, Double(wireDistance(x, y)))
        return sky(x, y) * (1 - 0.85 * w)
    }

    static func wireStroke(radius: Float = 7, mode: HealPatch.Mode = .heal) -> HealPatch {
        let size = SIMD2<Float>(Float(width), Float(height))
        return HealPatch.stroke(path: wirePath.map { $0 / size }, radius: radius / Float(min(width, height)),
                                feather: 0.35, mode: mode,
                                sensorSize: CGSize(width: width, height: height))!
    }

    /// RMS and worst 7 x 7 tone error (encoded 0...255) inside the stroke.
    static func score(_ result: (Int, Int) -> SIMD3<Double>, radius: Float) -> (rms: Double, tone: Double) {
        func encoded(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(Q.encode(c.x), Q.encode(c.y), Q.encode(c.z)) }
        var sum = 0.0, n = 0.0, tone = 0.0
        for y in 0..<height {
            for x in 0..<width where wireDistance(x, y) < radius && x > 36 && x < width - 20 {
                sum += simd_length_squared(encoded(result(x, y)) - encoded(sky(x, y))) / 3
                n += 1
                if x % 3 == 0 {
                    var local = SIMD3<Double>()
                    for oy in -3...3 { for ox in -3...3 {
                        local += encoded(result(x + ox, y + oy)) - encoded(sky(x + ox, y + oy))
                    } }
                    tone = max(tone, simd_reduce_max(simd_abs(local / 49)))
                }
            }
        }
        return ((sum / n).squareRoot(), tone)
    }

    /// The whole wire healed along its length: close to the clean sky, with
    /// no blotch where one piece hands over to the next.
    func testStrokeHealsAWireAlongItsLength() throws {
        let gpu = try GPUContext()
        let size = SIMD2<Float>(Float(Self.width), Float(Self.height))
        let input = try Q.texture(width: Self.width, height: Self.height, gpu: gpu) { Self.wired($0, $1) }
        let patch = Self.wireStroke()
        let placements = HealStage.placements(patch, width: Self.width, height: Self.height, sensorSize: size,
                                              tileOrigin: .zero, binSpan: 1)
        XCTAssertGreaterThan(placements.count, 10, "healed in pieces")
        let out = try Q.healed(input, patches: [patch], sensorSize: size, gpu: gpu)
        let healed = Self.score(out, radius: 7)
        let untouched = Self.score({ Self.wired($0, $1) }, radius: 7)
        print("heal stroke: wire rms \(untouched.rms) tone \(untouched.tone); healed rms \(healed.rms) tone \(healed.tone)")
        XCTAssertLessThan(healed.rms, untouched.rms / 4)
        XCTAssertLessThan(healed.tone, 3, "no tone blotch along the stroke")
        // Far from the stroke nothing changes.
        XCTAssertEqual(simd_reduce_max(simd_abs(out(200, 220) - Self.wired(200, 220))), 0, accuracy: 1e-3)
    }

    /// Clone pieces tile the stroke exactly: every pixel inside is the
    /// source's, none is written twice (which a feather would show as a
    /// darker joint), and outside is untouched.
    func testStrokePiecesCoverTheStrokeOnce() throws {
        let gpu = try GPUContext()
        let w = 200, h = 100
        let size = SIMD2<Float>(Float(w), Float(h))
        // Green above y = 50, red below; the stroke runs in the green and
        // copies from the red.
        let input = try Q.texture(width: w, height: h, gpu: gpu) { _, y in y < 50 ? SIMD3(0.1, 0.6, 0.1) : SIMD3(0.6, 0.1, 0.1) }
        let path: [SIMD2<Float>] = [[20, 25], [90, 30], [150, 18], [185, 26]]
        let radius: Float = 6
        let patch = HealPatch(target: path[0] / size, source: (path[0] + SIMD2(0, 50)) / size,
                              radius: radius / 100, feather: 0.5, mode: .clone,
                              stroke: path.map { ($0 - path[0]) / size })
        let out = try Q.healed(input, patches: [patch], sensorSize: size, gpu: gpu)
        var worstInside = 0.0, worstOutside = 0.0
        for y in 0..<50 {
            for x in 0..<w {
                let d = Self.wireDistance(x, y, path: path)
                // Feather 0.5: full inside half the radius, fading to none at it.
                let expected = 1 - Q.smoothstep(Double(radius) * 0.5, Double(radius), Double(d))
                let red = (out(x, y).x - 0.1) / 0.5
                if d < radius { worstInside = max(worstInside, abs(red - expected)) }
                else { worstOutside = max(worstOutside, abs(red)) }
            }
        }
        XCTAssertLessThan(worstInside, 0.02, "each stroke pixel blended once, by its distance to the whole path")
        XCTAssertLessThan(worstOutside, 1e-3)
    }

    /// A tile grown by `regionIncludingSources` heals a stroke exactly as
    /// the whole frame does, and a 2 x 2 binned render predicts it.
    func testStrokeTileAndBinnedRendersMatchFullResolution() throws {
        let gpu = try GPUContext()
        let w = Self.width, h = Self.height
        let size = SIMD2<Float>(Float(w), Float(h)), sensor = CGSize(width: w, height: h)
        let patch = Self.wireStroke()
        let full = try Q.healed(try Q.texture(width: w, height: h, gpu: gpu) { Self.wired($0, $1) },
                                patches: [patch], sensorSize: size, gpu: gpu)

        let visible = CGRect(x: 180, y: 90, width: 60, height: 40)
        let grown = HealPatch.regionIncludingSources(visible, patches: [patch], sensorSize: sensor)
            .intersection(CGRect(origin: .zero, size: sensor))
        let tx = Int(grown.minX.rounded(.down)), ty = Int(grown.minY.rounded(.down))
        let tw = Int(grown.maxX.rounded(.up)) - tx, th = Int(grown.maxY.rounded(.up)) - ty
        XCTAssertLessThan(grown.width, patch.targetBounds(sensorSize: sensor).width / 2,
                          "the pieces near the view, not the whole wire")
        let tile = try Q.healed(try Q.texture(width: tw, height: th, gpu: gpu) { Self.wired($0 + tx, $1 + ty) },
                                patches: [patch], sensorSize: size, tileOrigin: SIMD2(Float(tx), Float(ty)), gpu: gpu)
        var worst = 0.0
        for y in Int(visible.minY)..<Int(visible.maxY) {
            for x in Int(visible.minX)..<Int(visible.maxX) {
                worst = max(worst, simd_reduce_max(simd_abs(tile(x - tx, y - ty) - full(x, y))))
            }
        }
        XCTAssertLessThan(worst, 1e-3, "tile agrees with the whole frame")

        let binned = try Q.healed(try Q.texture(width: w / 2, height: h / 2, gpu: gpu) { x, y in
            (Self.wired(2 * x, 2 * y) + Self.wired(2 * x + 1, 2 * y) + Self.wired(2 * x, 2 * y + 1) + Self.wired(2 * x + 1, 2 * y + 1)) / 4
        }, patches: [patch], sensorSize: size, binSpan: 2, gpu: gpu)
        var sum = 0.0, n = 0.0
        for y in 0..<(h / 2) {
            for x in 20..<(w / 2 - 10) where Self.wireDistance(2 * x, 2 * y) < 5 {
                let down = (full(2 * x, 2 * y) + full(2 * x + 1, 2 * y) + full(2 * x, 2 * y + 1) + full(2 * x + 1, 2 * y + 1)) / 4
                let b = binned(x, y)
                sum += simd_reduce_max(SIMD3(abs(Q.encode(b.x) - Q.encode(down.x)), abs(Q.encode(b.y) - Q.encode(down.y)),
                                             abs(Q.encode(b.z) - Q.encode(down.z))))
                n += 1
            }
        }
        print("heal stroke binned vs full: mean worst-channel difference \(sum / n)")
        XCTAssertLessThan(sum / n, 3, "binned stroke predicts the full-resolution one")
    }

    /// A stroke whose source runs along the stroke itself: every piece
    /// reads the image as it was before the stroke, so a tile holding only
    /// the pieces near the view still heals it exactly. (Were pieces to
    /// read earlier pieces' results, each would need the one before it,
    /// back to the start of the stroke.)
    func testStrokeTileMatchesWhenTheSourceRunsAlongTheStroke() throws {
        let gpu = try GPUContext()
        let w = Self.width, h = Self.height
        let size = SIMD2<Float>(Float(w), Float(h)), sensor = CGSize(width: w, height: h)
        let start = SIMD2<Float>(40, 150)
        for mode in HealPatch.Mode.allCases {
            let patch = HealPatch(target: start / size, source: (start - SIMD2(24, 0)) / size, radius: 6 / Float(h),
                                  mode: mode, stroke: [.zero, SIMD2(300, 0) / size])
            let full = try Q.healed(try Q.texture(width: w, height: h, gpu: gpu) { Self.wired($0, $1) },
                                    patches: [patch], sensorSize: size, gpu: gpu)
            let visible = CGRect(x: 200, y: 135, width: 40, height: 30)
            let grown = HealPatch.regionIncludingSources(visible, patches: [patch], sensorSize: sensor)
                .intersection(CGRect(origin: .zero, size: sensor))
            let tx = Int(grown.minX.rounded(.down)), ty = Int(grown.minY.rounded(.down))
            let tw = Int(grown.maxX.rounded(.up)) - tx, th = Int(grown.maxY.rounded(.up)) - ty
            XCTAssertLessThan(tw, 200, "\(mode): only the pieces near the view")
            let tile = try Q.healed(try Q.texture(width: tw, height: th, gpu: gpu) { Self.wired($0 + tx, $1 + ty) },
                                    patches: [patch], sensorSize: size, tileOrigin: SIMD2(Float(tx), Float(ty)), gpu: gpu)
            var worst = 0.0
            for y in Int(visible.minY)..<Int(visible.maxY) {
                for x in Int(visible.minX)..<Int(visible.maxX) {
                    worst = max(worst, simd_reduce_max(simd_abs(tile(x - tx, y - ty) - full(x, y))))
                }
            }
            XCTAssertLessThan(worst, 1e-3, "\(mode): tile agrees with the whole frame")
        }
    }
}

/// Fixed ids for tests that compare encoded patches.
enum GoldenIDs {
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
}

private func XCTAssertEqual(_ a: SIMD2<Float>, _ b: SIMD2<Float>, accuracy: Float,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(a - b)), accuracy, "\(a) != \(b)", file: file, line: line)
}
