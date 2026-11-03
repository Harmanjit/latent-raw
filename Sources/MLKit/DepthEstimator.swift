import Foundation
import CoreGraphics
import CoreML
import PixelEngine

public enum DepthEstimatorError: Error, Equatable, CustomStringConvertible {
    case wrongKind(String)
    case noPackage(String)
    case unsupportedInput(String)
    case unexpectedOutput(String)
    case rotationFailed

    public var description: String {
        switch self {
        case .wrongKind(let id): return "'\(id)' is not a depth model"
        case .noPackage(let id): return "'\(id)' names no package to load"
        case .unsupportedInput(let id): return "'\(id)' does not take an image as its input"
        case .unexpectedOutput(let why): return "the depth model's output is not a depth map (\(why))"
        case .rotationFailed: return "the image could not be turned upright for the depth model"
        }
    }
}

/// A depth model: image in, relative inverse depth out (larger is
/// nearer), as Depth Anything V2 gives it. Nothing is bundled; the user
/// converts one with scripts/convert_depth_anything.py and adds it in
/// Settings › AI › Models (docs/wiki/Models.md). Lens Blur reads the
/// result; without a depth model it falls back to two planes from the
/// subject mask (`LensBlurDepth`).
///
/// Like the subject models it wants an upright picture: `estimate` turns
/// the sensor-orientation image upright, runs the model, and turns the
/// map back, so the caller never sees the upright copy.
public final class DepthEstimator: @unchecked Sendable {
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
    public static func load(_ entry: ModelEntry, computeUnits: MLComputeUnits) async throws -> DepthEstimator {
        guard entry.manifest.kind == .depth else { throw DepthEstimatorError.wrongKind(entry.id) }
        guard let location = entry.location, let package = entry.manifest.packages.first else {
            throw DepthEstimatorError.noPackage(entry.id)
        }
        let model = try await CoreMLStore.load(package, of: entry.manifest, at: location, computeUnits: computeUnits)
        let description = model.modelDescription
        let inputName = package.inputNames.first ?? description.inputDescriptionsByName.keys.sorted().first ?? ""
        let outputName = package.outputNames.first ?? description.outputDescriptionsByName.keys.sorted().first ?? ""
        guard let input = description.inputDescriptionsByName[inputName], let constraint = input.imageConstraint else {
            throw DepthEstimatorError.unsupportedInput(entry.id)
        }
        let size = constraint.pixelsWide > 0 ? constraint.pixelsWide : entry.manifest.inputSize
        return DepthEstimator(entry: entry, model: model, inputName: inputName, outputName: outputName, inputSize: size)
    }

    /// The depth of `image` (sensor orientation; `rotation` makes it
    /// upright), 255 nearest, at the model's output size, in the sensor
    /// orientation again.
    public func estimate(_ image: CGImage, rotation: ImageRotation = .none) throws -> MaskBitmap {
        guard let upright = UprightImage.rotated(image, by: rotation) else { throw DepthEstimatorError.rotationFailed }
        guard let buffer = MLImage.pixelBuffer(from: upright, width: inputSize, height: inputSize) else {
            throw AIMaskError.noResult
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: outputName)?.multiArrayValue else {
            throw DepthEstimatorError.unexpectedOutput("no '\(outputName)' in the result")
        }
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2, shape.dropLast(2).allSatisfy({ $0 == 1 }) else {
            throw DepthEstimatorError.unexpectedOutput("shape \(shape)")
        }
        let height = shape[shape.count - 2], width = shape[shape.count - 1]
        let values = array.floats()
        guard values.count == width * height, width > 0, height > 0 else {
            throw DepthEstimatorError.unexpectedOutput("\(values.count) values for \(width)x\(height)")
        }
        let map = Self.normalised(values, width: width, height: height)
        return SubjectSegmenter.sensorMask(map, rotation: rotation)
    }

    /// Relative inverse depth to 0…255: the 1st percentile to 0 and the
    /// 99th to 255, so a stray pixel at either end (a specular glint the
    /// model read as very near) doesn't squeeze the rest of the scene into
    /// a few levels. Non-finite values read as the far end.
    static func normalised(_ values: [Float], width: Int, height: Int) -> MaskBitmap {
        let finite = values.filter(\.isFinite).sorted()
        guard let first = finite.first, let last = finite.last else {
            return MaskBitmap(width: width, height: height, data: [UInt8](repeating: 0, count: width * height))
        }
        let lo = finite[min(finite.count - 1, finite.count / 100)]
        let hi = finite[max(0, finite.count - 1 - finite.count / 100)]
        let low = hi > lo ? lo : first, high = hi > lo ? hi : last
        let span = high - low
        let data = values.map { v -> UInt8 in
            guard v.isFinite, span > 0 else { return 0 }
            return MLImage.maskByte((v - low) / span)
        }
        return MaskBitmap(width: width, height: height, data: data)
    }
}
