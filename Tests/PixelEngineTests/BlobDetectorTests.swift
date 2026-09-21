import XCTest
import simd
@testable import PixelEngine

/// Synthetic scenes for the blob detector and the dust code: a sky
/// gradient with Gaussian noise, soft-edged dark spots of known size and
/// depth, and decoys that must not count. Seeded, so every run sees the
/// same scene.
enum DustScene {
    struct Spot: Equatable {
        var centre: SIMD2<Float>
        var radius: Float
        /// Fraction of the light the spot takes away (0.1 = 10 %).
        var attenuation: Float
        var stops: Float { -log2(1 - attenuation) }
    }

    struct Scene {
        var map: BlobDetector.Map
        var spots: [Spot]
        var noise: Float
    }

    /// SplitMix64: a few lines, good enough noise, the same everywhere.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uniform(_ range: ClosedRange<Float>) -> Float {
            Float.random(in: range, using: &self)
        }
        /// Box–Muller.
        mutating func gaussian() -> Float {
            let u1 = max(Float.random(in: 0..<1, using: &self), 1e-7), u2 = Float.random(in: 0..<1, using: &self)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    /// A soft-edged disc: 1 inside, fading over ±e around the radius.
    static func profile(_ distance: Float, radius: Float) -> Float {
        let edge = max(0.75, 0.2 * radius)
        let t = min(max((distance - (radius - edge)) / (2 * edge), 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// The sky in log2 stops: a gradient across the frame plus a touch of
    /// vignetting, a slope of about a thousandth of a stop per pixel.
    static func sky(x: Float, y: Float, width: Int, height: Int) -> Float {
        let cx = Float(width) / 2, cy = Float(height) / 2
        let dx = (x - cx) / cx, dy = (y - cy) / cy
        return -2.3 + 0.0012 * x - 0.0008 * y - 0.3 * (dx * dx + dy * dy)
    }

    /// A scene of `spotCount` dark spots with radii and attenuations in
    /// the given ranges, kept apart and away from the edges, with
    /// Gaussian noise of `noise` stops; `decoys` adds a hard-edged bird
    /// shape, a bright spot and a thin dark line.
    static func make(width: Int = 1024, height: Int = 768, noise: Float, spotCount: Int = 25,
                     radii: ClosedRange<Float> = 3...12, attenuation: ClosedRange<Float> = 0.05...0.25,
                     decoys: Bool = true, seed: UInt64 = 1) -> Scene {
        var rng = Generator(seed: seed)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = sky(x: Float(x), y: Float(y), width: width, height: height) + noise * rng.gaussian()
            }
        }
        // Decoys first, so the spots keep clear of them.
        var taken: [(centre: SIMD2<Float>, reach: Float)] = []
        if decoys {
            let bird = SIMD2<Float>(Float(width) * 0.3, Float(height) * 0.7)
            let bright = SIMD2<Float>(Float(width) * 0.75, Float(height) * 0.25)
            let line = SIMD2<Float>(Float(width) * 0.6, Float(height) * 0.6)
            taken = [(bird, 40), (bright, 30), (line, 70)]
            paint(&values, width: width, height: height, around: bird, reach: 40) { p in
                // Two wings meeting in a V, a hard edge all round.
                let d = p - bird
                let wing = abs(abs(d.x) * 0.5 - d.y) < 3 && abs(d.x) < 28
                return wing ? log2(1 - 0.4) : 0
            }
            paint(&values, width: width, height: height, around: bright, reach: 30) { p in
                log2(1 + 0.3 * profile(simd_distance(p, bright), radius: 6))
            }
            paint(&values, width: width, height: height, around: line, reach: 70) { p in
                let d = p - line
                let root2 = Float(2).squareRoot()
                let along = (d.x + d.y) / root2, across = abs(d.x - d.y) / root2
                return abs(along) < 45 && across < 0.9 ? log2(1 - 0.3) : 0
            }
        }
        var spots: [Spot] = []
        var attempts = 0
        while spots.count < spotCount && attempts < 20_000 {
            attempts += 1
            let r = rng.uniform(radii)
            let c = SIMD2(rng.uniform(40...Float(width - 41)), rng.uniform(40...Float(height - 41)))
            let clear = spots.allSatisfy { simd_distance($0.centre, c) >= 4 * ($0.radius + r) + 20 }
                && taken.allSatisfy { simd_distance($0.centre, c) >= $0.reach + 6 * r }
            guard clear else { continue }
            let spot = Spot(centre: c, radius: r, attenuation: rng.uniform(attenuation))
            spots.append(spot)
            paint(&values, width: width, height: height, around: c, reach: 2 * r + 4) { p in
                log2(1 - spot.attenuation * profile(simd_distance(p, c), radius: r))
            }
        }
        return Scene(map: BlobDetector.Map(values: values, width: width, height: height), spots: spots, noise: noise)
    }

    static func paint(_ values: inout [Float], width: Int, height: Int, around c: SIMD2<Float>, reach: Float,
                      _ delta: (SIMD2<Float>) -> Float) {
        let x0 = max(Int(c.x - reach), 0), x1 = min(Int(c.x + reach) + 1, width - 1)
        let y0 = max(Int(c.y - reach), 0), y1 = min(Int(c.y + reach) + 1, height - 1)
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                values[y * width + x] += delta(SIMD2(Float(x), Float(y)))
            }
        }
    }

    /// The §6 sensitivity mapping for a band in map pixels.
    static func parameters(sensitivity: Int, radii: ClosedRange<Float>, polarity: BlobDetector.Polarity = .dark) -> BlobDetector.Parameters {
        let s = Float(sensitivity) / 100
        return BlobDetector.Parameters(
            radiusRange: radii, polarity: polarity, contrastSigma: 6 - 4 * s, minimumContrast: 0.08 - 0.06 * s,
            minimumCircularity: 0.65 - 0.15 * s, smoothSurround: 2.5 + s, maximumSurroundGradient: 0.01, maximumCount: 200)
    }

    struct Tally {
        var truePositives = 0, falsePositives = 0, falseNegatives = 0
        var matched: [(spot: Spot, blob: BlobDetector.Blob)] = []
        var precision: Double { truePositives + falsePositives == 0 ? 1 : Double(truePositives) / Double(truePositives + falsePositives) }
        var recall: Double { truePositives + falseNegatives == 0 ? 1 : Double(truePositives) / Double(truePositives + falseNegatives) }
    }

    /// Each blob claims the nearest unclaimed spot within the spot's
    /// radius plus two pixels; the rest are false.
    static func tally(_ blobs: [BlobDetector.Blob], against spots: [Spot]) -> Tally {
        var t = Tally()
        var claimed = [Bool](repeating: false, count: spots.count)
        for blob in blobs {
            var best: (index: Int, distance: Float)?
            for (i, spot) in spots.enumerated() where !claimed[i] {
                let d = simd_distance(spot.centre, blob.centre)
                if d <= spot.radius + 2, best == nil || d < best!.distance { best = (i, d) }
            }
            if let best {
                claimed[best.index] = true
                t.truePositives += 1
                t.matched.append((spots[best.index], blob))
            } else {
                t.falsePositives += 1
            }
        }
        t.falseNegatives = spots.count - t.truePositives
        return t
    }
}

/// The blob detector on synthetic skies (docs/Retouch.md §2C, §11): what
/// it must find, what it must leave alone, how well it sizes a spot and
/// how long it takes.
final class BlobDetectorTests: XCTestCase {
    /// Noise in stops on the analysis map (already 2×2 binned), roughly
    /// ISO 100, 800 and 3200 on a full-frame sensor at middle grey.
    static let noiseLevels: [Float] = [0.008, 0.02, 0.04]

    private func tallyAcrossNoise(sensitivity: Int, seed: UInt64 = 1) -> (total: DustScene.Tally, perLevel: [DustScene.Tally]) {
        var total = DustScene.Tally()
        var perLevel: [DustScene.Tally] = []
        for (i, noise) in Self.noiseLevels.enumerated() {
            let scene = DustScene.make(noise: noise, seed: seed + UInt64(i))
            let blobs = BlobDetector.detect(scene.map, DustScene.parameters(sensitivity: sensitivity, radii: 3...12))
            let t = DustScene.tally(blobs, against: scene.spots)
            perLevel.append(t)
            total.truePositives += t.truePositives
            total.falsePositives += t.falsePositives
            total.falseNegatives += t.falseNegatives
            total.matched += t.matched
        }
        return (total, perLevel)
    }

    func testSensitivity50FindsMostSpotsAndLittleElse() {
        let (total, perLevel) = tallyAcrossNoise(sensitivity: 50)
        for (noise, t) in zip(Self.noiseLevels, perLevel) {
            print("BlobDetector sensitivity 50, noise \(noise): precision \(t.precision) recall \(t.recall) (\(t.truePositives) TP, \(t.falsePositives) FP, \(t.falseNegatives) FN)")
        }
        print("BlobDetector sensitivity 50 overall: precision \(total.precision) recall \(total.recall)")
        XCTAssertGreaterThanOrEqual(total.precision, 0.9)
        XCTAssertGreaterThanOrEqual(total.recall, 0.8)
        // Radii within ±30 % for nearly all, centres within a pixel or two.
        let within = total.matched.filter { abs($0.blob.radius - $0.spot.radius) <= 0.3 * $0.spot.radius }.count
        print("BlobDetector radii within 30%: \(within) of \(total.matched.count)")
        XCTAssertGreaterThanOrEqual(Double(within) / Double(max(total.matched.count, 1)), 0.9)
        for (spot, blob) in total.matched {
            XCTAssertLessThan(simd_distance(spot.centre, blob.centre), 2, "centre of r=\(spot.radius) spot")
        }
    }

    func testSensitivity100FindsNearlyEverything() {
        let (total, perLevel) = tallyAcrossNoise(sensitivity: 100)
        for (noise, t) in zip(Self.noiseLevels, perLevel) {
            print("BlobDetector sensitivity 100, noise \(noise): precision \(t.precision) recall \(t.recall)")
        }
        XCTAssertGreaterThanOrEqual(total.recall, 0.95)
    }

    /// Sky and noise alone give nothing up to sensitivity 70, with or
    /// without the decoys.
    func testCleanSceneGivesNoBlobs() {
        for (i, noise) in Self.noiseLevels.enumerated() {
            for decoys in [false, true] {
                let scene = DustScene.make(noise: noise, spotCount: 0, decoys: decoys, seed: 11 + UInt64(i))
                for sensitivity in [0, 50, 70] {
                    let blobs = BlobDetector.detect(scene.map, DustScene.parameters(sensitivity: sensitivity, radii: 3...12))
                    XCTAssertEqual(blobs.count, 0, "noise \(noise), decoys \(decoys), sensitivity \(sensitivity): \(blobs)")
                }
            }
        }
    }

    /// At the lowest noise every spot is found and sized within ±30 %,
    /// and the reported contrast is the spot's depth in stops.
    func testRadiiAndContrastAtLowNoise() {
        let scene = DustScene.make(noise: 0.008, seed: 5)
        let blobs = BlobDetector.detect(scene.map, DustScene.parameters(sensitivity: 50, radii: 3...12))
        let t = DustScene.tally(blobs, against: scene.spots)
        XCTAssertEqual(t.falseNegatives, 0)
        XCTAssertEqual(t.falsePositives, 0)
        for (spot, blob) in t.matched {
            XCTAssertEqual(blob.radius, spot.radius, accuracy: 0.3 * spot.radius, "r=\(spot.radius)")
            XCTAssertEqual(blob.contrast, spot.stops, accuracy: 0.3 * spot.stops + 0.01, "a=\(spot.attenuation) r=\(spot.radius)")
            XCTAssertGreaterThan(blob.score, 0)
        }
        // Best first.
        XCTAssertEqual(blobs.map(\.score), blobs.map(\.score).sorted(by: >))
        // The cap keeps the best.
        var capped = DustScene.parameters(sensitivity: 50, radii: 3...12)
        capped.maximumCount = 5
        XCTAssertEqual(BlobDetector.detect(scene.map, capped), Array(blobs.prefix(5)))
    }

    /// Red blemishes on an a* map: found where the skin weight allows,
    /// ignored outside it, and a greenish dip is not a blemish.
    func testReddishBlobsOnSkin() {
        let width = 512, height = 384
        var rng = DustScene.Generator(seed: 3)
        var values = [Float](repeating: 0, count: width * height)
        var weight = [Float](repeating: 0, count: width * height)
        let face = SIMD2<Float>(256, 192)
        for y in 0..<height {
            for x in 0..<width {
                // Skin a* around 14 with a slow drift and a little noise.
                values[y * width + x] = 14 + 0.004 * Float(x) + 0.5 * rng.gaussian()
                let d = (SIMD2(Float(x), Float(y)) - face) / SIMD2(150, 120)
                weight[y * width + x] = simd_length(d) < 1 ? 1 : 0
            }
        }
        let inside: [DustScene.Spot] = [
            .init(centre: [200, 150], radius: 3, attenuation: 6), .init(centre: [300, 230], radius: 5, attenuation: 4),
            .init(centre: [250, 260], radius: 8, attenuation: 5), .init(centre: [330, 160], radius: 4, attenuation: 8)]
        let outside = DustScene.Spot(centre: [60, 60], radius: 5, attenuation: 8)
        for spot in inside + [outside] {
            DustScene.paint(&values, width: width, height: height, around: spot.centre, reach: 2 * spot.radius + 4) { p in
                spot.attenuation * DustScene.profile(simd_distance(p, spot.centre), radius: spot.radius)
            }
        }
        // A green dip inside the face: the wrong polarity.
        DustScene.paint(&values, width: width, height: height, around: [180, 230], reach: 14) { p in
            -8 * DustScene.profile(simd_distance(p, [180, 230]), radius: 5)
        }
        let map = BlobDetector.Map(values: values, width: width, height: height, weight: weight)
        let p = BlobDetector.Parameters(radiusRange: 2...10, polarity: .reddish, contrastSigma: 2.5, minimumContrast: 2,
                                        minimumCircularity: 0.6, smoothSurround: 3, maximumSurroundGradient: nil, maximumCount: 64)
        let blobs = BlobDetector.detect(map, p)
        let t = DustScene.tally(blobs, against: inside)
        XCTAssertEqual(t.truePositives, inside.count, "\(blobs)")
        XCTAssertEqual(t.falsePositives, 0, "\(blobs)")
        for (spot, blob) in t.matched {
            XCTAssertEqual(blob.radius, spot.radius, accuracy: 0.3 * spot.radius)
            XCTAssertEqual(blob.contrast, spot.attenuation, accuracy: 0.3 * spot.attenuation + 0.5)
        }
        // With no weight map the one outside the face is a blob too.
        let unweighted = BlobDetector.detect(BlobDetector.Map(values: values, width: width, height: height), p)
        XCTAssertEqual(DustScene.tally(unweighted, against: inside + [outside]).truePositives, inside.count + 1)
        // Dark polarity on the same map finds the green dip and nothing red.
        var dark = p
        dark.polarity = .dark
        let dips = BlobDetector.detect(BlobDetector.Map(values: values, width: width, height: height), dark)
        XCTAssertEqual(dips.count, 1)
        XCTAssertEqual(dips.first.map { simd_distance($0.centre, [180, 230]) } ?? 99, 0, accuracy: 1.5)
    }

    func testLocalNoiseFollowsTheNoise() {
        let width = 512, height = 256
        var rng = DustScene.Generator(seed: 9)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let sigma: Float = x < width / 2 ? 0.02 : 0.06
                values[y * width + x] = DustScene.sky(x: Float(x), y: Float(y), width: width, height: height) + sigma * rng.gaussian()
            }
        }
        let noise = BlobDetector.localNoise(BlobDetector.Map(values: values, width: width, height: height))
        XCTAssertEqual(noise.count, width * height)
        // A one-pixel blur leaves about 87 % of white noise in the residual.
        XCTAssertEqual(noise[128 * width + 100], 0.02, accuracy: 0.005)
        XCTAssertEqual(noise[128 * width + 400], 0.06, accuracy: 0.012)
        XCTAssertGreaterThan(noise[128 * width + 300], noise[128 * width + 200], "rises across the seam")
        XCTAssertLessThan(noise[128 * width + 256], noise[128 * width + 400])
        XCTAssertEqual(BlobDetector.localNoise(BlobDetector.Map(values: [], width: 0, height: 0)), [])
        // A flat map has no noise, and small maps still get a full-size answer.
        let flat = BlobDetector.localNoise(BlobDetector.Map(values: [Float](repeating: 1, count: 40 * 30), width: 40, height: 30))
        XCTAssertEqual(flat.count, 1200)
        XCTAssertEqual(flat.max() ?? 1, 0)
    }

    func testDifferenceOfGaussiansPeaksOnASpot() {
        let width = 256, height = 192
        var values = [Float](repeating: -2, count: width * height)
        let centre = SIMD2<Float>(120, 90)
        DustScene.paint(&values, width: width, height: height, around: centre, reach: 20) { p in
            log2(1 - 0.2 * DustScene.profile(simd_distance(p, centre), radius: 6))
        }
        for sigma: Float in [3, 6, 12] {
            let dog = BlobDetector.differenceOfGaussians(BlobDetector.Map(values: values, width: width, height: height), sigma: sigma)
            XCTAssertEqual(dog.count, width * height)
            let peak = dog.indices.max { dog[$0] < dog[$1] }!
            XCTAssertEqual(peak % width, 120, accuracy: 1, "σ=\(sigma)")
            XCTAssertEqual(peak / width, 90, accuracy: 1, "σ=\(sigma)")
            XCTAssertGreaterThan(dog[peak], 0.05 * 0.32, "a dip is positive, σ=\(sigma)")
            XCTAssertEqual(dog[10 * width + 10], 0, accuracy: 1e-4, "flat far away")
        }
    }

    /// A 24 MP raw's analysis map (3000 × 2000 after binning) at the Large
    /// band in under 400 ms, with the noise map already measured as
    /// `DustDetector.Analysis` keeps it. The time is printed every run and
    /// asserted only under `LATENT_PERF=1`, since CI's shared runner can
    /// take twice as long as a Mac at the desk (it did once: 408 ms).
    func testLargeBandTimingOnA24MPMap() {
        let scene = DustScene.make(width: 3000, height: 2000, noise: 0.02, spotCount: 100, radii: 6...20,
                                   attenuation: 0.08...0.3, decoys: true, seed: 21)
        let p = DustDetector.blobParameters(options: .init(size: .large), expectedRadius: nil, binSpan: 2)
        XCTAssertEqual(p.radiusRange, 6...20)
        let noiseStart = Date()
        let noise = BlobDetector.localNoise(scene.map)
        let noiseSeconds = Date().timeIntervalSince(noiseStart)
        var times: [TimeInterval] = []
        var blobs: [BlobDetector.Blob] = []
        for _ in 0..<3 {
            let start = Date()
            blobs = BlobDetector.detect(scene.map, p, noise: noise)
            times.append(Date().timeIntervalSince(start))
        }
        let t = DustScene.tally(blobs, against: scene.spots)
        print("BlobDetector Large band on 3000×2000: detect \(times.map { Int($0 * 1000) }) ms (noise \(Int(noiseSeconds * 1000)) ms), precision \(t.precision) recall \(t.recall)")
        if ProcessInfo.processInfo.environment["LATENT_PERF"] == "1" {
            XCTAssertLessThanOrEqual(times.min()!, 0.4)
        }
        XCTAssertGreaterThanOrEqual(t.recall, 0.8)
        XCTAssertGreaterThanOrEqual(t.precision, 0.9)
    }

    func testDegenerateInputsFindNothing() {
        let p = DustScene.parameters(sensitivity: 50, radii: 3...12)
        XCTAssertEqual(BlobDetector.detect(BlobDetector.Map(values: [], width: 0, height: 0), p), [])
        XCTAssertEqual(BlobDetector.detect(BlobDetector.Map(values: [1, 2], width: 2, height: 2), p), [], "wrong count")
        let tiny = BlobDetector.Map(values: [Float](repeating: 0, count: 16), width: 4, height: 4)
        XCTAssertEqual(BlobDetector.detect(tiny, p), [])
        XCTAssertEqual(BlobDetector.differenceOfGaussians(BlobDetector.Map(values: [], width: 0, height: 0), sigma: 3), [])
    }
}
