import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// Highlights, Shadows, Whites, Blacks and the red, green and blue curves.
final class ToneRangesTests: XCTestCase {

    // MARK: - The tone mapping itself

    func testNeutralMovesNothing() {
        let neutral = ToneRanges.neutral
        XCTAssertTrue(neutral.isNeutral)
        XCTAssertTrue(ToneRanges(shadows: 0).isNeutral)
        XCTAssertTrue(neutral.lookupTable().allSatisfy { $0 == 0 })
        for t in stride(from: Float(-20), through: 20, by: 0.37) {
            XCTAssertEqual(neutral.remap(t), t)
        }
        XCTAssertTrue(RGBCurves.identity.isIdentity)
        XCTAssertTrue(EditParameters().toneRanges.isNeutral)
        XCTAssertTrue(EditParameters().channelCurves.isIdentity)
    }

    /// Every combination of the four at their extremes keeps tones in
    /// order and leaves mid grey where it was.
    func testTonesNeverReverse() {
        let values: [Float] = [-1, 0, 1]
        for h in values { for s in values { for w in values { for b in values {
            let r = ToneRanges(highlights: h, shadows: s, whites: w, blacks: b)
            XCTAssertEqual(r.remap(0), 0, "mid grey moved for \(r)")
            var previous = r.remap(-16)
            for t in stride(from: Float(-15.95), through: 16, by: 0.05) {
                let next = r.remap(t)
                XCTAssertGreaterThan(next, previous, "tones reversed near t = \(t) for \(r)")
                previous = next
            }
        } } } }
    }

    func testEachBandStaysUnderItsSlopeLimit() {
        let bands = [ToneRanges.shadowsBand, ToneRanges.highlightsBand, ToneRanges.blacksBand, ToneRanges.whitesBand]
        for band in bands {
            var steepest: Float = 0
            for t in stride(from: Float(-14), through: 14, by: 0.01) {
                let slope = abs(band.weight(t + 0.005) - band.weight(t - 0.005)) / 0.01 * band.reach
                steepest = max(steepest, slope)
            }
            XCTAssertLessThanOrEqual(steepest, ToneRanges.maximumSlope + 1e-3)
        }
    }

    func testEachSliderMovesItsOwnTones() {
        // t = -8 deep shadow, -3 shadow, +2.5 highlight, +7 near white.
        let shadows = ToneRanges(shadows: 1)
        XCTAssertGreaterThan(shadows.remap(-3), -3 + 1)
        XCTAssertEqual(shadows.remap(2.5), 2.5)

        let highlights = ToneRanges(highlights: -1)
        XCTAssertLessThan(highlights.remap(2.5), 2.5 - 1)
        XCTAssertEqual(highlights.remap(-3), -3)

        let whites = ToneRanges(whites: 1)
        XCTAssertGreaterThan(whites.remap(7), 7 + 2)
        XCTAssertEqual(whites.remap(-3), -3)

        let blacks = ToneRanges(blacks: -1)
        XCTAssertLessThan(blacks.remap(-8), -8 - 2)
        XCTAssertEqual(blacks.remap(1), 1)
    }

    /// The kernel clamps t to the table's range, which is only exact if
    /// every combination is flat beyond it.
    func testTableCoversEveryChange() {
        let r = ToneRanges(highlights: 1, shadows: -1, whites: 0.7, blacks: -0.6)
        let lo = ToneRanges.lutRange.lowerBound, hi = ToneRanges.lutRange.upperBound
        XCTAssertEqual(r.remap(lo) - lo, r.remap(lo - 30) - (lo - 30), accuracy: 1e-4)
        XCTAssertEqual(r.remap(hi) - hi, r.remap(hi + 30) - (hi + 30), accuracy: 1e-4)
        let lut = r.lookupTable()
        XCTAssertEqual(lut.count, ToneRanges.lutSize)
        XCTAssertEqual(lut.first!, r.remap(lo) - lo, accuracy: 1e-5)
        XCTAssertEqual(lut.last!, r.remap(hi) - hi, accuracy: 1e-5)
    }

    // MARK: - Edit stack

    func testUntouchedEditsEncodeAsBefore() throws {
        let json = try EditStack(parameters: EditParameters()).encodeJSON()
        XCTAssertFalse(json.contains("toneranges"))
        XCTAssertFalse(json.contains("\"red\""))
        XCTAssertFalse(json.contains("\"green\""))
        XCTAssertFalse(json.contains("\"blue\""))
    }

    /// A sidecar written before these controls existed.
    func testOldStacksDecodeToNeutral() throws {
        let old = """
        {"modules":{"curve":{"points":[[0,0],[0.5,0.6],[1,1]]},"exposure":{"ev":0.5},\
        "highlights":{"strength":0.8,"threshold":0.85},\
        "tone":{"contrast":1.7,"grey":0.18,"method":"sigmoid"}},"process":"1.0","schema":1}
        """
        let stack = try EditStack.decode(json: old)
        let p = stack.parameters()
        XCTAssertTrue(p.toneRanges.isNeutral)
        XCTAssertTrue(p.channelCurves.isIdentity)
        XCTAssertEqual(p.toneCurve.points.count, 3)
        XCTAssertEqual(p.highlightRecovery, 0.8)
        // And saving it again changes nothing the old build would see.
        XCTAssertEqual(try EditStack(parameters: p).encodeJSON(),
                       try EditStack(parameters: EditStack.decode(json: EditStack(parameters: p).encodeJSON()).parameters()).encodeJSON())
        XCTAssertNil(EditStack(parameters: p).modules.toneranges)
        XCTAssertNil(EditStack(parameters: p).modules.curve?.red)
    }

    func testRoundTripsThroughJSON() throws {
        var p = EditParameters()
        p.toneRanges = ToneRanges(highlights: -0.6, shadows: 0.45, whites: 0.2, blacks: -0.35)
        p.channelCurves = RGBCurves(red: ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.6), SIMD2(1, 1)]),
                                    blue: ToneCurve(points: [SIMD2(0, 0.05), SIMD2(1, 0.95)]))
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"toneranges\""))
        XCTAssertTrue(json.contains("\"red\""))
        XCTAssertFalse(json.contains("\"green\""), "a straight channel isn't stored")
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back, p)
        XCTAssertFalse(EditStack.isDefault(p, relativeTo: EditParameters()))
    }

    func testPartialBlocksDecodeLeniently() throws {
        let json = """
        {"schema":1,"process":"1.0","modules":{"toneranges":{"shadows":0.3},
          "curve":{"points":[[0,0],[1,1]],"green":[[0,0.1]]}}}
        """
        let p = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(p.toneRanges, ToneRanges(shadows: 0.3))
        XCTAssertTrue(p.channelCurves.green.isIdentity, "a one-point curve is ignored")
    }

    func testCopyPasteGroupsCarryThem() {
        var source = EditParameters()
        source.toneRanges = ToneRanges(shadows: 0.5)
        source.channelCurves.blue = ToneCurve(points: [SIMD2(0, 0.1), SIMD2(1, 1)])
        let stack = EditStack(parameters: source)
        XCTAssertTrue(stack.presentGroups.contains(.tone))

        let toneOnly = EditStack(parameters: EditParameters()).merged(with: stack, groups: [.tone]).parameters()
        XCTAssertEqual(toneOnly.toneRanges, source.toneRanges)
        XCTAssertTrue(toneOnly.channelCurves.isIdentity)

        let curveOnly = EditStack(parameters: EditParameters()).merged(with: stack, groups: [.toneCurve]).parameters()
        XCTAssertEqual(curveOnly.channelCurves, source.channelCurves)
        XCTAssertTrue(curveOnly.toneRanges.isNeutral)

        let look = stack.restricted(to: EditGroup.lookGroups)
        XCTAssertEqual(look.parameters(), source)
    }

    func testHistoryNamesEachSlider() {
        let a = EditParameters()
        var b = a
        b.toneRanges.shadows = 0.4
        b.toneRanges.whites = -0.2
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: a), to: EditStack(parameters: b)),
                       "Shadows, Whites")
        var c = a
        c.highlightRecovery = 0.3
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: a), to: EditStack(parameters: c)),
                       "Highlight Recovery")
        var d = a
        d.channelCurves.red = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.6), SIMD2(1, 1)])
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: a), to: EditStack(parameters: d)), "Curve")
    }

    // MARK: - On a real image

    func testEffectsOnARealImage() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        func pixels(_ p: EditParameters) throws -> [Float] {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
            return try TextureReadback.float16Pixels(of: tex, gpu: gpu).map { Float($0) }
        }
        func luma(_ px: [Float], _ i: Int) -> Float { 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2] }

        let plain = try pixels(EditParameters())

        // Mean change of encoded luma over the pixels that start within
        // `range`. This frame is mostly dark and has little above 0.9.
        func shift(_ px: [Float], _ range: ClosedRange<Float>) -> Float {
            var total: Float = 0, count: Float = 0
            for i in stride(from: 0, to: px.count, by: 4) where range.contains(luma(plain, i)) {
                total += luma(px, i) - luma(plain, i); count += 1
            }
            return total / max(count, 1)
        }
        let deep: ClosedRange<Float> = 0...0.2, dark: ClosedRange<Float> = 0.2...0.5
        let bright: ClosedRange<Float> = 0.8...1

        // Zero is the untouched render, bit for bit.
        var zero = EditParameters()
        zero.toneRanges = ToneRanges(highlights: 0, shadows: 0, whites: 0, blacks: 0)
        zero.channelCurves = RGBCurves(red: .identity, green: .identity, blue: .identity)
        XCTAssertTrue(try pixels(zero) == plain)

        // The kernel path itself is an identity when it has next to nothing
        // to do: a straight three-point red curve and a vanishing shadows
        // amount run the new code without meaning to change anything.
        var nearZero = EditParameters()
        nearZero.toneRanges = ToneRanges(shadows: 1e-6)
        nearZero.channelCurves.red = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.5), SIMD2(1, 1)])
        let near = try pixels(nearZero)
        var worst: Float = 0
        for i in plain.indices { worst = max(worst, abs(near[i] - plain[i])) }
        XCTAssertLessThan(worst, 2e-3)

        var lift = EditParameters(); lift.toneRanges.shadows = 1
        let lifted = try pixels(lift)
        XCTAssertGreaterThan(shift(lifted, dark), 0.1, "Shadows +1 lifts the dark tones")
        XCTAssertEqual(shift(lifted, bright), 0, accuracy: 0.002, "and leaves the bright ones")

        var recover = EditParameters(); recover.toneRanges.highlights = -1
        let recovered = try pixels(recover)
        XCTAssertLessThan(shift(recovered, bright), -0.02, "Highlights -1 darkens the bright tones")
        XCTAssertEqual(shift(recovered, dark), 0, accuracy: 0.002, "and leaves the dark ones")

        var crush = EditParameters(); crush.toneRanges.blacks = -1
        let crushed = try pixels(crush)
        XCTAssertLessThan(shift(crushed, deep), -0.02, "Blacks -1 deepens the darkest tones")
        XCTAssertEqual(shift(crushed, bright), 0, accuracy: 0.002)

        // A red curve lifts red and leaves green and blue alone.
        var red = EditParameters()
        red.channelCurves.red = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.65), SIMD2(1, 1)])
        // In the working space's own primaries: an sRGB file would mix the
        // lifted red into all three of its channels.
        let linear2020 = RenderOutput(space: .rec2020, headroom: 1, encoded: false)
        let plain2020 = try TextureReadback.float16Pixels(
            of: pipeline.render(session, scale: .binned(quads: 4), parameters: EditParameters(), output: linear2020),
            gpu: gpu).map { Float($0) }
        let reddened = try TextureReadback.float16Pixels(
            of: pipeline.render(session, scale: .binned(quads: 4), parameters: red, output: linear2020),
            gpu: gpu).map { Float($0) }
        var redGain: Float = 0, otherChange: Float = 0
        for i in stride(from: 0, to: plain2020.count, by: 4) {
            redGain += reddened[i] - plain2020[i]
            otherChange = max(otherChange, abs(reddened[i + 1] - plain2020[i + 1]),
                              abs(reddened[i + 2] - plain2020[i + 2]))
        }
        XCTAssertGreaterThan(redGain / Float(plain2020.count / 4), 0.02)
        XCTAssertLessThan(otherChange, 2e-3)
    }
}
