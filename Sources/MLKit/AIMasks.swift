import Foundation
import CoreGraphics
import CoreVideo
import Vision
import PixelEngine

/// The kinds of automatic mask (DESIGN.md §8.4). Click-to-select masks
/// are a separate shape (`MaskShape.prompted`) driven by SAM 2.
public enum AIMaskKind: String, CaseIterable, Sendable {
    /// Apple's Vision "lift subject": automatic, no clicks, no control.
    case subject
    /// Semantic classes from SegFormer (ADE20K).
    case sky, people, vegetation, water, buildings, ground, mountains, animals, vehicles

    public var displayName: String {
        switch self {
        case .subject: return "Subject (auto)"
        default: return segmentClass!.displayName
        }
    }

    public var segmentClass: SegmentClass? {
        switch self {
        case .subject: return nil
        default: return SegmentClass(rawValue: rawValue)
        }
    }

    /// What a NEW mask of this kind records, so a change of model is
    /// visible later: the registry's default subject model, or the
    /// installed class model (the sky heuristic when there is none;
    /// docs/Retouch.md §2 A).
    public var modelVersion: String {
        modelVersion(registry: .shared)
    }

    func modelVersion(registry: ModelRegistry) -> String {
        switch self {
        case .subject:
            return registry.defaultSubject().modelVersion
        default:
            if let installed = registry.installed(ModelRef(id: SegmentationModel.modelID, version: 1)) {
                return installed.modelVersion
            }
            return self == .sky ? Self.skyHeuristicVersion : SegmentationModel.modelVersion
        }
    }

    /// The sky mask made without a model (`SkyEstimator`).
    static let skyHeuristicID = "latent.skyHeuristic"
    static let skyHeuristicVersion = "latent.skyHeuristic@1"

    /// Legacy names from earlier sidecars.
    public init?(storedName: String) {
        if storedName == "person" { self = .people; return }
        self.init(rawValue: storedName)
    }
}

public enum AIMaskError: Error, CustomStringConvertible {
    case noResult
    case unsupportedPixelFormat
    case modelUnavailable(String)
    public var description: String {
        switch self {
        case .noResult: return "the model returned no mask"
        case .unsupportedPixelFormat: return "unexpected mask pixel format"
        case .modelUnavailable(let n): return "model '\(n)' is not bundled"
        }
    }
}

/// Generates masks from an image.
///
/// **Subject** uses the Vision framework's own model. Apple ships it with
/// the OS, so there's nothing to bundle or download, it is shared by every
/// app on the machine, and Vision schedules it on the Neural Engine when it
/// can. Its size and architecture aren't published; what's measurable is
/// the cost, which is reported with each result: on an M-series Mac a
/// subject lift is a few hundred milliseconds.
///
/// **Subject** masks made with a model from the registry (BiRefNet-lite
/// is bundled) go through `SubjectSegmenter`; the edit names which.
///
/// **Sky, people** and the other semantic classes use the bundled
/// SegFormer-B2 model (ADE20K). If it is missing, sky falls back to
/// `SkyEstimator`, a classic heuristic that says so in its model version
/// string, and people fall back to Vision's person segmentation.
///
/// Input is a small image (~1024 px on the long edge is plenty; the models
/// resize internally to ~512 anyway). Output is at the model's resolution
/// and is bilinearly upsampled when it's put into a mask slice.
public enum AIMaskGenerator {
    public struct Result: Sendable {
        public let mask: MaskBitmap
        public let seconds: TimeInterval
        /// The display name of the model the mask names but this Mac
        /// lacks (or the stored string itself when it names nothing), so
        /// the stand-in that ran can be reported: "made with Apple Vision
        /// because BiRefNet General is not installed" (docs/Retouch.md
        /// §2 A, §5). Nil when the mask was made with its own model.
        public let substitutedModel: String?

        public init(mask: MaskBitmap, seconds: TimeInterval, substitutedModel: String? = nil) {
            self.mask = mask
            self.seconds = seconds
            self.substitutedModel = substitutedModel
        }
    }

    /// A mask as the edit names it.
    ///
    /// `.subject`: `ModelRef(stored:)` → `registry.installed` → the
    /// SubjectSegmenter for that id, or built-in Vision when the edit
    /// names it; a version that is missing, cannot be parsed, or fails to
    /// load runs Vision and says so in `substitutedModel`. The classes
    /// run the installed class model whichever one the edit names (the
    /// 0.9.0 beta did the same), with the heuristic and Vision fallbacks
    /// below; only a real, missing class model is reported.
    ///
    /// `rotation` is the turn that makes `image` upright: the subject
    /// models need it (`SubjectSegmenter`), the rest ignore it.
    public static func generate(_ kind: AIMaskKind, modelVersion: String, from image: CGImage,
                                rotation: ImageRotation = .none,
                                registry: ModelRegistry = .shared) async throws -> Result {
        let start = Date()
        let ref = ModelRef(stored: modelVersion)
        switch kind {
        case .subject:
            if let entry = registry.installed(ref), entry.manifest.kind == .subjectSegmentation {
                if entry.status == .builtIn {
                    return Result(mask: try subjectMask(image), seconds: Date().timeIntervalSince(start))
                }
                if let model = await registry.subject(id: entry.id) {
                    let mask = try model.segment(image, rotation: rotation)
                    return Result(mask: mask, seconds: Date().timeIntervalSince(start))
                }
            }
            return Result(mask: try subjectMask(image), seconds: Date().timeIntervalSince(start),
                          substitutedModel: displayName(forMissing: modelVersion, registry: registry))
        default:
            guard let cls = kind.segmentClass else { throw AIMaskError.noResult }
            // The class model named, else the bundled one.
            var chosen = registry.installed(ref).flatMap { $0.manifest.kind == .semanticSegmentation ? $0 : nil }
            var substituted: String?
            if chosen == nil {
                chosen = registry.installed(ModelRef(id: SegmentationModel.modelID, version: 1))
                if let ref, ref.id != AIMaskKind.skyHeuristicID, ref.id != SegmentationModel.modelID {
                    substituted = displayName(forMissing: modelVersion, registry: registry)
                }
            }
            if let chosen, let model = await registry.semantic(id: chosen.id) {
                let map = try model.classify(image)
                return Result(mask: map.mask(classIndices: model.indices(forLabels: cls.labels)),
                              seconds: Date().timeIntervalSince(start), substitutedModel: substituted)
            }
            return Result(mask: try fallbackMask(kind, image), seconds: Date().timeIntervalSince(start),
                          substitutedModel: substituted)
        }
    }

    /// The mask a NEW local of this kind gets: `kind.modelVersion`'s
    /// model. The editor's path until W2-M passes the stored version.
    public static func generate(_ kind: AIMaskKind, from image: CGImage) async throws -> Result {
        try await generate(kind, modelVersion: kind.modelVersion, from: image)
    }

    /// Without a class model, sky falls back to the heuristic and people
    /// to Vision; the other classes have no fallback and throw.
    static func fallbackMask(_ kind: AIMaskKind, _ image: CGImage) throws -> MaskBitmap {
        switch kind {
        case .sky: return SkyEstimator.estimate(image)
        case .people: return try personMask(image)
        default: throw AIMaskError.modelUnavailable(SegmentationModel.packageName)
        }
    }

    /// What to call a stored version this Mac cannot run: the catalogue's
    /// display name when it lists the id, else the id, else the string
    /// as stored (one that does not parse names nothing).
    static func displayName(forMissing stored: String, registry: ModelRegistry) -> String {
        guard let ref = ModelRef(stored: stored) else { return stored }
        return registry.entry(id: ref.id)?.manifest.displayName ?? ref.id
    }

    // MARK: - Vision

    static func subjectMask(_ image: CGImage) throws -> MaskBitmap {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            // Nothing lifted: an empty mask is a valid answer ("no subject").
            return MaskBitmap(width: 1, height: 1, data: [0])
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances,
                                                                from: handler)
        return try bitmap(from: buffer)
    }

    static func personMask(_ image: CGImage) throws -> MaskBitmap {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw AIMaskError.noResult }
        return try bitmap(from: observation.pixelBuffer)
    }

    /// Reads a one-component 8-bit or 32-bit-float pixel buffer.
    static func bitmap(from buffer: CVPixelBuffer) throws -> MaskBitmap {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AIMaskError.noResult }
        var out = [UInt8](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = UInt8(min(max(row[x], 0), 1) * 255) }
            }
        default:
            throw AIMaskError.unsupportedPixelFormat
        }
        return MaskBitmap(width: w, height: h, data: out)
    }
}

/// A sky estimate without a neural network.
///
/// Sky, in the photographs this is for, is bright, low in saturation or
/// blue, smooth (few edges), and connected to the top of the frame. Each
/// pixel gets a score from the first three; the mask is the set of
/// high-scoring pixels reachable from the top edge through other
/// high-scoring pixels (a flood fill), which is what stops a bright grey
/// road at the bottom being called sky. The edge is then softened.
///
/// Where it fails: skies seen through foliage, reflections, sunsets with
/// strong orange (the saturation test), and scenes with no top-edge sky.
/// Used only when the SegFormer model isn't bundled.
public enum SkyEstimator {
    static let workingWidth = 256

    public static func estimate(_ image: CGImage) -> MaskBitmap {
        let w = workingWidth
        let h = max(1, image.height * w / max(image.width, 1))
        guard let rgb = downsampledRGB(image, width: w, height: h) else {
            return MaskBitmap(width: 1, height: 1, data: [0])
        }

        // Per-pixel sky score in [0,1].
        var score = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let r = Float(rgb[i]) / 255, g = Float(rgb[i + 1]) / 255, b = Float(rgb[i + 2]) / 255
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                let bright = smooth(0.25, 0.55, mx)
                // Blue-ish (b >= r) or nearly neutral.
                let blueish = b >= r * 0.95 ? 1 : smooth(0.25, 0.05, sat)
                let colourOK = max(blueish, smooth(0.35, 0.1, sat))
                // Smoothness: small gradient against the right/below neighbours.
                var grad: Float = 0
                if x + 1 < w {
                    let j = (y * w + x + 1) * 3
                    grad = max(grad, abs(Float(rgb[j]) - Float(rgb[i])) + abs(Float(rgb[j + 1]) - Float(rgb[i + 1])) + abs(Float(rgb[j + 2]) - Float(rgb[i + 2])))
                }
                if y + 1 < h {
                    let j = ((y + 1) * w + x) * 3
                    grad = max(grad, abs(Float(rgb[j]) - Float(rgb[i])) + abs(Float(rgb[j + 1]) - Float(rgb[i + 1])) + abs(Float(rgb[j + 2]) - Float(rgb[i + 2])))
                }
                let smoothOK = smooth(90, 30, grad / 3)
                score[y * w + x] = bright * colourOK * smoothOK
            }
        }

        // Flood fill from the top edge through pixels above the threshold.
        let threshold: Float = 0.35
        var inSky = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w where score[x] >= threshold { inSky[x] = true; stack.append(x) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                if !inSky[j] && score[j] >= threshold { inSky[j] = true; stack.append(j) }
            }
        }

        // Soft edge: a small box blur of the binary mask, weighted by score
        // so the boundary follows the image rather than the grid.
        var out = [UInt8](repeating: 0, count: w * h)
        let r = 2
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0, n: Float = 0
                for dy in -r...r { for dx in -r...r {
                    let nx = min(max(x + dx, 0), w - 1), ny = min(max(y + dy, 0), h - 1)
                    sum += inSky[ny * w + nx] ? 1 : 0; n += 1
                } }
                out[y * w + x] = UInt8(min(max(sum / n, 0), 1) * 255)
            }
        }
        return MaskBitmap(width: w, height: h, data: out)
    }

    private static func smooth(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func downsampledRGB(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = bytes[i * 4]; rgb[i * 3 + 1] = bytes[i * 4 + 1]; rgb[i * 3 + 2] = bytes[i * 4 + 2]
        }
        return rgb
    }
}
