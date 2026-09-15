import Foundation
import simd

// Exposure: how much to multiply each photo by so the panorama is evenly
// bright, from EXIF and refined on what overlapping photos actually show.

struct PanoramaGainSolution: Sendable {
    /// Multiply the photo's linear pixels by this, by frame index.
    var gains: [Int: Double]
    /// What EXIF alone says, by frame index.
    var exifGains: [Int: Double]
    /// Each pair measured: how many stops brighter the first photo recorded
    /// the overlap than the second, and from how many texels.
    var measurements: [PairKey: (stops: Double, samples: Int)]
}

/// Gain compensation.
///
/// **From EXIF.** A photo gathers light in proportion to shutter time x ISO
/// / f-number². Dividing the median photo's exposure by each photo's gives
/// the gain that brings it to the median's brightness: a photo shot at f/2.5
/// beside ones at f/3.5 gathered (3.5 / 2.5)² = 1.96 times the light, and
/// gets a gain of about 0.51.
///
/// **From the pixels.** EXIF is rounded (apertures to a sixth of a stop,
/// shutter speeds to nominal values), and lenses and shutters are never
/// exact, so each overlapping pair is also measured: the median difference
/// in log luminance between the two photos at the same scene points, over
/// texels both recorded well. Then one small least-squares solve finds the
/// gains that make every pair agree, with EXIF as a prior that holds the
/// overall brightness and any photo the measurements say little about.
///
/// **Why the median.** Someone walking through the overlap, or a cloud
/// that moved, is brighter or darker in one photo only; the median ignores
/// them where a mean would be pulled.
enum PanoramaGainSolver {
    /// How far EXIF's exposure is trusted, in stops (one sigma).
    static let exifSigmaStops = 0.25
    /// How precise a pair measurement from plenty of texels is, in stops.
    static let measurementSigmaStops = 0.02
    /// Fewest shared texels for a pair to be measured.
    static let minimumSamples = 64
    /// Texels are measured this far apart on the first photo's thumbnail.
    static let sampleStep = 3
    /// Linear luminance (white = 1) below which a texel is noise.
    static let darkest: Float = 1.0 / 1024

    static func solve(cameras: [PanoramaCamera], thumbnails: [Int: PanoramaThumbnail],
                      exposures: [Int: Double?]) -> PanoramaGainSolution {
        // EXIF: relative to the median of the known exposures.
        let known = exposures.values.compactMap { $0 }.sorted()
        let median = known.isEmpty ? nil : known[(known.count - 1) / 2]
        var exifGains: [Int: Double] = [:]
        for camera in cameras {
            if let e = exposures[camera.frameIndex] ?? nil, let median, e > 0 {
                exifGains[camera.frameIndex] = median / e
            } else {
                exifGains[camera.frameIndex] = 1
            }
        }

        var measurements: [PairKey: (stops: Double, samples: Int)] = [:]
        let luminances = thumbnails.mapValues(\.luminance)
        for a in cameras.indices {
            for b in cameras.indices where b > a {
                guard let m = measure(cameras[a], cameras[b], thumbnails, luminances) else { continue }
                measurements[PairKey(first: cameras[a].frameIndex, second: cameras[b].frameIndex)] = m
            }
        }

        // Least squares in log2 gains x: for each pair, x_a - x_b = -stops
        // (g_a L_a = g_b L_b); for each photo, x = log2(EXIF gain).
        let n = cameras.count
        var slot: [Int: Int] = [:]
        for (k, camera) in cameras.enumerated() { slot[camera.frameIndex] = k }
        var normal = [Double](repeating: 0, count: n * n)
        var right = [Double](repeating: 0, count: n)
        let prior = 1 / (exifSigmaStops * exifSigmaStops)
        for camera in cameras {
            let k = slot[camera.frameIndex]!
            normal[k * n + k] += prior
            right[k] += prior * log2(exifGains[camera.frameIndex]!)
        }
        for (key, m) in measurements {
            // Fewer samples, less weight; beyond a few hundred the median's
            // precision is limited by the scene, not the count.
            let weight = Double(m.samples) / Double(m.samples + 200) / (measurementSigmaStops * measurementSigmaStops)
            let a = slot[key.first]!, b = slot[key.second]!
            normal[a * n + a] += weight; normal[b * n + b] += weight
            normal[a * n + b] -= weight; normal[b * n + a] -= weight
            right[a] -= weight * m.stops
            right[b] += weight * m.stops
        }
        var gains: [Int: Double] = [:]
        let solved = PanoramaCameraSolver.solveSymmetric(normal, right, n: n)
        for camera in cameras {
            let k = slot[camera.frameIndex]!
            gains[camera.frameIndex] = solved.map { pow(2, $0[k]) } ?? exifGains[camera.frameIndex]!
        }
        return PanoramaGainSolution(gains: gains, exifGains: exifGains, measurements: measurements)
    }

    /// The median log2 luminance difference, first photo minus second, over
    /// texels of the first's thumbnail that the second also recorded well.
    static func measure(_ a: PanoramaCamera, _ b: PanoramaCamera,
                        _ thumbnails: [Int: PanoramaThumbnail], _ luminances: [Int: [Float]]) -> (stops: Double, samples: Int)? {
        guard let ta = thumbnails[a.frameIndex], let tb = thumbnails[b.frameIndex],
              let la = luminances[a.frameIndex], let lb = luminances[b.frameIndex] else { return nil }
        // Photos whose axes are further apart than both their half diagonals
        // can't overlap.
        func halfDiagonal(_ c: PanoramaCamera) -> Double {
            atan((Double(c.width * c.width + c.height * c.height)).squareRoot() / 2 / c.focalLengthPixels)
        }
        let axisA = a.rotationMatrix * SIMD3(0, 0, 1), axisB = b.rotationMatrix * SIMD3(0, 0, 1)
        guard acos(min(1, max(-1, simd_dot(axisA, axisB)))) < halfDiagonal(a) + halfDiagonal(b) else { return nil }
        var differences: [Float] = []
        let span = Double(ta.span)
        for j in stride(from: 0, to: ta.height, by: sampleStep) {
            for i in stride(from: 0, to: ta.width, by: sampleStep) {
                let ia = j * ta.width + i
                guard ta.isUsable(ia), la[ia] > darkest else { continue }
                let p = SIMD2((Double(i) + 0.5) * span, (Double(j) + 0.5) * span)
                let d = PanoramaMath.direction(framePixel: p, camera: a)
                guard let q = PanoramaMath.framePixel(direction: d, camera: b),
                      let value = usableSample(tb, lb, q) else { continue }
                differences.append(log2(la[ia]) - log2(value))
            }
        }
        guard differences.count >= minimumSamples else { return nil }
        differences.sort()
        return (Double(differences[differences.count / 2]), differences.count)
    }

    /// Bilinear luminance of `t` at full-resolution point `q`, if all four
    /// texels it blends are usable and bright enough.
    static func usableSample(_ t: PanoramaThumbnail, _ luminance: [Float], _ q: SIMD2<Double>) -> Float? {
        let x = q.x / Double(t.span) - 0.5, y = q.y / Double(t.span) - 0.5
        let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
        guard ix >= 0, iy >= 0, ix + 1 < t.width, iy + 1 < t.height else { return nil }
        let fx = Float(x - Double(ix)), fy = Float(y - Double(iy))
        let k = iy * t.width + ix
        for n in [k, k + 1, k + t.width, k + t.width + 1] {
            guard t.isUsable(n), luminance[n] > darkest else { return nil }
        }
        return (1 - fx) * (1 - fy) * luminance[k] + fx * (1 - fy) * luminance[k + 1]
            + (1 - fx) * fy * luminance[k + t.width] + fx * fy * luminance[k + t.width + 1]
    }
}
