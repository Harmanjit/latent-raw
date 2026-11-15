import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// The tone equalizer inside a mask (LocalToneEqualizer.swift): stored only
/// when a band is moved, carried through the edit stack, presets and
/// copies with the mask, and on the GPU it changes the picture inside the
/// mask and not a pixel outside it.
final class LocalToneEqualizerTests: XCTestCase {
    private static let lift: [Float] = [1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5]

    private func radial(_ bands: [Float]? = nil) -> LocalAdjustment {
        var local = LocalAdjustment(name: "Left", shape: .radial(centre: SIMD2(0.25, 0.5),
                                                                 radii: SIMD2(0.2, 0.2), feather: 0.1))
        local.toneEqualizerBands = bands
        return local
    }

    // MARK: - Model

    func testSettingBandsAndPuttingThemBackLeavesNothing() {
        var local = radial()
        XCTAssertTrue(local.isNeutral)
        local.setToneEqualizerBand(2, to: 1.2)
        XCTAssertEqual(local.toneEqualizerBands?.count, ToneEqualizer.bandCount)
        XCTAssertEqual(local.toneEqualizerBand(2), 1.2)
        XCTAssertTrue(local.hasToneEqualizerBands)
        XCTAssertFalse(local.isNeutral)
        local.setToneEqualizerBand(4, to: 9)
        XCTAssertEqual(local.toneEqualizerBand(4), ToneEqualizer.gainRange.upperBound, "clamped")
        local.setToneEqualizerBand(2, to: 0)
        local.setToneEqualizerBand(4, to: 0)
        XCTAssertNil(local.toneEqualizerBands, "all zero is stored as nothing")
        XCTAssertTrue(local.isNeutral)
        local.setToneEqualizerBand(12, to: 1)
        XCTAssertNil(local.toneEqualizerBands, "an out-of-range band is ignored")
    }

    func testHiddenOrZeroAmountMaskWantsNoWork() {
        var local = radial(Self.lift)
        XCTAssertTrue(local.wantsToneEqualizer)
        local.hidden = true
        XCTAssertFalse(local.wantsToneEqualizer)
        local.hidden = false
        local.amount = 0
        XCTAssertFalse(local.wantsToneEqualizer)
    }

    func testTablesOnlyForMasksWithBands() throws {
        let global = ToneEqualizer(bands: Array(repeating: 0, count: 9), maskExposure: 1)
        XCTAssertNil(LocalToneEqualizerStage.tables(locals: [radial(), radial()], global: global))
        let packed = try XCTUnwrap(LocalToneEqualizerStage.tables(locals: [radial(), radial(Self.lift)], global: global))
        XCTAssertEqual(packed.active, 0b10)
        let n = ToneEqualizer.lutCount
        XCTAssertEqual(packed.tables.count, LocalAdjustment.maximumCount * n)
        XCTAssertTrue(packed.tables[0..<n].allSatisfy { $0 == 0 })
        XCTAssertEqual(packed.tables[n + n / 2], 1.5, accuracy: 1e-4, "equal bands give that gain everywhere")
    }

    // MARK: - Stored form

    func testAbsentFromTheEditWhenNeutral() throws {
        var local = radial()
        local.toneEqualizerBands = Array(repeating: 0, count: 9)
        let json = String(decoding: try JSONEncoder().encode(local), as: UTF8.self)
        XCTAssertFalse(json.contains("toneEqualizer"), json)
        var p = EditParameters()
        p.locals = [radial()]
        let stackJSON = try EditStack(parameters: p).encodeJSON()
        XCTAssertFalse(stackJSON.contains("toneEqualizer"))
    }

    func testEditStackRoundTrip() throws {
        var p = EditParameters()
        var local = radial()
        local.setToneEqualizerBand(0, to: 0.8)
        local.setToneEqualizerBand(8, to: -1.4)
        p.locals = [local, radial()]
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("toneEqualizer"))
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.locals.count, 2)
        XCTAssertEqual(back.locals[0].toneEqualizerBands, local.toneEqualizerBands)
        XCTAssertNil(back.locals[1].toneEqualizerBands)
        XCTAssertEqual(back.locals, p.locals)
    }

    func testDecodingSanitizes() throws {
        let json = try JSONEncoder().encode(radial())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["toneEqualizer"] = [7, -9, 0.5]
        let decoded = try JSONDecoder().decode(LocalAdjustment.self,
                                               from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.toneEqualizerBands, [3, -3, 0.5, 0, 0, 0, 0, 0, 0])
        object["toneEqualizer"] = [0, 0]
        let zero = try JSONDecoder().decode(LocalAdjustment.self,
                                            from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(zero.toneEqualizerBands)
    }

    func testTravelsWithMaskPresetsAndDuplicates() {
        let local = radial(Self.lift)
        let preset = MaskPreset.capture(local, name: "Sky").preset
        XCTAssertEqual(preset.instantiate().toneEqualizerBands, Self.lift)
        XCTAssertEqual(local.duplicated(name: "Copy").toneEqualizerBands, Self.lift)
    }

    // MARK: - GPU

    private struct Image {
        var pixels: [Float16]
        var width: Int, height: Int
        func luma(_ x: Int, _ y: Int) -> Float {
            let i = (y * width + x) * 4
            return Float(pixels[i]) * 0.2627 + Float(pixels[i + 1]) * 0.6780 + Float(pixels[i + 2]) * 0.0593
        }
        func meanLuma(xs: Range<Int>, ys: Range<Int>) -> Float {
            var s: Float = 0
            for y in ys { for x in xs { s += luma(x, y) } }
            return s / Float(xs.count * ys.count)
        }
        func pixel(_ x: Int, _ y: Int) -> [Float16] {
            let i = (y * width + x) * 4
            return Array(pixels[i..<(i + 4)])
        }
    }

    /// On the D750 raw (the golden one on CI): a radial mask on the left
    /// with every band lifted brightens inside it and leaves every pixel
    /// outside it exactly as a render without the bands.
    func testInsideChangesAndOutsideDoesNot() throws {
        let gpu = try GPUContext()
        let file = try RawFile(path: try TestAssets.d750Path())
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        func render(_ local: LocalAdjustment) throws -> Image {
            var p = EditParameters()
            p.locals = [local]
            let tex = try pipeline.render(session, scale: .binned(quads: 8), parameters: p, output: .file(.sRGB))
            return Image(pixels: try TextureReadback.float16Pixels(of: tex, gpu: gpu), width: tex.width, height: tex.height)
        }
        let before = try render(radial())
        let after = try render(radial(Self.lift))
        XCTAssertEqual(before.width, after.width)
        let w = before.width, h = before.height
        // The right half is far outside the ellipse (centre x 0.25, radius
        // 0.2 of the short side): not a pixel there moves.
        for y in stride(from: 0, to: h, by: 3) {
            for x in stride(from: w * 6 / 10, to: w, by: 3) {
                XCTAssertEqual(before.pixel(x, y), after.pixel(x, y), "outside the mask at \(x), \(y)")
            }
        }
        // Its centre is lifted.
        let cx = w / 4, cy = h / 2, r = min(w, h) / 12
        let inBefore = before.meanLuma(xs: (cx - r)..<(cx + r), ys: (cy - r)..<(cy + r))
        let inAfter = after.meanLuma(xs: (cx - r)..<(cx + r), ys: (cy - r)..<(cy + r))
        XCTAssertGreaterThan(inAfter, inBefore * 1.1, "inside the mask brightens")
        // A hidden mask with the same bands changes nothing at all.
        var hidden = radial(Self.lift)
        hidden.hidden = true
        XCTAssertEqual(try render(hidden).pixels, before.pixels)
    }
}
