import Foundation
import CoreGraphics
import CoreML
import PixelEngine

/// What a Wave 0 stub throws when asked to do the work it stands in for
/// (docs/Retouch.md §14): named for the feature, never a made-up result.
public struct NotYetImplemented: Error, CustomStringConvertible {
    public let feature: String
    public init(_ feature: String) { self.feature = feature }
    public var description: String { "\(feature) is not built yet" }
}

public enum SubjectSegmenterError: Error, Equatable, CustomStringConvertible {
    case wrongKind(String)
    case noPackage(String)
    /// The model's input is not an image; a multi-array input would need
    /// a normalisation the manifest does not describe.
    case unsupportedInput(String)
    case unexpectedOutput(String)
    case rotationFailed

    public var description: String {
        switch self {
        case .wrongKind(let id): return "'\(id)' is not a subject model"
        case .noPackage(let id): return "'\(id)' names no package to load"
        case .unsupportedInput(let id): return "'\(id)' does not take an image as its input"
        case .unexpectedOutput(let why): return "the subject model's output is not a mask (\(why))"
        case .rotationFailed: return "the image could not be turned upright for the subject model"
        }
    }
}

/// A subjectSegmentation model: image in, soft mask out. BiRefNet-lite
/// is the bundled one (docs/Retouch.md §5); an imported one goes through
/// the same manifest.
///
/// **Orientation.** These models were trained on upright pictures and
/// fragment on a sideways one (the spike's notes, §0). The pipeline's
/// renders are in sensor orientation, and so is every mask, so
/// `segment(_:rotation:)` takes the sensor-orientation image with the
/// turn that makes it upright, turns it, runs the model, and turns the
/// mask back; the caller never sees the upright copy. The editor's
/// `modelInputImage` renders unrotated (its comment says why), so a
/// caller there passes `EditorModel.rotation`; the export worker passes
/// `ExportPlan.rotation(for:userRotation:)`.
public final class SubjectSegmenter: @unchecked Sendable {
    public let entry: ModelEntry
    /// The square the image is stretched to: the model's own constraint
    /// when it states one, else the manifest's `inputSize`.
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

    /// Loads the entry's one package through `CoreMLStore.load(_:of:at:computeUnits:)`.
    public static func load(_ entry: ModelEntry, computeUnits: MLComputeUnits) async throws -> SubjectSegmenter {
        guard entry.manifest.kind == .subjectSegmentation else { throw SubjectSegmenterError.wrongKind(entry.id) }
        guard let location = entry.location, let package = entry.manifest.packages.first else {
            throw SubjectSegmenterError.noPackage(entry.id)
        }
        let model = try await CoreMLStore.load(package, of: entry.manifest, at: location, computeUnits: computeUnits)
        let description = model.modelDescription
        // The manifest's names first (what the converter wrote), else the
        // model's own; a one-in one-out model needs neither.
        let inputName = package.inputNames.first ?? description.inputDescriptionsByName.keys.sorted().first ?? ""
        let outputName = package.outputNames.first ?? description.outputDescriptionsByName.keys.sorted().first ?? ""
        guard let input = description.inputDescriptionsByName[inputName], let constraint = input.imageConstraint else {
            throw SubjectSegmenterError.unsupportedInput(entry.id)
        }
        let size = constraint.pixelsWide > 0 ? constraint.pixelsWide : entry.manifest.inputSize
        return SubjectSegmenter(entry: entry, model: model, inputName: inputName, outputName: outputName, inputSize: size)
    }

    /// Stretches `image`, made upright by `rotation`, to inputSize², runs
    /// one prediction, reads a (1,1,H,W) or (1,H,W) Float16/Float32
    /// output, applies a sigmoid when the manifest says the output is
    /// logits, and returns 8-bit pixels at the model's native size (the
    /// guide's size after guided refinement), turned back into `image`'s
    /// orientation so the mask lands in sensor coordinates like every
    /// other mask.
    public func segment(_ image: CGImage, rotation: ImageRotation = .none) throws -> MaskBitmap {
        guard let upright = UprightImage.rotated(image, by: rotation) else { throw SubjectSegmenterError.rotationFailed }
        guard let buffer = MLImage.pixelBuffer(from: upright, width: inputSize, height: inputSize) else {
            throw AIMaskError.noResult
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: outputName)?.multiArrayValue else {
            throw SubjectSegmenterError.unexpectedOutput("no '\(outputName)' in the result")
        }
        // The last two dimensions are the mask; anything before them must
        // be a batch or channel of one.
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2, shape.dropLast(2).allSatisfy({ $0 == 1 }) else {
            throw SubjectSegmenterError.unexpectedOutput("shape \(shape)")
        }
        let height = shape[shape.count - 2], width = shape[shape.count - 1]
        let values = array.floats()
        guard values.count == width * height else {
            throw SubjectSegmenterError.unexpectedOutput("\(values.count) values for \(width)x\(height)")
        }
        let logits = entry.manifest.outputActivation == .sigmoid
        var data = [UInt8](repeating: 0, count: width * height)
        for i in 0..<data.count {
            var v = values[i]
            if logits { v = 1 / (1 + exp(-v)) }
            data[i] = UInt8(min(max(v, 0), 1) * 255)
        }
        var mask = MaskBitmap(width: width, height: height, data: data)
        if entry.manifest.refine == .guided {
            mask = GuidedMaskRefiner.refine(mask, guide: upright)
        }
        return Self.sensorMask(mask, rotation: rotation)
    }

    /// `mask`, in the upright image's frame, turned back into the sensor
    /// frame: each sensor pixel reads the image pixel `rotation` sends it
    /// to (`ImageRotation.imagePoint`), so this is the exact inverse of
    /// `UprightImage.rotated` at the mask's resolution.
    static func sensorMask(_ mask: MaskBitmap, rotation: ImageRotation) -> MaskBitmap {
        guard rotation != .none else { return mask }
        let width = rotation.swapsAxes ? mask.height : mask.width
        let height = rotation.swapsAxes ? mask.width : mask.height
        let sensorSize = CGSize(width: width, height: height)
        var out = [UInt8](repeating: 0, count: width * height)
        mask.data.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                for y in 0..<height {
                    for x in 0..<width {
                        let p = rotation.imagePoint(fromSensorPoint: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5),
                                                    sensorSize: sensorSize)
                        let ix = min(max(Int(p.x), 0), mask.width - 1)
                        let iy = min(max(Int(p.y), 0), mask.height - 1)
                        destination[y * width + x] = source[iy * mask.width + ix]
                    }
                }
            }
        }
        return MaskBitmap(width: width, height: height, data: out)
    }
}
