import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// The dust detector around the blob detector (docs/Retouch.md §6, §11):
/// the expected radius, the bands, detection into patches with sources
/// that never overlap a spot or leave the sensor, map verification, and
/// the GPU analysis on a real raw when one is there.
final class DustDetectorTests: XCTestCase {
    /// A synthetic analysis: the scene's map as a binned (quads: 1) render
    /// of a sensor twice its size.
    static func analysis(_ scene: DustScene.Scene) -> DustDetector.Analysis {
        DustDetector.Analysis(map: scene.map.values, width: scene.map.width, height: scene.map.height, binSpan: 2,
                              sensorSize: SIMD2(Float(scene.map.width * 2), Float(scene.map.height * 2)),
                              noise: BlobDetector.localNoise(scene.map))
    }

    /// A map spot's centre in sensor pixels.
    static func sensorCentre(_ spot: DustScene.Spot, _ a: DustDetector.Analysis) -> SIMD2<Float> {
        (spot.centre + 0.5) * a.binSpan
    }

    /// Patches without their ids (every detection mints new ones).
    static func geometry(_ patches: [HealPatch]) -> [SIMD4<Float>] {
        patches.map { SIMD4($0.target.x, $0.target.y, $0.source.x, $0.source.y) } + patches.map { SIMD4(repeating: $0.radius) }
    }

    // MARK: - Maths

    func testExpectedRadiusTable() throws {
        // (aperture, crop factor, raw width) → sensor px, from
        // 0.75 mm / (N × pitch) with pitch = 36 mm / crop / width.
        let table: [(Double, Double, Int, Float)] = [
            (8, 1, 6032, 15.7),       // D750 f/8: 5.97 µm pitch
            (11, 1, 6032, 11.4),
            (16, 1, 6032, 7.9),
            (22, 1, 6032, 5.7),
            (11, 1.5, 6000, 17.0),    // APS-C: 4 µm pitch
            (5.6, 2, 5184, 38.6),     // Micro Four Thirds: 3.47 µm
            (2.8, 1, 6032, 40),       // clamped high
            (32, 1, 3000, 2),         // clamped low (2.8 → 2)
        ]
        for (n, crop, width, expected) in table {
            let r = try XCTUnwrap(DustDetector.expectedRadius(aperture: n, cropFactor: crop, rawWidth: width))
            XCTAssertEqual(r, expected, accuracy: 0.1, "f/\(n) crop \(crop) width \(width)")
        }
        XCTAssertNil(DustDetector.expectedRadius(aperture: 8, cropFactor: 1, rawWidth: 0))
        XCTAssertNil(DustDetector.expectedRadius(aperture: -8, cropFactor: 1, rawWidth: 6032))
        XCTAssertNil(DustDetector.expectedRadius(aperture: 8, cropFactor: .infinity, rawWidth: 6032))
    }

    func testBandNarrowing() {
        func range(_ size: DustSpotSize, _ expected: Float?) -> ClosedRange<Float> {
            DustDetector.blobParameters(options: .init(size: size), expectedRadius: expected, binSpan: 2).radiusRange
        }
        // No expectation: the band as chosen, in map pixels.
        XCTAssertEqual(range(.small, nil), 2...4)
        XCTAssertEqual(range(.medium, nil), 3...8)
        XCTAssertEqual(range(.large, nil), 6...20)
        // [0.5r, 2.5r] cut to the band: 8 px leaves Medium alone, 20 px
        // lifts its floor, 5 px lowers Small's nothing and Large's ceiling.
        XCTAssertEqual(range(.medium, 8), 3...8)
        XCTAssertEqual(range(.medium, 20), 5...8)
        XCTAssertEqual(range(.small, 5), 2...4)
        XCTAssertEqual(range(.large, 10), 6...12.5)
        XCTAssertEqual(range(.large, 40), 10...20)
        // An expectation outside the band leaves the band as chosen.
        XCTAssertEqual(range(.small, 30), 2...4)
        XCTAssertEqual(range(.large, 3), 6...20)
        // Never below 2 map px: a 3 px shadow narrows Small to 2…3.75.
        XCTAssertEqual(range(.small, 3), 2...3.75)
        // Sensitivity is clamped and the polarity is always dark.
        let p = DustDetector.blobParameters(options: .init(sensitivity: -5), expectedRadius: nil, binSpan: 2)
        XCTAssertEqual(p.contrastSigma, 6, accuracy: 1e-6)
        XCTAssertEqual(p.polarity, .dark)
    }

    // MARK: - Source placement

    /// Over 500 random scenes no source disc leaves the sensor or comes
    /// within 1.5·r_source + r_other of another spot, and every source
    /// sits on one of the three rings in one of the eight directions.
    func testPlacementNeverOverlapsOrLeavesTheSensor() {
        var rng = DustScene.Generator(seed: 77)
        var placed = 0, dropped = 0
        for _ in 0..<500 {
            let sensor = SIMD2(rng.uniform(300...6000).rounded(), rng.uniform(200...4000).rounded())
            let count = Int(rng.uniform(1...40))
            let spots = (0..<count).map { _ in
                DustSourcePlacer.Spot(centre: SIMD2(rng.uniform(0...sensor.x), rng.uniform(0...sensor.y)),
                                      radius: rng.uniform(4...60))
            }
            for (i, spot) in spots.enumerated() {
                var others = spots
                others.remove(at: i)
                guard let source = DustSourcePlacer.place(spot, avoiding: others, sensorSize: sensor, analysis: nil) else {
                    dropped += 1
                    continue
                }
                placed += 1
                let r = spot.radius
                XCTAssertGreaterThanOrEqual(source.x - r, 0)
                XCTAssertGreaterThanOrEqual(source.y - r, 0)
                XCTAssertLessThanOrEqual(source.x + r, sensor.x)
                XCTAssertLessThanOrEqual(source.y + r, sensor.y)
                for other in others {
                    XCTAssertGreaterThanOrEqual(simd_distance(source, other.centre), 1.5 * r + other.radius - 1e-3)
                }
                let offset = source - spot.centre
                let ring = simd_length(offset) / r
                XCTAssertTrue(DustSourcePlacer.rings.contains { abs($0 - ring) < 1e-3 }, "ring \(ring)")
                let angle = atan2(offset.y, offset.x) / (.pi / 4)
                XCTAssertEqual(angle, angle.rounded(), accuracy: 1e-3, "one of eight directions")
                // The target itself is clear of its own source disc.
                XCTAssertGreaterThanOrEqual(simd_length(offset), 2.5 * r)
            }
        }
        print("DustSourcePlacer: \(placed) placed, \(dropped) dropped over 500 scenes")
        XCTAssertGreaterThan(placed, dropped * 4, "most spots find a source")
        XCTAssertGreaterThan(dropped, 0, "crowded corners do drop spots")

        // A spot too close to a corner for any ring is dropped (a smaller
        // one there still fits along the diagonal); one in the clear takes
        // the nearest ring.
        XCTAssertNil(DustSourcePlacer.place(.init(centre: [5, 5], radius: 40), avoiding: [], sensorSize: [100, 100], analysis: nil))
        XCTAssertNotNil(DustSourcePlacer.place(.init(centre: [5, 5], radius: 10), avoiding: [], sensorSize: [100, 100], analysis: nil))
        let source = DustSourcePlacer.place(.init(centre: [500, 500], radius: 10), avoiding: [], sensorSize: [1000, 1000], analysis: nil)
        XCTAssertEqual(source.map { simd_distance($0, [500, 500]) } ?? 0, 27.5, accuracy: 1e-3)
        // With the first ring blocked all round (and the second, which is
        // within 1.5·r + r_other of the same blockers), the third is used.
        let blockers = (0..<8).map { k -> DustSourcePlacer.Spot in
            let a = Float(k) * .pi / 4
            return .init(centre: [500, 500] + 27.5 * SIMD2(cos(a), sin(a)), radius: 2)
        }
        let second = DustSourcePlacer.place(.init(centre: [500, 500], radius: 10), avoiding: blockers, sensorSize: [1000, 1000], analysis: nil)
        XCTAssertEqual(second.map { simd_distance($0, [500, 500]) } ?? 0, 45, accuracy: 1e-3)
        // Not a number: no source.
        XCTAssertNil(DustSourcePlacer.place(.init(centre: [.nan, 5], radius: 10), avoiding: [], sensorSize: [100, 100], analysis: nil))
        XCTAssertNil(DustSourcePlacer.place(.init(centre: [50, 50], radius: 0), avoiding: [], sensorSize: [100, 100], analysis: nil))
    }

    /// With an analysis the smoothest disc wins: a hard edge to one side
    /// of the spot pushes the source to the other side.
    func testPlacementPrefersTheSmoothSide() {
        let width = 256, height = 256
        var values = [Float](repeating: -2, count: width * height)
        // A bright band to the right of x = 150 on the map (300 on the sensor).
        for y in 0..<height { for x in 150..<width { values[y * width + x] = -1 } }
        let a = DustDetector.Analysis(map: values, width: width, height: height, binSpan: 2, sensorSize: [512, 512],
                                      noise: [Float](repeating: 0.01, count: width * height))
        let spot = DustSourcePlacer.Spot(centre: [250, 256], radius: 12)
        let source = try? XCTUnwrap(DustSourcePlacer.place(spot, avoiding: [], sensorSize: [512, 512], analysis: a))
        XCTAssertLessThan(source?.x ?? 999, 250, "left of the spot, away from the edge: \(String(describing: source))")
        // The edge's gradient is what the placer measures.
        XCTAssertGreaterThan(DustSourcePlacer.meanGradient(at: [300, 256], radius: 12, in: a),
                             10 * DustSourcePlacer.meanGradient(at: [200, 256], radius: 12, in: a))
    }

    // MARK: - Detection into patches

    func testDetectMakesPatchesForTheSpots() {
        let scene = DustScene.make(noise: 0.01, seed: 31)
        let a = Self.analysis(scene)
        let patches = DustDetector.detect(a, options: .init(sensitivity: 50, size: .medium), expectedRadius: nil, existing: [])
        // Medium is 6…16 sensor px = 3…8 on the map; the scene's spots run
        // 3…12, so the big ones are outside the band.
        let inBand = scene.spots.filter { (3...8).contains($0.radius) }
        XCTAssertGreaterThanOrEqual(patches.count, inBand.count * 8 / 10, "\(patches.count) of \(inBand.count)")
        let shortSide = min(a.sensorSize.x, a.sensorSize.y)
        for patch in patches {
            XCTAssertEqual(patch.feather, 0.5)
            XCTAssertEqual(patch.mode, .heal)
            XCTAssertNil(patch.stroke)
            let target = patch.target * a.sensorSize
            let spot = scene.spots.min { simd_distance(Self.sensorCentre($0, a), target) < simd_distance(Self.sensorCentre($1, a), target) }!
            XCTAssertLessThan(simd_distance(Self.sensorCentre(spot, a), target), 2 * spot.radius, "a patch sits on a spot")
            // radius = (1.5·r_eq·binSpan + 2) / shortSide, r_eq within 30 % of the spot.
            let rEq = (patch.radius * shortSide - 2) / (1.5 * a.binSpan)
            XCTAssertEqual(rEq, spot.radius, accuracy: 0.3 * spot.radius + 0.5)
            // The source is on a ring, off the target, inside the sensor.
            let offset = (patch.source - patch.target) * a.sensorSize
            let ring = simd_length(offset) / (patch.radius * shortSide)
            XCTAssertTrue(DustSourcePlacer.rings.contains { abs($0 - ring) < 1e-2 }, "ring \(ring)")
            XCTAssertTrue((0...1).contains(patch.source.x) && (0...1).contains(patch.source.y))
        }
        // Best first, and stable (the ids alone are new each time).
        XCTAssertEqual(Self.geometry(DustDetector.detect(a, options: .init(), expectedRadius: nil, existing: [])), Self.geometry(patches))

        // A spot already under a patch (a user heal, an earlier dust spot
        // or a blemish) is left out; the others stay.
        let first = patches[0]
        let cover = HealPatch(target: first.target, source: first.source, radius: first.radius * 1.2)
        let rest = DustDetector.detect(a, options: .init(), expectedRadius: nil, existing: [cover])
        XCTAssertEqual(rest.count, patches.count - 1)
        XCTAssertFalse(rest.contains { simd_distance($0.target, first.target) < 1e-4 })
        // A stroke's path counts too.
        let stroke = HealPatch(target: first.target - [0.1, 0], source: first.source, radius: first.radius * 1.2,
                               stroke: [[0, 0], [0.1, 0]])
        XCTAssertEqual(DustDetector.detect(a, options: .init(), expectedRadius: nil, existing: [stroke]).count, patches.count - 1)
    }

    func testDetectStopsAtTheCap() {
        // 250 small spots on a big map: at most 200 patches, best first.
        let scene = DustScene.make(width: 2400, height: 1800, noise: 0.005, spotCount: 250, radii: 4...6,
                                   attenuation: 0.15...0.3, decoys: false, seed: 41)
        XCTAssertEqual(scene.spots.count, 250)
        let a = Self.analysis(scene)
        let patches = DustDetector.detect(a, options: .init(sensitivity: 60, size: .medium), expectedRadius: nil, existing: [])
        XCTAssertEqual(patches.count, HealPatch.maximumDustCount)

        // Hand heals over the 30 strongest spots free 30 slots, which the
        // next-best spots take: the cap is on the patches, not the blobs.
        let healed = Array(patches.prefix(30))
        let rest = DustDetector.detect(a, options: .init(sensitivity: 60, size: .medium), expectedRadius: nil,
                                       existing: healed)
        XCTAssertEqual(rest.count, HealPatch.maximumDustCount)
        for patch in rest {
            XCTAssertFalse(healed.contains { simd_distance($0.target, patch.target) < $0.radius },
                           "a healed spot is not patched again")
        }
    }

    func testSensitivityAndSizeChangeTheList() {
        let scene = DustScene.make(noise: 0.02, seed: 51)
        let a = Self.analysis(scene)
        let strict = DustDetector.detect(a, options: .init(sensitivity: 0), expectedRadius: nil, existing: []).count
        let loose = DustDetector.detect(a, options: .init(sensitivity: 100), expectedRadius: nil, existing: []).count
        XCTAssertGreaterThan(loose, strict)
        let small = DustDetector.detect(a, options: .init(size: .small), expectedRadius: nil, existing: [])
        let large = DustDetector.detect(a, options: .init(size: .large), expectedRadius: nil, existing: [])
        let shortSide = min(a.sensorSize.x, a.sensorSize.y)
        for p in small { XCTAssertLessThanOrEqual((p.radius * shortSide - 2) / 1.5, 8 * 1.3) }
        for p in large { XCTAssertGreaterThanOrEqual((p.radius * shortSide - 2) / 1.5, 12 * 0.7) }
        XCTAssertEqual(DustDetector.detect(DustDetector.Analysis(map: [], width: 0, height: 0, binSpan: 2, sensorSize: [0, 0], noise: []),
                                           options: .init(), expectedRadius: nil, existing: []), [])
    }

    // MARK: - Map verification

    func testVerifyFindsTheMapsSpotsAndNotPhantoms() {
        let scene = DustScene.make(noise: 0.015, seed: 61)
        let a = Self.analysis(scene)
        let shortSide = min(a.sensorSize.x, a.sensorSize.y)
        // The map: every true spot, slightly misplaced (a map from another
        // photo is never exact), plus phantoms where the sky is clean.
        var rng = DustScene.Generator(seed: 62)
        let real = scene.spots.map { spot -> DustMapSpot in
            let jitter = SIMD2(rng.uniform(-0.3...0.3), rng.uniform(-0.3...0.3)) * spot.radius
            return DustMapSpot(centre: (Self.sensorCentre(spot, a) + jitter * a.binSpan) / a.sensorSize,
                               radius: spot.radius * a.binSpan / shortSide, contrast: spot.stops)
        }
        var phantoms: [DustMapSpot] = []
        while phantoms.count < 15 {
            let c = SIMD2(rng.uniform(60...Float(a.width - 60)), rng.uniform(60...Float(a.height - 60)))
            let clear = scene.spots.allSatisfy { simd_distance($0.centre, c) > 6 * $0.radius + 40 }
                && simd_distance(c, [Float(a.width) * 0.3, Float(a.height) * 0.7]) > 80
                && simd_distance(c, [Float(a.width) * 0.75, Float(a.height) * 0.25]) > 60
                && simd_distance(c, [Float(a.width) * 0.6, Float(a.height) * 0.6]) > 100
            guard clear else { continue }
            phantoms.append(DustMapSpot(centre: (c + 0.5) * a.binSpan / a.sensorSize, radius: 5 * a.binSpan / shortSide, contrast: 0.2))
        }
        let patches = DustDetector.verify(real + phantoms, in: a, options: .init(sensitivity: 50), existing: [])
        var found = 0, ghosts = 0
        for patch in patches {
            let target = patch.target * a.sensorSize
            if let spot = scene.spots.first(where: { simd_distance(Self.sensorCentre($0, a), target) <= ($0.radius + 2) * a.binSpan }) {
                found += 1
                // The larger of the map's radius and this photo's.
                let rEq = (patch.radius * shortSide - 2) / (1.5 * a.binSpan)
                XCTAssertGreaterThanOrEqual(rEq, spot.radius - 1e-3)
                XCTAssertLessThan(rEq, spot.radius * 1.5 + 1)
            } else {
                ghosts += 1
            }
            XCTAssertEqual(patch.feather, 0.5)
            XCTAssertNotEqual(patch.source, patch.target)
        }
        print("DustDetector.verify: \(found) of \(scene.spots.count) map spots found, \(ghosts) of \(phantoms.count) phantoms accepted")
        XCTAssertGreaterThanOrEqual(Double(found) / Double(scene.spots.count), 0.9)
        XCTAssertGreaterThanOrEqual(Double(found) / Double(max(found + ghosts, 1)), 0.9)
        // Spots off the sensor and inside an existing patch are skipped.
        let off = DustMapSpot(centre: [1.5, 0.5], radius: 0.002, contrast: 0.2)
        XCTAssertEqual(DustDetector.verify([off], in: a, options: .init(), existing: []), [])
        let cover = HealPatch(target: real[0].centre, source: real[0].centre + [0.05, 0], radius: real[0].radius * 3)
        XCTAssertEqual(DustDetector.verify([real[0]], in: a, options: .init(), existing: [cover]), [])
        XCTAssertEqual(DustDetector.verify([real[0]], in: a, options: .init(), existing: []).count, 1)
    }

    func testMapSpotsMeasureTheContrast() {
        let scene = DustScene.make(noise: 0.01, seed: 71)
        let a = Self.analysis(scene)
        let shortSide = min(a.sensorSize.x, a.sensorSize.y)
        let patches = scene.spots.map { spot in
            HealPatch(target: Self.sensorCentre(spot, a) / a.sensorSize, source: [0.5, 0.5],
                      radius: (1.5 * spot.radius * a.binSpan + 2) / shortSide, feather: 0.5, mode: .heal)
        }
        let spots = DustDetector.mapSpots(from: patches, analysis: a)
        XCTAssertEqual(spots.count, scene.spots.count)
        for (spot, truth) in zip(spots, scene.spots) {
            XCTAssertEqual(spot.centre, Self.sensorCentre(truth, a) / a.sensorSize)
            XCTAssertEqual(spot.radius * shortSide, truth.radius * a.binSpan, accuracy: 1e-3)
            XCTAssertEqual(spot.contrast, truth.stops, accuracy: 0.3 * truth.stops + 0.01)
        }
        // Strokes and patches off the map are left out.
        let stroke = HealPatch(target: [0.5, 0.5], source: [0.6, 0.5], radius: 0.01, stroke: [[0, 0], [0.05, 0]])
        let off = HealPatch(target: [1.5, 0.5], source: [0.6, 0.5], radius: 0.01)
        XCTAssertEqual(DustDetector.mapSpots(from: [stroke, off], analysis: a), [])
    }

    // MARK: - The analysis render

    /// The real thing on the D750 raw: the map is the binned render's
    /// size, finite, with a noise estimate, and two runs agree.
    func testAnalyseAndDetectOnTheGoldenRaw() throws {
        let path = try TestAssets.d750Path()
        let file = try RawFile(path: path)
        let gpu = try GPUContext()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var parameters = EditParameters()
        parameters.whiteBalance = session.asShotWhiteBalance
        parameters.exposureEV = 1.5   // must not matter to the analysis

        let bytesBefore = session.approximateBytesHeld
        let start = Date()
        let a = try DustDetector.analyse(session: session, pipeline: pipeline, gpu: gpu, parameters: parameters)
        let analyseSeconds = Date().timeIntervalSince(start)
        XCTAssertEqual(a.width, file.summary.rawWidth / 2)
        XCTAssertEqual(a.height, file.summary.rawHeight / 2)
        XCTAssertEqual(a.binSpan, 2)
        XCTAssertEqual(a.sensorSize, SIMD2(Float(file.summary.rawWidth), Float(file.summary.rawHeight)))
        XCTAssertEqual(a.map.count, a.width * a.height)
        XCTAssertEqual(a.noise.count, a.width * a.height)
        XCTAssertTrue(a.map.allSatisfy(\.isFinite))
        XCTAssertGreaterThanOrEqual(a.map.min()!, log2(1e-4) - 1e-3)
        XCTAssertGreaterThan(a.noise.max()!, 0)
        XCTAssertTrue(a.noise.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertEqual(session.approximateBytesHeld, bytesBefore, "the analysis pool is released")

        let expected = DustDetector.expectedRadius(aperture: file.summary.aperture, cropFactor: file.summary.lens.cropFactor,
                                                   rawWidth: file.summary.rawWidth)
        let detectStart = Date()
        let patches = DustDetector.detect(a, options: .init(), expectedRadius: expected, existing: [])
        let detectSeconds = Date().timeIntervalSince(detectStart)
        print("DustDetector on \(path.split(separator: "/").last!): analyse \(Int(analyseSeconds * 1000)) ms, detect \(Int(detectSeconds * 1000)) ms, \(patches.count) spots, expected radius \(String(describing: expected))")
        XCTAssertLessThanOrEqual(patches.count, HealPatch.maximumDustCount)
        for patch in patches {
            XCTAssertTrue((0...1).contains(patch.target.x) && (0...1).contains(patch.target.y))
            XCTAssertTrue((0...1).contains(patch.source.x) && (0...1).contains(patch.source.y))
            XCTAssertGreaterThan(patch.radius, 0)
        }
        XCTAssertEqual(DustDetector.mapSpots(from: patches, analysis: a).count, patches.count)

        // A second analysis and detection give the same spots.
        let again = try DustDetector.analyse(session: session, pipeline: pipeline, gpu: gpu, parameters: parameters)
        XCTAssertEqual(again.map, a.map)
        let repeated = DustDetector.detect(again, options: .init(), expectedRadius: expected, existing: [])
        XCTAssertEqual(repeated.count, patches.count)
        XCTAssertEqual(Self.geometry(repeated), Self.geometry(patches))
    }

    /// A linear DNG goes through the same seam.
    func testAnalyseOnALinearFixture() throws {
        let gpu = try GPUContext()
        let file = try RawFile(path: LinearFixtures.path(LinearFixtures.ramp))
        let session = try ImageSession(file: file, gpu: gpu)
        let a = try DustDetector.analyse(session: session, pipeline: RenderPipeline(gpu: gpu), gpu: gpu, parameters: EditParameters())
        XCTAssertEqual(a.width, 600)
        XCTAssertEqual(a.height, 400)
        XCTAssertEqual(a.sensorSize, [1200, 800])
        XCTAssertTrue(a.map.allSatisfy(\.isFinite))
        // The fixture's flat rectangle (100…300 on each axis) is one value.
        let inside = a.map[100 * a.width + 100], other = a.map[100 * a.width + 120]
        XCTAssertEqual(inside, other, accuracy: 1e-3)
    }
}
