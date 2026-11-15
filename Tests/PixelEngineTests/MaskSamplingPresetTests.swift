import XCTest
import simd
@testable import PixelEngine

/// Multi-sample Pick Range's union of samples (MaskRangeSampling.swift)
/// and mask presets' capture, round trip and store (MaskPresets.swift).
final class MaskSamplingPresetTests: XCTestCase {
    private let feathers = MaskRangeBand(low: 0.4, high: 0.6, featherLow: 0.05, featherHigh: 0.2)

    // MARK: - Range union

    func testOnePointMatchesTheSingleClickBand() {
        let set = MaskRangeSampleSet(samples: [.point(0.5, at: SIMD2(0.1, 0.1))])
        let band = try! XCTUnwrap(set.band(keepingFeathersOf: feathers))
        let single = MaskRangeBand.around(0.5, feather: 0.05)
        XCTAssertEqual(band.low, single.low, accuracy: 1e-6)
        XCTAssertEqual(band.high, single.high, accuracy: 1e-6)
        XCTAssertEqual(band.featherLow, 0.05)
        XCTAssertEqual(band.featherHigh, 0.2, "the fades are kept as they were")
    }

    func testTheBandGrowsToCoverEverySample() {
        var set = MaskRangeSampleSet(samples: [.point(0.3, at: SIMD2(0.1, 0.1))])
        set.samples.append(.point(0.7, at: SIMD2(0.9, 0.9)))
        set.samples.append(try! XCTUnwrap(MaskRangeSample.region([0.45, 0.5, 0.55], at: SIMD2(0.5, 0.5))))
        let band = try! XCTUnwrap(set.band(keepingFeathersOf: feathers))
        XCTAssertEqual(band.low, 0.2, accuracy: 1e-6)
        XCTAssertEqual(band.high, 0.8, accuracy: 1e-6)
        for sample in set.samples {
            XCTAssertLessThanOrEqual(band.low, sample.low + 1e-6)
            XCTAssertGreaterThanOrEqual(band.high, sample.high - 1e-6)
        }
    }

    func testTheBaseIsGrownNotReplaced() {
        let base = MaskRangeBand(low: 0.1, high: 0.2, featherLow: 0.1, featherHigh: 0.1)
        let set = MaskRangeSampleSet(base: base, samples: [.point(0.8, at: SIMD2(0.5, 0.5))])
        let band = try! XCTUnwrap(set.band(keepingFeathersOf: base))
        XCTAssertEqual(band.low, 0.1, accuracy: 1e-6)
        XCTAssertEqual(band.high, 0.9, accuracy: 1e-6)
    }

    func testPointSamplesStayInsideZeroToOne() {
        let set = MaskRangeSampleSet(samples: [.point(0.02, at: .zero), .point(0.99, at: SIMD2(1, 1))])
        let band = try! XCTUnwrap(set.band(keepingFeathersOf: feathers))
        XCTAssertEqual(band.low, 0)
        XCTAssertEqual(band.high, 1)
    }

    func testRemoveNearestTakesTheClosestSampleAndRefits() {
        var set = MaskRangeSampleSet(samples: [
            .point(0.2, at: SIMD2(0.1, 0.1)), .point(0.5, at: SIMD2(0.5, 0.5)), .point(0.9, at: SIMD2(0.9, 0.9)),
        ])
        let removed = set.removeNearest(to: SIMD2(0.85, 0.8))
        XCTAssertEqual(removed?.position, SIMD2(0.9, 0.9))
        let band = try! XCTUnwrap(set.band(keepingFeathersOf: feathers))
        XCTAssertEqual(band.low, 0.1, accuracy: 1e-6)
        XCTAssertEqual(band.high, 0.6, accuracy: 1e-6)
        set.samples.removeAll()
        XCTAssertNil(set.removeNearest(to: .zero), "nothing to take away")
        XCTAssertNil(set.band(keepingFeathersOf: feathers), "an empty set makes no band")
    }

    func testNearestUsesSensorPixelsNotNormalisedUnits() {
        // On a 3:1 frame, 0.1 across is three times as far as 0.1 down.
        let set = MaskRangeSampleSet(samples: [.point(0.2, at: SIMD2(0.6, 0.5)), .point(0.8, at: SIMD2(0.5, 0.65))])
        XCTAssertEqual(set.nearestIndex(to: SIMD2(0.5, 0.5)), 0, "square units: the first is nearer")
        XCTAssertEqual(set.nearestIndex(to: SIMD2(0.5, 0.5), aspect: SIMD2(3000, 1000)), 1)
    }

    func testColourNearestSample() {
        let range = ColourRange(samples: [ColourSample(hue: 0, saturation: 0.8), ColourSample(hue: 120, saturation: 0.8)])
        XCTAssertEqual(range.nearestSampleIndex(to: ColourSample(hue: 110, saturation: 0.7)), 1)
        XCTAssertNil(ColourRange().nearestSampleIndex(to: ColourSample(hue: 0, saturation: 0)))
    }

    // MARK: - Presets

    private func sampleMask() -> LocalAdjustment {
        var local = LocalAdjustment(name: "Sky", shape: .linear(start: SIMD2(0.5, 0), end: SIMD2(0.5, 0.4)),
                                    exposureEV: -0.7, saturation: 0.2)
        local.dehaze = 0.3
        local.hidden = true
        local.components = [
            MaskComponent(mode: .add, source: .shape(.brush(strokes: [
                BrushStroke(points: [SIMD2(0.2, 0.2), SIMD2(0.3, 0.25)], radius: 0.05, feather: 0.5, flow: 1, erase: false),
            ]))),
            MaskComponent(mode: .intersect, source: .shape(.ai(kind: "subject", modelVersion: "test-1"))),
            MaskComponent(mode: .intersect, source: .luminance(LuminanceRange(low: 0.5, high: 1, feather: 0.1))),
            MaskComponent(mode: .subtract, source: .mask(id: UUID())),
        ]
        return local
    }

    func testCaptureKeepsPortableComponentsAndListsTheRest() {
        let (preset, skipped) = MaskPreset.capture(sampleMask(), name: "Moody sky")
        XCTAssertEqual(preset.mask.components.count, 3, "brush, subject and range travel; the link doesn't")
        XCTAssertEqual(skipped.map(\.reason), [.linkedMask])
        XCTAssertFalse(preset.mask.hidden, "a preset is saved shown")
        XCTAssertEqual(preset.mask.name, "Moody sky")
        XCTAssertEqual(MaskPreset.skippedComponents(of: sampleMask()).count, 1)
    }

    func testInstantiateGivesFreshIDsAndKeepsEverythingElse() {
        let (preset, _) = MaskPreset.capture(sampleMask(), name: "Moody sky")
        let a = preset.instantiate(), b = preset.instantiate()
        XCTAssertNotEqual(a.id, preset.mask.id)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(Set(a.components.map(\.id)).isDisjoint(with: preset.mask.components.map(\.id)))
        var same = a
        same.id = preset.mask.id
        same.components = zip(a.components, preset.mask.components).map { var c = $0; c.id = $1.id; return c }
        XCTAssertEqual(same, preset.mask, "only the ids differ")
    }

    func testPresetRoundTripsThroughJSON() throws {
        let (preset, _) = MaskPreset.capture(sampleMask(), name: "Moody sky")
        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(MaskPreset.self, from: data)
        XCTAssertEqual(back, preset)
        XCTAssertEqual(back.format, MaskPreset.currentFormat)
    }

    func testStoreSavesLoadsRenamesAndDeletes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mask-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MaskPresetStore(directory: dir)
        XCTAssertTrue(store.load().isEmpty)

        let (saved, skipped) = try store.saveNew(sampleMask(), name: "  Moody sky ")
        XCTAssertEqual(saved.name, "Moody sky", "the name is trimmed")
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(store.load(), [saved])
        XCTAssertThrowsError(try store.saveNew(sampleMask(), name: "moody SKY")) {
            XCTAssertEqual($0 as? MaskPresetStoreError, .nameTaken("moody SKY"))
        }
        XCTAssertThrowsError(try store.saveNew(sampleMask(), name: "   ")) {
            XCTAssertEqual($0 as? MaskPresetStoreError, .emptyName)
        }

        _ = try store.saveNew(LocalAdjustment(name: "Vignette", shape: .whole), name: "A vignette")
        XCTAssertEqual(store.load().map(\.name), ["A vignette", "Moody sky"], "sorted by name")

        let renamed = try store.rename(saved, to: "Evening sky")
        XCTAssertEqual(renamed.mask.components, saved.mask.components)
        XCTAssertEqual(store.load().map(\.name), ["A vignette", "Evening sky"])
        XCTAssertThrowsError(try store.rename(renamed, to: "A Vignette"))
        let recased = try store.rename(renamed, to: "evening sky")
        XCTAssertEqual(store.load().map(\.name), ["A vignette", "evening sky"], "a case-only rename keeps one file")

        try store.delete(named: recased.name)
        XCTAssertEqual(store.load().map(\.name), ["A vignette"])
    }
}
