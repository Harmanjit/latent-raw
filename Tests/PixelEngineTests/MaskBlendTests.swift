import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// Mask blending, combination and management: blend modes, Sum and
/// Exclusion, linked mask components, Edge refine and Smooth
/// (MaskBlend.swift, MaskLinks.swift, MaskRefine.swift, LocalDetailStage.swift).
final class MaskBlendTests: XCTestCase {
    // MARK: - Stored form

    func testNeutralAdditionsAreNotWritten() throws {
        var local = LocalAdjustment(name: "L", shape: .brush(strokes: []), exposureEV: 0.5)
        local.components = [MaskComponent(mode: .add, source: .shape(.whole))]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(local), as: UTF8.self)
        for key in ["blendMode", "smooth", "edgeRefine"] {
            XCTAssertFalse(json.contains("\"\(key)\""), "a neutral \(key) is not written")
        }
    }

    func testAdditionsRoundTrip() throws {
        let other = LocalAdjustment(name: "Sky", shape: .radial(centre: SIMD2(0.5, 0.3), radii: SIMD2(0.2, 0.2), feather: 0.3))
        var local = LocalAdjustment(name: "L", shape: .brush(strokes: []), exposureEV: 0.5)
        local.blendMode = .lightness
        local.smooth = 0.4
        local.edgeRefine = 0.6
        local.components = [
            MaskComponent(mode: .sum, source: .mask(id: other.id), invert: true),
            MaskComponent(mode: .exclusion, source: .shape(.ai(kind: "sky", modelVersion: "m@1")), edgeRefine: 0.3),
        ]
        var p = EditParameters()
        p.locals = [other, local]
        let back = try EditStack.decode(json: try EditStack(parameters: p).encodeJSON()).parameters()
        XCTAssertEqual(back.locals, p.locals)

        // A blend mode a later build might add reads as Normal.
        var json = String(decoding: try JSONEncoder().encode(local), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"lightness\"", with: "\"dissolve\"")
        XCTAssertEqual(try JSONDecoder().decode(LocalAdjustment.self, from: Data(json.utf8)).blendMode, .normal)
        XCTAssertNil(MaskComponent(mode: .add, source: .shape(.whole), edgeRefine: 0).edgeRefine, "zero is stored as off")
    }

    // MARK: - Model

    func testSumAndExclusion() {
        XCTAssertEqual(MaskCombineMode.sum.combine(0.3, 0.4), 0.7, accuracy: 1e-6)
        XCTAssertEqual(MaskCombineMode.sum.combine(0.8, 0.6), 1, "never past full")
        XCTAssertEqual(MaskCombineMode.exclusion.combine(1, 1), 0, "both is neither")
        XCTAssertEqual(MaskCombineMode.exclusion.combine(1, 0), 1)
        XCTAssertEqual(MaskCombineMode.exclusion.combine(0.5, 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(MaskCombineMode.addButtons, [.add, .subtract, .intersect], "the buttons above the list are unchanged")
        XCTAssertEqual(MaskCombineMode.allCases.map(\.gpuCode), [0, 1, 2, 3, 4])
        var local = LocalAdjustment(name: "B", shape: .brush(strokes: []))
        local.components = [MaskComponent(mode: .sum, source: .shape(.whole))]
        XCTAssertFalse(local.isEmptyMask, "Sum puts pixels in")
    }

    func testBlendModeArithmetic() {
        let before = SIMD3<Float>(0.2, 0.3, 0.4), after = SIMD3<Float>(0.6, 0.3, 0.1)
        let w = SIMD3<Float>(0.2627, 0.6780, 0.0593)
        XCTAssertEqual(LocalBlendMode.normal.blend(before: before, after: after), after)
        let colour = LocalBlendMode.colour.blend(before: before, after: after)
        XCTAssertEqual(simd_dot(colour, w), simd_dot(before, w), accuracy: 1e-5, "colour only keeps the lightness")
        XCTAssertEqual(colour.x / colour.z, after.x / after.z, accuracy: 1e-4, "and takes the result's colour")
        let light = LocalBlendMode.lightness.blend(before: before, after: after)
        XCTAssertEqual(simd_dot(light, w), simd_dot(after, w), accuracy: 1e-5, "lightness only takes the result's lightness")
        XCTAssertEqual(light.x / light.z, before.x / before.z, accuracy: 1e-4, "and keeps the colour")
        XCTAssertEqual(LocalBlendMode.colour.blend(before: before, after: .zero), before)
    }

    func testDetailParamsCarrySmoothAndBlend() {
        var l = LocalAdjustment(name: "L", shape: .whole)
        XCTAssertFalse(l.wantsDetailStage)
        l.smooth = 0.5
        XCTAssertTrue(l.wantsDetailStage, "Smooth runs in the detail stage")
        l.blendMode = .colour
        let params = LocalDetailStage.params(for: [l], binSpan: 2)
        XCTAssertEqual(params.count, 1)
        XCTAssertEqual(params[0].extra.x, 0.5 * LocalDetailStage.smoothReach / 2, accuracy: 1e-5, "radius scales with the render")
        XCTAssertEqual(params[0].extra.y, 0.5)
        XCTAssertEqual(params[0].extra.z, 1)
        XCTAssertFalse(LocalDetailStage.needsBlurs([l]), "Smooth samples the picture itself")
        XCTAssertEqual(LocalAdjustGPU(l, brushSlice: -1).info.w, 1, "the colour kernel's blend code")
        XCTAssertEqual(LocalAdjustGPU(LocalAdjustment(name: "n", shape: .whole), brushSlice: -1).info.w, 0)
    }

    // MARK: - Links

    private func linked() -> (target: LocalAdjustment, user: LocalAdjustment) {
        var target = LocalAdjustment(name: "Sky", shape: .radial(centre: SIMD2(0.3, 0.5), radii: SIMD2(0.2, 0.2), feather: 0.2),
                                     invert: true, luminanceRange: LuminanceRange(low: 0.2, high: 1, feather: 0.1),
                                     hueRange: HueRange(centre: 200, width: 40, minimumSaturation: 0.1))
        target.components = [MaskComponent(mode: .subtract, source: .shape(.whole))]
        target.invertMask = true
        var user = LocalAdjustment(name: "User", shape: .whole)
        user.components = [MaskComponent(mode: .add, source: .shape(.whole)),
                           MaskComponent(mode: .intersect, source: .mask(id: target.id), invert: true)]
        return (target, user)
    }

    func testLinkedMaskInlinesAsAGroup() {
        let (target, user) = linked()
        let plan = LocalsGPUPlan(locals: [target, user], slices: [target.id: 3])
        XCTAssertEqual(plan.locals[1].info2.y, 1 + 4, "one component, then the linked mask's four entries")
        let start = Int(plan.locals[1].info2.x)
        XCTAssertEqual(plan.components.count, start + 5)
        let group = Array(plan.components[(start + 1)...(start + 4)])
        XCTAssertEqual(group[0].info.x, 2, "the linked mask's own shape first")
        XCTAssertEqual(group[0].info.z, MaskLinks.groupStart | 1, "starting the group, with its shape's Invert")
        XCTAssertEqual(group[0].info.w, MaskCombineMode.intersect.gpuCode, "carrying the link's mode")
        XCTAssertEqual(group[1].info.z, MaskLinks.groupInvert, "Invert mask after its components")
        XCTAssertEqual(group[2].info.x, 5, "then its luminance range")
        XCTAssertEqual(group[3].info.x, MaskLinks.hueRangeType, "and its hue range")
        XCTAssertEqual(group[3].info.z, MaskLinks.groupEnd | MaskLinks.groupEndInvert, "closing, with the link's Invert")
        XCTAssertEqual(MaskLinks.groupSize(target), 4)

        var p = EditParameters()
        p.locals = [target, user]
        XCTAssertEqual(p.packedComponentCount(ofLocal: 1), 5)
        XCTAssertEqual(p.localsLinking(to: target.id), [1])
        XCTAssertEqual(p.linkedMaskName(target.id), "Sky")
        XCTAssertEqual(p.linkedMaskName(UUID()), "Missing Mask")
    }

    func testLinksStayOneLevelDeepAndFit() {
        let (target, user) = linked()
        var p = EditParameters()
        let third = LocalAdjustment(name: "Third", shape: .whole)
        p.locals = [target, user, third]
        XCTAssertFalse(p.canLink(mask: target.id, intoLocal: 0), "not itself")
        XCTAssertFalse(p.canLink(mask: user.id, intoLocal: 2), "not a mask with links of its own")
        XCTAssertFalse(p.canLink(mask: third.id, intoLocal: 0), "not into a mask another one uses")
        XCTAssertTrue(p.canLink(mask: target.id, intoLocal: 2))
        var full = third
        full.components = Array(repeating: MaskComponent(mode: .add, source: .shape(.whole)), count: 3)
        p.locals[2] = full
        XCTAssertFalse(p.canLink(mask: target.id, intoLocal: 2), "3 + 4 entries would pass six")

        // Packing: self links, missing masks and nested links are nothing.
        var selfLinked = LocalAdjustment(name: "S", shape: .whole)
        selfLinked.components = [MaskComponent(mode: .add, source: .mask(id: selfLinked.id)),
                                 MaskComponent(mode: .add, source: .mask(id: UUID())),
                                 MaskComponent(mode: .add, source: .mask(id: user.id))]
        let plan = LocalsGPUPlan(locals: [target, user, selfLinked], slices: [:])
        XCTAssertEqual(plan.locals[2].info2.y, 0)
    }

    func testPlanWithoutLinksIsAsBefore() {
        var local = LocalAdjustment(name: "L", shape: .whole)
        local.components = (0..<8).map { k in
            MaskComponent(mode: k % 2 == 0 ? .add : .intersect, source: .luminance(LuminanceRange(low: Float(k) / 10)))
        }
        let plan = LocalsGPUPlan(locals: [local], slices: [:])
        XCTAssertEqual(plan.components.count, MaskComponent.maximumPerMask, "still the first six")
        for (k, c) in plan.components.enumerated() {
            XCTAssertEqual(c.info, SIMD4(5, -1, 0, k % 2 == 0 ? 0 : 2))
            XCTAssertEqual(c.geometry0.x, Float(k) / 10)
        }
    }

    // MARK: - Edge refine

    func testEdgeRefineSnapsToTheGuide() {
        // A guide dark left of column 100 and bright right of it; a mask
        // painted with a soft edge ramping from column 90 to 110.
        let w = 200, h = 150
        var guide = [UInt8](repeating: 0, count: w * h * 3)
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 3
            guide[o] = x < 100 ? 40 : 220; guide[o + 1] = 85; guide[o + 2] = 85
            mask[y * w + x] = UInt8(min(max(Float(x - 90) / 20, 0), 1) * 255)
        } }
        let g = BrushGuide(width: w, height: h, data: guide)
        let bitmap = MaskBitmap(width: w, height: h, data: mask)
        XCTAssertEqual(bitmap.edgeRefined(0, guide: g), bitmap, "zero is exactly nothing")
        let refined = bitmap.edgeRefined(1, guide: g)
        let row = 75 * w
        XCTAssertLessThan(Int(refined.data[row + 97]), Int(mask[row + 97]) - 8, "the dark side of the edge falls")
        XCTAssertGreaterThan(Int(refined.data[row + 103]), Int(mask[row + 103]) + 8, "the bright side rises")
        XCTAssertEqual(refined.data[row + 20], 0, "far from the edge nothing moves")
        XCTAssertEqual(refined.data[row + 180], 255)
        XCTAssertEqual(bitmap.edgeRefined(1, guide: BrushGuide(width: 10, height: 10, data: [UInt8](repeating: 0, count: 300))),
                       bitmap, "a guide of another size leaves it")

        var l = LocalAdjustment(name: "L", shape: .brush(strokes: []))
        XCTAssertFalse(l.usesEdgeRefine)
        l.edgeRefine = 0.5
        XCTAssertTrue(l.usesEdgeRefine)
        l.shape = .radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.1, 0.1), feather: 0.2)
        XCTAssertFalse(l.usesEdgeRefine, "geometric shapes are never refined")
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
            var s = SIMD3<Float>(repeating: 0)
            for dy in -2...2 { for dx in -2...2 {
                let i = ((Int(n.y * Float(h)) + dy) * w + Int(n.x * Float(w)) + dx) * 4
                s += SIMD3(px[i], px[i + 1], px[i + 2])
            } }
            return s / 25
        }
        func luma(at n: SIMD2<Float>) -> Float { simd_dot(pixel(at: n), SIMD3(0.2627, 0.678, 0.0593)) }
    }

    private func render(_ f: Fixture, _ p: EditParameters) throws -> Image {
        let tex = try f.pipeline.render(f.session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
        return Image(w: tex.width, h: tex.height, px: try TextureReadback.float16Pixels(of: tex, gpu: f.gpu).map(Float.init))
    }

    private let centre = SIMD2<Float>(0.5, 0.5), left = SIMD2<Float>(0.15, 0.5)

    func testBlendModesRender() throws {
        let f = try fixture()
        let base = try render(f, EditParameters())
        // +1 EV with Colour only: the lightness barely moves.
        var bright = EditParameters()
        bright.locals = [LocalAdjustment(name: "w", shape: .whole, exposureEV: 1)]
        let normal = try render(f, bright)
        bright.locals[0].blendMode = .colour
        let colourOnly = try render(f, bright)
        XCTAssertGreaterThan(normal.luma(at: centre), base.luma(at: centre) + 0.05)
        XCTAssertEqual(colourOnly.luma(at: centre), base.luma(at: centre), accuracy: 0.01, "colour only keeps the lightness")

        // A hue turn with Lightness only: the colour stays.
        var turn = EditParameters()
        turn.locals = [LocalAdjustment(name: "h", shape: .whole)]
        turn.locals[0].hue = 120
        let turned = try render(f, turn)
        turn.locals[0].blendMode = .lightness
        let lightnessOnly = try render(f, turn)
        let moved = simd_length(turned.pixel(at: centre) - base.pixel(at: centre))
        let kept = simd_length(lightnessOnly.pixel(at: centre) - base.pixel(at: centre))
        XCTAssertLessThan(kept, moved * 0.5, "lightness only keeps the colour (\(kept) vs \(moved))")
    }

    func testLinkedComponentRendersAsTheMaskItUses() throws {
        let f = try fixture()
        let shape = MaskShape.radial(centre: left, radii: SIMD2(0.15, 0.15), feather: 0.3)
        var direct = EditParameters()
        direct.locals = [LocalAdjustment(name: "Ref", shape: shape),
                         LocalAdjustment(name: "R", shape: shape, exposureEV: 1)]
        var link = EditParameters()
        let ref = LocalAdjustment(name: "Ref", shape: shape)
        var user = LocalAdjustment(name: "U", shape: .whole, exposureEV: 1)
        user.components = [MaskComponent(mode: .intersect, source: .mask(id: ref.id))]
        link.locals = [ref, user]
        let a = try render(f, direct), b = try render(f, link)
        XCTAssertTrue(a.px == b.px, "whole ∩ the linked radial is the radial")

        // Editing the linked mask moves every user.
        link.locals[0].shape = .radial(centre: centre, radii: SIMD2(0.15, 0.15), feather: 0.3)
        let base = try render(f, EditParameters())
        let moved = try render(f, link)
        XCTAssertGreaterThan(moved.luma(at: centre), base.luma(at: centre) + 0.03)
        XCTAssertEqual(moved.luma(at: left), base.luma(at: left), accuracy: 0.003)

        // Exclusion of the whole image with itself is nothing.
        var none = EditParameters()
        var ex = LocalAdjustment(name: "x", shape: .whole, exposureEV: 1)
        ex.components = [MaskComponent(mode: .exclusion, source: .shape(.whole))]
        none.locals = [ex]
        XCTAssertEqual(try render(f, none).luma(at: centre), base.luma(at: centre), accuracy: 0.003)
    }

    func testSmoothActsInsideTheMaskOnly() throws {
        let f = try fixture()
        let base = try render(f, EditParameters())
        var p = EditParameters()
        var local = LocalAdjustment(name: "s", shape: .radial(centre: centre, radii: SIMD2(0.25, 0.25), feather: 0.2))
        local.smooth = 1
        p.locals = [local]
        let r = try render(f, p)
        func difference(near n: SIMD2<Float>) -> Float {
            var d: Float = 0
            for dy in -8...8 { for dx in -8...8 {
                let i = ((Int(n.y * Float(r.h)) + dy) * r.w + Int(n.x * Float(r.w)) + dx) * 4
                d = max(d, abs(r.px[i] - base.px[i]), abs(r.px[i + 1] - base.px[i + 1]))
            } }
            return d
        }
        XCTAssertGreaterThan(difference(near: centre), 0.002, "smooths inside")
        XCTAssertEqual(difference(near: left), 0, "and leaves the outside exactly")
    }
}
