import Foundation
import simd

// Pairwise registration: how two overlapping photos of a panorama line up,
// found by `FrameAligner` and, where that fails, by matching corners.

/// A pair of the same scene point, seen in two photos (full-resolution
/// pixels, top-left origin).
struct PanoramaCorrespondence: Sendable, Equatable {
    var first: SIMD2<Double>
    var second: SIMD2<Double>
}

/// How one photo lines up with another.
public struct PanoramaPairRegistration: Sendable, Equatable {
    public enum Method: String, Sendable {
        /// `FrameAligner` on its own: phase correlation, then ECC.
        case ecc = "ECC"
        /// Corners matched and a rotation fitted, then refined by ECC.
        case featuresECC = "features+ECC"
        /// Corners matched and a rotation fitted; ECC couldn't refine it.
        case features
    }

    /// Indices (in capture order) of the two photos: `homography` maps the
    /// first's pixels onto the second's.
    public let first: Int
    public let second: Int
    /// How the answer was found; nil when nothing worked.
    public let method: Method?
    /// First photo -> second photo, full-resolution pixels (see `Homography`).
    public let homography: simd_double3x3
    /// Normalised cross-correlation of the overlap once lined up (the
    /// aligner's score), 0 when not measured.
    public let ncc: Double
    /// Corners matched, and how many of them the fitted rotation explains
    /// (0 when corners weren't needed).
    public let matches: Int
    public let inliers: Int
    /// The share of the second photo the first covers once lined up.
    public let overlap: Double
    public let accepted: Bool
    /// For the report: why not accepted, or for an accepted pair what
    /// didn't work on the way (nil when the first try did).
    public let note: String?
    /// The points the camera solve fits: corner inliers, or points spread
    /// over the overlap and carried across by the homography.
    let correspondences: [PanoramaCorrespondence]
}

/// Registers pairs of thumbnails.
///
/// **First `FrameAligner`**, in panorama mode, on the thumbnails' luminance
/// divided by each photo's EXIF exposure (so frames shot a stop apart
/// compare alike), with texels outside the lens-corrected photo or clipped
/// marked unusable. Its answer counts only if it is also what a camera
/// turning about its lens could produce (`isRotationLike`).
///
/// **Then corners** (`PanoramaFeatures`), when the aligner's answer isn't
/// accepted: corners matched and a rotation fitted with RANSAC, using the
/// EXIF focal length. The rotation's homography K R K⁻¹ is handed to the
/// aligner as its starting guess, which usually refines it to a fraction of
/// a pixel; if it can't, the corners' own answer stands when enough of them
/// agree.
final class PanoramaRegistrar: @unchecked Sendable {
    let frames: [PanoramaFrameInput]
    /// Each frame's EXIF exposure relative to the median frame (1 = median).
    let gains: [Double]
    /// Full-resolution focal length in pixels, shared by every frame.
    let focal: Double
    var aligner = FrameAligner()

    /// The least corner inliers a corner-only answer needs.
    static let minimumInliers = 16
    /// How far (in thumbnail texels) a corner may land from where the
    /// rotation puts it and still agree: enough for a focal length a few
    /// percent off and a little parallax, far less than a wrong match.
    static let inlierToleranceTexels = 2.5
    /// How far (thumbnail texels) an aligner homography may differ, over
    /// the overlap, from the nearest pure rotation and still be a camera
    /// turning: parallax and a focal length off by a few percent stay
    /// inside it; a match to the wrong part of the scene doesn't.
    static let rotationToleranceTexels = 6.0
    /// An aligner answer scoring at least this is taken as it is; below it
    /// (but above the aligner's own 0.9) the corners are asked too. Real
    /// neighbours score 0.99 or more, even with people walking through.
    static let confidentNCC = 0.98

    private var images: [Int: AlignmentImage] = [:]
    private var features: [Int: PanoramaFeatureSet] = [:]
    private let lock = NSLock()

    init(frames: [PanoramaFrameInput], gains: [Double], focal: Double) {
        self.frames = frames
        self.gains = gains
        self.focal = focal
    }

    func centre(_ index: Int) -> SIMD2<Double> {
        SIMD2(Double(frames[index].metadata.width), Double(frames[index].metadata.height)) / 2
    }

    /// K for frame `index`: focal length and principal point, full resolution.
    func intrinsics(_ index: Int, focal f: Double? = nil) -> simd_double3x3 {
        let f = f ?? focal, c = centre(index)
        return simd_double3x3(rows: [SIMD3(f, 0, c.x), SIMD3(0, f, c.y), SIMD3(0, 0, 1)])
    }

    /// The homography a rotation `r` (rays of `first` -> rays of `second`) gives.
    func homography(rotation r: simd_double3x3, first: Int, second: Int) -> simd_double3x3 {
        Homography.normalised(intrinsics(second) * r * intrinsics(first).inverse)
    }

    // MARK: - Cached inputs

    func alignmentImage(_ index: Int) -> AlignmentImage {
        lock.lock(); defer { lock.unlock() }
        if let cached = images[index] { return cached }
        let t = frames[index].thumbnail
        var clipped = t.clippedShare
        for i in clipped.indices { clipped[i] = max(clipped[i], 1 - min(max(t.rgba[4 * i + 3], 0), 1)) }
        // The thumbnail's own clipped share decides clipping; the channel
        // limit only has to stay out of its way (vignetting correction
        // lifts corners above 1).
        let exposure = AlignmentExposure(gain: gains[index], channelClip: SIMD3(repeating: 64))
        let image = AlignmentImage(luminance: t.luminance, clippedShare: clipped, width: t.width, height: t.height,
                                   fullWidth: t.width * t.span, fullHeight: t.height * t.span, exposure: exposure)
        images[index] = image
        return image
    }

    func featureSet(_ index: Int) -> PanoramaFeatureSet {
        lock.lock(); defer { lock.unlock() }
        if let cached = features[index] { return cached }
        let set = PanoramaFeatures.detect(frames[index].thumbnail, gain: gains[index])
        features[index] = set
        return set
    }

    // MARK: - Registering

    /// Lines `first` up with `second`.
    ///
    /// - Parameters:
    ///   - predicted: a guess at first -> second from the cameras solved so
    ///     far, for a pair that aren't neighbours.
    ///   - cornersFirst: skip the aligner's own try and start from corners,
    ///     for a pair whose first answer the camera solve found wrong.
    func register(first: Int, second: Int, predicted: simd_double3x3? = nil,
                  cornersFirst: Bool = false) -> PanoramaPairRegistration {
        let moving = alignmentImage(first), reference = alignmentImage(second)
        let span = Double(frames[first].thumbnail.span)
        let a = featureSet(first), b = featureSet(second)
        // Corners are matched only when needed, and at most once.
        var cornerFit: (pairs: [(Int, Int)], fit: PanoramaFeatures.RotationFit?)?
        func corners() -> (pairs: [(Int, Int)], fit: PanoramaFeatures.RotationFit?) {
            if let cornerFit { return cornerFit }
            let pairs = PanoramaFeatures.match(a, b)
            let fit = PanoramaFeatures.fitRotation(
                pointsA: pairs.map { a.points[$0.0] }, pointsB: pairs.map { b.points[$0.1] }, focal: focal,
                centreA: centre(first), centreB: centre(second), tolerance: Self.inlierToleranceTexels * span)
            let found = (pairs, fit.flatMap { $0.inliers.count >= Self.minimumInliers ? $0 : nil })
            cornerFit = found
            return found
        }

        var eccNote = "ECC skipped: the camera solve disagreed with its answer"
        var directNCC = 0.0
        if !cornersFirst {
            let direct = aligner.align(moving: moving, reference: reference, model: .panorama, initial: predicted)
            directNCC = direct.ncc
            if direct.accepted, isRotationLike(direct.estimatedHomography, first: first, second: second) {
                // A modest score can be a near miss that settled on the wrong
                // part of the overlap (seen on synthetic sweeps at 0.96):
                // when it is, ask the corners for a second opinion.
                guard direct.ncc < Self.confidentNCC, let fit = corners().fit else {
                    return accepted(direct, method: .ecc, first: first, second: second, matches: 0, inliers: 0,
                                    note: nil)
                }
                let cornersMap = homography(rotation: fit.rotation, first: first, second: second)
                let points = gridPoints(first: first, second: second, map: direct.estimatedHomography, columns: 8, rows: 8)
                if points.allSatisfy({ simd_distance(Homography.apply(cornersMap, $0.first), $0.second)
                                       < Self.rotationToleranceTexels * span }) {
                    return accepted(direct, method: .ecc, first: first, second: second, matches: 0, inliers: 0,
                                    note: nil)
                }
                eccNote = String(format: "ECC (NCC %.3f) disagreed with the corners", direct.ncc)
            } else if direct.accepted {
                eccNote = "ECC: not a camera rotation"
            } else {
                eccNote = "ECC: " + Self.describe(direct.rejection)
            }
        }

        // Corners.
        let (pairs, found) = corners()
        guard let fit = found else {
            return rejected(first: first, second: second, matches: pairs.count, ncc: directNCC,
                            reason: eccNote + "; corners: too few agree (\(pairs.count) matches)")
        }
        let guess = homography(rotation: fit.rotation, first: first, second: second)
        let refined = aligner.align(moving: moving, reference: reference, model: .panorama, initial: guess)
        let refinedNote: String
        if refined.accepted {
            if isRotationLike(refined.estimatedHomography, first: first, second: second) {
                return accepted(refined, method: .featuresECC, first: first, second: second, matches: pairs.count,
                                inliers: fit.inliers.count, note: eccNote)
            }
            refinedNote = "refinement: not a camera rotation"
        } else {
            refinedNote = "refinement: " + Self.describe(refined.rejection)
        }
        let score = aligner.score(guess, moving: moving, reference: reference)
        let correspondences = fit.inliers.map {
            PanoramaCorrespondence(first: a.points[pairs[$0].0], second: b.points[pairs[$0].1])
        }
        return PanoramaPairRegistration(first: first, second: second, method: .features, homography: guess,
                                        ncc: score.ncc, matches: pairs.count, inliers: fit.inliers.count,
                                        overlap: score.overlapFraction, accepted: true,
                                        note: eccNote + "; " + refinedNote, correspondences: correspondences)
    }

    static func describe(_ rejection: AlignmentRejection?) -> String {
        switch rejection {
        case .lowCorrelation(let ncc)?: String(format: "NCC %.3f", ncc)
        case .insufficientOverlap(let fraction)?: String(format: "overlap %.2f", fraction)
        case .noSharedExposureRange?: "no shared exposure range"
        case .notEnoughDetail?: "not enough detail"
        case .refinementFailed?: "refinement failed"
        case .scaleChange(let fraction)?: String(format: "scale change %.3f", fraction)
        case .chainBroken?: "chain broken"
        case nil: "rejected"
        }
    }

    /// Whether `h` (first -> second) is, over the overlap, within
    /// `rotationToleranceTexels` of the pure camera rotation nearest it.
    func isRotationLike(_ h: simd_double3x3, first: Int, second: Int) -> Bool {
        let points = gridPoints(first: first, second: second, map: h, columns: 10, rows: 10)
        guard points.count >= 4 else { return false }
        let r = PanoramaCameraSolver.relativeRotation(points, centreA: centre(first), centreB: centre(second),
                                                      focal: focal)
        let rotationMap = homography(rotation: r, first: first, second: second)
        let tolerance = Self.rotationToleranceTexels * Double(frames[first].thumbnail.span)
        return points.allSatisfy { simd_distance(Homography.apply(rotationMap, $0.first), $0.second) < tolerance }
    }

    /// Points on a grid over `first`, with where `map` takes them, keeping
    /// those that land inside `second` and are covered in both thumbnails.
    func gridPoints(first: Int, second: Int, map: simd_double3x3, columns: Int, rows: Int) -> [PanoramaCorrespondence] {
        let a = frames[first], b = frames[second]
        var out: [PanoramaCorrespondence] = []
        for j in 0..<rows {
            for i in 0..<columns {
                let p = SIMD2((Double(i) + 0.5) / Double(columns) * Double(a.metadata.width),
                              (Double(j) + 0.5) / Double(rows) * Double(a.metadata.height))
                let q = Homography.apply(map, p)
                guard q.x.isFinite, q.y.isFinite, covered(a.thumbnail, p), covered(b.thumbnail, q) else { continue }
                out.append(PanoramaCorrespondence(first: p, second: q))
            }
        }
        return out
    }

    /// Whether full-resolution point `p` is on the thumbnail's photo.
    func covered(_ t: PanoramaThumbnail, _ p: SIMD2<Double>) -> Bool {
        let x = Int((p.x / Double(t.span)).rounded(.down)), y = Int((p.y / Double(t.span)).rounded(.down))
        guard x >= 0, y >= 0, x < t.width, y < t.height else { return false }
        return t.rgba[4 * (y * t.width + x) + 3] >= 0.5
    }

    private func accepted(_ result: AlignmentResult, method: PanoramaPairRegistration.Method, first: Int, second: Int,
                          matches: Int, inliers: Int, note: String?) -> PanoramaPairRegistration {
        PanoramaPairRegistration(
            first: first, second: second, method: method, homography: result.estimatedHomography, ncc: result.ncc,
            matches: matches, inliers: inliers, overlap: result.overlapFraction, accepted: true, note: note,
            correspondences: gridPoints(first: first, second: second, map: result.estimatedHomography,
                                        columns: 16, rows: 24))
    }

    private func rejected(first: Int, second: Int, matches: Int, ncc: Double, reason: String) -> PanoramaPairRegistration {
        PanoramaPairRegistration(first: first, second: second, method: nil, homography: Homography.identity, ncc: ncc,
                                 matches: matches, inliers: 0, overlap: 0, accepted: false, note: reason,
                                 correspondences: [])
    }
}
