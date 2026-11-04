import XCTest
@testable import PixelEngine
@testable import RawCore

/// The tone curve, Point Colour and grain inside a mask, and the brush's
/// Auto Mask (LocalToneColour.swift, BrushAutoMask.swift): the model, the
/// stored form, the rasterizer and the renders.
final class MaskToneColourTests: XCTestCase {
    // MARK: - Model and stored form

    func testUnusedAdditionsAreNotWritten() throws {
        var local = LocalAdjustment(name: "r", shape: .whole, exposureEV: 0.5)
        local.curve = .identity
        local.channelCurves = .identity
        local.grain = Grain(amount: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(local), as: UTF8.self)
        for key in ["curve", "channelCurves", "pointColours", "grain"] {
            XCTAssertFalse(json.contains("\"\(key)\""), "a neutral \(key) is not written")
        }
        XCTAssertFalse(local.wantsToneColourStage)
        XCTAssertFalse(local.wantsDetailStage)

        let stroke = BrushStroke(points: [SIMD2(0.5, 0.5)], radius: 0.1, feather: 0.5, flow: 1, erase: false)
        let strokeJSON = String(decoding: try encoder.encode(stroke), as: UTF8.self)
        XCTAssertFalse(strokeJSON.contains("autoMask"), "a stroke without Auto Mask stores what it always did")
    }

    func testAdditionsRoundTripAndWantTheStage() throws {
        var local = LocalAdjustment(name: "r", shape: .whole)
        local.curve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.65), SIMD2(1, 1)])
        local.channelCurves = RGBCurves(blue: ToneCurve(points: [SIMD2(0, 0.1), SIMD2(1, 1)]))
        local.pointColours = [PointColour(hue: 200, saturation: 0.5, value: 0.6, saturationShift: -0.5)]
        local.grain = Grain(amount: 0.4, size: 0.3, roughness: 0.6)
        let read = try JSONDecoder().decode(LocalAdjustment.self, from: try JSONEncoder().encode(local))
        XCTAssertEqual(read, local)
        XCTAssertTrue(local.wantsToneColourStage)
        XCTAssertTrue(local.wantsDetailStage)
        XCTAssertEqual(local.toneColourFlags, 15)
        XCTAssertFalse(LocalDetailStage.needsBlurs([local]), "the curve, colour and grain read no blur")

        var p = EditParameters()
        p.locals = [LocalAdjustment(name: "a", shape: .whole, exposureEV: 1), local]
        let params = LocalDetailStage.params(for: p.locals, shortSide: 4000)
        XCTAssertEqual(params.count, 1)
        XCTAssertEqual(params[0].detail.w, 15)
        XCTAssertEqual(params[0].grain.w, 1, "one swatch")
        let slots = LocalsGPUPlan(locals: p.locals, slices: [:]).detailSlots
        let table = try XCTUnwrap(LocalToneColour.curveTable(for: p.locals, slots: slots))
        XCTAssertEqual(table.count, LocalToneColour.tableStride)
        XCTAssertGreaterThan(table[128], 0.6, "the master curve lifts the middle")
        XCTAssertEqual(table[3 * 256], 0.1, accuracy: 1e-4, "the blue curve's black point")

        let auto = BrushStroke(points: [SIMD2(0.5, 0.5)], radius: 0.1, feather: 0.5, flow: 1, erase: false, autoMask: true)
        XCTAssertEqual(try JSONDecoder().decode(BrushStroke.self, from: try JSONEncoder().encode(auto)), auto)
        XCTAssertTrue(LocalAdjustment(name: "b", shape: .brush(strokes: [auto])).usesAutoMask)
    }

    // MARK: - Auto Mask

    /// A guide dark on the left half, bright on the right.
    private func splitGuide(width: Int, height: Int) -> BrushGuide {
        var data = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let v: Float = x < width / 2 ? 0.02 : 0.5
                let (l, cr, cb) = BrushGuide.encode(r: v, g: v, b: v)
                let o = (y * width + x) * 3
                data[o] = l; data[o + 1] = cr; data[o + 2] = cb
            }
        }
        return BrushGuide(width: width, height: height, data: data)
    }

    func testAutoMaskStopsAtAnEdge() throws {
        let plain = try XCTUnwrap(BrushMaskRasterizer(sensorWidth: 400, sensorHeight: 400))
        let auto = try XCTUnwrap(BrushMaskRasterizer(sensorWidth: 400, sensorHeight: 400))
        let guide = splitGuide(width: plain.width, height: plain.height)
        let points = [SIMD2<Float>(0.44, 0.5), SIMD2(0.44, 0.52), SIMD2(0.44, 0.48)]
        let stroke = BrushStroke(points: points, radius: 0.15, feather: 0.3, flow: 1, erase: false)
        var autoStroke = stroke
        autoStroke.autoMask = true
        XCTAssertTrue(plain.update(strokes: [stroke], guide: guide))
        XCTAssertTrue(auto.update(strokes: [autoStroke], guide: guide))
        let inside = SIMD2<Float>(0.4, 0.5), across = SIMD2<Float>(0.54, 0.5)
        XCTAssertGreaterThan(plain.value(atNormalized: across), 0.5, "a plain stroke crosses the edge")
        XCTAssertGreaterThan(auto.value(atNormalized: inside), 0.9, "Auto Mask paints the side it started on")
        XCTAssertLessThan(auto.value(atNormalized: across), 0.05, "and stops at the edge")

        // Erasing with Auto Mask leaves the other side alone.
        let both = try XCTUnwrap(BrushMaskRasterizer(sensorWidth: 400, sensorHeight: 400))
        let fill = BrushStroke(points: [SIMD2(0.5, 0.5)], radius: 0.4, feather: 0, flow: 1, erase: false)
        var erase = BrushStroke(points: [SIMD2(0.56, 0.5)], radius: 0.15, feather: 0, flow: 1, erase: true)
        erase.autoMask = true
        _ = both.update(strokes: [fill, erase], guide: guide)
        XCTAssertLessThan(both.value(atNormalized: SIMD2(0.6, 0.5)), 0.05)
        XCTAssertGreaterThan(both.value(atNormalized: SIMD2(0.46, 0.5)), 0.95)

        // Without a guide an Auto Mask stroke draws as a plain one, and
        // redraws when the guide arrives.
        let late = try XCTUnwrap(BrushMaskRasterizer(sensorWidth: 400, sensorHeight: 400))
        _ = late.update(strokes: [autoStroke], guide: nil)
        XCTAssertGreaterThan(late.value(atNormalized: across), 0.5)
        XCTAssertTrue(late.update(strokes: [autoStroke], guide: guide))
        XCTAssertLessThan(late.value(atNormalized: across), 0.05)
    }

    // MARK: - Renders

    private struct Fixture {
        let session: ImageSession
        let pipeline: RenderPipeline
        let gpu: GPUContext
    }

    private func fixture() throws -> Fixture {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: try TestAssets.d750Path()), gpu: gpu)
        return Fixture(session: session, pipeline: RenderPipeline(gpu: gpu), gpu: gpu)
    }

    private struct Image {
        let w: Int, h: Int, px: [Float]
        func pixel(at n: SIMD2<Float>) -> SIMD3<Float> {
            let i = (Int(n.y * Float(h)) * w + Int(n.x * Float(w))) * 4
            return SIMD3(px[i], px[i + 1], px[i + 2])
        }
        /// The largest channel difference from `other` over 13×13 pixels.
        func difference(_ other: Image, near n: SIMD2<Float>) -> Float {
            var d: Float = 0
            for dy in -6...6 { for dx in -6...6 {
                let i = ((Int(n.y * Float(h)) + dy) * w + Int(n.x * Float(w)) + dx) * 4
                for c in 0..<3 { d = max(d, abs(px[i + c] - other.px[i + c])) }
            } }
            return d
        }
    }

    private func render(_ f: Fixture, _ p: EditParameters) throws -> Image {
        let tex = try f.pipeline.render(f.session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
        return Image(w: tex.width, h: tex.height, px: try TextureReadback.float16Pixels(of: tex, gpu: f.gpu).map(Float.init))
    }

    private let centre = SIMD2<Float>(0.5, 0.5), left = SIMD2<Float>(0.12, 0.5)

    func testCurveColourAndGrainActInsideTheMaskOnly() throws {
        let f = try fixture()
        let base = try render(f, EditParameters())
        let edits: [(String, (inout LocalAdjustment) -> Void)] = [
            ("curve", { $0.curve = ToneCurve(points: [SIMD2(0, 0.2), SIMD2(0.5, 0.75), SIMD2(1, 1)]) }),
            ("RGB curves", { $0.channelCurves = RGBCurves(red: ToneCurve(points: [SIMD2(0, 0.3), SIMD2(1, 1)])) }),
            // A grey swatch with the widest range takes in almost everything.
            ("Point Colour", { $0.pointColours = [PointColour(hue: 0, saturation: 0, value: 0.5,
                                                               luminanceShift: 1, range: 1)] }),
            ("grain", { $0.grain = Grain(amount: 1, size: 0.5, roughness: 0.5) }),
        ]
        for (name, edit) in edits {
            var p = EditParameters()
            var local = LocalAdjustment(name: "r", shape: .radial(centre: centre, radii: SIMD2(0.25, 0.25), feather: 0.2))
            edit(&local)
            p.locals = [local]
            let r = try render(f, p)
            XCTAssertGreaterThan(r.difference(base, near: centre), 0.01, "\(name) changes the middle")
            XCTAssertEqual(r.pixel(at: left), base.pixel(at: left), "\(name) leaves the outside alone")
        }
        // Hidden, nothing moves at all.
        var hidden = EditParameters()
        var local = LocalAdjustment(name: "h", shape: .whole)
        local.curve = ToneCurve(points: [SIMD2(0, 0.3), SIMD2(1, 1)])
        local.hidden = true
        hidden.locals = [local]
        XCTAssertTrue(try render(f, hidden).px == base.px)
    }

    func testAutoMaskBuildsItsGuideAndRenders() throws {
        let f = try fixture()
        var p = EditParameters()
        let stroke = BrushStroke(points: [SIMD2(0.5, 0.5), SIMD2(0.52, 0.5)], radius: 0.1, feather: 0.5,
                                 flow: 1, erase: false, autoMask: true)
        p.locals = [LocalAdjustment(name: "b", shape: .brush(strokes: [stroke]), exposureEV: 2)]
        XCTAssertNil(f.session.brushGuide)
        let base = try render(f, EditParameters())
        let r = try render(f, p)
        let guide = try XCTUnwrap(f.session.brushGuide, "the first render with Auto Mask builds the guide")
        let summary = f.session.file.summary
        XCTAssertEqual(guide.width, summary.rawWidth / BrushMaskRasterizer.downscale)
        XCTAssertEqual(guide.height, summary.rawHeight / BrushMaskRasterizer.downscale)
        XCTAssertGreaterThan(r.difference(base, near: centre), 0.02, "the stroke's own centre is always painted")
        XCTAssertEqual(r.pixel(at: left), base.pixel(at: left))
    }
}
