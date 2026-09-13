import Foundation
import CoreML
import CoreGraphics
import PixelEngine

/// Semantic segmentation: every pixel gets a probability for each of the
/// ADE20K classes. One forward pass answers "where is the sky", "where
/// are the people", "where is water" and so on at once.
///
/// The model is SegFormer-B2 (27 M parameters, ~55 MB in fp16), converted
/// by `scripts/convert_segformer.py` with the normalisation, upsampling
/// and softmax folded into the graph, so this class only resizes the
/// image in and reads probabilities out.
public final class SegmentationModel: @unchecked Sendable {
    public static let packageName = "SegFormer_segformer_b2_finetuned_ade_512_512"
    public static let modelVersion = "segformer-b2-ade20k-512.1"

    public let labels: [String]
    public let inputSize: Int
    private let model: MLModel
    private let inputName: String
    private let outputName: String

    /// Loaded once per process; nil when the package isn't bundled.
    public static let shared: Task<SegmentationModel?, Never> = Task.detached(priority: .utility) {
        try? await SegmentationModel.load()
    }

    public static var isAvailable: Bool { CoreMLStore.isAvailable(packageName) }

    public static func load() async throws -> SegmentationModel {
        let model = try await CoreMLStore.load(packageName)   // see CoreMLStore.defaultComputeUnits
        let labels = CoreMLStore.json(packageName + ".labels.json", as: [String].self) ?? []
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
