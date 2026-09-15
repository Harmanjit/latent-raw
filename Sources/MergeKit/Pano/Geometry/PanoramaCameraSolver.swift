import Foundation
import simd

// The camera solve: from pairwise registrations to one rotation per photo
// and a shared focal length, adjusted together so a long sequence doesn't
// drift, then turned so the horizon is level.

/// What the camera solve found.
struct PanoramaCameraSolution: Sendable {
    /// Camera-to-world rotation of every connected frame, by frame index.
    var rotations: [Int: simd_double3x3]
    /// Shared focal length, full-resolution pixels.
    var focal: Double
    /// Root-mean-square distance, in full-resolution pixels, between where
    /// the cameras put each correspondence and where it was seen.
    var rmsError: Double
    /// The same per pair, keyed by (first, second).
    var pairErrors: [PairKey: Double]
    /// Pairs the solve dropped because they disagreed with the rest.
    var droppedPairs: [PairKey]
}

struct PairKey: Hashable, Sendable {
    let first: Int
    let second: Int
}

enum PanoramaCameraSolver {
    /// A pair's error must be this many times the typical pair's, and at
    /// least `outlierFloorTexels` thumbnail texels, before it is dropped as
    /// a wrong match.
    static let outlierFactor = 5.0
    static let outlierFloorTexels = 3.0
    /// Correspondences further than this (full-resolution pixels) from
    /// where the cameras put them pull less (Huber weighting): a person who
    /// walked, a cloud that moved.
    static let huberPixels = 16.0
    /// How far (in log focal length) the solve's focal length is expected to
    /// stray from EXIF's: 10%. Only matters when the photos can't say (all
    /// of them in a straight line, say); otherwise the correspondences decide.
    static let focalPriorSigma = 0.1

    /// Solves the cameras of every frame the accepted pairs connect to the
    /// best-connected frame.
    ///
    /// - Parameters:
    ///   - centres: each frame's principal point (full resolution).
    ///   - focal: EXIF's focal length in pixels, the starting point.
    ///   - refineFocal: adjust the focal length too.
    ///   - span: thumbnail span, for the outlier floor.
    static func solve(pairs: [PanoramaPairRegistration], frameCount: Int, centres: [SIMD2<Double>], focal: Double,
                      refineFocal: Bool, span: Int) -> PanoramaCameraSolution {
        var active = pairs.filter { $0.accepted && $0.correspondences.count >= 4 }
        var dropped: [PairKey] = []
        var solution = PanoramaCameraSolution(rotations: [:], focal: focal, rmsError: 0, pairErrors: [:],
                                              droppedPairs: [])
        for _ in 0..<4 {
            let initial = initialRotations(pairs: active, frameCount: frameCount, centres: centres, focal: focal)
            solution = bundleAdjust(pairs: active, rotations: initial, centres: centres, focalPrior: focal,
                                    refineFocal: refineFocal)
            // A pair far worse than the rest is a wrong match: drop it and
            // solve again without it.
            let errors = solution.pairErrors.values.sorted()
            guard let median = errors.isEmpty ? nil : errors[errors.count / 2] else { break }
            let limit = max(outlierFactor * median, outlierFloorTexels * Double(span))
            guard let worst = solution.pairErrors.max(by: { $0.value < $1.value }), worst.value > limit else { break }
            dropped.append(worst.key)
            active.removeAll { PairKey(first: $0.first, second: $0.second) == worst.key }
        }
        solution.droppedPairs = dropped
        return solution
    }

    // MARK: - Starting rotations

    /// Rotations from the pairwise homographies along a maximum spanning
    /// tree (the pairs with the most correspondences first), starting from
    /// the frame with the most correspondences overall at the identity.
    ///
    /// **From a pair to a rotation.** A camera turning about its lens maps
    /// the first photo's pixels to the second's by H = K R₂ᵀ R₁ K⁻¹, so the
    /// relative rotation R₂ᵀ R₁ takes each ray through a first-photo point
    /// to the ray through where the second photo saw it
    /// (`relativeRotation`). Fitting it to the pair's correspondences, rather
    /// than orthonormalising K⁻¹ H K directly, weighs every part of the
    /// overlap by where it is seen, not by how the matrix entries happen to
    /// scale (the homography's perspective terms are multiplied by the
    /// focal length there, and their small errors would tilt the result).
    static func initialRotations(pairs: [PanoramaPairRegistration], frameCount: Int, centres: [SIMD2<Double>],
                                 focal: Double) -> [Int: simd_double3x3] {
        guard !pairs.isEmpty else { return [:] }
        var strength = [Int](repeating: 0, count: frameCount)
        for p in pairs {
            strength[p.first] += p.correspondences.count
            strength[p.second] += p.correspondences.count
        }
        let root = strength.indices.max { strength[$0] < strength[$1] }!
        var rotations: [Int: simd_double3x3] = [root: matrix_identity_double3x3]
        // Prim's algorithm: repeatedly take the strongest pair joining a
        // solved frame to an unsolved one.
        while true {
            let candidates = pairs.filter { (rotations[$0.first] == nil) != (rotations[$0.second] == nil) }
            guard let best = candidates.max(by: { $0.correspondences.count < $1.correspondences.count }) else { break }
            let relative = relativeRotation(best.correspondences, centreA: centres[best.first],
                                            centreB: centres[best.second], focal: focal)
            if let r1 = rotations[best.first] {
                rotations[best.second] = r1 * relative.transpose
            } else if let r2 = rotations[best.second] {
                rotations[best.first] = r2 * relative
            }
        }
        return rotations
    }

    /// The rotation taking rays of the first photo to rays of the second
    /// that best explains `correspondences`, for focal length `focal`.
    static func relativeRotation(_ correspondences: [PanoramaCorrespondence], centreA: SIMD2<Double>,
                                 centreB: SIMD2<Double>, focal: Double) -> simd_double3x3 {
        func ray(_ p: SIMD2<Double>, _ c: SIMD2<Double>) -> SIMD3<Double> {
            simd_normalize(SIMD3((p.x - c.x) / focal, (p.y - c.y) / focal, 1))
        }
        return PanoramaRotation.fit(from: correspondences.map { ray($0.first, centreA) },
                                    to: correspondences.map { ray($0.second, centreB) })
    }

    // MARK: - Bundle adjustment

    /// Levenberg-Marquardt over every camera's rotation (the root's stays
    /// put, fixing the panorama's overall direction) and, optionally, the
    /// shared focal length, minimising how far each correspondence lands
    /// from where it was seen, both ways round.
    ///
    /// **Why adjust everything together.** Chaining pair rotations adds up
    /// their small errors: after 16 links the last frame can be pixels off
    /// its neighbour. Fitting all correspondences at once spreads the error
    /// evenly, and a pair's error can't pile up.
    ///
    /// **The residual.** For a point p₁ seen in photo 1 and p₂ in photo 2:
    /// the ray through p₁, turned from camera 1 into the world and into
    /// camera 2, projected with the focal length, minus p₂; and the same
    /// from 2 to 1. Derivatives are numerical, block by block (each residual
    /// depends only on its two cameras and the focal length), and the normal
    /// equations are small (3 per camera plus 1), so they are solved directly.
    static func bundleAdjust(pairs: [PanoramaPairRegistration], rotations initial: [Int: simd_double3x3],
                             centres: [SIMD2<Double>], focalPrior: Double, refineFocal: Bool) -> PanoramaCameraSolution {
        var rotations = initial
        guard !rotations.isEmpty else {
            return PanoramaCameraSolution(rotations: [:], focal: focalPrior, rmsError: 0, pairErrors: [:], droppedPairs: [])
        }
        let usable = pairs.filter { rotations[$0.first] != nil && rotations[$0.second] != nil }
        // The root: the frame the starting rotations put at the identity.
        let root = rotations.first { PanoramaRotation.angle(between: $0.value, and: matrix_identity_double3x3) < 1e-12 }?.key
            ?? rotations.keys.min()!
        let free = rotations.keys.filter { $0 != root }.sorted()
        var slot: [Int: Int] = [:]
        for (n, frame) in free.enumerated() { slot[frame] = n * 3 }
        let focalSlot = refineFocal ? free.count * 3 : -1
        let parameterCount = free.count * 3 + (refineFocal ? 1 : 0)
        var logFocal = log(focalPrior)
        let logFocalPrior = logFocal

        /// The residual of one correspondence seen from `a` into `b`.
        func residual(_ pa: SIMD2<Double>, _ pb: SIMD2<Double>, _ ra: simd_double3x3, _ rb: simd_double3x3,
                      _ ca: SIMD2<Double>, _ cb: SIMD2<Double>, _ f: Double) -> SIMD2<Double> {
            let ray = ra * SIMD3((pa.x - ca.x) / f, (pa.y - ca.y) / f, 1)
            let v = rb.transpose * ray
            guard v.z > 1e-9 else { return SIMD2(1e4, 1e4) }
            return SIMD2(f * v.x / v.z, f * v.y / v.z) + cb - pb
        }

        func evaluate(_ rotations: [Int: simd_double3x3], _ logF: Double)
        -> (cost: Double, perPair: [PairKey: (sum: Double, count: Int)]) {
            let f = Foundation.exp(logF)
            var cost = 0.0
            var perPair: [PairKey: (sum: Double, count: Int)] = [:]
            for p in usable {
                let r1 = rotations[p.first]!, r2 = rotations[p.second]!
                var sum = 0.0
                for c in p.correspondences {
                    for e in [residual(c.first, c.second, r1, r2, centres[p.first], centres[p.second], f),
                              residual(c.second, c.first, r2, r1, centres[p.second], centres[p.first], f)] {
                        let squared = simd_length_squared(e)
                        sum += squared
                        cost += huber(squared)
                    }
                }
                perPair[PairKey(first: p.first, second: p.second)] = (sum, 2 * p.correspondences.count)
            }
            if refineFocal {
                let z = (logF - logFocalPrior) / focalPriorSigma
                cost += z * z
            }
            return (cost, perPair)
        }

        var lambda = 1e-3
        var current = evaluate(rotations, logFocal)
        let step = 1e-6
        for _ in 0..<60 {
            var normal = [Double](repeating: 0, count: parameterCount * parameterCount)
            var gradient = [Double](repeating: 0, count: parameterCount)
            let f = Foundation.exp(logFocal)
            for p in usable {
                let r1 = rotations[p.first]!, r2 = rotations[p.second]!
                let c1 = centres[p.first], c2 = centres[p.second]
                // This block's parameters: first's rotation, second's, focal.
                var indices: [Int] = []
                for frame in [p.first, p.second] {
                    if let s = slot[frame] { indices += [s, s + 1, s + 2] } else { indices += [-1, -1, -1] }
                }
                indices.append(focalSlot)
                for c in p.correspondences {
                    for forward in [true, false] {
                        func r(_ ra: simd_double3x3, _ rb: simd_double3x3, _ f: Double) -> SIMD2<Double> {
                            forward ? residual(c.first, c.second, ra, rb, c1, c2, f)
                                : residual(c.second, c.first, rb, ra, c2, c1, f)
                        }
                        let e = r(r1, r2, f)
                        let squared = simd_length_squared(e)
                        let weight = huberWeight(squared)
                        // Numerical derivatives of both components.
                        var columns = [SIMD2<Double>](repeating: .zero, count: 7)
                        for k in 0..<7 where indices[k] >= 0 {
                            var ra = r1, rb = r2, ff = f
                            switch k {
                            case 0, 1, 2:
                                var d = SIMD3<Double>.zero; d[k] = step
                                ra = r1 * PanoramaRotation.exp(d)
                            case 3, 4, 5:
                                var d = SIMD3<Double>.zero; d[k - 3] = step
                                rb = r2 * PanoramaRotation.exp(d)
                            default:
                                ff = Foundation.exp(logFocal + step)
                            }
                            columns[k] = (r(ra, rb, ff) - e) / step
                        }
                        for a in 0..<7 where indices[a] >= 0 {
                            gradient[indices[a]] += weight * simd_dot(columns[a], e)
                            for b in 0..<7 where indices[b] >= 0 {
                                normal[indices[a] * parameterCount + indices[b]] += weight * simd_dot(columns[a], columns[b])
                            }
                        }
                    }
                }
            }
            if refineFocal {
                let z = (logFocal - logFocalPrior) / focalPriorSigma
                gradient[focalSlot] += z / focalPriorSigma
                normal[focalSlot * parameterCount + focalSlot] += 1 / (focalPriorSigma * focalPriorSigma)
            }

            // Levenberg-Marquardt: try a damped step; keep it if the cost
            // falls, otherwise damp harder and try again.
            var improved = false
            for _ in 0..<10 {
                var damped = normal
                for i in 0..<parameterCount {
                    damped[i * parameterCount + i] += lambda * max(normal[i * parameterCount + i], 1e-9)
                }
                guard let delta = solveSymmetric(damped, gradient.map { -$0 }, n: parameterCount) else { lambda *= 10; continue }
                var trial = rotations
                for frame in free {
                    let s = slot[frame]!
                    trial[frame] = rotations[frame]! * PanoramaRotation.exp(SIMD3(delta[s], delta[s + 1], delta[s + 2]))
                }
                let trialFocal = refineFocal ? logFocal + delta[focalSlot] : logFocal
                let result = evaluate(trial, trialFocal)
                if result.cost < current.cost {
                    let relative = (current.cost - result.cost) / max(current.cost, 1e-30)
                    rotations = trial
                    logFocal = trialFocal
                    current = result
                    lambda = max(lambda / 10, 1e-12)
                    improved = relative > 1e-10
                    break
                }
                lambda *= 10
            }
            if !improved { break }
        }

        var total = 0.0, count = 0
        var pairErrors: [PairKey: Double] = [:]
        for (key, value) in current.perPair {
            total += value.sum
            count += value.count
            pairErrors[key] = (value.sum / Double(max(value.count, 1))).squareRoot()
        }
        return PanoramaCameraSolution(rotations: rotations, focal: Foundation.exp(logFocal),
                                      rmsError: (total / Double(max(count, 1))).squareRoot(),
                                      pairErrors: pairErrors, droppedPairs: [])
    }

    @inline(__always)
    static func huber(_ squared: Double) -> Double {
        let d = huberPixels
        return squared <= d * d ? squared : 2 * d * squared.squareRoot() - d * d
    }

    @inline(__always)
    static func huberWeight(_ squared: Double) -> Double {
        let d = huberPixels
        return squared <= d * d ? 1 : d / squared.squareRoot()
    }

    /// Solves the symmetric positive-definite system `a x = b` (row-major
    /// n x n) by Cholesky factorisation; nil if it isn't positive definite.
    static func solveSymmetric(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        guard n > 0 else { return [] }
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i * n + j]
                for k in 0..<j { sum -= l[i * n + k] * l[j * n + k] }
                if i == j {
                    guard sum > 0, sum.isFinite else { return nil }
                    l[i * n + i] = sum.squareRoot()
                } else {
                    l[i * n + j] = sum / l[j * n + j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = b[i]
            for k in 0..<i { sum -= l[i * n + k] * y[k] }
            y[i] = sum / l[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            for k in (i + 1)..<n { sum -= l[k * n + i] * x[k] }
            x[i] = sum / l[i * n + i]
        }
        return x
    }

    // MARK: - Straightening

    /// A rotation of the whole panorama that makes its horizon level and
    /// centres it: `level * R` for every camera R.
    ///
    /// **Which way is up.** People turn a camera about the vertical, keeping
    /// its sideways axis (+x) roughly horizontal whether it points up or
    /// down, so across a sweep the cameras' +x axes all lie in the horizontal
    /// plane, and the direction square to all of them is vertical: the
    /// eigenvector of Σ xᵢxᵢᵀ with the smallest eigenvalue. That also takes
    /// out a roll that builds up across the sequence, which averaging would
    /// leave as a slope. With too narrow a sweep for the +x axes to span a
    /// plane (the second-smallest eigenvalue tiny), the cameras' average down
    /// direction is used instead.
    ///
    /// **Where the centre is.** The middle of the arc the cameras' viewing
    /// directions cover around that vertical, so a 270° panorama is centred
    /// on its own middle rather than on the mean of its directions.
    static func levelling(_ rotations: [simd_double3x3]) -> simd_double3x3 {
        guard !rotations.isEmpty else { return matrix_identity_double3x3 }
        var scatter = [[Double]](repeating: [0, 0, 0], count: 3)
        var down = SIMD3<Double>.zero
        for r in rotations {
            let x = r * SIMD3(1, 0, 0)
            for i in 0..<3 { for j in 0..<3 { scatter[i][j] += x[i] * x[j] } }
            down += r * SIMD3(0, 1, 0)
        }
        let (values, vectors) = PanoramaRotation.symmetricEigen(scatter)
        let order = values.indices.sorted { values[$0] < values[$1] }
        var up = SIMD3(vectors[order[0]][0], vectors[order[0]][1], vectors[order[0]][2])
        // The +x axes span a plane when the second eigenvalue is a fair share
        // of the largest: a sweep of about 20° or more.
        let spansPlane = values[order[1]] > 0.02 * max(values[order[2]], 1e-12)
        var vertical = simd_normalize(down)
        if spansPlane {
            if simd_dot(up, down) < 0 { up = -up }
            vertical = simd_normalize(up)
        }
        // Horizontal directions: project each camera's view onto the plane
        // square to the vertical, in a basis of that plane.
        var reference = SIMD3<Double>(0, 0, 1) - vertical * vertical.z
        if simd_length(reference) < 1e-6 { reference = SIMD3(1, 0, 0) - vertical * vertical.x }
        reference = simd_normalize(reference)
        let side = simd_cross(vertical, reference)
        let angles = rotations.map { r -> Double in
            let forward = r * SIMD3(0, 0, 1)
            return atan2(simd_dot(forward, side), simd_dot(forward, reference))
        }.sorted()
        // The centre of the smallest arc holding every direction: opposite
        // the middle of the largest gap between neighbouring directions.
        var gapStart = angles.last! - 2 * .pi, gapSize = angles.first! - (angles.last! - 2 * .pi)
        for k in 1..<angles.count where angles[k] - angles[k - 1] > gapSize {
            gapStart = angles[k - 1]
            gapSize = angles[k] - angles[k - 1]
        }
        let centreAngle = gapStart + gapSize / 2 + .pi
        let forward = simd_normalize(reference * cos(centreAngle) + side * sin(centreAngle))
        // World axes as columns in the old frame: x right, y down, z forward.
        let right = simd_cross(vertical, forward)
        let axes = simd_double3x3(columns: (right, vertical, forward))
        return axes.transpose
    }
}
