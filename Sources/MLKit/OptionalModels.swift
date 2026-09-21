import Foundation

/// The one row of the dormant download path (DESIGN.md §4a), kept only
/// because `EditorModel` still declares the download state and the two
/// functions in `EditorModel+Denoise.swift` that use it. Nothing offers
/// the download, the app has no network entitlement, and the release
/// its URL names was never published. Models are added from disk with
/// `ModelImporter` (docs/Retouch.md §2 A); W2-M removes the callers and
/// this file with them.
@available(*, deprecated, message: "the download path goes with docs/Retouch.md; models come from ModelImporter")
public struct OptionalModel: Sendable, Identifiable {
    public let id: String            // package name
    public let title: String
    public let sizeMB: Int
    public let url: URL
    /// SHA-256 of the zip as published; a mismatch is refused.
    public let sha256: String

    /// The flat legacy location `CoreMLStore.packageURL` still looks in
    /// for this one name.
    public var installedURL: URL {
        CoreMLStore.externalModelsDirectory.appendingPathComponent(id + ".mlpackage")
    }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// NAFNet SIDD width 64: ~0.3 dB better than the bundled width-32
    /// model on SIDD, at about four times the compute. Not published.
    public static let nafnetWidth64 = OptionalModel(
        id: "NAFNet_SIDD_width64",
        title: "NAFNet high-quality denoiser",
        sizeMB: 214,
        url: URL(string: "https://github.com/Harmanjit/latent-raw/releases/download/models-v1/NAFNet_SIDD_width64.mlpackage.zip")!,
        sha256: "f8671a233053cc9549d138f4dcfce8f5f730c3a9310584e1ab9bcb46cb34bc5f")
}

@available(*, deprecated, message: "the download path goes with docs/Retouch.md")
public enum ModelDownloadError: Error, CustomStringConvertible {
    case noNetwork
    case notInArchive(String)

    public var description: String {
        switch self {
        case .noNetwork: "Latent never downloads anything; add a model from disk in Settings › AI › Models."
        case .notInArchive(let name): "The archive did not contain \(name)."
        }
    }
}

/// What remains of the downloader: `install` refuses (the app cannot
/// reach the network, and never tried), `remove` still clears a copy an
/// earlier build may have left.
@available(*, deprecated, message: "the download path goes with docs/Retouch.md; models come from ModelImporter")
public enum ModelDownloader {
    public static func install(_ model: OptionalModel,
                               progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        throw ModelDownloadError.noNetwork
    }

    public static func remove(_ model: OptionalModel) throws {
        if model.isInstalled { try FileManager.default.removeItem(at: model.installedURL) }
    }
}
