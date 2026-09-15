import CoreGraphics
import Foundation
import simd

// The panorama geometry end to end: photos (as `PanoramaFrameInput`) in, a
// `PanoramaLayout` out, with a report of what each step found.

public struct PanoramaLayoutOptions: Sendable, Equatable {
    /// `.automatic` lets the photos' extent decide.
    public var projection: PanoramaProjection
    /// Adjust the shared focal length in the camera solve, not only the
    /// rotations. On by default: EXIF focal lengths are nominal (a "50 mm"
    /// lens is rarely exactly 50 mm, and focusing changes it).
    public var refineFocalLength: Bool

    public init(projection: PanoramaProjection = .automatic, refineFocalLength: Bool = true) {
        self.projection = projection
        self.refineFocalLength = refineFocalLength
    }
}

/// What the geometry found, step by step, for the CLI and the dialog.
public struct PanoramaLayoutReport: Sendable {
    public struct Stage: Sendable, Equatable {
        public let name: String
        public let seconds: Double
    }

    /// One photo, in capture order.
    public struct Frame: Sendable, Equatable {
        public let name: String
        public let captureTime: Date
        public let exposureTime: Double
        public let iso: Double
        public let aperture: Double
        /// The gain EXIF alone gives, and the one the layout uses (nil for a
        /// photo left out).
        public let exifGain: Double
        public let gain: Double?
        /// Yaw, pitch and roll in degrees (see `PanoramaCamera`); nil when
        /// left out.
        public let yawPitchRoll: SIMD3<Double>?
    }

    public var stages: [Stage] = []
    public var frames: [Frame] = []
    /// Every registration tried, neighbours first.
    public var pairs: [PanoramaPairRegistration] = []
    /// Pairs the camera solve dropped as disagreeing with the rest, as
    /// (first, second).
    public var droppedPairs: [SIMD2<Int>] = []
    /// Photos no accepted pair connects to the rest: left out of the layout.
    public var leftOut: [Int] = []
    /// EXIF's focal length and the solve's, full-resolution pixels.
    public var exifFocalLengthPixels = 0.0
    public var focalLengthPixels = 0.0
    /// How closely the cameras explain the correspondences: root-mean-square
    /// distance, full-resolution pixels.
    public var rmsErrorPixels = 0.0
    /// How far the photos reach around the horizon and up and down.
    public var widthDegrees = 0.0
    public var heightDegrees = 0.0

    /// One overlapping pair's exposure, in stops: how much brighter the
    /// first photo recorded the overlap than the second, as measured, as
    /// EXIF predicts, and as the chosen gains leave it (0 is a perfect match).
    public struct ExposureMeasurement: Sendable, Equatable {
        public let first: Int
        public let second: Int
        public let measuredStops: Double
        public let exifStops: Double
        public let remainingStops: Double
        public let samples: Int
    }

    public var exposureMeasurements: [ExposureMeasurement] = []

    public init() {}

    public var totalSeconds: Double { stages.reduce(0) { $0 + $1.seconds } }

    mutating func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let clock = ContinuousClock(), start = clock.now
        defer {
            let elapsed = clock.now - start
            stages.append(Stage(name: name, seconds: Double(elapsed.components.seconds)
                                + Double(elapsed.components.attoseconds) * 1e-18))
        }
        return try body()
    }
}

public struct PanoramaLayoutResult: Sendable {
    public let layout: PanoramaLayout
    public let report: PanoramaLayoutReport
}

/// Works out where every photo of a panorama goes.
///
/// **The steps** (docs/PhotoMerge.md section 4, stages 3-6 and 9):
/// 1. **Order** by capture time.
/// 2. **Register neighbours** (`PanoramaRegistrar`): ECC, with corners as the
///    fallback.
/// 3. **Solve the cameras** (`PanoramaCameraSolver`): rotations from the
///    pairs, then adjusted together with the shared focal length.
/// 4. **Register more pairs**: photos further apart in the sequence whose
///    solved cameras overlap a lot (a panorama shot in more than one pass,
///    or with small steps), and neighbours that failed but now have a
///    guess; then solve again with everything.
/// 5. **Straighten**: level the horizon and centre the panorama.
/// 6. **Project** (Perspective, Cylindrical or Spherical) and size the
///    canvas to the photos.
/// 7. **Exposure** (`PanoramaGainSolver`): EXIF, refined over the overlaps.
/// 8. **Auto Crop**: the largest rectangle inside the covered area.
///
/// Photos are refused as a panorama when no pair matches, or when they show
/// almost the same view (an exposure bracket).
public struct PanoramaLayoutSolver: Sendable {
    public var options: PanoramaLayoutOptions

    /// Non-neighbours are registered when their solved cameras predict at
    /// least this share of overlap.
    static let extraPairOverlap = 0.2
    /// Photos that together cover less than this much more than a single
    /// photo, in both directions, are the same view, not a panorama.
    static let minimumExtentGrowth = 1.2

    public init(options: PanoramaLayoutOptions = PanoramaLayoutOptions()) {
        self.options = options
    }

    public func solve(_ input: [PanoramaFrameInput]) throws -> PanoramaLayoutResult {
        guard input.count >= 2 else { throw PanoramaError.tooFewPhotos }
        var report = PanoramaLayoutReport()
        let frames = input.enumerated().sorted {
            $0.element.metadata.captureTime != $1.element.metadata.captureTime
                ? $0.element.metadata.captureTime < $1.element.metadata.captureTime : $0.offset < $1.offset
        }.map(\.element)
        let n = frames.count
        let span = frames[0].thumbnail.span

        // EXIF: the focal length every camera starts from, and exposures.
        // The median photo's, should the photos disagree; without EXIF, a
        // "normal" lens (focal length = the diagonal), for the solve to refine.
        let focals = frames.compactMap(\.metadata.focalLengthPixels).sorted()
        let exifFocal = focals.isEmpty
            ? (Double(frames[0].metadata.width * frames[0].metadata.width
                      + frames[0].metadata.height * frames[0].metadata.height)).squareRoot()
            : focals[(focals.count - 1) / 2]
        report.exifFocalLengthPixels = exifFocal
        let exposures = frames.map(\.metadata.exposure)
        let known = exposures.compactMap { $0 }.sorted()
        let medianExposure = known.isEmpty ? 1 : known[(known.count - 1) / 2]
        // For alignment: how much more light than the median each gathered.
        let alignmentGains = exposures.map { ($0 ?? medianExposure) / medianExposure }
        let registrar = PanoramaRegistrar(frames: frames, gains: alignmentGains, focal: exifFocal)
        let centres = (0..<n).map { registrar.centre($0) }

        // 2. Neighbours.
        var pairs: [PanoramaPairRegistration] = []
        for k in 0..<(n - 1) {
            let pair = report.time("Register \(k)-\(k + 1)") { registrar.register(first: k, second: k + 1) }
            pairs.append(pair)
        }
        guard pairs.contains(where: \.accepted) else {
            report.pairs = pairs
            throw PanoramaError.notAPanorama(reason: "no two neighbouring photos could be matched.")
        }

        // 3. Cameras.
        var solution = report.time("Solve cameras") {
            PanoramaCameraSolver.solve(pairs: pairs, frameCount: n, centres: centres, focal: exifFocal,
                                       refineFocal: options.refineFocalLength, span: span)
        }

        // A pair the solve dropped disagreed with every other pair: its
        // aligner answer was a near miss. Corners get a say, and the
        // cameras are solved again.
        if !solution.droppedPairs.isEmpty {
            let dropped = Set(solution.droppedPairs)
            report.time("Register dropped pairs again") {
                pairs = pairs.map { pair in
                    guard dropped.contains(PairKey(first: pair.first, second: pair.second)), pair.method == .ecc
                    else { return pair }
                    return registrar.register(first: pair.first, second: pair.second, cornersFirst: true)
                }
            }
            solution = report.time("Solve cameras again") {
                PanoramaCameraSolver.solve(pairs: pairs, frameCount: n, centres: centres, focal: exifFocal,
                                           refineFocal: options.refineFocalLength, span: span)
            }
        }

        // 4. More pairs, guessed from the cameras so far.
        var extra: [PanoramaPairRegistration] = []
        report.time("Register more pairs") {
            let tried = Set(pairs.filter(\.accepted).map { PairKey(first: $0.first, second: $0.second) })
            for a in 0..<n {
                for b in (a + 1)..<n where !tried.contains(PairKey(first: a, second: b)) {
                    guard let ra = solution.rotations[a], let rb = solution.rotations[b] else { continue }
                    let k = { (i: Int) in
                        simd_double3x3(rows: [SIMD3(solution.focal, 0, centres[i].x),
                                              SIMD3(0, solution.focal, centres[i].y), SIMD3(0, 0, 1)])
                    }
                    let predicted = Homography.normalised(k(b) * rb.transpose * ra * k(a).inverse)
                    // The share of a grid over photo a whose rays land on
                    // photo b, in front of it (a homography alone would also
                    // "land" rays from behind the camera).
                    var inside = 0
                    for j in 0..<10 {
                        for i in 0..<10 {
                            let p = SIMD2((Double(i) + 0.5) / 10 * Double(frames[a].metadata.width),
                                          (Double(j) + 0.5) / 10 * Double(frames[a].metadata.height))
                            let v = rb.transpose * ra
                                * SIMD3((p.x - centres[a].x) / solution.focal, (p.y - centres[a].y) / solution.focal, 1)
                            guard v.z > 1e-6 else { continue }
                            let q = SIMD2(solution.focal * v.x / v.z, solution.focal * v.y / v.z) + centres[b]
                            if q.x >= 0, q.y >= 0, q.x <= Double(frames[b].metadata.width),
                               q.y <= Double(frames[b].metadata.height) { inside += 1 }
                        }
                    }
                    let overlap = Double(inside) / 100
                    let isNeighbour = b == a + 1
                    guard overlap >= Self.extraPairOverlap || (isNeighbour && overlap > 0.05) else { continue }
                    extra.append(registrar.register(first: a, second: b, predicted: predicted))
                }
            }
        }
        if extra.contains(where: \.accepted) {
            let all = pairs.filter(\.accepted) + extra.filter(\.accepted)
            solution = report.time("Solve cameras again") {
                PanoramaCameraSolver.solve(pairs: all, frameCount: n, centres: centres, focal: exifFocal,
                                           refineFocal: options.refineFocalLength, span: span)
            }
        }
        report.pairs = pairs + extra
        report.droppedPairs = solution.droppedPairs.map { SIMD2($0.first, $0.second) }
        report.focalLengthPixels = solution.focal
        report.rmsErrorPixels = solution.rmsError

        // Photos the pairs don't connect to the rest are left out.
        let connected = (0..<n).filter { solution.rotations[$0] != nil }
        report.leftOut = (0..<n).filter { solution.rotations[$0] == nil }
        guard connected.count >= 2 else {
            throw PanoramaError.notAPanorama(reason: "no two photos could be matched reliably.")
        }

        // 5. Level and centre.
        let level = PanoramaCameraSolver.levelling(connected.map { solution.rotations[$0]! })
        var cameras = connected.map { i in
            PanoramaCamera(frameIndex: i, rotation: PanoramaRotation.rowMajor(level * solution.rotations[i]!),
                           focalLengthPixels: solution.focal, principalPoint: centres[i],
                           width: frames[i].metadata.width, height: frames[i].metadata.height, exposureGain: 1)
        }

        // 6. Projection and canvas.
        let extent = PanoramaCanvasBuilder.extent(cameras)
        report.widthDegrees = extent.widthDegrees
        report.heightDegrees = extent.heightDegrees
        let single = PanoramaCanvasBuilder.extent([cameras[0]])
        if extent.widthDegrees < Self.minimumExtentGrowth * single.widthDegrees,
           extent.heightDegrees < Self.minimumExtentGrowth * single.heightDegrees {
            let overlaps = pairs.filter(\.accepted).map(\.overlap)
            let typical = overlaps.isEmpty ? 1 : overlaps.sorted()[overlaps.count / 2]
            throw PanoramaError.notAPanorama(reason: String(
                format: "they show almost the same view (each overlaps the next by about %.0f%%), like an "
                    + "exposure bracket. Use Photo Merge > HDR for a bracket.", typical * 100))
        }
        let projection = options.projection == .automatic
            ? PanoramaCanvasBuilder.automaticProjection(extent) : options.projection
        let canvas = PanoramaCanvasBuilder.canvas(cameras, projection: projection, focal: solution.focal)

        // 7. Exposure.
        var thumbnails: [Int: PanoramaThumbnail] = [:]
        for i in connected { thumbnails[i] = frames[i].thumbnail }
        let gains = report.time("Exposure") {
            PanoramaGainSolver.solve(cameras: cameras, thumbnails: thumbnails,
                                     exposures: Dictionary(uniqueKeysWithValues: connected.map { ($0, exposures[$0]) }))
        }
        cameras = cameras.map {
            PanoramaCamera(frameIndex: $0.frameIndex, rotation: $0.rotation, focalLengthPixels: $0.focalLengthPixels,
                           principalPoint: $0.principalPoint, width: $0.width, height: $0.height,
                           exposureGain: gains.gains[$0.frameIndex] ?? 1)
        }
        report.exposureMeasurements = gains.measurements.map { key, m in
            let exif = log2(gains.exifGains[key.second]! / gains.exifGains[key.first]!)
            let remaining = m.stops + log2(gains.gains[key.first]! / gains.gains[key.second]!)
            return PanoramaLayoutReport.ExposureMeasurement(first: key.first, second: key.second, measuredStops: m.stops,
                                                            exifStops: exif, remainingStops: remaining, samples: m.samples)
        }.sorted { ($0.first, $0.second) < ($1.first, $1.second) }

        // 8. Auto Crop.
        let crop = report.time("Auto crop") { () -> CGRect in
            let coverage = PanoramaCanvasBuilder.coverage(canvas: canvas, cameras: cameras, thumbnails: thumbnails)
            return PanoramaCanvasBuilder.largestRectangle(coverage, canvas: canvas)
        }

        let exifGainsAll: [Double] = exposures.map { e in e.map { medianExposure / $0 } ?? 1 }
        report.frames = frames.indices.map { i in
            let camera = cameras.first { $0.frameIndex == i }
            let angles = camera.map { PanoramaRotation.yawPitchRoll($0.rotationMatrix) }
            let m = frames[i].metadata
            return PanoramaLayoutReport.Frame(
                name: m.name, captureTime: m.captureTime, exposureTime: m.exposureTime, iso: m.iso,
                aperture: m.aperture, exifGain: exifGainsAll[i], gain: camera?.exposureGain,
                yawPitchRoll: angles.map { SIMD3($0.yaw, $0.pitch, $0.roll) })
        }
        let layout = PanoramaLayout(cameras: cameras, canvas: canvas, autoCropRect: crop)
        return PanoramaLayoutResult(layout: layout, report: report)
    }
}
