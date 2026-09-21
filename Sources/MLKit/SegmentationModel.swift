import Foundation
import CoreML
import CoreGraphics
import PixelEngine

/// Semantic segmentation: every pixel gets a probability for each of the
/// ADE20K classes. One forward pass answers "where is the sky", "where
/// are the people", "where is water" and so on at once.
///
/// The model is SegFormer-B2 (27 M parameters, ~55 MB in fp16), converted
/// by `scripts/convert_segformer.py` with the normalisation and softmax
/// folded into the graph, so this class only resizes the image in and
/// reads probabilities out. They come out at a quarter of the input size
/// (128 x 128 for a 512 x 512 input); upsampling 150 class maps inside the
/// graph would cost far more than resizing the one mask that is wanted.
public final class SegmentationModel: @unchecked Sendable {
    public static let packageName = "SegFormer_segformer_b2_finetuned_ade_512_512"
    /// The bundled model's id in the registry (docs/Retouch.md §2 A).
    public static let modelID = "segformer-b2-ade20k-512"
    /// What a new class mask stores; the 0.9.0 literal
    /// "segformer-b2-ade20k-512.1" is still read (`ModelRef.legacy`).
    public static let modelVersion = "segformer-b2-ade20k-512@1"

    public let labels: [String]
    public let inputSize: Int
    private let model: MLModel
    private let inputName: String
    private let outputName: String

    /// The bundled model as the registry holds it, loaded on first use;
    /// nil when the package isn't bundled. `release()` releases the
    /// registry's copy (see `RegistryModel`).
    public static let shared = RegistryModel<SegmentationModel>(id: modelID) {
        if case .semantic(let model) = $0 { return model }
        return nil
    }

    public static var isAvailable: Bool {
        ModelRegistry.shared.installed(ModelRef(id: modelID, version: 1)) != nil
    }

    /// The bundled model, at the registry's effective compute units (see
    /// `CoreMLStore.defaultComputeUnits`).
    public static func load() async throws -> SegmentationModel {
        guard let entry = ModelRegistry.shared.installed(ModelRef(id: modelID, version: 1)) else {
            throw CoreMLStore.StoreError.modelMissing(packageName)
        }
        return try await load(entry, computeUnits: ModelRegistry.shared.effectiveComputeUnits(for: entry))
    }

    /// A semanticSegmentation entry's one package, with the class labels
    /// from the JSON its manifest names in the model's own folder.
    public static func load(_ entry: ModelEntry, computeUnits: MLComputeUnits) async throws -> SegmentationModel {
        guard entry.manifest.kind == .semanticSegmentation else { throw SegmentationModelError.wrongKind(entry.id) }
        guard let location = entry.location, let package = entry.manifest.packages.first else {
            throw SegmentationModelError.noPackage(entry.id)
        }
        let model = try await CoreMLStore.load(package, of: entry.manifest, at: location, computeUnits: computeUnits)
        guard let file = entry.manifest.labelsFile,
              let labels = CoreMLStore.json(file, in: location, as: [String].self) else {
            throw SegmentationModelError.noLabels(entry.id)
        }
        return SegmentationModel(model: model, labels: labels)
    }

    init(model: MLModel, labels: [String]) {
        self.model = model
        self.labels = labels
        let input = model.modelDescription.inputDescriptionsByName.first!
        inputName = input.key
        inputSize = Int(input.value.imageConstraint?.pixelsWide ?? 512)
        outputName = model.modelDescription.outputDescriptionsByName.keys.first!
    }

    /// Per-class probabilities, `labels.count` planes of `inputSize²`.
    public struct ClassMap: Sendable {
        public let size: Int
        public let classCount: Int
        public let probabilities: [Float]   // [class][y][x]

        /// A soft mask for the union of `classIndices`: the summed
        /// probability of those classes at each pixel.
        public func mask(classIndices: [Int]) -> MaskBitmap {
            let n = size * size
            var out = [UInt8](repeating: 0, count: n)
            for i in 0..<n {
                var p: Float = 0
                for c in classIndices { p += probabilities[c * n + i] }
                out[i] = UInt8(min(max(p, 0), 1) * 255)
            }
            return MaskBitmap(width: size, height: size, data: out)
        }
    }

    public func classify(_ image: CGImage) throws -> ClassMap {
        guard let buffer = MLImage.pixelBuffer(from: image, width: inputSize, height: inputSize) else {
            throw AIMaskError.noResult
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: outputName)?.multiArrayValue else { throw AIMaskError.noResult }
        // Output is (1, classes, H, W) at the network's native resolution —
        // a quarter of the input. The chosen mask is upsampled later.
        let size = array.shape.count >= 4 ? array.shape[2].intValue : inputSize
        return ClassMap(size: size, classCount: labels.count, probabilities: array.floats())
    }

    public func indices(forLabels names: [String]) -> [Int] {
        names.compactMap { name in labels.firstIndex(of: name) }
    }
}

public enum SegmentationModelError: Error, Equatable, CustomStringConvertible {
    case wrongKind(String), noPackage(String), noLabels(String)
    public var description: String {
        switch self {
        case .wrongKind(let id): return "'\(id)' is not a class model"
        case .noPackage(let id): return "'\(id)' names no package to load"
        case .noLabels(let id): return "'\(id)' has no readable labels file beside its package"
        }
    }
}

/// Named groups of ADE20K classes offered in the UI.
public enum SegmentClass: String, CaseIterable, Sendable {
    case sky, people, vegetation, water, buildings, ground, mountains, animals, vehicles

    public var displayName: String {
        switch self {
        case .sky: return "Sky"
        case .people: return "People"
        case .vegetation: return "Vegetation"
        case .water: return "Water"
        case .buildings: return "Buildings"
        case .ground: return "Ground"
        case .mountains: return "Mountains & Rock"
        case .animals: return "Animals"
        case .vehicles: return "Vehicles"
        }
    }

    public var labels: [String] {
        switch self {
        case .sky: return ["sky"]
        case .people: return ["person"]
        case .vegetation: return ["tree", "grass", "plant", "palm", "flower", "field"]
        case .water: return ["water", "sea", "river", "lake", "swimming pool", "waterfall"]
        case .buildings: return ["building", "house", "skyscraper", "tower", "hovel", "bridge"]
        case .ground: return ["earth", "road", "sidewalk", "sand", "path", "dirt track", "land", "floor", "runway"]
        case .mountains: return ["mountain", "hill", "rock"]
        case .animals: return ["animal"]
        case .vehicles: return ["car", "bus", "truck", "van", "bicycle", "minibike", "boat", "ship", "airplane"]
        }
    }
}
