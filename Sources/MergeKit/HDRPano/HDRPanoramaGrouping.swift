// Which photos belong to which position of an HDR panorama
// (docs/PhotoMerge.md section 8, phase 9).

import Foundation

/// One selected photo, as the grouping understands it. Everything here
/// comes from the file's metadata, so grouping needs no pixels.
public struct HDRPanoramaPhoto: Sendable, Equatable {
    public let url: URL
    public let captureTime: Date
    public let exposureSeconds: Double
    public let iso: Double
    public let aperture: Double
    /// True for a photo that is already an HDR merge (a linear DNG, ours or
    /// another app's), so it is a position of its own and is stitched as it is.
    public let alreadyMerged: Bool

    public init(url: URL, captureTime: Date, exposureSeconds: Double, iso: Double, aperture: Double,
                alreadyMerged: Bool = false) {
        self.url = url; self.captureTime = captureTime; self.exposureSeconds = exposureSeconds
        self.iso = iso; self.aperture = aperture; self.alreadyMerged = alreadyMerged
    }

    /// The light this photo gathered, in stops, from shutter, ISO and
    /// aperture; nil when the metadata doesn't say. Two photos of one
    /// bracket differ by the bracket's step (−2, 0, +2 and so on).
    public var lightStops: Double? {
        guard exposureSeconds > 0, iso > 0, aperture > 0, exposureSeconds.isFinite, iso.isFinite,
              aperture.isFinite else { return nil }
        return log2(exposureSeconds * iso / (aperture * aperture))
    }

    /// "1/250 s · ƒ/8 · ISO 100", as the dialog lists it.
    public var exposureText: String {
        var parts: [String] = []
        if exposureSeconds > 0 {
            parts.append(exposureSeconds >= 1 ? String(format: "%g s", exposureSeconds)
                : "1/\(Int((1 / exposureSeconds).rounded())) s")
        }
        if aperture > 0 { parts.append(String(format: "ƒ/%g", (aperture * 10).rounded() / 10)) }
        if iso > 0 { parts.append("ISO \(Int(iso.rounded()))") }
        return parts.joined(separator: " · ")
    }
}

/// The positions an HDR panorama's photos fall into, and what said so.
public struct HDRPanoramaGrouping: Sendable, Equatable {
    /// One camera position: the photos taken there, and which of them the
    /// position is measured and named by.
    public struct Position: Sendable, Equatable {
        /// Indices into the photos given, in capture order.
        public let frames: [Int]
        /// One of `frames`: the photo whose exposure sits in the middle of
        /// the bracket, which the position's metadata and name come from.
        public let reference: Int
        /// True for a position of one photo that is already an HDR merge.
        public let alreadyMerged: Bool

        public init(frames: [Int], reference: Int, alreadyMerged: Bool = false) {
            self.frames = frames; self.reference = reference; self.alreadyMerged = alreadyMerged
        }

        /// A position of one photo has nothing to merge: it goes into the
        /// panorama as it is.
        public var needsMerging: Bool { frames.count > 1 }
    }

    /// In capture order, at least two of them.
    public let positions: [Position]
    public let evidence: Evidence

    /// What the positions were worked out from, in the order the grouper
    /// trusts them.
    public enum Evidence: String, Sendable, Equatable {
        /// The exposures repeat (−2, 0, +2, −2, 0, +2…) and the gaps between
        /// shots agree with where the pattern restarts.
        case exposurePatternAndTiming
        /// The exposures repeat; the capture times said nothing either way.
        case exposurePattern
        /// The exposures don't repeat cleanly, but the photos come in bursts
        /// separated by much longer gaps.
        case timeGaps
        /// Neither did: consecutive photos were compared, and a position
        /// starts where the view jumps.
        case overlap
        /// The two kinds of evidence disagreed; the exposure pattern won.
        case mixed
        /// Every photo is already an HDR merge, so every photo is a position.
        case alreadyMerged

        /// How the dialog says it.
        public var text: String {
            switch self {
            case .exposurePatternAndTiming: "from the repeating exposures and the gaps between shots"
            case .exposurePattern: "from the repeating exposures"
            case .timeGaps: "from the gaps between shots"
            case .overlap: "from how much consecutive photos overlap"
            case .mixed: "from the repeating exposures, which the gaps between shots don't quite match"
            case .alreadyMerged: "each photo is already an HDR merge"
            }
        }
    }

    public init(positions: [Position], evidence: Evidence) {
        self.positions = positions; self.evidence = evidence
    }

    /// "3 exposures at each of 5 positions", or "5 positions of 3, 3, 2, 3
    /// and 3 photos" when they differ.
    public var summaryText: String {
        let counts = positions.map(\.frames.count)
        guard let first = counts.first else { return "no positions" }
        if counts.allSatisfy({ $0 == first }) {
            let photos = first == 1 ? "photo" : "exposures"
            return "\(first) \(photos) at each of \(positions.count) positions"
        }
        return "\(positions.count) positions of " + Self.list(counts.map(String.init)) + " photos"
    }

    /// "3, 3 and 2" — a list as a sentence names it.
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// True when the positions hold different numbers of photos.
    public var isUneven: Bool {
        Set(positions.map(\.frames.count)).count > 1
    }
}

/// Works out the positions of an HDR panorama from the photos' metadata,
/// and from how much they overlap when the metadata can't tell.
///
/// **The evidence, strongest first.**
/// 1. **The repeating exposure pattern.** A bracketed panorama is shot as
///    the same bracket over and over: −2, 0, +2, −2, 0, +2… The shortest
///    period the exposures repeat with, whose own exposures are all
///    different, is the bracket. This is the strongest evidence there is:
///    nothing else makes a camera repeat exposures that way.
/// 2. **The gaps between shots.** A bracket is shot in a burst; moving to
///    the next position takes seconds. When the gaps fall into two clear
///    groups, the long ones are the moves. (EXIF records whole seconds, so
///    a burst's gaps are often all 0; that is still a clear split.)
/// 3. **How much consecutive photos overlap.** A bracket's frames show
///    nearly the same view; a new position is a big move. Measured on the
///    pixels, and asked for only when 1 and 2 both say nothing, because it
///    means reading every photo.
///
/// When 1 and 2 both answer and agree, the grouping is
/// `.exposurePatternAndTiming`. When they disagree the pattern wins
/// (`.mixed`): a camera's exposures repeat on purpose, where a gap can grow
/// because the photographer paused.
///
/// **Photos that are already HDR merges** (linear DNGs) are positions of one
/// photo, and they cut the sequence: a bracket can't run through one.
///
/// **A stray single photo** — a raw with no bracket around it — is a
/// position of one photo too. It is stitched as it is; there is nothing to
/// merge it with.
public enum HDRPanoramaGrouper {
    /// How much longer a gap between positions must be than the longest gap
    /// inside a bracket for the split to be believed.
    public static let gapRatio = 2.5
    /// When the gaps inside a bracket are all 0 (EXIF's whole seconds), a
    /// gap of at least this many seconds still splits positions.
    public static let gapFloorSeconds = 1.0
    /// Exposures are compared to a third of a stop, the smallest step
    /// cameras bracket by.
    public static let exposureStepsPerStop = 3.0
    /// How much less two photos may overlap, as a share of a perfect match,
    /// before they count as different positions.
    public static let overlapDrop = 0.15
    /// The most photos one bracket can hold: the HDR merge takes at most 9
    /// (`HDRMerger.frameLimit`), so a longer run that won't split isn't one
    /// position however it is read.
    public static let maximumBracket = 9

    /// The positions of `photos`, which must be in capture order.
    ///
    /// - Parameter overlap: how alike consecutive photos are, 0 (nothing in
    ///   common) to 1 (the same view), for the pair starting at the index
    ///   given. Only called when the metadata can't tell, and only for
    ///   consecutive pairs. nil: don't measure, fail instead.
    /// - Throws: `HDRPanoramaError` saying what is wrong with the selection.
    public static func group(_ photos: [HDRPanoramaPhoto],
                             overlap: ((Int) throws -> Double)? = nil) throws -> HDRPanoramaGrouping {
        guard photos.count >= 2 else { throw HDRPanoramaError.tooFewPhotos }
        // Already-merged photos are positions of their own, and they cut
        // the sequence into runs of raws that are bracketed separately.
        var positions: [HDRPanoramaGrouping.Position] = []
        var evidences: Set<HDRPanoramaGrouping.Evidence> = []
        var run: [Int] = []

        func finishRun() throws {
            guard !run.isEmpty else { return }
            let (groups, evidence) = try cut(run, photos: photos, overlap: overlap)
            positions += groups.map { position(of: $0, photos: photos) }
            if let evidence { evidences.insert(evidence) }
            run = []
        }

        for index in photos.indices {
            if photos[index].alreadyMerged {
                try finishRun()
                positions.append(HDRPanoramaGrouping.Position(frames: [index], reference: index,
                                                              alreadyMerged: true))
                evidences.insert(.alreadyMerged)
            } else {
                run.append(index)
            }
        }
        try finishRun()

        guard positions.count >= 2 else { throw HDRPanoramaError.tooFewPositions }
        guard positions.contains(where: { $0.frames.count > 1 || $0.alreadyMerged }) else {
            throw HDRPanoramaError.notBrackets
        }
        return HDRPanoramaGrouping(positions: positions, evidence: evidence(from: evidences))
    }

    /// The evidence to report when a selection was grouped several ways
    /// (already-merged photos beside brackets): the weakest one used, since
    /// that is what the whole grouping rests on.
    static func evidence(from found: Set<HDRPanoramaGrouping.Evidence>) -> HDRPanoramaGrouping.Evidence {
        let order: [HDRPanoramaGrouping.Evidence] = [.mixed, .overlap, .timeGaps, .exposurePattern,
                                                     .exposurePatternAndTiming, .alreadyMerged]
        return order.first { found.contains($0) } ?? .alreadyMerged
    }

    /// A position from the photos at `frames`: its reference is the one
    /// whose exposure is in the middle of the bracket (the earliest of the
    /// two middles for an even bracket), where the HDR merge's own
    /// reference usually lands, and which the dialog names the position by.
    static func position(of frames: [Int], photos: [HDRPanoramaPhoto]) -> HDRPanoramaGrouping.Position {
        guard frames.count > 1 else {
            return HDRPanoramaGrouping.Position(frames: frames, reference: frames[0])
        }
        let sorted = frames.sorted {
            let a = photos[$0].lightStops ?? 0, b = photos[$1].lightStops ?? 0
            return a != b ? a < b : $0 < $1
        }
        return HDRPanoramaGrouping.Position(frames: frames, reference: sorted[(sorted.count - 1) / 2])
    }

    // MARK: - Cutting one run of raws into positions

    /// `indices` (consecutive photos, none of them already merged) cut into
    /// positions, with what said so.
    ///
    /// A run that won't cut is one position when it could be one bracket —
    /// its exposures all different, and not more of them than an HDR merge
    /// takes. Otherwise none of the evidence can read it, and that is an
    /// error: a jumble of exposures at even intervals is not a sweep this
    /// can guess at.
    static func cut(_ indices: [Int], photos: [HDRPanoramaPhoto],
                    overlap: ((Int) throws -> Double)?)
    throws -> (groups: [[Int]], evidence: HDRPanoramaGrouping.Evidence?) {
        guard indices.count > 1 else { return ([indices], nil) }
        let byPattern = cutByExposurePattern(indices, photos: photos)
        let byGaps = cutByTimeGaps(indices, photos: photos)
        switch (byPattern, byGaps) {
        case (let pattern?, let gaps?):
            return pattern == gaps ? (pattern, .exposurePatternAndTiming) : (pattern, .mixed)
        case (let pattern?, nil):
            return (pattern, .exposurePattern)
        case (nil, let gaps?):
            return (gaps, .timeGaps)
        case (nil, nil):
            if let overlap, let byOverlap = try cutByOverlap(indices, overlap: overlap) {
                return (byOverlap, .overlap)
            }
            let lights = indices.compactMap { photos[$0].lightStops }
            let tolerance = 0.5 / exposureStepsPerStop
            // All one exposure: not a bracket at all, and saying so is more
            // use than "can't tell".
            if lights.count == indices.count, let first = lights.first,
               lights.allSatisfy({ abs($0 - first) < tolerance }) {
                throw HDRPanoramaError.sameExposure
            }
            let distinct = lights.count == indices.count
                && Set(lights.map { Int(($0 * exposureStepsPerStop).rounded()) }).count == indices.count
            guard distinct, indices.count <= maximumBracket else { throw HDRPanoramaError.cantTellPositions }
            return ([indices], nil)
        }
    }

    /// The run cut where the exposures start repeating, or nil when they
    /// don't repeat, the metadata doesn't say, or there is only one period.
    static func cutByExposurePattern(_ indices: [Int], photos: [HDRPanoramaPhoto]) -> [[Int]]? {
        let steps = indices.compactMap { photos[$0].lightStops.map { Int(($0 * exposureStepsPerStop).rounded()) } }
        guard steps.count == indices.count, steps.count >= 3, Set(steps).count > 1 else { return nil }
        for period in 2...(steps.count - 1) {
            // A bracket takes each exposure once, and the pattern must hold
            // to the end (the last position may be cut short).
            guard Set(steps[0..<period]).count == period else { continue }
            guard (0..<steps.count).allSatisfy({ steps[$0] == steps[$0 % period] }) else { continue }
            return stride(from: 0, to: indices.count, by: period).map {
                Array(indices[$0..<min($0 + period, indices.count)])
            }
        }
        return nil
    }

    /// The run cut at the long gaps between bursts, or nil when the capture
    /// times don't fall into two clear groups.
    static func cutByTimeGaps(_ indices: [Int], photos: [HDRPanoramaPhoto]) -> [[Int]]? {
        let gaps = (0..<(indices.count - 1)).map {
            photos[indices[$0 + 1]].captureTime.timeIntervalSince(photos[indices[$0]].captureTime)
        }
        guard let threshold = splitThreshold(gaps, ratio: gapRatio, floorValue: gapFloorSeconds) else { return nil }
        return split(indices, cuttingAfter: gaps.indices.filter { gaps[$0] >= threshold })
    }

    /// The run cut where consecutive photos stop showing the same view, or
    /// nil when they don't split clearly. `overlap` is asked once per pair.
    static func cutByOverlap(_ indices: [Int], overlap: (Int) throws -> Double) throws -> [[Int]]? {
        // Measured as a distance (1 - overlap), so the same split rule as
        // the gaps applies: the long ones are the moves.
        var distances: [Double] = []
        for pair in 0..<(indices.count - 1) {
            distances.append(max(0, 1 - (try overlap(indices[pair]))))
        }
        guard let threshold = splitThreshold(distances, ratio: gapRatio, floorValue: overlapDrop) else { return nil }
        return split(indices, cuttingAfter: distances.indices.filter { distances[$0] >= threshold })
    }

    /// `indices` cut after each position in `cuts`, when that makes at
    /// least two groups; nil otherwise.
    static func split(_ indices: [Int], cuttingAfter cuts: [Int]) -> [[Int]]? {
        guard !cuts.isEmpty else { return nil }
        var groups: [[Int]] = []
        var start = 0
        for cut in cuts {
            groups.append(Array(indices[start...cut]))
            start = cut + 1
        }
        if start < indices.count { groups.append(Array(indices[start...])) }
        return groups.count >= 2 ? groups : nil
    }

    /// The smallest value that counts as "between positions", when the
    /// values fall into clear groups: the *lowest* step in the sorted
    /// values that is at least `ratio` times the value below it — or at
    /// least `floorValue` when that value is 0 (the gaps EXIF rounded to
    /// the same second). Nil when no step is clear enough.
    ///
    /// The lowest rather than the largest, because gaps often come at three
    /// sizes: within a bracket, between positions, and the long pause when
    /// the photographer stopped to change something. The shortest gap that
    /// is clearly longer than the ordinary ones is the move; anything
    /// longer is a move too.
    static func splitThreshold(_ values: [Double], ratio: Double, floorValue: Double) -> Double? {
        let sorted = values.sorted()
        guard let largest = sorted.last, largest > 0, sorted.count > 1 else { return nil }
        for index in 1..<sorted.count {
            let below = sorted[index - 1], above = sorted[index]
            guard above > below else { continue }
            if below > 0 ? above >= below * ratio : above >= floorValue { return above }
        }
        // Every value alike: no split. Photos evenly spaced are a sweep of
        // single shots, not brackets.
        return nil
    }
}
