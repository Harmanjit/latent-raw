import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

final class PresenceTests: XCTestCase {
    let sensor = CGSize(width: 6000, height: 4000)

    func testPerspectiveIdentityAndDirection() {
        let none = PerspectiveCorrection()
        XCTAssertTrue(none.isIdentity)
        let p = CGPoint(x: 1000, y: 500)
        let same = none.sourcePoint(forSensorPoint: p, sensorSize: sensor)
        XCTAssertEqual(same.x, 1000, accuracy: 1e-3); XCTAssertEqual(same.y, 500, accuracy: 1e-3)

        // Positive vertical widens the top: an output pixel near the top-left
        // corner reads from closer to the centre line than where it sits.
        let v = PerspectiveCorrection(vertical: 0.6)
        let topLeft = v.sourcePoint(forSensorPoint: CGPoint(x: 500, y: 200), sensorSize: sensor)
        XCTAssertGreaterThan(topLeft.x, 500, "source is nearer the centre (x=3000)")
        let bottomLeft = v.sourcePoint(forSensorPoint: CGPoint(x: 500, y: 3800), sensorSize: sensor)
        XCTAssertLessThan(bottomLeft.x, 500, "bottom is squeezed the other way")
        // The centre never moves.
        let c = v.sourcePoint(forSensorPoint: CGPoint(x: 3000, y: 2000), sensorSize: sensor)
        XCTAssertEqual(c.x, 3000, accuracy: 1e-3); XCTAssertEqual(c.y, 2000, accuracy: 1e-3)

        let r = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertTrue(v.sourceRect(forSensorRect: r, sensorSize: sensor).contains(r))
    }

    func testEditStackRoundTripAndGroups() throws {
        var p = EditParameters()
        p.texture = 0.3; p.clarity = -0.2; p.dehaze = 0.5; p.vibrance = 0.4
        p.defringePurple = 0.7; p.defringeGreen = 0.1
        p.perspective = PerspectiveCorrection(vertical: 0.25, horizontal: -0.1)
        let json = try EditStack(parameters: p).encodeJSON()
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back, p)
        XCTAssertNil(EditStack(parameters: EditParameters()).modules.presence)

        let stack = EditStack(parameters: p)
        XCTAssertTrue(EditGroup.lookGroups.contains(.presence))
        XCTAssertEqual(stack.presentGroups.intersection([.presence, .colour, .lens, .crop]),
                       [.presence, .colour, .lens, .crop])
        // Vibrance rides with colour; perspective with crop; defringe with lens.
        let onlyColour = EditStack().merged(with: stack, groups: [.colour]).parameters()
        XCTAssertEqual(onlyColour.vibrance, 0.4)
        XCTAssertEqual(onlyColour.texture, 0)
        XCTAssertTrue(onlyColour.perspective.isIdentity)
        let onlyCrop = EditStack().merged(with: stack, groups: [.crop]).parameters()
        XCTAssertEqual(onlyCrop.perspective.vertical, 0.25)
    }

    /// GPU, on the sample NEF: each control moves the statistic it is
    /// meant to move, and zero settings reproduce the baseline exactly.
    func testControlsMoveTheRightStatistics() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        struct Stats { var mean: Float; var stdDev: Float; var meanSat: Float; var meanDark: Float; var highFreq: Float }
        func stats(_ p: EditParameters) throws -> ([Float16], Stats) {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            let w = tex.width, h = tex.height
            var sumL: Float = 0, sumL2: Float = 0, sumS: Float = 0, sumD: Float = 0, hf: Float = 0
            var n: Float = 0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = (y * w + x) * 4
                    let r = Float(px[i]), g = Float(px[i + 1]), b = Float(px[i + 2])
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let mx = max(r, g, b), mn = min(r, g, b)
                    sumL += l; sumL2 += l * l; sumS += mx > 1e-4 ? (mx - mn) / mx : 0; sumD += mn
                    let j = (y * w + x + 1) * 4
                    let ln = 0.2126 * Float(px[j]) + 0.7152 * Float(px[j + 1]) + 0.0722 * Float(px[j + 2])
                    hf += abs(l - ln)
                    n += 1
                }
            }
            let mean = sumL / n
            return (px, Stats(mean: mean, stdDev: (sumL2 / n - mean * mean).squareRoot(),
                              meanSat: sumS / n, meanDark: sumD / n, highFreq: hf / n))
        }

        let (basePx, base) = try stats(EditParameters())
        var zero = EditParameters()
        zero.defringePurple = 0; zero.texture = 0
        XCTAssertEqual(try stats(zero).0, basePx, "all-zero presence is a no-op")

        var clarity = EditParameters(); clarity.clarity = 1
        XCTAssertGreaterThan(try stats(clarity).1.stdDev, base.stdDev * 1.02, "clarity adds local contrast")
        var negClarity = EditParameters(); negClarity.clarity = -1
        XCTAssertLessThan(try stats(negClarity).1.stdDev, base.stdDev, "negative clarity softens")

        var texture = EditParameters(); texture.texture = 1
        XCTAssertGreaterThan(try stats(texture).1.highFreq, base.highFreq * 1.02, "texture adds fine detail")

        var dehaze = EditParameters(); dehaze.dehaze = 0.8
        XCTAssertLessThan(try stats(dehaze).1.meanDark, base.meanDark, "dehaze deepens the dark channel")

        var vibrance = EditParameters(); vibrance.vibrance = 1
        XCTAssertGreaterThan(try stats(vibrance).1.meanSat, base.meanSat * 1.05, "vibrance adds saturation")
        var dull = EditParameters(); dull.vibrance = -1
        XCTAssertLessThan(try stats(dull).1.meanSat, base.meanSat * 0.2, "−1 vibrance is near grey")

        var defringe = EditParameters(); defringe.defringePurple = 1; defringe.defringeGreen = 1
        let (dfPx, df) = try stats(defringe)
        XCTAssertLessThanOrEqual(df.meanSat, base.meanSat, "defringe never adds colour")
        XCTAssertEqual(df.mean, base.mean, accuracy: 0.002, "and barely touches brightness")
        XCTAssertNotEqual(dfPx, basePx)

        var keystone = EditParameters(); keystone.perspective = PerspectiveCorrection(vertical: 0.5)
        let (kPx, _) = try stats(keystone)
        XCTAssertNotEqual(kPx, basePx, "perspective moves pixels")
        // The centre pixel is a fixed point of the homography (up to interpolation).
        let w = Int(Double(file.summary.rawWidth) / 8), h = Int(Double(file.summary.rawHeight) / 8)
        let ci = ((h / 2) * w + w / 2) * 4
        XCTAssertEqual(Float(kPx[ci + 1]), Float(basePx[ci + 1]), accuracy: 0.03)
    }
}
