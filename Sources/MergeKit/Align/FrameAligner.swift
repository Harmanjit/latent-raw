import Foundation
import simd

// Frame alignment's public face: align one frame to another, check the
// answer can be trusted, and chain neighbour alignments to a reference.

/// What kind of merge the frames are for; it decides which answers make sense.
public enum AlignmentModel: Sendable, Equatable {
    /// A bracket shot from (nearly) one spot: frames overlap almost
    /// completely, and a scale change means something went wrong (a camera
    /// doesn't zoom between bracket frames).
    case hdr
    /// Overlapping frames of a camera turning: any homography goes.
    case panorama
}

/// Why an alignment wasn't accepted.
public enum AlignmentRejection: Sendable, Equatable {
    /// The frames' exposures share less than a stop of usable range, so
    /// there is nothing both recorded well to compare.
    case noSharedExposureRange
    /// The frames overlap by this share of the reference, below the minimum.
    case insufficientOverlap(fraction: Double)
    /// Too few pixels both frames recorded well were left to judge by.
    case notEnoughDetail
    /// The frames differ in scale by this fraction, more than a bracket can.
    case scaleChange(fraction: Double)
    /// After warping, the frames correlate only this well (NCC), below the minimum.
    case lowCorrelation(ncc: Double)
    /// The refinement produced no usable homography.
    case refinementFailed
    /// A chained alignment: the link between frames `link` and `link + 1`
    /// was rejected, so this frame couldn't be carried to the reference.
    case chainBroken(link: Int)
}

/// The outcome of aligning a moving frame to a reference frame.
public struct AlignmentResult: Sendable, Equatable {
    /// What to warp the moving frame by: moving -> reference, in
    /// full-resolution pixel coordinates with a top-left origin (see
    /// `Homography`). Exactly the identity when the frame needn't move
    /// (accepted with `maxCornerShift` under the no-warp limit) or when the
    /// alignment was rejected, so the merge falls back to unaligned.
    public var homography: simd_double3x3
    /// What the refinement found, whether or not it was accepted: for
    /// reports and for composing chains.
    public var estimatedHomography: simd_double3x3
    /// How far the estimate moves the moving frame's corners, at most, in
    /// full-resolution pixels.
    public var maxCornerShift: Double
    /// Normalised cross-correlation between the reference and the warped
    /// moving frame, over pixels both recorded well (1 = identical up to
    /// brightness and contrast).
    public var ncc: Double
    /// The share of the reference the warped moving frame covers.
    public var overlapFraction: Double
    /// How much the estimate enlarges the frame at its centre: 0.01 = 1%.
    public var scaleChange: Double
    /// Whether the finest level's refinement settled (its last step moved
    /// the corners less than 0.002 level pixels) rather than running out of
    /// iterations.
    public var converged: Bool
    public var accepted: Bool
    /// Why not accepted; nil when accepted.
    public var rejection: AlignmentRejection?

    /// Whether the moving frame must be resampled.
    public var needsWarp: Bool { !Homography.isIdentity(homography) }

    /// This result read the other way round (reference -> moving), for
    /// chaining a link aligned in the opposite direction.
    public func inverted(movingWidth: Int, movingHeight: Int) -> AlignmentResult {
        var result = self
        result.estimatedHomography = Homography.normalised(estimatedHomography.inverse)
        result.homography = Homography.isIdentity(homography) ? Homography.identity
            : Homography.normalised(homography.inverse)
        result.maxCornerShift = Homography.maxCornerShift(result.estimatedHomography, width: movingWidth,
                                                          height: movingHeight)
        result.scaleChange = Homography.scaleChange(result.estimatedHomography,
                                                    at: SIMD2(Double(movingWidth), Double(movingHeight)) / 2)
        return result
    }

    /// The reference aligned to itself.
    public static let identity = AlignmentResult(
        homography: Homography.identity, estimatedHomography: Homography.identity, maxCornerShift: 0, ncc: 1,
        overlapFraction: 1, scaleChange: 0, converged: true, accepted: true, rejection: nil)
}

/// Finds how a frame moved relative to another, from their `AlignmentImage`s.
///
/// **The steps** (docs/PhotoMerge.md section 0, "Vision spike"):
/// 1. The two frames' log images are clamped to the exposure range both
///    record well, and pixels outside it (or clipped) are set aside.
/// 2. Phase correlation at about 800 px gives a coarse shift (skipped when
///    the caller supplies an `initial` guess that works).
/// 3. ECC refinement fits a full homography, coarse to fine, over the
///    pyramid's levels up to 3200 px.
/// 4. The answer is checked: normalised cross-correlation of the warped
///    overlap at least 0.9, overlap at least 5%, and for HDR a scale change
///    of at most 2%. Only then is a tiny movement (under 0.1 px at the
///    corners) called "no warp needed": the check comes after refinement,
///    because a coarse estimate can't tell 0.05 px from 0.5 px.
///
/// If the answer fails the checks, the next starting point is tried (the
/// initial guess, the two best phase-correlation shifts, then no movement
/// at all); the best-scoring failure is reported when none passes.
///
/// A value type with its limits as properties; `align` is safe to call
/// from several threads at once. The work inside is spread over all cores.
public struct FrameAligner: Sendable {
    /// The least NCC to accept. The spike measured 0.96 or more for correct
    /// alignments and 0.4-0.8 for shifts of 30 px on real detail.
    public var minimumNCC = 0.9
    /// The least share of the reference the moving frame must cover.
    public var minimumOverlap = 0.05
    /// HDR only: the largest scale change to accept.
    public var maximumHDRScaleChange = 0.02
    /// Movements smaller than this at every corner (full-resolution pixels)
    /// need no warp.
    public var noWarpShift = 0.1
    /// Iterations allowed per pyramid level.
    public var maximumIterations = 20
    /// Down-weight pixels that disagree far more than most, such as moving
    /// leaves, water or people, so they pull the fit less.
    public var robust = true

    /// The level the coarse shift and the final score use.
    static let scoringLongEdge = 800

    public init() {}

    /// Aligns `moving` to `reference`.
    ///
    /// - Parameters:
    ///   - initial: a guess at moving -> reference (full-resolution pixels),
    ///     such as a neighbour's result; tried before phase correlation.
    public func align(moving: AlignmentImage, reference: AlignmentImage, model: AlignmentModel,
                      initial: simd_double3x3? = nil) -> AlignmentResult {
        guard let range = AlignmentPairRange(reference.exposure, moving.exposure) else {
            return rejected(.noSharedExposureRange, moving: moving)
        }
        let pair = PairLevels(reference: reference, moving: moving, range: range)

        var best: AlignmentResult?
        var tried: [simd_double3x3] = []
        func attempt(_ start: simd_double3x3) -> AlignmentResult? {
            guard Homography.isUsable(start),
                  !tried.contains(where: { Homography.maxCornerDistance($0, start, width: moving.fullWidth,
                                                                         height: moving.fullHeight) < 0.5 })
            else { return nil }
            tried.append(start)
            let result = refineAndCheck(start, pair: pair, model: model)
            if result.accepted { return result }
            if best == nil || result.ncc > best!.ncc { best = result }
            return nil
        }

        if let initial, let result = attempt(Homography.normalised(initial)) { return result }
        let coarse = coarseShifts(pair)
        if coarse.isEmpty, best == nil {
            best = rejected(.insufficientOverlap(fraction: 0), moving: moving)
        }
        // The two best-matching shifts: with repetitive detail or a small
        // overlap the right one is sometimes only second.
        for start in coarse.prefix(2) {
            if let result = attempt(start) { return result }
        }
        if let result = attempt(Homography.identity) { return result }
        return best ?? rejected(.refinementFailed, moving: moving)
    }

    /// How well `movingToReference` lines the frames up, without refining
    /// it: NCC and overlap. For tests and reports.
    ///
    /// - Parameter finestLevel: score at the finest level rather than the
    ///   800 px level `align` accepts by. The 800 px score is the one the
    ///   0.9 limit was calibrated on and shrugs off noise, but it can't see
    ///   the difference a fraction of a full-size pixel makes; the finest
    ///   level can.
    public func score(_ movingToReference: simd_double3x3, moving: AlignmentImage, reference: AlignmentImage,
                      finestLevel: Bool = false) -> (ncc: Double, overlapFraction: Double) {
        guard let range = AlignmentPairRange(reference.exposure, moving.exposure) else { return (0, 0) }
        let pair = PairLevels(reference: reference, moving: moving, range: range)
        let s = similarity(pair, referenceToMoving: movingToReference.inverse,
                           level: finestLevel ? pair.reference.levels.count - 1 : nil)
        return (s.ncc, s.overlap)
    }

    // MARK: - Chains

    /// Carries neighbour-to-neighbour alignments to one reference frame.
    ///
    /// **Why chain.** In a bracket spanning 8 stops, the darkest and
    /// brightest frames share almost no tones both recorded well, but each
    /// frame shares plenty with its neighbour. So each neighbour pair is
    /// aligned, and the pair homographies are multiplied together along
    /// the way to the reference.
    ///
    /// - Parameters:
    ///   - links: `links[k]` aligns frame k (moving) to frame k + 1
    ///     (reference); there is one fewer link than frames. A link measured
    ///     the other way (k + 1 onto k) can be turned round with `inverted`.
    ///   - reference: the frame everything is carried to.
    ///   - width, height: the frames' full-resolution size.
    /// - Returns: one result per frame, moving -> reference; the reference's
    ///   own is `AlignmentResult.identity`. A frame whose path crosses a
    ///   rejected link is rejected with `chainBroken`.
    public static func chain(_ links: [AlignmentResult], reference: Int, width: Int, height: Int) -> [AlignmentResult] {
        let frames = links.count + 1
        precondition(reference >= 0 && reference < frames, "reference must be a frame index")
        return (0..<frames).map { frame in
            guard frame != reference else { return .identity }
            // The links on the path, each as a map towards the reference.
            let path: [(index: Int, map: simd_double3x3)] = frame < reference
                ? (frame..<reference).map { ($0, links[$0].estimatedHomography) }
                : (reference..<frame).reversed().map { ($0, Homography.normalised(links[$0].estimatedHomography.inverse)) }
            if let broken = path.first(where: { !links[$0.index].accepted }) {
                var result = AlignmentResult.identity
                result.accepted = false
                result.rejection = .chainBroken(link: broken.index)
                result.ncc = 0
                result.converged = false
                return result
            }
            // Frame -> ... -> reference: later maps apply after earlier ones.
            let composed = Homography.normalised(path.reduce(Homography.identity) { $1.map * $0 })
            let used = path.map { links[$0.index] }
            let shift = Homography.maxCornerShift(composed, width: width, height: height)
            return AlignmentResult(
                homography: shift < FrameAligner().noWarpShift ? Homography.identity : composed,
                estimatedHomography: composed, maxCornerShift: shift,
                ncc: used.map(\.ncc).min() ?? 1, overlapFraction: used.map(\.overlapFraction).min() ?? 1,
                scaleChange: Homography.scaleChange(composed, at: SIMD2(Double(width), Double(height)) / 2),
                converged: used.allSatisfy(\.converged), accepted: true, rejection: nil)
        }
    }

    /// Aligns a whole bracket (`images` in exposure order) to
    /// `images[reference]`: neighbours pairwise, carried along the chain,
    /// and any frame the chain can't carry aligned directly to the
    /// reference instead. Holds every image at once; a merge that can't
    /// afford that aligns neighbours as it reads them and calls `chain`.
    public func alignBracket(_ images: [AlignmentImage], reference: Int, model: AlignmentModel = .hdr) -> [AlignmentResult] {
        guard images.count > 1 else { return images.map { _ in .identity } }
        let links = (0..<(images.count - 1)).map { k -> AlignmentResult in
            // Align towards the reference, so each pair's reference is the
            // frame nearer to it; turn the frames after it round.
            if k < reference { return align(moving: images[k], reference: images[k + 1], model: model) }
            return align(moving: images[k + 1], reference: images[k], model: model)
                .inverted(movingWidth: images[k].fullWidth, movingHeight: images[k].fullHeight)
        }
        var results = Self.chain(links, reference: reference, width: images[reference].fullWidth,
                                 height: images[reference].fullHeight)
        for (index, result) in results.enumerated() where !result.accepted {
            results[index] = align(moving: images[index], reference: images[reference], model: model)
        }
        return results
    }

    // MARK: - Steps

    /// Starting homographies from phase correlation, best-matching first.
    func coarseShifts(_ pair: PairLevels) -> [simd_double3x3] {
        let index = pair.index(nearest: Self.scoringLongEdge)
        let (ra, ma) = (pair.reference.levels[index], pair.moving.levels[index])
        let clampedA = AlignmentPlane.clamped(ra, range: pair.range)
        let clampedB = AlignmentPlane.clamped(ma, range: pair.range)
        let scored = PhaseCorrelation.candidates(reference: clampedA, moving: clampedB).compactMap {
            candidate -> (simd_double3x3, Double)? in
            // Level shift -> full resolution (reference -> moving), then
            // turned round to moving -> reference.
            let referenceToMoving = Homography.scale(1 / ma.scaleX, 1 / ma.scaleY)
                * Homography.translation(candidate.dx, candidate.dy) * Homography.scale(ra.scaleX, ra.scaleY)
            // Every other pixel is plenty to rank candidates.
            let s = similarity(pair, referenceToMoving: referenceToMoving, level: index, step: 2)
            guard s.overlap >= minimumOverlap, s.samples >= ECCRefinement.minimumSamples / 4 else { return nil }
            return (Homography.normalised(referenceToMoving.inverse), s.ncc)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Refines `start` over the pyramid and checks the answer.
    func refineAndCheck(_ start: simd_double3x3, pair: PairLevels, model: AlignmentModel) -> AlignmentResult {
        let moving = pair.moving, reference = pair.reference
        var referenceToMoving = start.inverse
        var alpha = 1.0, beta = 0.0
        var converged = false
        for index in pair.reference.levels.indices {
            let ra = reference.levels[index], ma = moving.levels[index]
            let planes = pair.planes(index)
            let sa = Homography.scale(ra.scaleX, ra.scaleY), sm = Homography.scale(ma.scaleX, ma.scaleY)
            let outcome = ECCRefinement.refine(reference: planes.reference, moving: planes.moving,
                                               gradients: planes.gradients,
                                               start: Homography.normalised(sm * referenceToMoving * sa.inverse),
                                               alpha: alpha, beta: beta, maxIterations: maximumIterations,
                                               robust: robust,
                                               stopStep: index == pair.reference.levels.count - 1
                                                   ? ECCRefinement.convergedStep : ECCRefinement.coarseConvergedStep)
            referenceToMoving = Homography.normalised(sm.inverse * outcome.referenceToMoving * sa)
            alpha = outcome.alpha
            beta = outcome.beta
            converged = outcome.converged
        }
        guard Homography.isUsable(referenceToMoving) else { return rejected(.refinementFailed, moving: moving) }

        let estimate = Homography.normalised(referenceToMoving.inverse)
        let s = similarity(pair, referenceToMoving: referenceToMoving)
        let shift = Homography.maxCornerShift(estimate, width: moving.fullWidth, height: moving.fullHeight)
        let scale = Homography.scaleChange(estimate, at: SIMD2(Double(moving.fullWidth), Double(moving.fullHeight)) / 2)
        var result = AlignmentResult(homography: Homography.identity, estimatedHomography: estimate,
                                     maxCornerShift: shift, ncc: s.ncc, overlapFraction: s.overlap,
                                     scaleChange: scale, converged: converged, accepted: false, rejection: nil)
        if s.overlap < minimumOverlap {
            result.rejection = .insufficientOverlap(fraction: s.overlap)
        } else if s.samples < ECCRefinement.minimumSamples {
            result.rejection = .notEnoughDetail
        } else if model == .hdr, abs(scale) > maximumHDRScaleChange {
            result.rejection = .scaleChange(fraction: scale)
        } else if !(s.ncc >= minimumNCC) {
            result.rejection = .lowCorrelation(ncc: s.ncc)
        } else {
            result.accepted = true
            result.homography = shift < noWarpShift ? Homography.identity : estimate
        }
        return result
    }

    /// NCC, overlap and sample count of the moving frame warped onto the
    /// reference at a level (the scoring level by default), over pixels
    /// both recorded well.
    ///
    /// **NCC** (normalised cross-correlation) is the correlation
    /// coefficient of the two sets of values: 1 when one is exactly a
    /// brighter or higher-contrast copy of the other, near 0 when unrelated.
    func similarity(_ pair: PairLevels, referenceToMoving: simd_double3x3, level: Int? = nil,
                    step: Int = 1) -> (ncc: Double, overlap: Double, samples: Int) {
        let index = level ?? pair.index(nearest: Self.scoringLongEdge)
        let ra = pair.reference.levels[index], ma = pair.moving.levels[index]
        let planes = pair.planes(index)
        let a = planes.reference, b = planes.moving
        let m = Homography.normalised(Homography.scale(ma.scaleX, ma.scaleY) * referenceToMoving
                                      * Homography.scale(1 / ra.scaleX, 1 / ra.scaleY))
        let rowCount = (a.height + step - 1) / step
        let bands = AlignmentSampling.bandCount(rows: rowCount)
        // Per band: n, sum a, sum b, sum a², sum b², sum ab, pixels inside.
        var sums = [Double](repeating: 0, count: bands * 7)
        let rows = m.transpose
        let (m0, m1, m2) = (rows[0].x, rows[0].y, rows[0].z)
        let (m3, m4, m5) = (rows[1].x, rows[1].y, rows[1].z)
        let (m6, m7, m8) = (rows[2].x, rows[2].y, rows[2].z)
        let aw = a.width, bw = b.width, bh = b.height
        let maxX = Double(bw) - 1.001, maxY = Double(bh) - 1.001
        a.values.withUnsafeBufferPointer { aBuffer in
            b.values.withUnsafeBufferPointer { bBuffer in
                sums.withUnsafeMutableBufferPointer { sumsBuffer in
                    let ap = aBuffer.baseAddress!, bp = bBuffer.baseAddress!, all = sumsBuffer.baseAddress!
                    AlignmentSampling.parallel(bands) { band in
                        var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0, inside = 0.0
                        for row in (band * rowCount / bands)..<((band + 1) * rowCount / bands) {
                            let j = row * step
                            let y = Double(j) + 0.5
                            for i in stride(from: 0, to: aw, by: step) {
                                let x = Double(i) + 0.5
                                let z = m6 * x + m7 * y + m8
                                if !(z > 1e-12) { continue }
                                let px = (m0 * x + m1 * y + m2) / z, py = (m3 * x + m4 * y + m5) / z
                                if !(px >= 0 && py >= 0 && px <= Double(bw) && py <= Double(bh)) { continue }
                                inside += 1
                                let bx = px - 0.5, by = py - 0.5
                                if !(bx >= 0 && by >= 0 && bx < maxX && by < maxY) { continue }
                                let va = ap[j * aw + i]
                                if va.isNaN { continue }
                                let ix = Int(bx), iy = Int(by)
                                let fx = Float(bx - Double(ix)), fy = Float(by - Double(iy))
                                let k = iy * bw + ix
                                let vb = (1 - fx) * (1 - fy) * bp[k] + fx * (1 - fy) * bp[k + 1]
                                    + (1 - fx) * fy * bp[k + bw] + fx * fy * bp[k + bw + 1]
                                if vb.isNaN { continue }
                                let da = Double(va), db = Double(vb)
                                n += 1; sa += da; sb += db; saa += da * da; sbb += db * db; sab += da * db
                            }
                        }
                        let out = all + band * 7
                        out[0] = n; out[1] = sa; out[2] = sb; out[3] = saa; out[4] = sbb; out[5] = sab; out[6] = inside
                    }
                }
            }
        }
        var t = [Double](repeating: 0, count: 7)
        for band in 0..<bands { for k in 0..<7 { t[k] += sums[band * 7 + k] } }
        let n = t[0], overlap = t[6] / Double(rowCount * ((a.width + step - 1) / step))
        guard n >= 2 else { return (0, overlap, Int(n)) }
        let covariance = t[5] / n - (t[1] / n) * (t[2] / n)
        let varianceA = t[3] / n - (t[1] / n) * (t[1] / n), varianceB = t[4] / n - (t[2] / n) * (t[2] / n)
        let ncc = covariance / max(varianceA * varianceB, 1e-20).squareRoot()
        return (ncc.isFinite ? ncc : 0, overlap, Int(n))
    }

    private func rejected(_ reason: AlignmentRejection, moving: AlignmentImage) -> AlignmentResult {
        var result = AlignmentResult.identity
        result.accepted = false
        result.rejection = reason
        result.ncc = 0
        result.overlapFraction = 0
        result.converged = false
        return result
    }
}

/// A pair's pyramid levels, matched finest to finest, with each level's
/// masked planes and gradients made once, when first needed.
final class PairLevels: @unchecked Sendable {
    let reference: AlignmentImage
    let moving: AlignmentImage
    let range: AlignmentPairRange
    private var cache: [Int: (reference: AlignmentPlane, moving: AlignmentPlane, gradients: ECCRefinement.Gradients)] = [:]
    private let lock = NSLock()

    init(reference: AlignmentImage, moving: AlignmentImage, range: AlignmentPairRange) {
        // Pyramids of different depths are matched from the finest level.
        let depth = min(reference.levels.count, moving.levels.count)
        self.reference = reference.keepingFinest(depth)
        self.moving = moving.keepingFinest(depth)
        self.range = range
    }

    func index(nearest longEdge: Int) -> Int {
        reference.levels.indices.min {
            abs(max(reference.levels[$0].width, reference.levels[$0].height) - longEdge)
                < abs(max(reference.levels[$1].width, reference.levels[$1].height) - longEdge)
        }!
    }

    func planes(_ index: Int) -> (reference: AlignmentPlane, moving: AlignmentPlane, gradients: ECCRefinement.Gradients) {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[index] { return cached }
        let a = AlignmentPlane.masked(reference.levels[index], range: range)
        let b = AlignmentPlane.masked(moving.levels[index], range: range)
        let entry = (a, b, ECCRefinement.Gradients(b))
        cache[index] = entry
        return entry
    }
}

extension AlignmentImage {
    /// The same image with only its `count` finest levels.
    func keepingFinest(_ count: Int) -> AlignmentImage {
        guard count < levels.count else { return self }
        return AlignmentImage(fullWidth: fullWidth, fullHeight: fullHeight, exposure: exposure,
                              levels: Array(levels.suffix(count)))
    }
}
