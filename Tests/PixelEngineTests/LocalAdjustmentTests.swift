import XCTest
@testable import PixelEngine
@testable import RawCore

final class LocalAdjustmentTests: XCTestCase {
    func testBrushRasterizerDabAndIncrementalUpdate() throws {
        let r = try XCTUnwrap(BrushMaskRasterizer(sensorWidth: 800, sensorHeight: 600))
        XCTAssertEqual(r.width, 200); XCTAssertEqual(r.height, 150)

        var stroke = BrushStroke(points: [SIMD2(0.5, 0.5)], radius: 0.2, feather: 0.5, flow: 1, erase: false)
        XCTAssertTrue(r.update(strokes: [stroke]))
        XCTAssertEqual(r.value(atNormalized: SIMD2(0.5, 0.5)), 1, accuracy: 0.02, "dab centre is solid")
        XCTAssertEqual(r.value(atNormalized: SIMD2(0.05, 0.05)), 0, accuracy: 0.02, "far away is empty")
        let mid = r.value(atNormalized: SIMD2(0.5 + 0.2 * 0.75 * 150 / 200, 0.5))   // inside the feather
        XCTAssertTrue(mid > 0.05 && mid < 0.95, "feather is a ramp, got \(mid)")

        // Extending the stroke draws only the new dab; nothing changes on repeat.
        stroke.points.append(SIMD2(0.2, 0.5))
        XCTAssertTrue(r.update(strokes: [stroke]))
        XCTAssertFalse(r.update(strokes: [stroke]), "nothing new to draw")
        XCTAssertEqual(r.value(atNormalized: SIMD2(0.2, 0.5)), 1, accuracy: 0.02)

        // Erasing removes.
        let eraser = BrushStroke(points: [SIMD2(0.5, 0.5)], radius: 0.05, feather: 0, flow: 1, erase: true)
        XCTAssertTrue(r.update(strokes: [stroke, eraser]))
        XCTAssertEqual(r.value(atNormalized: SIMD2(0.5, 0.5)), 0, accuracy: 0.02)
        XCTAssertEqual(r.value(atNormalized: SIMD2(0.2, 0.5)), 1, accuracy: 0.02, "the other dab survives")
    }

    func testEditStackRoundTripsLocals() throws {
        var p = EditParameters()
        p.locals = [
            LocalAdjustment(name: "Sky", shape: .linear(start: SIMD2(0.5, 0.1), end: SIMD2(0.5, 0.5)),
                            exposureEV: -0.7, luminanceRange: LuminanceRange(low: 0.5, high: 1, feather: 0.1)),
            LocalAdjustment(name: "Face", shape: .radial(centre: SIMD2(0.4, 0.4), radii: SIMD2(0.1, 0.15), feather: 0.6),
                            exposureEV: 0.5, saturation: 0.2),
            LocalAdjustment(name: "Paint", shape: .brush(strokes: [
                BrushStroke(points: [SIMD2(0.1, 0.1), SIMD2(0.2, 0.2)], radius: 0.05, feather: 0.5, flow: 0.8, erase: false)]),
                            warmth: 0.3, hueRange: HueRange(centre: 120, width: 40, minimumSaturation: 0.2)),
        ]
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"locals\""))
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.locals, p.locals)
        XCTAssertFalse(EditStack.isDefault(p, relativeTo: EditParameters()))
    }

    func testMasksBrightenOnlyWhereTheyShould() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        /// Mean scene-linear luminance of a patch around a normalized point.
        func patch(_ p: EditParameters, at n: SIMD2<Float>) throws -> Double {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .sceneLinear)
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            let w = tex.width, h = tex.height
            let cx = Int(n.x * Float(w)), cy = Int(n.y * Float(h))
            var s = 0.0
            for dy in -2...2 { for dx in -2...2 {
                let i = ((cy + dy) * w + (cx + dx)) * 4
                s += 0.2627 * Double(px[i]) + 0.678 * Double(px[i + 1]) + 0.0593 * Double(px[i + 2])
            } }
            return s / 25
        }
        let base = EditParameters()
        let left = SIMD2<Float>(0.15, 0.5), right = SIMD2<Float>(0.85, 0.5), centre = SIMD2<Float>(0.5, 0.5)
        let b = (l: try patch(base, at: left), r: try patch(base, at: right), c: try patch(base, at: centre))

        // Radial +2 EV in the centre: centre x4, edges untouched.
        var radial = base
        radial.locals = [LocalAdjustment(name: "r", shape: .radial(centre: centre, radii: SIMD2(0.25, 0.25), feather: 0.3),
                                         exposureEV: 2)]
        XCTAssertEqual(try patch(radial, at: centre), b.c * 4, accuracy: b.c * 0.2)
        XCTAssertEqual(try patch(radial, at: left), b.l, accuracy: b.l * 0.02)

        // Linear gradient from the left edge to the middle, +1 EV. The
        // left patch sits 30% of the way along the ramp, so the mask there
        // is 1 - smoothstep(0.3) = 0.784 and the gain 2^0.784, not 2.
        var linear = base
        linear.locals = [LocalAdjustment(name: "g", shape: .linear(start: SIMD2(0, 0.5), end: SIMD2(0.5, 0.5)),
                                         exposureEV: 1)]
        let t = 0.3, mask = 1 - (3 * t * t - 2 * t * t * t)
        XCTAssertEqual(try patch(linear, at: left), b.l * pow(2, mask), accuracy: b.l * 0.05)
        XCTAssertEqual(try patch(linear, at: right), b.r, accuracy: b.r * 0.02)

        // Inverted radial: the reverse.
        var inverted = radial
        inverted.locals[0].invert = true
        XCTAssertEqual(try patch(inverted, at: centre), b.c, accuracy: b.c * 0.05)
        XCTAssertEqual(try patch(inverted, at: left), b.l * 4, accuracy: b.l * 0.2)

        // A whole-image local limited to the darkest tones can't touch a
        // bright patch. (The sample's centre is a dark house; the sky at
        // the top is bright.)
        var shadows = base
        shadows.locals = [LocalAdjustment(name: "s", shape: .whole, exposureEV: 1,
                                          luminanceRange: LuminanceRange(low: 0, high: 0.25, feather: 0.05))]
        let sky = SIMD2<Float>(0.5, 0.1)
        let bSky = try patch(base, at: sky)
        XCTAssertEqual(try patch(shadows, at: sky), bSky, accuracy: bSky * 0.03, "bright sky is outside the range")

        // A neutral local (all sliders zero) is bit-identical to none.
        var neutral = base
        neutral.locals = [LocalAdjustment(name: "n", shape: .whole)]
        XCTAssertEqual(try patch(neutral, at: centre), b.c, accuracy: 1e-9)
    }
}
