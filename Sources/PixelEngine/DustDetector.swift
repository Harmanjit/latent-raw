import Foundation
import Accelerate
import simd

/// The spot sizes Find Spots looks for, in sensor pixels. The bands
/// overlap so a spot at a band's edge is found from either side.
public enum DustSpotSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    /// Sensor px: small 4…8, medium 6…16, large 12…40.
    public var sensorRadiusRange: ClosedRange<Float> {
        switch self {
        case .small:  return 4...8
        case .medium: return 6...16
        case .large:  return 12...40
        }
    }

    public var displayName: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }
}

/// What `DustDetector.analyse` can fail with beyond the render's own
/// errors.
public enum DustDetectorError: Error, CustomStringConvertible {
    /// The analysis render came back with no pixels.
    case emptyRender

    public var description: String {
        switch self {
        case .emptyRender: return "The photo could not be rendered for dust analysis"
        }
    }
}

/// Sensor dust (docs/Retouch.md §6): the analysis map, the detector's
/// parameters per band and sensitivity, detection into heal patches,
/// map verification and saving a list as a map. Used by the editor's
/// panel and by the Remove Dust batch job.
public enum DustDetector {
    public struct Options: Codable, Equatable, Sendable {
        /// 0…100, default 50.
        public var sensitivity: Int
        public var size: DustSpotSize

        public init(sensitivity: Int = 50, size: DustSpotSize = .medium) {
            self.sensitivity = sensitivity
            self.size = size
        }
    }

    /// The analysis map: log2 luminance of the binned (quads: 1) camera
    /// RGB, un-denoised, with its noise estimate. About 72 MB at 24 MP.
    public struct Analysis: Sendable {
        public let map: [Float]
        public let width: Int
        public let height: Int
        /// Sensor px per map px: 2.
        public let binSpan: Float
        /// rawWidth, rawHeight.
        public let sensorSize: SIMD2<Float>
        /// `BlobDetector.localNoise` of `map`.
        public let noise: [Float]

        public init(map: [Float], width: Int, height: Int, binSpan: Float, sensorSize: SIMD2<Float>, noise: [Float]) {
            self.map = map
            self.width = width
            self.height = height
            self.binSpan = binSpan
            self.sensorSize = sensorSize
            self.noise = noise
        }

        var blobMap: BlobDetector.Map { BlobDetector.Map(values: map, width: width, height: height) }
        var shortSide: Float { min(sensorSize.x, sensorSize.y) }
        /// Sensor px → map px (pixel-index frame): map pixel x covers
        /// sensor [x·binSpan, (x+1)·binSpan).
        func mapPoint(_ sensor: SIMD2<Float>) -> SIMD2<Float> { sensor / binSpan - 0.5 }
        func sensorPoint(_ map: SIMD2<Float>) -> SIMD2<Float> { (map + 0.5) * binSpan }
        func contains(_ map: SIMD2<Float>) -> Bool {
            map.x >= 0 && map.y >= 0 && map.x <= Float(width - 1) && map.y <= Float(height - 1)
        }
    }

    /// The parameters the analysis render actually depends on: it stops
    /// at the camera-RGB seam, so only the white balance and the demosaic
    /// matter; everything else is set neutral so two edits that differ
    /// only in their look share an analysis.
    public static func analysisParameters(_ p: EditParameters) -> EditParameters {
        var neutral = EditParameters()
        neutral.whiteBalance = p.whiteBalance
        neutral.demosaic = p.demosaic
        return neutral
    }

    /// `renderCameraRGB(.binned(quads: 1))` in the `.analysis` pool, read
    /// back and converted to log2 luminance row by row. The Float16
    /// readback (48 MB at 24 MP) is dropped before the noise estimate, so
    /// the peak is the readback plus the map.
    public static func analyse(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                               parameters: EditParameters) throws -> Analysis {
        let summary = session.file.summary
        let p = analysisParameters(parameters)
        var width = 0, height = 0
        var pixels: [Float16] = []
        try session.withTexturePool(.analysis) {
            let texture = try pipeline.renderCameraRGB(session, scale: .binned(quads: 1), parameters: p)
            width = texture.width
            height = texture.height
            pixels = try TextureReadback.float16Pixels(of: texture, gpu: gpu)
        }
        session.releasePooledTextures(in: .analysis)
        guard width > 0, height > 0, pixels.count == width * height * 4 else { throw DustDetectorError.emptyRender }

        var map = [Float](repeating: 0, count: width * height)
        var rgba = [Float](repeating: 0, count: width * 4)
        var luminance = [Float](repeating: 0, count: width)
        var quarter: Float = 0.25, half: Float = 0.5, floor: Float = 1e-4
        var n = Int32(width)
        pixels.withUnsafeBufferPointer { src in
            map.withUnsafeMutableBufferPointer { dst in
                rgba.withUnsafeMutableBufferPointer { row in
                    luminance.withUnsafeMutableBufferPointer { lum in
                        for y in 0..<height {
                            // One row of RGBA halfs to floats, then 0.25R + 0.5G + 0.25B
                            // (a cheap luma in camera space), floored and logged.
                            var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress! + y * width * 4),
                                                  height: 1, width: vImagePixelCount(width * 4), rowBytes: width * 4 * 2)
                            var d = vImage_Buffer(data: row.baseAddress!, height: 1,
                                                  width: vImagePixelCount(width * 4), rowBytes: width * 4 * 4)
                            vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
                            vDSP_vsmul(row.baseAddress!, 4, &quarter, lum.baseAddress!, 1, vDSP_Length(width))
                            vDSP_vsma(row.baseAddress! + 1, 4, &half, lum.baseAddress!, 1, lum.baseAddress!, 1, vDSP_Length(width))
                            vDSP_vsma(row.baseAddress! + 2, 4, &quarter, lum.baseAddress!, 1, lum.baseAddress!, 1, vDSP_Length(width))
                            vDSP_vthr(lum.baseAddress!, 1, &floor, lum.baseAddress!, 1, vDSP_Length(width))
                            vvlog2f(dst.baseAddress! + y * width, lum.baseAddress!, &n)
                        }
                    }
                }
            }
        }
        pixels = []
        let noise = BlobDetector.localNoise(BlobDetector.Map(values: map, width: width, height: height))
        return Analysis(map: map, width: width, height: height, binSpan: 2,
                        sensorSize: SIMD2(Float(summary.rawWidth), Float(summary.rawHeight)), noise: noise)
    }

    /// The radius a dust shadow should have, in sensor pixels: the dust
    /// sits on the filter stack a fixed distance in front of the sensor,
    /// so its shadow's diameter scales with 1/N. 0.75 / (N × pitch),
    /// pitch = 36 mm / max(cropFactor, 1) / rawWidth, clamped 2…40; nil
    /// without an aperture or crop factor to go on.
    public static func expectedRadius(aperture: Double, cropFactor: Double, rawWidth: Int) -> Float? {
        guard aperture.isFinite, aperture > 0, cropFactor.isFinite, cropFactor > 0, rawWidth > 0 else { return nil }
        let pitch = 36 / max(cropFactor, 1) / Double(rawWidth)
        let radius = 0.75 / (aperture * pitch)
        return Float(min(max(radius, 2), 40))
    }

    /// The blob detector's parameters for a band and sensitivity, on a map
    /// of `binSpan` sensor pixels per map pixel. With an expected radius
    /// the band narrows to [0.5r, 2.5r] (never below 2 map px; a 2 px blob
    /// need not be found); a radius outside the band leaves it as chosen.
    public static func blobParameters(options: Options, expectedRadius: Float?, binSpan: Float) -> BlobDetector.Parameters {
        let band = options.size.sensorRadiusRange
        var lo = band.lowerBound, hi = band.upperBound
        if let r = expectedRadius, r.isFinite {
            let narrowLo = max(lo, 0.5 * r), narrowHi = min(hi, 2.5 * r)
            if narrowLo <= narrowHi { lo = narrowLo; hi = narrowHi }
        }
        let span = max(binSpan, 1)
        let mapLo = max(lo / span, 2), mapHi = max(hi / span, mapLo)
        let s = Float(min(max(options.sensitivity, 0), 100)) / 100
        return BlobDetector.Parameters(
            radiusRange: mapLo...mapHi, polarity: .dark,
            contrastSigma: 6 - 4 * s, minimumContrast: 0.08 - 0.06 * s,
            minimumCircularity: 0.65 - 0.15 * s, smoothSurround: 2.5 + s,
            maximumSurroundGradient: 0.01, maximumCount: HealPatch.maximumDustCount)
    }

    /// Spots as heal patches (best first, cap `HealPatch.maximumDustCount`)
    /// with sources from `DustSourcePlacer`, excluding blobs centred inside
    /// any of `existing` (dust, blemishes, heals).
    public static func detect(_ a: Analysis, options: Options, expectedRadius: Float?, existing: [HealPatch]) -> [HealPatch] {
        guard a.width > 0, a.height > 0, a.map.count == a.width * a.height else { return [] }
        let p = blobParameters(options: options, expectedRadius: expectedRadius, binSpan: a.binSpan)
        let blobs = BlobDetector.detect(a.blobMap, p, noise: a.noise.count == a.map.count ? a.noise : nil)
        let spots = blobs.map { spot(centre: $0.centre, radius: $0.radius, in: a) }
        return patches(for: spots, in: a, existing: existing)
    }

    /// Map spots verified in this image: the strongest DoG peak at the
    /// spot's radius within ±r of it, passing the contrast and circularity
    /// tests at the target's threshold (the surround tests are the
    /// reference photo's business). Absent spots are skipped; an accepted
    /// spot takes the larger of the map's radius and the one found here.
    public static func verify(_ spots: [DustMapSpot], in a: Analysis, options: Options, existing: [HealPatch]) -> [HealPatch] {
        guard a.width > 0, a.height > 0, a.map.count == a.width * a.height else { return [] }
        let band = blobParameters(options: options, expectedRadius: nil, binSpan: a.binSpan)
        let map = a.blobMap
        let noise = a.noise.count == a.map.count ? a.noise : nil
        var found: [DustSourcePlacer.Spot] = []
        for spot in spots {
            let centre = a.mapPoint(spot.centre * a.sensorSize)
            let r = spot.radius * a.shortSide / a.binSpan
            guard r >= 1, r.isFinite, a.contains(centre) else { continue }
            let p = BlobDetector.Parameters(
                radiusRange: max(0.5 * r, 1)...max(2.5 * r, 2), polarity: .dark,
                contrastSigma: band.contrastSigma, minimumContrast: band.minimumContrast,
                minimumCircularity: band.minimumCircularity, smoothSurround: nil, maximumSurroundGradient: nil,
                maximumCount: band.maximumCount)
            guard let blob = BlobDetector.verify(at: centre, radius: r, in: map, p, noise: noise) else { continue }
            found.append(self.spot(centre: blob.centre, radius: max(blob.radius, r), in: a))
        }
        return patches(for: found, in: a, existing: existing)
    }

    /// The current list as map spots (Save as dust map…): each patch's
    /// target and blob radius, with the contrast measured in this
    /// analysis. Strokes and patches off the map are left out.
    public static func mapSpots(from patches: [HealPatch], analysis a: Analysis) -> [DustMapSpot] {
        guard a.width > 0, a.height > 0, a.map.count == a.width * a.height else { return [] }
        let map = a.blobMap
        return patches.compactMap { patch in
            guard !patch.isStroke else { return nil }
            let centre = a.mapPoint(patch.target * a.sensorSize)
            guard a.contains(centre) else { return nil }
            let radiusSensor = max((patch.radius * a.shortSide - 2) / 1.5, 1)
            guard let contrast = BlobDetector.contrast(at: centre, radius: radiusSensor / a.binSpan, in: map) else { return nil }
            return DustMapSpot(centre: patch.target, radius: radiusSensor / a.shortSide, contrast: contrast)
        }
    }

    // MARK: - Blobs to patches

    /// A blob on the map as the patch that heals it, in sensor px: the
    /// patch reaches half again as far as the blob plus a pixel each side,
    /// so the feather starts outside the shadow's soft edge.
    static func spot(centre: SIMD2<Float>, radius: Float, in a: Analysis) -> DustSourcePlacer.Spot {
        DustSourcePlacer.Spot(centre: a.sensorPoint(centre), radius: 1.5 * radius * a.binSpan + 2)
    }

    /// Patches for `spots` (best first): those centred inside an existing
    /// patch's target are dropped, each of the rest gets a source placed
    /// clear of every spot and existing target, and a spot with nowhere
    /// to copy from is dropped.
    static func patches(for spots: [DustSourcePlacer.Spot], in a: Analysis, existing: [HealPatch]) -> [HealPatch] {
        let shortSide = a.shortSide
        let existingSpots = existing.flatMap { patch in
            patch.pathPoints().map { DustSourcePlacer.Spot(centre: $0 * a.sensorSize, radius: patch.radius * shortSide) }
        }
        let kept = spots.filter { spot in
            !existingSpots.contains { simd_distance(spot.centre, $0.centre) < $0.radius }
        }
        var patches: [HealPatch] = []
        for (index, spot) in kept.enumerated() {
            guard patches.count < HealPatch.maximumDustCount else { break }
            var others = kept
            others.remove(at: index)
            others += existingSpots
            guard let source = DustSourcePlacer.place(spot, avoiding: others, sensorSize: a.sensorSize, analysis: a) else { continue }
            patches.append(HealPatch(target: spot.centre / a.sensorSize, source: source / a.sensorSize,
                                     radius: spot.radius / shortSide, feather: 0.5, mode: .heal))
        }
        return patches
    }
}

/// Where a dust patch copies from (docs/Retouch.md §6): a clean disc
/// near the spot, clear of every other spot and patch.
public enum DustSourcePlacer {
    /// Sensor px.
    public struct Spot: Sendable, Equatable {
        public var centre: SIMD2<Float>
        public var radius: Float

        public init(centre: SIMD2<Float>, radius: Float) {
            self.centre = centre
            self.radius = radius
        }
    }

    /// The rings tried, as multiples of the spot's radius: the nearest
    /// first, since the heal's ratio field wants a source that shares the
    /// target's surroundings.
    static let rings: [Float] = [2.75, 3.5, 4.5]

    /// 8 directions at 2.75r, then 3.5r and 4.5r; rejects a source that
    /// leaves the sensor or lies within 1.5·r_source + r_other of any spot
    /// in `others` (the heal field's σ = r/2 still leaks from a dip within
    /// about 1.5r); among a ring's survivors the lowest mean |∇(G_r∗D)|
    /// over the disc wins, ties by the largest margin from the others;
    /// without an `analysis` the margin alone decides. Nil means drop the
    /// spot.
    public static func place(_ spot: Spot, avoiding others: [Spot], sensorSize: SIMD2<Float>,
                             analysis: DustDetector.Analysis?) -> SIMD2<Float>? {
        let r = spot.radius
        guard r > 0, r.isFinite, spot.centre.x.isFinite, spot.centre.y.isFinite else { return nil }
        for ring in rings {
            var best: (source: SIMD2<Float>, gradient: Float, margin: Float)?
            for k in 0..<8 {
                let angle = Float(k) * .pi / 4
                let source = spot.centre + ring * r * SIMD2(cos(angle), sin(angle))
                guard source.x - r >= 0, source.y - r >= 0,
                      source.x + r <= sensorSize.x, source.y + r <= sensorSize.y else { continue }
                var margin = Float.greatestFiniteMagnitude
                var clear = true
                for other in others {
                    let gap = simd_distance(source, other.centre) - (1.5 * r + other.radius)
                    if gap < 0 { clear = false; break }
                    margin = min(margin, gap)
                }
                guard clear else { continue }
                let gradient = analysis.map { meanGradient(at: source, radius: r, in: $0) } ?? 0
                if let b = best, !(gradient < b.gradient || (gradient == b.gradient && margin > b.margin)) { continue }
                best = (source, gradient, margin)
            }
            if let best { return best.source }
        }
        return nil
    }

    /// Mean |∇(G_r∗D)| over the disc of `radius` at `source` (sensor px),
    /// in stops per map pixel.
    static func meanGradient(at source: SIMD2<Float>, radius: Float, in a: DustDetector.Analysis) -> Float {
        guard a.map.count == a.width * a.height, a.width > 0, a.height > 0 else { return 0 }
        let plane = BlobDetector.Plane(width: a.width, height: a.height, values: a.map)
        let r = max(radius / a.binSpan, 1)
        return plane.meanGradient(centre: a.mapPoint(source), sigma: r, innerRadius: 0, outerRadius: r)
    }
}
