import Foundation
import CoreML
import CoreGraphics
import PixelEngine

/// A point the user clicked: where (normalized sensor coordinates), and
/// whether it marks the thing wanted (foreground) or something to leave
/// out (background).
public struct PromptPoint: Equatable, Sendable, Codable {
    public var x: Float
    public var y: Float
    public var foreground: Bool
    public init(x: Float, y: Float, foreground: Bool) { self.x = x; self.y = y; self.foreground = foreground }
}

/// Segment Anything 2.1 (small), Apple's Core ML conversion, driven with
/// point prompts: "the thing here" / "not the thing there".
///
/// Three networks. The **image encoder** is the expensive one (a
/// hierarchical vision transformer, ~35 M parameters, 80 MB in fp16) and
/// runs once per image at 1024×1024. The **prompt encoder** turns points
/// into embeddings and the **mask decoder** combines them with the image
/// embeddings into candidate masks with confidence scores — a few
/// milliseconds each, which is why clicking feels instant after the first
/// encode.
public final class SAM2Models: @unchecked Sendable {
    /// What a new click-to-select mask stores for the bundled model; the
    /// 0.9.0 literal "sam2.1-small.1" is still read (`ModelRef.legacy`).
    public static let modelVersion = "sam2.1-small@1"
    static let encoderName = "SAM2_1SmallImageEncoderFLOAT16"
    static let promptName = "SAM2_1SmallPromptEncoderFLOAT16"
    static let decoderName = "SAM2_1SmallMaskDecoderFLOAT16"
    /// The roles a promptedSegmentation manifest gives its three packages.
    static let encoderRole = "imageEncoder", promptRole = "promptEncoder", decoderRole = "maskDecoder"

    let encoder: MLModel
    let promptEncoder: MLModel
    let decoder: MLModel
    public let inputSize: Int

    /// Whether the bundled SAM 2.1 Small is there to load.
    public static var isAvailable: Bool {
        ModelRegistry.shared.installed(ModelRef(id: ModelRegistry.defaultPromptedID, version: 1)) != nil
    }

    /// The bundled model as the registry holds it, loaded on first use;
    /// nil when the packages aren't bundled. `release()` releases the
    /// registry's copy (see `RegistryModel`).
    public static let shared = RegistryModel<SAM2Models>(id: ModelRegistry.defaultPromptedID) {
        if case .prompted(let model) = $0 { return model }
        return nil
    }

    /// The bundled SAM 2.1 Small; nil compute units means the registry's
    /// effective choice for it.
    public static func load(computeUnits: MLComputeUnits? = nil) async throws -> SAM2Models {
        guard let entry = ModelRegistry.shared.installed(ModelRef(id: ModelRegistry.defaultPromptedID, version: 1)) else {
            throw CoreMLStore.StoreError.modelMissing(encoderName)
        }
        return try await load(entry, computeUnits: computeUnits ?? ModelRegistry.shared.effectiveComputeUnits(for: entry))
    }

    /// The three packages of a promptedSegmentation manifest, by role
    /// (docs/Retouch.md §5), loaded together from the model's folder.
    public static func load(_ entry: ModelEntry, computeUnits: MLComputeUnits) async throws -> SAM2Models {
        guard entry.manifest.kind == .promptedSegmentation else { throw SAM2Error.wrongKind(entry.id) }
        guard let location = entry.location else { throw SAM2Error.missingRole(entry.id, encoderRole) }
        func package(_ role: String) throws -> ModelManifest.Package {
            guard let package = entry.manifest.packages.first(where: { $0.role == role }) else {
                throw SAM2Error.missingRole(entry.id, role)
            }
            return package
        }
        let encoderPackage = try package(encoderRole)
        let promptPackage = try package(promptRole)
        let decoderPackage = try package(decoderRole)
        async let e = CoreMLStore.load(encoderPackage, of: entry.manifest, at: location, computeUnits: computeUnits)
        async let p = CoreMLStore.load(promptPackage, of: entry.manifest, at: location, computeUnits: computeUnits)
        async let d = CoreMLStore.load(decoderPackage, of: entry.manifest, at: location, computeUnits: computeUnits)
        return SAM2Models(encoder: try await e, promptEncoder: try await p, decoder: try await d)
    }

    init(encoder: MLModel, promptEncoder: MLModel, decoder: MLModel) {
        self.encoder = encoder
        self.promptEncoder = promptEncoder
        self.decoder = decoder
        let input = encoder.modelDescription.inputDescriptionsByName.values.first
        inputSize = Int(input?.imageConstraint?.pixelsWide ?? 1024)
    }
}

public enum SAM2Error: Error, Equatable, CustomStringConvertible {
    case wrongKind(String)
    /// A prompted manifest without one of imageEncoder, promptEncoder, maskDecoder.
    case missingRole(String, String)
    public var description: String {
        switch self {
        case .wrongKind(let id): return "'\(id)' is not a click-to-select model"
        case .missingRole(let id, let role): return "'\(id)' names no package with the role \(role)"
        }
    }
}

/// The encoded state of one image, ready to answer clicks.
public final class SAM2Session: @unchecked Sendable {
    let models: SAM2Models
    private let embeddings: MLFeatureProvider
    public let encodeSeconds: TimeInterval

    public init(models: SAM2Models, image: CGImage) throws {
        self.models = models
        let start = Date()
        guard let buffer = MLImage.pixelBuffer(from: image, width: models.inputSize, height: models.inputSize) else {
            throw AIMaskError.noResult
        }
        let inputName = models.encoder.modelDescription.inputDescriptionsByName.keys.first!
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        embeddings = try models.encoder.prediction(from: input)
        encodeSeconds = Date().timeIntervalSince(start)
        // Core ML specialises a model for the hardware on its first
        // prediction, which took ~2 s for the decoder in measurement. Pay
        // that here, while the user is still reaching for the mouse, so
        // the first real click costs the same ~40 ms as every other.
        _ = try? predict(points: [PromptPoint(x: 0.5, y: 0.5, foreground: true)])
    }

    public struct Prediction: Sendable {
        public let mask: MaskBitmap
        public let score: Float
        public let seconds: TimeInterval
    }

    /// Decodes a mask for `points`. Returns the highest-scoring candidate
    /// as a soft mask (sigmoid of the logits), 256×256.
    public func predict(points: [PromptPoint]) throws -> Prediction {
        precondition(!points.isEmpty)
        let start = Date()
        let n = points.count
        let size = Float(models.inputSize)
        let coords = try MLMultiArray(shape: [1, NSNumber(value: n), 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        for (i, p) in points.enumerated() {
            coords[[0, i, 0] as [NSNumber]] = NSNumber(value: p.x * size)
            coords[[0, i, 1] as [NSNumber]] = NSNumber(value: p.y * size)
            labels[[0, i] as [NSNumber]] = NSNumber(value: p.foreground ? 1 : 0)
        }
        let promptInput = try MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: coords),
            "labels": MLFeatureValue(multiArray: labels),
        ])
        let prompt = try models.promptEncoder.prediction(from: promptInput)

        // Decoder input names as in Apple's conversion; embeddings pass
        // straight through from the encoder.
        var decoderInputs: [String: MLFeatureValue] = [:]
        for name in models.decoder.modelDescription.inputDescriptionsByName.keys {
            if let v = embeddings.featureValue(for: name) ?? prompt.featureValue(for: name) {
                decoderInputs[name] = v
            } else if name == "sparse_embedding", let v = prompt.featureValue(for: "sparse_embeddings") {
                decoderInputs[name] = v
            } else if name == "dense_embedding", let v = prompt.featureValue(for: "dense_embeddings") {
                decoderInputs[name] = v
            }
        }
        let output = try models.decoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: decoderInputs))
        guard let masks = output.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = output.featureValue(for: "scores")?.multiArrayValue else {
            throw AIMaskError.noResult
        }
        let scoreValues = scores.floats()
        let best = scoreValues.indices.max { scoreValues[$0] < scoreValues[$1] } ?? 0
        let h = masks.shape[2].intValue, w = masks.shape[3].intValue
        let all = masks.floats()
        let plane = h * w
        var data = [UInt8](repeating: 0, count: plane)
        for i in 0..<plane {
            // Logits; 0 is the decision boundary. A sigmoid gives a soft
            // edge a few pixels wide at 256², which upsamples cleanly.
            let logit = all[best * plane + i]
            data[i] = UInt8(min(max(1 / (1 + exp(-logit)), 0), 1) * 255)
        }
        return Prediction(mask: MaskBitmap(width: w, height: h, data: data),
                          score: scoreValues[best], seconds: Date().timeIntervalSince(start))
    }
}
