import XCTest
@testable import PixelEngine
@testable import RawCore

/// Mask components, Mask Amount, Feather and Edge, the wider local slider
/// set and the overlay modes (MaskComponents.swift, MaskRefine.swift,
/// LocalDetailStage.swift): the model, the stored form and the renders.
final class MaskComponentTests: XCTestCase {
    // MARK: - Stored form

    /// An edit saved before components existed: the JSON the synthesized
    /// conformance wrote. It must read back with every new field at its
    /// default and write out exactly as it was read.
    func testAnOldLocalLoadsWithDefaultsAndSavesUnchanged() throws {
        let old = LocalAdjustment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Sky",
                                  shape: .radial(centre: SIMD2(0.5, 0.4), radii: SIMD2(0.2, 0.3), feather: 0.4),
                                  invert: true, exposureEV: -0.5, contrast: 0.1, saturation: 0.2, warmth: -0.3,
                                  luminanceRange: LuminanceRange(low: 0.5, high: 1, feather: 0.1))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(old), as: UTF8.self)
        for key in ["components", "amount", "hidden", "invertMask", "modelFeather", "clarity", "tint"] {
            XCTAssertFalse(json.contains("\"\(key)\""), "a default \(key) is not written")
        }
        // The exact keys the 0.9 conformance wrote.
        let legacy = #"{"contrast":0.1,"exposureEV":-0.5,"id":"00000000-0000-0000-0000-000000000001","invert":true,"luminanceRange":{"feather":0.1,"high":1,"low":0.5},"name":"Sky","saturation":0.2,"shape":{"radial":{"centre":[0.5,0.4],"feather":0.4,"radii":[0.2,0.3]}},"warmth":-0.3}"#
        let read = try JSONDecoder().decode(LocalAdjustment.self, from: Data(legacy.utf8))
        XCTAssertEqual(read, old)
        XCTAssertEqual(read.components, [])
        XCTAssertEqual(read.amount, 1)
        XCTAssertFalse(read.hidden)
        XCTAssertEqual(String(decoding: try encoder.encode(read), as: UTF8.self), legacy)
    }

    func testEditStackRoundTripsComponentsAndNewSliders() throws {
        var local = LocalAdjustment(name: "Subject", shape: .ai(kind: "subject", modelVersion: "m@1"), exposureEV: 0.3)
        local.components = [
            MaskComponent(mode: .subtract, source: .shape(.brush(strokes: [
                BrushStroke(points: [SIMD2(0.2, 0.2)], radius: 0.05, feather: 0.5, flow: 1, erase: false, density: 0.6)]))),
            MaskComponent(mode: .intersect, source: .colour(ColourRange(samples: [ColourSample(hue: 20, saturation: 0.5)], refine: 0.3))),
            MaskComponent(mode: .add, source: .luminance(LuminanceRange(low: 0.6, high: 1, feather: 0.1)), invert: true),
            MaskComponent(mode: .add, source: .shape(.prompted(points: [MaskPromptPoint(x: 0.1, y: 0.1, corner: 1),
                                                                         MaskPromptPoint(x: 0.4, y: 0.5, corner: 2)],
                                                                modelVersion: "sam@1")), feather: 0.3, edge: -0.4),
        ]
        local.amount = 0.7; local.invertMask = true; local.hidden = true
        local.modelFeather = 0.5; local.modelEdge = 0.25
        local.highlights = -0.4; local.shadows = 0.3; local.whites = 0.1; local.blacks = -0.2
        local.tint = 0.2; local.hue = 30
        local.texture = 0.3; local.clarity = 0.4; local.dehaze = 0.5; local.sharpness = -0.2
        local.noise = 0.6; local.defringe = 0.7
        var p = EditParameters()
        p.locals = [local]
        let json = try EditStack(parameters: p).encodeJSON()
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.locals, p.locals)
        // And once more: what this build wrote, this build reads.
        let again = try EditStack.decode(json: try EditStack(parameters: back).encodeJSON()).parameters()
        XCTAssertEqual(again.locals, p.locals)
    }

    // MARK: - Model

    func testCombineModes() {
        XCTAssertEqual(MaskCombineMode.add.combine(0.3, 0.8), 0.8)
        XCTAssertEqual(MaskCombineMode.add.combine(0.9, 0.2), 0.9)
        XCTAssertEqual(MaskCombineMode.subtract.combine(1, 0.25), 0.75)
        XCTAssertEqual(MaskCombineMode.intersect.combine(0.5, 0.5), 0.25)
    }

    func testColourRangeSelectsNearSamplesOnly() {
        let range = ColourRange(samples: [ColourSample(hue: 10, saturation: 0.7), ColourSample(hue: 200, saturation: 0.5)],
                                refine: 0.3)
        XCTAssertEqual(range.weight(hue: 10, saturation: 0.7), 1)
        XCTAssertEqual(range.weight(hue: 200, saturation: 0.5), 1, "the second sample counts too")
        XCTAssertEqual(range.weight(hue: 110, saturation: 0.7), 0, "green is far from both")
        XCTAssertEqual(ColourRange().weight(hue: 10, saturation: 0.7), 0, "no samples selects nothing")
        let tight = ColourRange(samples: range.samples, refine: 0)
        XCTAssertLessThan(tight.weight(hue: 18, saturation: 0.7), range.weight(hue: 18, saturation: 0.7),
                          "a lower refine is stricter")
    }

    func testColourSampleMatchesTheKernelsView() {
        // A strong red in working space reads as a red with high saturation.
        let red = ColourRange.sample(working: SIMD3(0.4, 0.05, 0.03), contrast: 1.5, greyPoint: 0.1845)
        XCTAssertTrue(red.hue < 20 || red.hue > 340, "hue \(red.hue)")
        XCTAssertGreaterThan(red.saturation, 0.5)
        let grey = ColourRange.sample(working: SIMD3(repeating: 0.18), contrast: 1.5, greyPoint: 0.1845)
        XCTAssertEqual(grey.saturation, 0, accuracy: 1e-5)
    }

    func testEmptyMasksAndDuplicates() {
        let brush = LocalAdjustment(name: "Brush", shape: .brush(strokes: []))
        XCTAssertTrue(brush.isEmptyMask)
        var painted = brush
        painted.shape = .brush(strokes: [BrushStroke(points: [SIMD2(0.5, 0.5)], radius: 0.1, feather: 0.5, flow: 1, erase: false)])
        XCTAssertFalse(painted.isEmptyMask)
        var withColour = brush
        withColour.components = [MaskComponent(mode: .add, source: .colour(ColourRange(samples: [ColourSample(hue: 0, saturation: 1)])))]
        XCTAssertFalse(withColour.isEmptyMask, "a colour range added in counts")
        XCTAssertFalse(LocalAdjustment(name: "Sky", shape: .ai(kind: "sky", modelVersion: "x")).isEmptyMask)
        var p = EditParameters()
        p.locals = [brush, painted, LocalAdjustment(name: "Sel", shape: .prompted(points: [], modelVersion: "s"))]
        XCTAssertEqual(p.emptyLocalIndices, [0, 2])

        var original = painted
        original.components = [MaskComponent(mode: .subtract, source: .shape(.whole))]
        let copy = original.duplicated()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNotEqual(copy.components[0].id, original.components[0].id)
        XCTAssertEqual(copy.components[0].source, original.components[0].source)
        XCTAssertEqual(copy.name, "Brush copy")
        let flipped = original.duplicatedAndInverted()
        XCTAssertTrue(flipped.invertMask, "with components the whole mask inverts")
        XCTAssertFalse(flipped.invert)
        XCTAssertTrue(painted.duplicatedAndInverted().invert, "a single shape flips its own invert")
    }

    func testElementsAndShapeEditing() {
        var local = LocalAdjustment(name: "L", shape: .whole)
        let brush = MaskComponent(mode: .add, source: .shape(.brush(strokes: [])))
        let lum = MaskComponent(mode: .intersect, source: .luminance(LuminanceRange()))
        local.components = [brush, lum]
        XCTAssertEqual(local.maskElements.map(\.id), [local.id, brush.id], "ranges own no pixels")
        XCTAssertTrue(local.setShape(.radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.1, 0.1), feather: 0.5), ofElement: brush.id))
        XCTAssertEqual(local.shape(ofElement: brush.id), .radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.1, 0.1), feather: 0.5))
        XCTAssertFalse(local.setShape(.whole, ofElement: lum.id), "a range has no shape to set")
        XCTAssertTrue(local.setShape(.brush(strokes: []), ofElement: local.id))
        XCTAssertEqual(local.shape, .brush(strokes: []))
    }

    func testDetailStageOnlyWhenNeeded() {
        var l = LocalAdjustment(name: "L", shape: .whole)
        XCTAssertFalse(l.wantsDetailStage)
        l.highlights = 0.5
        XCTAssertFalse(l.wantsDetailStage, "tone sliders run in the colour kernel")
        l.clarity = 0.5
        XCTAssertTrue(l.wantsDetailStage)
        l.hidden = true
        XCTAssertFalse(l.wantsDetailStage, "a hidden mask does nothing")
        l.hidden = false; l.amount = 0
        XCTAssertFalse(l.wantsDetailStage)
        var p = EditParameters()
        XCTAssertFalse(RenderPipeline.wantsLocalDetail(p))
        l.amount = 1
        p.locals = [LocalAdjustment(name: "a", shape: .whole), l]
        XCTAssertTrue(RenderPipeline.wantsLocalDetail(p))
        XCTAssertEqual(LocalDetailStage.params(for: p.locals).map(\.detail.z), [0], "slots count only masks that use the stage")
    }

    // MARK: - Feather and Edge

    /// A square in the middle of a 200×200 mask.
    private func square() -> MaskBitmap {
        var data = [UInt8](repeating: 0, count: 200 * 200)
        for y in 60..<140 { for x in 60..<140 { data[y * 200 + x] = 255 } }
        return MaskBitmap(width: 200, height: 200, data: data)
    }

    func testEdgeAndFeather() {
        let mask = square()
        XCTAssertEqual(mask.refined(feather: 0, edge: 0), mask, "zero is exactly nothing")
        let grown = mask.refined(feather: 0, edge: 1)
        let shrunk = mask.refined(feather: 0, edge: -1)
        XCTAssertGreaterThan(grown.coverage, mask.coverage)
        XCTAssertLessThan(shrunk.coverage, mask.coverage)
        XCTAssertEqual(grown.data[100 * 200 + 57], 255, "grows a few pixels past the edge")
        XCTAssertEqual(shrunk.data[100 * 200 + 62], 0, "shrinks a few pixels inside it")
        XCTAssertEqual(shrunk.data[100 * 200 + 100], 255, "the middle stays")

        let soft = mask.refined(feather: 1, edge: 0)
        let edgeValue = soft.data[100 * 200 + 60]
        XCTAssertTrue(edgeValue > 60 && edgeValue < 200, "the edge is a ramp, got \(edgeValue)")
        XCTAssertEqual(soft.data[100 * 200 + 100], 255)
        XCTAssertEqual(soft.data[5 * 200 + 5], 0)
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
        func luma(at n: SIMD2<Float>) -> Double {
            let cx = Int(n.x * Float(w)), cy = Int(n.y * Float(h))
            var s = 0.0
            for dy in -2...2 { for dx in -2...2 {
                let i = ((cy + dy) * w + (cx + dx)) * 4
                s += 0.2627 * Double(px[i]) + 0.678 * Double(px[i + 1]) + 0.0593 * Double(px[i + 2])
            } }
            return s / 25
        }
        func pixel(at n: SIMD2<Float>) -> SIMD3<Float> {
            let i = (Int(n.y * Float(h)) * w + Int(n.x * Float(w))) * 4
            return SIMD3(px[i], px[i + 1], px[i + 2])
        }
    }

    private func render(_ f: Fixture, _ p: EditParameters, output: RenderOutput = .file(.sRGB)) throws -> Image {
        let tex = try f.pipeline.render(f.session, scale: .binned(quads: 4), parameters: p, output: output)
        return Image(w: tex.width, h: tex.height, px: try TextureReadback.float16Pixels(of: tex, gpu: f.gpu).map(Float.init))
    }

    private let centre = SIMD2<Float>(0.5, 0.5), left = SIMD2<Float>(0.12, 0.5), right = SIMD2<Float>(0.88, 0.5)
    private func radial(_ c: SIMD2<Float>, _ r: Float) -> MaskShape {
        .radial(centre: c, radii: SIMD2(r, r), feather: 0.2)
    }

    func testInactiveAdditionsRenderIdentically() throws {
        let f = try fixture()
        var base = EditParameters()
        base.locals = [LocalAdjustment(name: "r", shape: radial(centre, 0.25), exposureEV: 1)]
        let reference = try render(f, base)
        // Through the stored form and back, and with a hidden extra mask
        // whose new sliders are set: nothing may move.
        let reread = try EditStack.decode(json: try EditStack(parameters: base).encodeJSON()).parameters()
        XCTAssertTrue(try render(f, reread).px == reference.px)
        var hidden = base
        var extra = LocalAdjustment(name: "h", shape: .whole, exposureEV: 2)
        extra.hidden = true; extra.clarity = 1; extra.highlights = 1
        hidden.locals.append(extra)
        XCTAssertTrue(try render(f, hidden).px == reference.px, "a hidden mask changes nothing")
    }

    func testSubtractAndIntersectComponents() throws {
        let f = try fixture()
        let base = try render(f, EditParameters())
        // Whole image +1 EV, minus a radial in the middle.
        var subtract = EditParameters()
        var local = LocalAdjustment(name: "s", shape: .whole, exposureEV: 1)
        local.components = [MaskComponent(mode: .subtract, source: .shape(radial(centre, 0.2)))]
        subtract.locals = [local]
        let s = try render(f, subtract)
        XCTAssertEqual(s.luma(at: centre), base.luma(at: centre), accuracy: 0.004, "the middle is taken out")
        XCTAssertGreaterThan(s.luma(at: left), base.luma(at: left) + 0.02, "the rest is brighter")

        // A radial on the left intersected with a whole-image component
        // inverted (nothing): nothing anywhere.
        var intersect = EditParameters()
        var two = LocalAdjustment(name: "i", shape: radial(left, 0.2), exposureEV: 1)
        two.components = [MaskComponent(mode: .intersect, source: .shape(.whole), invert: true)]
        intersect.locals = [two]
        let i = try render(f, intersect)
        XCTAssertEqual(i.luma(at: left), base.luma(at: left), accuracy: 0.004)

        // Adding a second radial on the right extends the first.
        var add = EditParameters()
        var three = LocalAdjustment(name: "a", shape: radial(left, 0.15), exposureEV: 1)
        three.components = [MaskComponent(mode: .add, source: .shape(radial(right, 0.15)))]
        add.locals = [three]
        let a = try render(f, add)
        XCTAssertGreaterThan(a.luma(at: left), base.luma(at: left) + 0.02)
        XCTAssertGreaterThan(a.luma(at: right), base.luma(at: right) + 0.02)
        XCTAssertEqual(a.luma(at: centre), base.luma(at: centre), accuracy: 0.004)
    }

    func testAmountScalesTheEffect() throws {
        let f = try fixture()
        var full = EditParameters()
        full.locals = [LocalAdjustment(name: "w", shape: .whole, exposureEV: 1)]
        var half = full
        half.locals[0].amount = 0.5
        var halfEV = full
        halfEV.locals[0].exposureEV = 0.5
        let a = try render(f, half), b = try render(f, halfEV)
        XCTAssertEqual(a.luma(at: centre), b.luma(at: centre), accuracy: 0.002, "50% of +1 EV is +0.5 EV")
    }

    func testNewPointSlidersWorkInsideTheMaskOnly() throws {
        let f = try fixture()
        let base = try render(f, EditParameters())
        for edit in [{ (l: inout LocalAdjustment) in l.shadows = 1 }, { $0.tint = 1 }, { $0.hue = 90 }] {
            var p = EditParameters()
            var local = LocalAdjustment(name: "r", shape: radial(centre, 0.25))
            edit(&local)
            p.locals = [local]
            let r = try render(f, p)
            XCTAssertNotEqual(r.pixel(at: centre), base.pixel(at: centre), "\(local) changes the middle")
            XCTAssertEqual(r.pixel(at: left), base.pixel(at: left), "and nothing outside")
        }
        // Highlights and Whites move bright tones: brighten the middle
        // into each one's band first, then pull it down. How far to lift
        // depends on the raw (the private sample's centre is ~2.5 stops
        // brighter than the golden raw's), so lift until the centre is as
        // bright as the band needs: Highlights peaks just above mid grey
        // (display ~0.96), Whites near white (~0.99).
        for (edit, target) in [({ (l: inout LocalAdjustment) in l.highlights = -1 }, 0.95), ({ $0.whites = -1 }, 0.99)] {
            var bright = EditParameters()
            var ev: Float = 2
            var lifted: Image
            repeat {
                ev += 0.5
                bright.locals = [LocalAdjustment(name: "r", shape: radial(centre, 0.25), exposureEV: ev)]
                lifted = try render(f, bright)
            } while lifted.luma(at: centre) < target && ev < 10
            var p = bright
            edit(&p.locals[0])
            let r = try render(f, p)
            XCTAssertLessThan(r.luma(at: centre), lifted.luma(at: centre) - 0.01, "at +\(ev) EV")
        }
    }

    func testDetailSlidersWorkInsideTheMask() throws {
        let f = try fixture()
        let base = try render(f, EditParameters())
        var p = EditParameters()
        var local = LocalAdjustment(name: "r", shape: radial(centre, 0.25))
        local.clarity = 1; local.texture = 1; local.dehaze = 0.6
        p.locals = [local]
        let r = try render(f, p)
        func difference(_ a: Image, _ b: Image, near n: SIMD2<Float>) -> Float {
            var d: Float = 0
            for dy in -6...6 { for dx in -6...6 {
                let x = Int(n.x * Float(a.w)) + dx, y = Int(n.y * Float(a.h)) + dy
                let i = (y * a.w + x) * 4
                d = max(d, abs(a.px[i] - b.px[i]), abs(a.px[i + 1] - b.px[i + 1]))
            } }
            return d
        }
        XCTAssertGreaterThan(difference(r, base, near: centre), 0.02, "clarity, texture and dehaze act inside")
        XCTAssertLessThan(difference(r, base, near: left), 0.002, "and not outside")
    }

    func testOverlayWhiteOnBlackShowsTheMask() throws {
        let f = try fixture()
        var p = EditParameters()
        p.locals = [LocalAdjustment(name: "r", shape: radial(centre, 0.25))]
        var output = RenderOutput.file(.sRGB)
        output.maskOverlay = 0
        output.maskOverlayStyle = MaskOverlayStyle(mode: .whiteOnBlack)
        let r = try render(f, p, output: output)
        XCTAssertEqual(r.pixel(at: centre).x, 1, accuracy: 0.002, "full mask is white")
        XCTAssertEqual(r.pixel(at: left).x, 0, accuracy: 0.002, "no mask is black")
    }
}
