import XCTest
import LensKit
import Metal
import simd
import PixelEngine
import RawCore
@testable import MergeKit
@testable import PixelEngine

/// Panorama frame preparation (MergePanoPrepKernels): the lens pass matches
/// its CPU twin, alpha is exactly 0 outside the photo, frames are turned
/// upright, and full resolution comes out the same however it is banded.
final class PanoPrepTests: XCTestCase {
    /// A barrel lens with vignetting and a little TCA, strong enough that the
    /// corrected corners read from outside the photo.
    static let lens = MergePanoPrepKernels.Lens(LensCorrection(
        distortion: .poly3(k1: 0.03), tca: TCAModel(red: SIMD3(0, 0, 1.002), blue: SIMD3(0, 0, 0.998)),
        vignetting: VignettingModel(k1: -0.35, k2: 0.05, k3: 0), cropRatio: 1, autoScale: 0.9, profileName: "test"))

    /// A summary for a linear source of this size and orientation (LibRaw's flip).
    private func summary(width: Int, height: Int, orientation: Int) throws -> RawSummary {
        let json: [String: Any] = [
            "width": width, "height": height, "leftMargin": 0, "topMargin": 0, "rawWidth": width, "rawHeight": height,
            "cfaCode": 0xFE, "cameraMultipliers": [2, 1, 1.5, 0], "blackLevel": 0, "whiteLevel": 1,
            "channelBlackLevels": [0, 0, 0, 0], "dataMaximum": 0, "baselineExposure": 0,
            "cameraMake": "Nikon", "cameraModel": "D750", "lensModel": "",
            "iso": 100, "shutter": 0.01, "aperture": 4, "focalLength": 50, "timestamp": 1_789_498_800,
            "orientation": orientation, "lensMake": "", "lensMakerNotesName": "",
            "makerLensID": 0, "nikonLensID": 0, "nikonLensType": 0, "minFocal": 0, "maxFocal": 0,
            "maxApertureAtMinFocal": 0, "maxApertureAtMaxFocal": 0, "cropFactor": 0,
            "thumbnailError": 0, "isMetadataOnly": true, "planeSampleCount": 0,
        ]
        return try JSONDecoder().decode(RawSnapshotMetadata.self, from: JSONSerialization.data(withJSONObject: json)).summary
    }

    /// Smooth, distinct values per channel, so a misplaced read shows.
    private static func pattern(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let fx = Float(x), fy = Float(y)
        return SIMD3(0.5 + 0.4 * sin(fx / 9.3) * cos(fy / 7.1), 0.5 + 0.4 * cos(fx / 11.7 + fy / 13.1),
                     0.3 + 0.2 * sin((fx + 2 * fy) / 15.3))
    }

    private func linearSource(width: Int, height: Int, orientation: Int) throws -> RawFile {
        let reference = try summary(width: width, height: height, orientation: orientation)
        return try XCTUnwrap(RawFile.linearSource(width: width, height: height, like: reference, cameraToXYZ: nil,
                                                  baselineExposure: 0, mergeInfo: nil, fill: { plane in
            for y in 0..<height {
                for x in 0..<width {
                    let v = Self.pattern(x, y), i = 4 * (y * width + x)
                    plane[i] = Float16(v.x); plane[i + 1] = Float16(v.y); plane[i + 2] = Float16(v.z); plane[i + 3] = 1
                }
            }
        }))
    }

    /// A shared rgba16Float texture's pixels as Float32.
    private func readBack(_ texture: MTLTexture, gpu: GPUContext) throws -> [Float] {
        XCTAssertEqual(texture.storageMode, .shared)
        var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&halves, bytesPerRow: texture.width * 8,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return halves.map { Float($0) }
    }

    /// Bilinear read of a `width x height` RGB function at texel coordinates
    /// (centres at i + 0.5), edges repeated: the kernel's sampling.
    private func bilinear(_ value: (Int, Int) -> SIMD3<Float>, width: Int, height: Int, _ q: SIMD2<Double>) -> SIMD3<Float> {
        let p = q - 0.5
        let ix = Int(p.x.rounded(.down)), iy = Int(p.y.rounded(.down))
        let fx = Float(p.x - Double(ix)), fy = Float(p.y - Double(iy))
        let x0 = min(max(ix, 0), width - 1), x1 = min(max(ix + 1, 0), width - 1)
        let y0 = min(max(iy, 0), height - 1), y1 = min(max(iy + 1, 0), height - 1)
        let top = (1 - fx) * value(x0, y0) + fx * value(x1, y0)
        let bottom = (1 - fx) * value(x0, y1) + fx * value(x1, y1)
        return (1 - fy) * top + fy * bottom
    }

    /// Checks every texel of a prepared frame against the CPU twin of the
    /// lens pass. `sourceValue` reads the source grid the kernel samples
    /// (the plane itself at span 1, its block means otherwise).
    private func checkPrepared(_ pixels: [Float], width: Int, height: Int, span: Int,
                               orientation: MergePanoPrepKernels.Orientation,
                               sourceValue: (Int, Int) -> SIMD3<Float>, sourceWidth: Int, sourceHeight: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        let lens = Self.lens
        let sw = orientation.sensorWidth, sh = orientation.sensorHeight
        var outside = 0, inside = 0, worst: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = 4 * (y * width + x)
                let upright = SIMD2((Double(x) + 0.5) * Double(span), (Double(y) + 0.5) * Double(span))
                let sensor = orientation.sensorPoint(uprightPoint: upright)
                let reads = lens.sourcePoints(sensorPoint: sensor, sensorWidth: sw, sensorHeight: sh)
                let g = reads.green
                // Well away from the photo's edge both ways, so rounding
                // can't decide the test.
                let margin = 0.01
                let clearlyOutside = g.x < -margin || g.y < -margin || g.x > Double(sw) + margin || g.y > Double(sh) + margin
                let clearlyInside = g.x > margin && g.y > margin && g.x < Double(sw) - margin && g.y < Double(sh) - margin
                if clearlyOutside {
                    outside += 1
                    XCTAssertEqual(pixels[i + 3], 0, "alpha outside at \(x), \(y)", file: file, line: line)
                    XCTAssertEqual(max(pixels[i], pixels[i + 1], pixels[i + 2]), 0, "colour outside", file: file, line: line)
                } else if clearlyInside {
                    inside += 1
                    XCTAssertEqual(pixels[i + 3], 1, "alpha inside at \(x), \(y)", file: file, line: line)
                    let gain = Float(lens.vignettingGain(sensorPoint: sensor, sensorWidth: sw, sensorHeight: sh))
                    let s = Double(span)
                    let green = bilinear(sourceValue, width: sourceWidth, height: sourceHeight, g / s)
                    let red = bilinear(sourceValue, width: sourceWidth, height: sourceHeight, reads.red / s)
                    let blue = bilinear(sourceValue, width: sourceWidth, height: sourceHeight, reads.blue / s)
                    let expected = SIMD3(red.x, green.y, blue.z) * gain
                    let got = SIMD3(pixels[i], pixels[i + 1], pixels[i + 2])
                    worst = max(worst, simd_reduce_max(simd_abs(got - expected)))
                }
            }
        }
        XCTAssertGreaterThan(outside, 0, "the corrected corners must read from outside the photo", file: file, line: line)
        XCTAssertGreaterThan(inside, width * height / 2, file: file, line: line)
        // Half-float storage and single-precision maths: a few thousandths.
        XCTAssertLessThan(worst, 4e-3, "largest colour difference from the CPU twin", file: file, line: line)
    }

    func testLensPassMatchesItsTwinWithAlphaZeroOutsideAndTurnsUpright() throws {
        let gpu = try HDRTestSupport.gpu()
        let kernels = MergePanoPrepKernels(gpu: gpu)
        let (w, h) = (300, 200)
        for flip in [0, 6, 5] {
            let file = try linearSource(width: w, height: h, orientation: flip)
            let orientation = MergePanoPrepKernels.Orientation(summary: file.summary)
            for span in [1, 2, 3] {
                // Span 1 in small windows, so several bands are exercised.
                let texture = try kernels.prepare(.linear(file, clipLevel: 1), span: span, lens: Self.lens,
                                                  storage: .shared, windowPixelBudget: 20_000)
                let size = MergePanoPrepKernels.preparedSize(orientation, span: span)
                XCTAssertEqual(texture.width, size.width)
                XCTAssertEqual(texture.height, size.height)
                XCTAssertEqual(size.width, (flip == 0 ? w : h) / span, "upright width")
                let pixels = try readBack(texture, gpu: gpu)
                let binnedW = (w + span - 1) / span, binnedH = (h + span - 1) / span
                checkPrepared(pixels, width: texture.width, height: texture.height, span: span, orientation: orientation,
                              sourceValue: { bx, by in
                                  // The linear box mean of a span x span block.
                                  var sum = SIMD3<Float>.zero, count: Float = 0
                                  for y in (by * span)..<min((by + 1) * span, h) {
                                      for x in (bx * span)..<min((bx + 1) * span, w) {
                                          let v = Self.pattern(x, y)
                                          sum += SIMD3(Float(Float16(v.x)), Float(Float16(v.y)), Float(Float16(v.z)))
                                          count += 1
                                      }
                                  }
                                  return sum / count
                              }, sourceWidth: binnedW, sourceHeight: binnedH)
            }
        }
    }

    func testWithoutALensEveryTexelIsCoveredAndUnchanged() throws {
        let gpu = try HDRTestSupport.gpu()
        let kernels = MergePanoPrepKernels(gpu: gpu)
        let file = try linearSource(width: 64, height: 48, orientation: 3)
        let texture = try kernels.prepare(.linear(file, clipLevel: 1), span: 1, lens: nil, storage: .shared,
                                          windowPixelBudget: 1_000)
        let pixels = try readBack(texture, gpu: gpu)
        for y in 0..<48 {
            for x in 0..<64 {
                // Turned 180°: upright (x, y) is sensor (63 - x, 47 - y).
                let v = Self.pattern(63 - x, 47 - y), i = 4 * (y * 64 + x)
                XCTAssertEqual(pixels[i + 3], 1)
                XCTAssertEqual(pixels[i], Float(Float16(v.x)), accuracy: 1e-3)
                XCTAssertEqual(pixels[i + 2], Float(Float16(v.z)), accuracy: 1e-3)
            }
        }
    }

    func testBandPlanWindowsHoldEveryReadAndShareOneSize() {
        let d750Lens = MergePanoPrepKernels.Lens(LensCorrection(distortion: .ptlens(a: 0.01, b: -0.03, c: 0.02),
                                                                cropRatio: 1))
        for rotation in [ImageRotation.none, .cw90, .cw270] {
            let orientation = MergePanoPrepKernels.Orientation(rotation: rotation, sensorWidth: 6016, sensorHeight: 4016)
            let plan = MergePanoPrepKernels.bandPlan(orientation: orientation, lens: d750Lens, pixelBudget: 2_000_000)
            XCTAssertGreaterThan(plan.bands.count, 2)
            // One window's RCD scratch stays near the budget, whatever the band.
            XCTAssertLessThanOrEqual(plan.windowWidth * plan.windowHeight, 2_000_000 * 5 / 4, "\(rotation)")
            XCTAssertEqual(plan.bands.first?.rows.lowerBound, 0)
            XCTAssertEqual(plan.bands.last?.rows.upperBound, orientation.uprightHeight)
            XCTAssertEqual((6016 - plan.windowWidth) % 2, 0, "the window can reach the far edge from an even origin")
            XCTAssertEqual((4016 - plan.windowHeight) % 2, 0)
            for (k, band) in plan.bands.enumerated() {
                if k > 0 { XCTAssertEqual(band.rows.lowerBound, plan.bands[k - 1].rows.upperBound) }
                XCTAssertEqual(band.windowX % 2, 0)
                XCTAssertEqual(band.windowY % 2, 0)
                XCTAssertLessThanOrEqual(band.windowX + plan.windowWidth, 6016)
                XCTAssertLessThanOrEqual(band.windowY + plan.windowHeight, 4016)
                // Every read of the band's rows, on a fine grid, inside its
                // window (clamped to the sensor), with RCD's margin kept
                // wherever the window's edge isn't the sensor's.
                for y in stride(from: band.rows.lowerBound, to: band.rows.upperBound, by: 7) {
                    for x in stride(from: 0, to: orientation.uprightWidth, by: 37) {
                        let sensor = orientation.sensorPoint(uprightPoint: SIMD2(Double(x) + 0.5, Double(y) + 0.5))
                        let p = simd_clamp(d750Lens.sourcePoints(sensorPoint: sensor, sensorWidth: 6016,
                                                                 sensorHeight: 4016).green,
                                           SIMD2(0, 0), SIMD2(6016, 4016))
                        let lo = SIMD2(Double(band.windowX), Double(band.windowY))
                        let hi = lo + SIMD2(Double(plan.windowWidth), Double(plan.windowHeight))
                        let margin = 11.0
                        XCTAssertTrue(p.x >= (lo.x == 0 ? 0 : lo.x + margin) && p.x <= (hi.x == 6016 ? 6016 : hi.x - margin)
                                      && p.y >= (lo.y == 0 ? 0 : lo.y + margin)
                                      && p.y <= (hi.y == 4016 ? 4016 : hi.y - margin),
                                      "\(rotation) band \(k) reads \(p) outside \(lo)-\(hi)")
                    }
                }
            }
        }
    }

    /// The golden D750 NEF (in CI): prepared at full resolution in small and
    /// large bands, and reduced, the frames agree.
    func testGoldenNEFPreparesTheSameInAnyBandsAndMatchesItsReducedCopy() throws {
        let url = AlignTestSupport.assets.appendingPathComponent("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "golden NEF missing")
        let gpu = try HDRTestSupport.gpu()
        let kernels = MergePanoPrepKernels(gpu: gpu)
        let file = try RawFile(path: url.path)
        let levels = try HDRMerger.levels(for: file, gpu: gpu)
        let multipliers = SIMD3<Float>(2.0, 1, 1.4)
        let source = MergePanoPrepKernels.Source.bayer(file, levels: levels, multipliers: multipliers)
        let lens = MergePanoPrepKernels.Lens.profile(for: file.summary) ?? Self.lens
        let small = try readBack(try kernels.prepare(source, span: 1, lens: lens, storage: .shared,
                                                     windowPixelBudget: 1_500_000), gpu: gpu)
        let large = try kernels.prepare(source, span: 1, lens: lens, storage: .shared, windowPixelBudget: 100_000_000)
        let largePixels = try readBack(large, gpu: gpu)
        var worst: Float = 0, uncovered = 0
        // Every 13th pixel: tests run unoptimised, and 24 MP is a lot of loop.
        for i in stride(from: 0, to: small.count, by: 4 * 13) {
            worst = max(worst, abs(small[i] - largePixels[i]), abs(small[i + 1] - largePixels[i + 1]),
                        abs(small[i + 2] - largePixels[i + 2]))
            XCTAssertEqual(small[i + 3], largePixels[i + 3])
            if small[i + 3] == 0 { uncovered += 1 }
        }
        XCTAssertLessThan(worst, 1e-3, "bands of different sizes must give the same frame")

        // The reduced frame (block means, no demosaic) against the full one
        // box-averaged: the same picture, within demosaicing's differences.
        let span = 4
        let reduced = try readBack(try kernels.prepare(source, span: span, lens: lens, storage: .shared), gpu: gpu)
        let rw = large.width / span, rh = large.height / span
        var difference = 0.0, total = 0.0
        for y in stride(from: 0, to: rh, by: 5) {
            for x in stride(from: 0, to: rw, by: 5) {
                var sum = 0.0, covered = true
                for dy in 0..<span {
                    for dx in 0..<span {
                        let i = 4 * ((y * span + dy) * large.width + x * span + dx)
                        sum += Double(largePixels[i + 1])
                        if largePixels[i + 3] == 0 { covered = false }
                    }
                }
                let i = 4 * (y * rw + x)
                guard covered, reduced[i + 3] == 1 else { continue }
                difference += abs(Double(reduced[i + 1]) - sum / Double(span * span))
                total += sum / Double(span * span)
            }
        }
        XCTAssertLessThan(difference / total, 0.03, "reduced and full-resolution frames must agree")
        print("pano-prep | golden NEF: bands agree within \(worst), \(uncovered) uncovered texels, "
              + "reduced vs full \(difference / total), lens \(lens.profileName)")
    }
}
