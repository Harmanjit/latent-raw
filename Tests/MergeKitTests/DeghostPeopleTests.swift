import XCTest
import PixelEngine
import RawCore
@testable import MergeKit

/// Deghosting a person-like shape walking through a bracket: a tall body
/// with a head, moving less than its own width between frames, so its poses
/// overlap as a walking person's do. Whatever else happens, the merge must
/// show the shape as one frame saw it, never a blend of poses (translucent)
/// or a patchwork of them (two heads).
final class DeghostPeopleTests: XCTestCase {
    static let width = 640, height = 400
    /// A grey wall, well exposed in all three frames (exposures 4, 1, 1/4).
    static let wall = SIMD3<Float>(repeating: 0.08)
    /// The body's left edge in each frame, its top and its size; the head
    /// sits centred on top of it.
    static let bodyColumns = [180, 200, 220]
    static let bodyTop = 180, bodyWidth = 48, bodyHeight = 160
    static let headSize = 24

    /// The wall with a strip of neutral steps above it, so the analysis has
    /// more than one brightness to measure the exposures on.
    static func scene() -> SyntheticBracket.Scene {
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let value = y < 100 ? SIMD3<Float>(repeating: Float(pow(2, -7 + 6 * Double(x) / Double(width))))
                    : wall
                let i = (y * width + x) * 3
                rgb[i] = value.x; rgb[i + 1] = value.y; rgb[i + 2] = value.z
            }
        }
        return SyntheticBracket.Scene(width: width, height: height, rgb: rgb)
    }

    /// A three-frame bracket (reference: the middle frame) with the shape in
    /// `colour` at `bodyColumns[i]` in frame i, with noise. The frames are
    /// merged without Auto Align: a plain wall has too little detail to
    /// align, and the brightest frame would be left out.
    static func walkingBracket(_ name: String, colour: SIMD3<Float>, folder: URL) throws -> [URL] {
        var frames = SyntheticBracket.frames(HDRTestSupport.threeExposures)
        for i in frames.indices {
            let x = bodyColumns[i]
            frames[i].patches = [
                SyntheticBracket.Patch(x: x, y: bodyTop, width: bodyWidth, height: bodyHeight, radiance: colour),
                SyntheticBracket.Patch(x: x + (bodyWidth - headSize) / 2, y: bodyTop - headSize - 2,
                                       width: headSize, height: headSize, radiance: colour),
            ]
        }
        return try SyntheticBracket.write(frames, of: scene(), noise: true, to: folder, name: name)
    }

    /// Column ranges of the body, 4 px clear of every pose's edges: only
    /// frame 0's pose, frames 0 and 1, frames 1 and 2, only frame 2's.
    static let strips: [(columns: Range<Int>, poses: Set<Int>)] = [
        (184..<196, [0]), (204..<216, [0, 1]), (232..<244, [1, 2]), (252..<264, [2]),
    ]

    /// Per strip, where the merged value lies between the wall (0) and the
    /// shape (1), by `measure` (a log quantity that tells them apart),
    /// averaged over the body's height 10 px in from its ends.
    static func positions(_ merged: HDRTestSupport.Merged, colour: SIMD3<Float>,
                          measure: (SIMD3<Double>) -> Double) -> [Double] {
        let wallValue = measure(SyntheticBracket.mergeUnits(wall, brightest: 4))
        let shapeValue = measure(SyntheticBracket.mergeUnits(colour, brightest: 4))
        return strips.map { strip in
            var sum = SIMD3<Double>(), count = 0.0
            for y in (bodyTop + 10)..<(bodyTop + bodyHeight - 10) {
                for x in strip.columns {
                    sum += SIMD3<Double>(merged.pixel(x, y))
                    count += 1
                }
            }
            return (measure(sum / count) - wallValue) / (shapeValue - wallValue)
        }
    }

    /// The frame whose view of the shape `positions` shows, or nil if they
    /// match no single frame: every strip must be clearly wall (under 0.1)
    /// or clearly shape (over 0.9), in the pattern one frame has.
    static func frameShown(_ positions: [Double]) -> Int? {
        guard positions.allSatisfy({ $0 < 0.1 || $0 > 0.9 }) else { return nil }
        let shape = Set(strips.indices.filter { positions[$0] > 0.9 })
        return (0..<3).first { frame in shape == Set(strips.indices.filter { strips[$0].poses.contains(frame) }) }
    }

    /// A beige figure exactly as bright as the grey wall behind it: its
    /// red, green and blue average the wall's, so brightness alone can't see
    /// it move. Its colour can (red over green is 0.46 stops up, blue over
    /// green 0.68 down), and at medium it comes from the reference frame
    /// alone. Without deghosting the three poses blend.
    func testSameBrightnessDifferentColourFigureComesFromOneFrame() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let beige = SIMD3<Float>(0.11, 0.08, 0.05)
        XCTAssertEqual((beige.x + beige.y + beige.z) / 3, Self.wall.x, accuracy: 1e-6, "as bright as the wall")
        let urls = try Self.walkingBracket("beige", colour: beige, folder: folder)
        let redOverBlue = { (value: SIMD3<Double>) in log2(max(value.x, 1e-9) / max(value.z, 1e-9)) }

        let (_, result, report, output) = try await HDRTestSupport.merge(
            urls, options: HDRMergeOptions(referenceIndex: 1, deghost: .medium, autoAlign: false))
        defer { try? FileManager.default.removeItem(at: output) }
        let positions = Self.positions(try HDRTestSupport.readBack(result.url), colour: beige, measure: redOverBlue)
        print("Beige figure at medium: \(positions), masked \(report.ghostMaskedFractions)")
        XCTAssertEqual(Self.frameShown(positions), 1, "the reference frame's pose alone: \(positions)")

        let (_, plain, _, plainOutput) = try await HDRTestSupport.merge(urls, options: HDRMergeOptions(referenceIndex: 1, autoAlign: false))
        defer { try? FileManager.default.removeItem(at: plainOutput) }
        let blended = Self.positions(try HDRTestSupport.readBack(plain.url), colour: beige, measure: redOverBlue)
        XCTAssertNil(Self.frameShown(blended), "without deghosting the poses blend: \(blended)")
    }

    /// A dark figure, nearly black in the reference frame (under the counts
    /// deghosting trusts), so the frame that sees it best changes from its
    /// middle (the brightest frame) to its surroundings (the reference).
    /// Chosen block by block, that made a patchwork of poses; chosen for the
    /// whole moving area, the figure appears exactly once, as one frame saw
    /// it, at every amount.
    func testDarkFigureAppearsExactlyOnce() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dark = SIMD3<Float>(repeating: 0.0015)
        let urls = try Self.walkingBracket("dark", colour: dark, folder: folder)
        let brightness = { (value: SIMD3<Double>) in log2(max((value.x + value.y + value.z) / 3, 1e-9)) }
        let merger = try HDRTestSupport.merger()
        for amount in [DeghostAmount.low, .medium, .high] {
            let (_, result, report, output) = try await HDRTestSupport.merge(
                urls, merger: merger, options: HDRMergeOptions(referenceIndex: 1, deghost: amount, autoAlign: false))
            defer { try? FileManager.default.removeItem(at: output) }
            let positions = Self.positions(try HDRTestSupport.readBack(result.url), colour: dark, measure: brightness)
            print("Dark figure at \(amount): \(positions), masked \(report.ghostMaskedFractions)")
            XCTAssertNotNil(Self.frameShown(positions), "\(amount): one pose, whole: \(positions)")
        }
    }
}
