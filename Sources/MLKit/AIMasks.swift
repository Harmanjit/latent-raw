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

    /// Recorded in the edit so a change of model is visible later.
    public var modelVersion: String {
        switch self {
        case .subject: return "vision.foregroundInstance.1"
        case .sky where !SegmentationModel.isAvailable: return "latent.skyHeuristic.1"
        default: return SegmentationModel.modelVersion
        }
    }

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
/// **Subject and people** use the Vision framework's own models. Apple
/// ships them with the OS, so there's nothing to bundle or download, they
/// are shared by every app on the machine, and Vision schedules them on
/// the Neural Engine when it can. Their sizes and architectures aren't
/// published; what's measurable is the cost, which is printed with each
/// result: on an M-series Mac a subject lift is a few hundred
/// milliseconds and a person mask well under one hundred.
///
/// **Sky** has no system model on macOS, and a proper one (a small
/// semantic-segmentation network such as SegFormer-B0 trained on ADE20K,
/// ~8 MB in fp16) needs a Core ML conversion step that this machine lacks
/// tooling for. Until that lands, sky is estimated by a classic heuristic
/// — see `SkyEstimator` — which works for open skies and is honest about
/// being a heuristic in its model version string.
///
/// Input is a small image (~1024 px on the long edge is plenty; the models
/// resize internally to ~512 anyway). Output is at the model's resolution
/// and is bilinearly upsampled when it's put into a mask slice.
public enum AIMaskGenerator {
    public struct Result: Sendable {
        public let mask: MaskBitmap
        public let seconds: TimeInterval
    }

    /// Semantic classes go through SegFormer when it's bundled. Without
    /// it, sky falls back to the heuristic and people to Vision; the other
    /// classes have no fallback and throw.
    public static func generate(_ kind: AIMaskKind, from image: CGImage) async throws -> Result {
        let start = Date()
        let mask: MaskBitmap
        switch kind {
        case .subject:
            mask = try subjectMask(image)
        default:
            if let model = await SegmentationModel.shared.value, let cls = kind.segmentClass {
                let map = try model.classify(image)
                mask = map.mask(classIndices: model.indices(forLabels: cls.labels))
            } else if kind == .sky {
                mask = SkyEstimator.estimate(image)
            } else if kind == .people {
                mask = try personMask(image)
            } else {
                throw AIMaskError.modelUnavailable(SegmentationModel.packageName)
            }
        }
        return Result(mask: mask, seconds: Date().timeIntervalSince(start))
    }

    /// Whether `generate` for this kind uses a bundled neural model.
    public static var segmentationAvailable: Bool { SegmentationModel.isAvailable }

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
/// A real model replaces this; the interface stays the same.
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
