import Foundation
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

/// Thrown by the parts of the detector Wave 0 leaves as stubs.
public enum DustDetectorError: Error, CustomStringConvertible {
    case notImplemented

    public var description: String {
        switch self {
        case .notImplemented: return "Sensor dust analysis is not implemented yet"
        }
    }
}

/// Sensor dust (docs/Retouch.md §6): the analysis map, the detector's
/// parameters per band and sensitivity, detection into heal patches,
/// map verification and saving a list as a map. Used by the editor's
/// panel and by the Remove Dust batch job.
///
/// Wave 0: the pure maths (`analysisParameters`, `expectedRadius`,
/// `blobParameters`) is real; `analyse` throws and the detection calls
/// find nothing until Wave 1 (dust-core) fills them in.
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
    /// back and converted to log2 luminance row by row.
    public static func analyse(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                               parameters: EditParameters) throws -> Analysis {
        // Wave 1 (dust-core) writes the render and readback.
        throw DustDetectorError.notImplemented
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
        // Wave 1 (dust-core) writes the detection; nothing is found until then.
        []
    }

    /// Map spots verified in this image (a DoG peak within ±r passing the
    /// tests at the target's threshold); absent spots are skipped.
    public static func verify(_ spots: [DustMapSpot], in a: Analysis, options: Options, existing: [HealPatch]) -> [HealPatch] {
        // Wave 1 (dust-core) writes the verification; nothing is found until then.
        []
    }

    /// The current list as map spots (Save as dust map…).
    public static func mapSpots(from patches: [HealPatch], analysis: Analysis) -> [DustMapSpot] {
        // Wave 1 (dust-core) measures each spot's contrast in the analysis.
        []
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

    /// 8 directions at 2.75r, then 3.5r and 4.5r; rejects a source that
    /// leaves the sensor or lies within 1.5·r_source + r_other of any spot
    /// in `others`; the lowest mean gradient over the disc wins
    /// (gradient-free when `analysis` is nil); nil means drop the spot.
    public static func place(_ spot: Spot, avoiding others: [Spot], sensorSize: SIMD2<Float>,
                             analysis: DustDetector.Analysis?) -> SIMD2<Float>? {
        // Wave 1 (dust-core) writes the placement; no source until then.
        nil
    }
}
