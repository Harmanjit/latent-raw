import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

final class HealTests: XCTestCase {
    func testRegionGrowsToIncludeSources() {
        let s = CGSize(width: 1000, height: 800)
        let p = HealPatch(target: [0.1, 0.1], source: [0.9, 0.9], radius: 0.05)
        let region = CGRect(x: 0, y: 0, width: 300, height: 300)
        let grown = HealPatch.regionIncludingSources(region, patches: [p], sensorSize: s)
        XCTAssertTrue(grown.contains(p.sourceBounds(sensorSize: s)))
        // A patch whose target is elsewhere doesn't grow the region.
        let far = HealPatch(target: [0.9, 0.1], source: [0.5, 0.5], radius: 0.05)
        XCTAssertEqual(HealPatch.regionIncludingSources(region, patches: [far], sensorSize: s), region)
        XCTAssertEqual(p.radiusPixels(sensorSize: s), 40, accuracy: 1e-4)
        // A heal also reads the surroundings of both circles, well past
        // their edges (as far as the sensor goes); a clone only its source.
        let reach = p.readRadiusPixels(sensorSize: s)
        XCTAssertGreaterThan(reach, 40 + 3 * 20)
        let sensor = CGRect(origin: .zero, size: s)
        XCTAssertTrue(grown.contains(p.targetBounds(sensorSize: s).insetBy(dx: 40.5 - reach, dy: 40.5 - reach).intersection(sensor)))
        XCTAssertTrue(grown.contains(p.sourceBounds(sensorSize: s).insetBy(dx: 40.5 - reach, dy: 40.5 - reach).intersection(sensor)))
        var clone = p
        clone.mode = .clone
        XCTAssertEqual(clone.readRadiusPixels(sensorSize: s), 42, accuracy: 1e-4)
        // Patches read earlier ones: a patch whose source reads an earlier
        // patch's target pulls in that patch's source too.
        let earlier = HealPatch(target: [0.9, 0.9], source: [0.5, 0.1], radius: 0.02, mode: .clone)
        let chained = HealPatch.regionIncludingSources(region, patches: [earlier, p], sensorSize: s)
        XCTAssertTrue(chained.contains(earlier.sourceBounds(sensorSize: s)))
    }

    /// Only patches that can change the region count. A later patch whose
    /// target lies where an earlier one reads can't change that read, so
    /// its source stays out; otherwise spots cleaned one after another
    /// across a sky chain the tile across the whole frame.
    func testRegionLeavesOutLaterPatchesAndChains() {
        let s = CGSize(width: 6000, height: 4000)
        let region = CGRect(x: 1000, y: 1800, width: 400, height: 400)
        // Each spot's source sits where the next spot is.
        let spots = (0..<6).map { i in
            HealPatch(target: [Float(1200 + 500 * i) / 6000, 0.5], source: [Float(1700 + 500 * i) / 6000, 0.5], radius: 0.02)
        }
        let grown = HealPatch.regionIncludingSources(region, patches: spots, sensorSize: s)
        XCTAssertTrue(grown.contains(spots[0].sourceBounds(sensorSize: s)))
        XCTAssertLessThan(grown.maxX, spots[1].sourceBounds(sensorSize: s).minX, "the next spot's source isn't read")
        // Its target is in the tile, reading outside it, so the tile beyond
        // the region isn't all healed as the frame is.
        XCTAssertFalse(HealPatch.isSelfContained(grown, patches: spots, sensorSize: s))
        // The same spots in the other order do read each other.
        let chained = HealPatch.regionIncludingSources(region, patches: spots.reversed(), sensorSize: s)
        XCTAssertTrue(chained.contains(spots[5].sourceBounds(sensorSize: s)))
        XCTAssertTrue(HealPatch.isSelfContained(chained, patches: spots.reversed(), sensorSize: s))
        XCTAssertTrue(HealPatch.isSelfContained(region, patches: [], sensorSize: s))
    }

    /// A heal's reach past the sensor edge adds no width: the render would
    /// otherwise keep the width and shift the tile further into the frame.
    func testRegionReachStopsAtTheSensor() {
        let s = CGSize(width: 6000, height: 4000)
        let big = HealPatch(target: [Float(700) / 6000, 0.5], source: [0.2, 0.5], radius: 0.15)
        XCTAssertGreaterThan(big.readRadiusPixels(sensorSize: s), 1300)
        let region = CGRect(x: 500, y: 1800, width: 400, height: 400)
        let grown = HealPatch.regionIncludingSources(region, patches: [big], sensorSize: s)
        XCTAssertEqual(grown.minX, 0)
        XCTAssertGreaterThanOrEqual(grown.minY, 0)
        XCTAssertLessThanOrEqual(grown.maxY, 4000)
        // The region asked for is kept as it is, off the sensor or not.
        let offEdge = CGRect(x: -128, y: 1800, width: 400, height: 400)
        XCTAssertEqual(HealPatch.regionIncludingSources(offEdge, patches: [big], sensorSize: s).minX, -128)
    }

    /// Tile planning runs over stage 5's whole list: a dust spot's source
    /// far from the view must be in the tile, or the tile heals it from
    /// nothing while the preview heals it from the source.
    func testRegionPlanningCoversDustAndBlemishesToo() {
        let s = CGSize(width: 6000, height: 4000)
        let region = CGRect(x: 1000, y: 1000, width: 400, height: 400)
        var p = EditParameters()
        p.dust = [HealPatch(target: [0.2, 0.3], source: [0.8, 0.8], radius: 0.003, feather: 0.5)]
        p.touchUp.blemishes = [HealPatch(target: [0.21, 0.3], source: [0.1, 0.9], radius: 0.002, feather: 0.5)]
        p.touchUp.blemishRemoval = true
        p.heals = [HealPatch(target: [0.22, 0.3], source: [0.9, 0.1], radius: 0.01)]
        let grown = HealPatch.regionIncludingSources(region, patches: p.allHealPatches, sensorSize: s)
        XCTAssertTrue(grown.contains(p.dust[0].sourceBounds(sensorSize: s)))
        XCTAssertTrue(grown.contains(p.touchUp.blemishes[0].sourceBounds(sensorSize: s)))
        XCTAssertTrue(grown.contains(p.heals[0].sourceBounds(sensorSize: s)))
        // Over the user's patches alone, as the sites used to plan, the
        // dust's source is left out.
        XCTAssertFalse(HealPatch.regionIncludingSources(region, patches: p.heals, sensorSize: s)
            .contains(p.dust[0].sourceBounds(sensorSize: s)))
        XCTAssertFalse(HealPatch.isSelfContained(region, patches: p.allHealPatches, sensorSize: s))
        XCTAssertTrue(HealPatch.isSelfContained(grown, patches: p.allHealPatches, sensorSize: s))
    }

    /// GPU: the stage no longer caps the list at 32. With 200 dust spots,
    /// 64 blemishes and 32 user patches, the 233rd (the first user patch)
    /// and the 296th change pixels like the first.
    func testStageHealsTheWholeConcatenatedList() throws {
        let gpu = try GPUContext()
        let w = 512, h = 384
        // Left half a dark flat, right half a light one: every target is
        // on the left and copies from the same spot on the right.
        let dark = SIMD3<Double>(0.2, 0.25, 0.3), light = SIMD3<Double>(0.8, 0.7, 0.6)
        let input = try HealQualityTests.texture(width: w, height: h, gpu: gpu) { x, _ in x < w / 2 ? dark : light }
        let size = SIMD2<Float>(Float(w), Float(h))
        func cell(_ i: Int) -> SIMD2<Float> {
            SIMD2(10 + Float(i % 12) * 20, 8 + Float(i / 12) * 15)
        }
        let patches = (0..<296).map { i in
            HealPatch(target: cell(i) / size, source: (cell(i) + SIMD2(256, 0)) / size,
                      radius: 5 / Float(min(w, h)), feather: 0, mode: .clone)
        }
        XCTAssertEqual(patches.count, HealPatch.maximumDustCount + HealPatch.maximumBlemishCount + HealPatch.maximumCount)
        let healed = try HealQualityTests.healed(input, patches: patches, sensorSize: size, gpu: gpu)
        func at(_ i: Int) -> SIMD3<Double> { healed(Int(cell(i).x), Int(cell(i).y)) }
        for i in [0, 31, 32, 199, 200, 232, 233, 295] {
            XCTAssertLessThan(simd_length(at(i) - light), 0.01, "patch \(i + 1) copied its source")
        }
        // Between the cells the left half is still dark.
        XCTAssertLessThan(simd_length(healed(20, 15) - dark), 0.01)
        XCTAssertLessThan(simd_length(healed(w / 2 + 10, 15) - light), 0.01)
    }

    func testEditStackRoundTrip() throws {
        var p = EditParameters()
        p.heals = [HealPatch(target: [0.2, 0.3], source: [0.4, 0.5], radius: 0.02, feather: 0.5, mode: .clone)]
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"heal\""))
        XCTAssertEqual(try EditStack.decode(json: json).parameters().heals, p.heals)
        XCTAssertNil(EditStack(parameters: EditParameters()).modules.heal)
        XCTAssertFalse(EditGroup.lookGroups.contains(.heal))
    }

    /// GPU, on the sample NEF: a clone patch makes the target look like
    /// the source, and leaves the rest of the frame alone. A heal patch
    /// on a uniform area is close to the original (it copies texture but
    /// matches the rim), which is the property that hides seams.
    ///
    /// Only on the private sample: its spots are chosen for that picture.
    /// On the golden raw the source lands on the ball's fine pattern, where
    /// one pixel of a copy isn't the same pixel of the source.
    func testClonePatchCopiesSourceAndLeavesRestAlone() throws {
        let path = TestAssets.path(TestAssets.privateSampleName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "needs \(TestAssets.privateSampleName)")
        let gpu = try GPUContext()
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        func render(_ p: EditParameters) throws -> (px: [Float16], w: Int, h: Int) {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .sceneLinear)
            return (try TextureReadback.float16Pixels(of: tex, gpu: gpu), tex.width, tex.height)
        }
        func at(_ r: (px: [Float16], w: Int, h: Int), _ n: SIMD2<Float>) -> SIMD3<Float> {
            let x = min(r.w - 1, Int(n.x * Float(r.w))), y = min(r.h - 1, Int(n.y * Float(r.h)))
            let i = (y * r.w + x) * 4
            return SIMD3(Float(r.px[i]), Float(r.px[i + 1]), Float(r.px[i + 2]))
        }
        func differ(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            simd_length(a - b) / max(simd_length(b), 1e-3)
        }

        let base = try render(EditParameters())
        // Find two spots that differ, so the copy is measurable.
        let target = SIMD2<Float>(0.3, 0.3), source = SIMD2<Float>(0.65, 0.6)
        let before = at(base, target), src = at(base, source), elsewhere = at(base, SIMD2(0.85, 0.2))

        var cloned = EditParameters()
        cloned.heals = [HealPatch(target: target, source: source, radius: 0.04, feather: 0.2, mode: .clone)]
        let after = try render(cloned)
        XCTAssertLessThan(differ(at(after, target), src), 0.05, "target now shows the source pixels")
        XCTAssertLessThan(differ(at(after, source), src), 1e-3, "source untouched")
        XCTAssertLessThan(differ(at(after, SIMD2(0.85, 0.2)), elsewhere), 1e-3, "far away untouched")
        if differ(before, src) > 0.1 {
            XCTAssertGreaterThan(differ(at(after, target), before), 0.05, "and it actually changed")
        }

        // Heal mode: the copied pixels are rescaled to the target rim, so
        // the patch centre's brightness lands near the target's own
        // neighbourhood rather than the source's.
        var healed = EditParameters()
        healed.heals = [HealPatch(target: target, source: source, radius: 0.04, feather: 0.2, mode: .heal)]
        let h = try render(healed)
        let healedCentre = at(h, target)
        let rim = at(base, target + SIMD2(0.033, 0))     // just inside the edge, on the original
        let clonedLuma = (at(after, target).x + at(after, target).y + at(after, target).z) / 3
        let healedLuma = (healedCentre.x + healedCentre.y + healedCentre.z) / 3
        let rimLuma = (rim.x + rim.y + rim.z) / 3
        XCTAssertLessThan(abs(healedLuma - rimLuma), abs(clonedLuma - rimLuma) + 1e-4,
                          "heal is at least as close to the rim as a plain clone")
    }
}
