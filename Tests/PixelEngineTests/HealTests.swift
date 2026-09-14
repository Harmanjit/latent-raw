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
        // their edges; a clone only its source.
        let reach = p.readRadiusPixels(sensorSize: s)
        XCTAssertGreaterThan(reach, 40 + 3 * 20)
        XCTAssertTrue(grown.contains(p.targetBounds(sensorSize: s).insetBy(dx: 40.5 - reach, dy: 40.5 - reach)))
        XCTAssertTrue(grown.contains(p.sourceBounds(sensorSize: s).insetBy(dx: 40.5 - reach, dy: 40.5 - reach)))
        var clone = p
        clone.mode = .clone
        XCTAssertEqual(clone.readRadiusPixels(sensorSize: s), 42, accuracy: 1e-4)
        // Patches read earlier ones: a patch whose source reads an earlier
        // patch's target pulls in that patch's source too.
        let earlier = HealPatch(target: [0.9, 0.9], source: [0.5, 0.1], radius: 0.02, mode: .clone)
        let chained = HealPatch.regionIncludingSources(region, patches: [earlier, p], sensorSize: s)
        XCTAssertTrue(chained.contains(earlier.sourceBounds(sensorSize: s)))
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
    func testClonePatchCopiesSourceAndLeavesRestAlone() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
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
