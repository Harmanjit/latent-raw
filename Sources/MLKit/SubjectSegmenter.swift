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

/// A subjectSegmentation model: image in, soft mask out. BiRefNet-lite
/// is the bundled one (docs/Retouch.md §5); an imported one goes through
/// the same manifest.
public final class SubjectSegmenter: @unchecked Sendable {
    public let entry: ModelEntry

    private init(entry: ModelEntry) {
        self.entry = entry
    }

    /// Loads the entry's one package through `CoreMLStore.load(_:of:at:computeUnits:)`.
    /// Wave 1 (W1-A) fills this in.
    public static func load(_ entry: ModelEntry, computeUnits: MLComputeUnits) async throws -> SubjectSegmenter {
        throw NotYetImplemented("Loading \(entry.manifest.displayName)")
    }

    /// Stretches to inputSize², one prediction, (1,1,H,W) or (1,H,W)
    /// output, sigmoid when the manifest says so, 8-bit at the model's
    /// native size; guided refinement when `entry.manifest.refine == .guided`.
    public func segment(_ image: CGImage) throws -> MaskBitmap {
        throw NotYetImplemented("Subject masks with \(entry.manifest.displayName)")
    }
}
