import Foundation
import CoreGraphics
import CoreML
import CoreVideo
import PixelEngine

public enum ReflectionRemoverError: Error, Equatable, CustomStringConvertible {
    case wrongKind(String)
    case noPackage(String)
    case unsupportedInput(String)
    case unexpectedOutput(String)
    case rotationFailed

    public var description: String {
        switch self {
        case .wrongKind(let id): return "'\(id)' is not a reflection removal model"
        case .noPackage(let id): return "'\(id)' names no package to load"
        case .unsupportedInput(let id): return "'\(id)' does not take an image as its input"
        case .unexpectedOutput(let why): return "the reflection model's output is not a picture (\(why))"
        case .rotationFailed: return "the image could not be turned upright for the reflection model"
        }
    }
}

/// A reflection-removal model: a photo taken through glass in, the scene
/// behind the glass out (the "transmission layer"). Nothing is bundled;
/// the user converts one with scripts/convert_reflection_removal.py and
/// adds it in Settings › AI › Models (docs/wiki/Models.md).
///
/// The output may be an image, or a float array shaped [1, 3, H, W] or
/// [3, H, W] in 0…1 (0…255 is recognised and scaled). Either way it
/// becomes a gain map (`ReflectionMap`): per pixel and channel, the
/// model's picture over the one it was given, in linear light. Like the
/// depth model it sees the picture upright, and the map is turned back
/// to the sensor's orientation.
public final class ReflectionRemover: @unchecked Sendable {
    public let entry: ModelEntry
    public let inputSize: Int
    private let model: MLModel
    private let inputName: String
    private let outputName: String

    private init(entry: ModelEntry, model: MLModel, inputName: String, outputName: String, inputSize: Int) {
        self.entry = entry
        self.model = model
        self.inputName = inputName
        self.outputName = outputName
        self.inputSize = inputSize
    }

    /// Loads the entry's one package through `CoreMLStore`.
    public static func load(_ entry: ModelEntry, computeUnits: MLComputeUnits) async throws -> ReflectionRemover {
        guard entry.manifest.kind == .reflectionRemoval else { throw ReflectionRemoverError.wrongKind(entry.id) }
        guard let location = entry.location, let package = entry.manifest.packages.first else {
            throw ReflectionRemoverError.noPackage(entry.id)
        }
        let model = try await CoreMLStore.load(package, of: entry.manifest, at: location, computeUnits: computeUnits)
        let description = model.modelDescription
        let inputName = package.inputNames.first ?? description.inputDescriptionsByName.keys.sorted().first ?? ""
        let outputName = package.outputNames.first ?? description.outputDescriptionsByName.keys.sorted().first ?? ""
        guard let input = description.inputDescriptionsByName[inputName], let constraint = input.imageConstraint else {
            throw ReflectionRemoverError.unsupportedInput(entry.id)
        }
        let size = constraint.pixelsWide > 0 ? constraint.pixelsWide : entry.manifest.inputSize
        return ReflectionRemover(entry: entry, model: model, inputName: inputName, outputName: outputName,
                                 inputSize: size)
    }

    /// The gain map of `image` (sensor orientation; `rotation` makes it
    /// upright) at the model's output size, in the sensor orientation.
    public func gainMap(for image: CGImage, rotation: ImageRotation = .none) throws -> ReflectionMap {
        guard let upright = UprightImage.rotated(image, by: rotation) else { throw ReflectionRemoverError.rotationFailed }
        guard let buffer = MLImage.pixelBuffer(from: upright, width: inputSize, height: inputSize) else {
            throw AIMaskError.noResult
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let output = try model.prediction(from: input)
        guard let value = output.featureValue(for: outputName) else {
            throw ReflectionRemoverError.unexpectedOutput("no '\(outputName)' in the result")
        }
        let picture: Planar
        if let array = value.multiArrayValue {
            picture = try Self.planar(from: array)
        } else if let pixels = value.imageBufferValue {
            picture = try Self.planar(from: pixels)
        } else {
            throw ReflectionRemoverError.unexpectedOutput("neither an image nor an array")
        }
        guard let original = Self.planar(from: upright, width: picture.width, height: picture.height) else {
            throw AIMaskError.noResult
        }
        let gains = Self.gains(original: original, removed: picture)
        return Self.sensorMap(gains, rotation: rotation, source: entry.modelVersion)
    }

    // MARK: - The arithmetic, separate so tests can run it without a model

    /// Three planes of 0…1 sRGB-encoded values.
    struct Planar {
        var width: Int
        var height: Int
        var r: [Float], g: [Float], b: [Float]
    }

    /// The model's array as planes: [1, 3, H, W] or [3, H, W], 0…1, or
    /// 0…255 when anything is above 1.5.
    static func planar(from array: MLMultiArray) throws -> Planar {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 3, shape.dropLast(3).allSatisfy({ $0 == 1 }), shape[shape.count - 3] == 3 else {
            throw ReflectionRemoverError.unexpectedOutput("shape \(shape)")
        }
        let height = shape[shape.count - 2], width = shape[shape.count - 1]
        let values = array.floats()
        let n = width * height
        guard n > 0, values.count == 3 * n else {
            throw ReflectionRemoverError.unexpectedOutput("\(values.count) values for 3x\(width)x\(height)")
        }
        return planar(values, width: width, height: height)
    }

    static func planar(_ values: [Float], width: Int, height: Int) -> Planar {
        let n = width * height
        let scale: Float = (values.lazy.filter(\.isFinite).max() ?? 0) > 1.5 ? 1.0 / 255 : 1
        func plane(_ k: Int) -> [Float] {
            (0..<n).map { i in
                let v = values[k * n + i] * scale
                return v.isFinite ? min(max(v, 0), 1) : 0
            }
        }
        return Planar(width: width, height: height, r: plane(0), g: plane(1), b: plane(2))
    }

    /// A BGRA (or ARGB) image output as planes.
    static func planar(from buffer: CVPixelBuffer) throws -> Planar {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB else {
            throw ReflectionRemoverError.unexpectedOutput("pixel format \(format)")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ReflectionRemoverError.unexpectedOutput("an empty image")
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let (ri, gi, bi) = format == kCVPixelFormatType_32BGRA ? (2, 1, 0) : (1, 2, 3)
        var out = Planar(width: width, height: height, r: [], g: [], b: [])
        out.r.reserveCapacity(width * height); out.g.reserveCapacity(width * height); out.b.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * row + x * 4
                out.r.append(Float(bytes[p + ri]) / 255)
                out.g.append(Float(bytes[p + gi]) / 255)
                out.b.append(Float(bytes[p + bi]) / 255)
            }
        }
        return out
    }

    /// `image` stretched to `width x height`, as planes: the picture the
    /// model was given, at the size of what it gave back.
    static func planar(from image: CGImage, width: Int, height: Int) -> Planar? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var out = Planar(width: width, height: height, r: [], g: [], b: [])
        for i in 0..<(width * height) {
            out.r.append(Float(bytes[i * 4]) / 255)
            out.g.append(Float(bytes[i * 4 + 1]) / 255)
            out.b.append(Float(bytes[i * 4 + 2]) / 255)
        }
        return out
    }

    /// Below this linear level a ratio means little (noise over noise), so
    /// both sides are lifted by it: dark pixels keep a gain near 1.
    static let ratioFloor: Float = 0.01

    static func linear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Per pixel and channel, removed over original in linear light,
    /// smoothed over 3 x 3 so the model's pixel noise doesn't become
    /// texture in the photo, as RGBA bytes (`ReflectionMap`).
    static func gains(original o: Planar, removed t: Planar) -> (width: Int, height: Int, rgba: [UInt8]) {
        let w = t.width, h = t.height, n = w * h
        func ratio(_ a: [Float], _ b: [Float]) -> [Float] {
            (0..<n).map { i in (linear(b[i]) + ratioFloor) / (linear(a[i]) + ratioFloor) }
        }
        let planes = [ratio(o.r, t.r), ratio(o.g, t.g), ratio(o.b, t.b)]
        var rgba = [UInt8](repeating: 255, count: n * 4)
        for (k, plane) in planes.enumerated() {
            for y in 0..<h {
                for x in 0..<w {
                    var sum: Float = 0, count: Float = 0
                    for dy in -1...1 {
                        let yy = y + dy
                        guard yy >= 0, yy < h else { continue }
                        for dx in -1...1 {
                            let xx = x + dx
                            guard xx >= 0, xx < w else { continue }
                            sum += plane[yy * w + xx]
                            count += 1
                        }
                    }
                    rgba[(y * w + x) * 4 + k] = ReflectionMap.byte(forGain: sum / count)
                }
            }
        }
        return (w, h, rgba)
    }

    /// The upright gains turned back to the sensor's orientation, one
    /// channel at a time through the subject masks' exact inverse.
    static func sensorMap(_ g: (width: Int, height: Int, rgba: [UInt8]), rotation: ImageRotation,
                          source: String) -> ReflectionMap {
        guard rotation != .none else { return ReflectionMap(width: g.width, height: g.height, gains: g.rgba, source: source) }
        let n = g.width * g.height
        let channels = (0..<3).map { k in
            SubjectSegmenter.sensorMask(MaskBitmap(width: g.width, height: g.height,
                                                   data: (0..<n).map { g.rgba[$0 * 4 + k] }), rotation: rotation)
        }
        let w = channels[0].width, h = channels[0].height
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4] = channels[0].data[i]
            rgba[i * 4 + 1] = channels[1].data[i]
            rgba[i * 4 + 2] = channels[2].data[i]
        }
        return ReflectionMap(width: w, height: h, gains: rgba, source: source)
    }
}
