import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// Rotatable ellipses, shape handles, separate range fades, Channel Range
/// and Show Channel (MaskShapeGeometry.swift, ChannelRange.swift): the
/// stored form, the GPU packing, the CPU mirrors and the renders.
final class MaskShapesTests: XCTestCase {
    private let size = SIMD2<Float>(6000, 4000)

    // MARK: - Stored form

    func testAnUnturnedRadialIsWrittenAsBefore() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacy = #"{"radial":{"centre":[0.5,0.4],"feather":0.4,"radii":[0.2,0.3]}}"#
        let read = try JSONDecoder().decode(MaskShape.self, from: Data(legacy.utf8))
        XCTAssertEqual(read, .radial(centre: SIMD2(0.5, 0.4), radii: SIMD2(0.2, 0.3), feather: 0.4))
        XCTAssertEqual(read.radialAngle, 0)
        XCTAssertEqual(String(decoding: try encoder.encode(read), as: UTF8.self), legacy)
        // Turned and back to 0: nothing extra is written.
        XCTAssertEqual(String(decoding: try encoder.encode(read.withRadialAngle(30).withRadialAngle(0)), as: UTF8.self), legacy)

        let turned = read.withRadialAngle(390)
        XCTAssertEqual(turned.radialAngle, 30, accuracy: 1e-4)
        let back = try JSONDecoder().decode(MaskShape.self, from: try encoder.encode(turned))
        XCTAssertEqual(back, turned)
        XCTAssertEqual(read.withRadialAngle(-190).radialAngle, 170, accuracy: 1e-4)
    }

    func testRangeFadesAreWrittenOnlyWhenSetApart() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var range = LuminanceRange(low: 0.4, high: 0.8, feather: 0.1)
        XCTAssertEqual(String(decoding: try encoder.encode(range), as: UTF8.self), #"{"feather":0.1,"high":0.8,"low":0.4}"#)
        range.band = MaskRangeBand(low: 0.4, high: 0.8, featherLow: 0.05, featherHigh: 0.2)
        XCTAssertEqual(range.featherLow, 0.05)
        XCTAssertEqual(range.featherHigh, 0.2)
        XCTAssertEqual(try JSONDecoder().decode(LuminanceRange.self, from: try encoder.encode(range)), range)
        // Equal again: back to the one feather.
        range.band = MaskRangeBand(low: 0.4, high: 0.8, featherLow: 0.15, featherHigh: 0.15)
        XCTAssertNil(range.featherLow)
        XCTAssertNil(range.featherHigh)
        XCTAssertEqual(range.feather, 0.15)
        range.band = MaskRangeBand(low: 0.4, high: 0.8, featherLow: 0.05, featherHigh: 0.2)
        range.bothFeathers = 0.3
        XCTAssertEqual(range.band, MaskRangeBand(low: 0.4, high: 0.8, featherLow: 0.3, featherHigh: 0.3))
    }

    func testAChannelRangeComponentRoundTrips() throws {
        var local = LocalAdjustment(name: "c", shape: .whole, exposureEV: 1)
        var channel = ChannelRange(channel: .labChroma, low: 0.3, high: 0.9, feather: 0.05)
        channel.featherHigh = 0.2
        local.components = [MaskComponent(mode: .intersect, source: .channel(channel))]
        var p = EditParameters()
        p.locals = [local]
        let back = try EditStack.decode(json: try EditStack(parameters: p).encodeJSON()).parameters()
        XCTAssertEqual(back.locals, p.locals)
        XCTAssertEqual(local.components[0].displayName, "Channel Range (Lab Chroma)")
        XCTAssertFalse(local.isEmptyMask, "an intersected range leaves the whole image")
    }

    // MARK: - GPU packing

    func testPackingKeepsOldEditsAsTheyWere() {
        var local = LocalAdjustment(name: "r", shape: .radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.2, 0.2), feather: 0.4),
                                    luminanceRange: LuminanceRange(low: 0.3, high: 0.7, feather: 0.12))
        var packed = LocalAdjustGPU(local, brushSlice: -1)
        XCTAssertEqual(packed.geometry1, SIMD4(0.4, 0, 0, 0), "an unturned ellipse packs as before")
        XCTAssertEqual(packed.lumRange, SIMD4(0.3, 0.7, 0.12, 1))
        XCTAssertEqual(packed.adjust3.z, 0.12, "the fade above High equals the one below")

        local.shape = local.shape.withRadialAngle(90)
        local.luminanceRange?.featherHigh = 0.3
        packed = LocalAdjustGPU(local, brushSlice: -1)
        XCTAssertEqual(packed.geometry1.y, .pi / 2, accuracy: 1e-5)
        XCTAssertEqual(packed.adjust3.z, 0.3)

        let lum = MaskComponentGPU(MaskComponent(mode: .add, source: .luminance(LuminanceRange(low: 0.2, high: 0.6, feather: 0.1))), slice: -1)
        XCTAssertEqual(lum.geometry0, SIMD4(0.2, 0.6, 0.1, 0.1))
        let ch = MaskComponentGPU(MaskComponent(mode: .add, source: .channel(ChannelRange(channel: .labB))), slice: -1)
        XCTAssertEqual(ch.info.x, 8, "7 is a linked mask's hue range")
        XCTAssertEqual(ch.info.x, MaskComponentGPU.channelRangeType)
        XCTAssertNotEqual(MaskComponentGPU.channelRangeType, MaskLinks.hueRangeType)
        XCTAssertEqual(ch.extra.x, 6)
    }

    func testChannelRangeAfterALinkedMaskPacksAndShowsItsOwnEntry() {
        var target = LocalAdjustment(name: "Sky", shape: .whole)
        target.hueRange = HueRange()
        var user = LocalAdjustment(name: "User", shape: .whole)
        user.components = [MaskComponent(mode: .add, source: .mask(id: target.id)),
                           MaskComponent(mode: .sum, source: .channel(ChannelRange(channel: .green)))]
        let plan = LocalsGPUPlan(locals: [target, user], slices: [:])
        let start = Int(plan.locals[1].info2.x)
        XCTAssertEqual(plan.locals[1].info2.y, 3, "the linked group (shape, hue range), then the channel range")
        XCTAssertEqual(plan.components[start + 1].info.x, MaskLinks.hueRangeType)
        XCTAssertEqual(plan.components[start + 2].info.x, MaskComponentGPU.channelRangeType)
        XCTAssertEqual(plan.components[start + 2].info.w, MaskCombineMode.sum.gpuCode)
        XCTAssertEqual(plan.componentOffsets[1], [0, 2])

        var output = RenderOutput.file(.sRGB)
        output.maskOverlay = 1
        output.maskOverlayStyle.channelComponent = 1
        XCTAssertEqual(plan.channelViewFlag(output), UInt32(start + 2 + 1), "Show Channel finds the channel range past the group")
        output.maskOverlayStyle.channelComponent = 2
        XCTAssertEqual(plan.channelViewFlag(output), 0)
    }

    // MARK: - CPU mirrors

    func testATurnedEllipseCoversWhereItPoints() {
        let flat = MaskShape.radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.3, 0.03), feather: 0.2)
        let short = min(size.x, size.y)
        // 0.2 of the short side below the centre.
        let below = SIMD2<Float>(0.5, 0.5 + 0.2 * short / size.y)
        XCTAssertEqual(flat.radialWeight(at: below, sensorSize: size)!, 0, accuracy: 1e-4)
        XCTAssertEqual(flat.withRadialAngle(90).radialWeight(at: below, sensorSize: size)!, 1, accuracy: 1e-4)
        XCTAssertEqual(flat.withRadialAngle(-90).radialWeight(at: below, sensorSize: size)!, 1, accuracy: 1e-4)
        // The outline point on the turned x axis is on the outline.
        let turned = flat.withRadialAngle(37)
        let edge = MaskShape.radialPoint(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.3, 0.03), angle: 37, t: 0, sensorSize: size)
        XCTAssertEqual(MaskShape.ellipseNorm(edge, centre: SIMD2(0.5, 0.5), radii: SIMD2(0.3, 0.03), angle: 37,
                                             sensorSize: size), 1, accuracy: 1e-4)
        XCTAssertTrue(turned.contains(SIMD2(0.5, 0.5), sensorSize: size))
    }

    func testHandlesReshapeTheShape() {
        let radial = MaskShape.radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.2, 0.1), feather: 0.5)
        let handles = Dictionary(uniqueKeysWithValues: radial.handlePositions(sensorSize: size).map { ($0.handle, $0.point) })
        XCTAssertEqual(Set(handles.keys), [.radialCentre, .radialEdgeX, .radialEdgeY, .radialFeather, .radialRotate])
        let short = min(size.x, size.y)
        // Rotate: drag the handle (above the centre) round to the right.
        let right = SIMD2<Float>(0.5 + 0.3 * short / size.x, 0.5)
        let turned = radial.dragging(.radialRotate, from: handles[.radialRotate]!, to: right, sensorSize: size)
        XCTAssertEqual(turned.radialAngle, 90, accuracy: 0.01)
        // The x edge, dragged out to 0.3 of the short side.
        guard case .radial(_, let r, _, _) = radial.dragging(.radialEdgeX, from: handles[.radialEdgeX]!, to: right, sensorSize: size)
        else { return XCTFail() }
        XCTAssertEqual(r.x, 0.3, accuracy: 1e-4)
        XCTAssertEqual(r.y, 0.1)
        // The feather ring, dragged to the edge: no feather; to the centre: all.
        guard case .radial(_, _, let f0, _) = radial.dragging(.radialFeather, from: handles[.radialFeather]!,
                                                              to: handles[.radialEdgeX]!, sensorSize: size),
              case .radial(_, _, let f1, _) = radial.dragging(.radialFeather, from: handles[.radialFeather]!,
                                                              to: SIMD2(0.5, 0.5), sensorSize: size)
        else { return XCTFail() }
        XCTAssertEqual(f0, 0, accuracy: 1e-3)
        XCTAssertEqual(f1, 1, accuracy: 1e-3)

        let linear = MaskShape.linear(start: SIMD2(0.2, 0.2), end: SIMD2(0.4, 0.2))
        XCTAssertEqual(linear.dragging(.linearEnd, from: SIMD2(0.4, 0.2), to: SIMD2(0.6, 0.3), sensorSize: size),
                       .linear(start: SIMD2(0.2, 0.2), end: SIMD2(0.6, 0.3)))
        guard case .linear(let s, let e) = linear.dragging(.linearMiddle, from: SIMD2(0.3, 0.2), to: SIMD2(0.3, 0.5), sensorSize: size)
        else { return XCTFail() }
        XCTAssertEqual(s.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(e.y, 0.5, accuracy: 1e-6)
        // Scrolling: a wider fade, about the same middle.
        guard case .linear(let ws, let we) = linear.scrollingFeather(by: 0.1) else { return XCTFail() }
        XCTAssertEqual(we.x - ws.x, 0.24, accuracy: 1e-5)
        XCTAssertEqual((ws.x + we.x) / 2, 0.3, accuracy: 1e-5)
        guard case .radial(_, _, let more, _) = radial.scrollingFeather(by: 0.02) else { return XCTFail() }
        XCTAssertEqual(more, 0.52, accuracy: 1e-5)
    }

    func testChannelValues() {
        XCTAssertEqual(MaskChannel.red.value(perceptual: SIMD3(0.8, 0.1, 0.2)), 0.8)
        XCTAssertEqual(MaskChannel.saturation.value(perceptual: SIMD3(1, 0.5, 0.5)), 0.5, accuracy: 1e-5)
        XCTAssertEqual(MaskChannel.lightness.value(perceptual: SIMD3(1, 1, 1)), 1, accuracy: 1e-3)
        XCTAssertEqual(MaskChannel.labA.value(perceptual: SIMD3(0.5, 0.5, 0.5)), 0.5, accuracy: 1e-3, "grey is neutral")
        XCTAssertEqual(MaskChannel.labChroma.value(perceptual: SIMD3(0.5, 0.5, 0.5)), 0, accuracy: 1e-3)
        XCTAssertLessThan(MaskChannel.labA.value(perceptual: SIMD3(0.1, 0.8, 0.1)), 0.4, "green is below the middle of a")
        XCTAssertGreaterThan(MaskChannel.labB.value(perceptual: SIMD3(0.9, 0.85, 0.1)), 0.6, "yellow is above the middle of b")
        // Separate fades: the weight follows each side's own.
        var range = ChannelRange(channel: .red, low: 0.4, high: 0.6, feather: 0.1)
        range.featherHigh = 0.3
        XCTAssertEqual(range.weight(value: 0.5), 1)
        XCTAssertEqual(range.weight(value: 0.29), 0)
        XCTAssertGreaterThan(range.weight(value: 0.8), 0.1, "the wide upper fade still reaches")
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
            let i = (min(Int(n.y * Float(h)), h - 1) * w + min(Int(n.x * Float(w)), w - 1)) * 4
            return SIMD3(px[i], px[i + 1], px[i + 2])
        }
        func luma(at n: SIMD2<Float>) -> Float { simd_dot(pixel(at: n), SIMD3(0.2627, 0.678, 0.0593)) }
    }

    private func render(_ f: Fixture, _ p: EditParameters, output: RenderOutput = .file(.sRGB)) throws -> Image {
        let tex = try f.pipeline.render(f.session, scale: .binned(quads: 4), parameters: p, output: output)
        return Image(w: tex.width, h: tex.height, px: try TextureReadback.float16Pixels(of: tex, gpu: f.gpu).map(Float.init))
    }

    func testATurnedEllipseRendersWhereItPoints() throws {
        let f = try fixture()
        let summary = f.session.file.summary
        let sensor = SIMD2(Float(summary.rawWidth), Float(summary.rawHeight))
        let short = min(sensor.x, sensor.y)
        let below = SIMD2<Float>(0.5, 0.5 + 0.25 * short / sensor.y)
        let base = try render(f, EditParameters())
        let flat = MaskShape.radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.35, 0.05), feather: 0.2)
        var p = EditParameters()
        p.locals = [LocalAdjustment(name: "r", shape: flat, exposureEV: 1)]
        let unturned = try render(f, p)
        XCTAssertEqual(unturned.luma(at: below), base.luma(at: below), accuracy: 0.002, "a flat ellipse misses the point below")
        p.locals[0].shape = flat.withRadialAngle(90)
        let turned = try render(f, p)
        XCTAssertGreaterThan(turned.luma(at: below), base.luma(at: below) + 0.02, "turned upright it covers it")
    }

    func testEqualFadesRenderAsOneFeatherAndApartDiffer() throws {
        let f = try fixture()
        var p = EditParameters()
        var local = LocalAdjustment(name: "l", shape: .whole, exposureEV: 1,
                                    luminanceRange: LuminanceRange(low: 0.3, high: 0.5, feather: 0.1))
        local.components = [MaskComponent(mode: .intersect, source: .luminance(LuminanceRange(low: 0.2, high: 0.6, feather: 0.1)))]
        p.locals = [local]
        let reference = try render(f, p)
        var same = p
        same.locals[0].luminanceRange?.featherLow = 0.1
        same.locals[0].luminanceRange?.featherHigh = 0.1
        XCTAssertTrue(try render(f, same).px == reference.px, "both fades at the feather render as before")
        var apart = p
        apart.locals[0].luminanceRange?.featherHigh = 0.5
        XCTAssertFalse(try render(f, apart).px == reference.px, "a wider upper fade selects more")
    }

    func testChannelRangeSelectsByItsChannel() throws {
        let f = try fixture()
        let base = try render(f, EditParameters())
        var all = EditParameters()
        var local = LocalAdjustment(name: "c", shape: .whole, exposureEV: 1)
        local.components = [MaskComponent(mode: .intersect, source: .channel(ChannelRange(channel: .lightness, low: 0, high: 1, feather: 0.05)))]
        all.locals = [local]
        var whole = EditParameters()
        whole.locals = [LocalAdjustment(name: "w", shape: .whole, exposureEV: 1)]
        let a = try render(f, all), w = try render(f, whole)
        let mid = SIMD2<Float>(0.5, 0.5)
        XCTAssertEqual(a.luma(at: mid), w.luma(at: mid), accuracy: 0.003, "the full range is the whole image")
        // A band of chroma no pixel reaches selects nothing.
        var none = all
        none.locals[0].components[0].source = .channel(ChannelRange(channel: .labChroma, low: 0.99, high: 1, feather: 0.01))
        let n = try render(f, none)
        XCTAssertEqual(n.luma(at: mid), base.luma(at: mid), accuracy: 0.003)
    }

    func testShowChannelDrawsTheRangeInputAsGrey() throws {
        let f = try fixture()
        var p = EditParameters()
        var local = LocalAdjustment(name: "c", shape: .whole)
        local.components = [MaskComponent(mode: .intersect, source: .channel(ChannelRange(channel: .red))),
                            MaskComponent(mode: .intersect, source: .luminance(LuminanceRange()))]
        p.locals = [local]
        var output = RenderOutput.file(.sRGB)
        output.maskOverlay = 0
        output.maskOverlayStyle.channelComponent = 1
        let lum = try render(f, p, output: output)
        let base = try render(f, EditParameters())
        for n in [SIMD2<Float>(0.3, 0.3), SIMD2(0.5, 0.5), SIMD2(0.7, 0.6)] {
            let px = lum.pixel(at: n)
            XCTAssertEqual(px.x, px.y, accuracy: 1e-3, "grey")
            XCTAssertEqual(px.y, px.z, accuracy: 1e-3, "grey")
        }
        // Brighter where the picture is brighter.
        let a = SIMD2<Float>(0.2, 0.2), b = SIMD2<Float>(0.6, 0.7)
        if abs(base.luma(at: a) - base.luma(at: b)) > 0.05 {
            XCTAssertEqual(lum.luma(at: a) > lum.luma(at: b), base.luma(at: a) > base.luma(at: b))
        }
        output.maskOverlayStyle.channelComponent = nil
        XCTAssertFalse(try render(f, p, output: output).px == lum.px, "off, the ordinary overlay")
    }
}
