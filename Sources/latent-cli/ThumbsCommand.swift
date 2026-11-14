import Foundation
import CoreGraphics
import RawCore
import PixelEngine
import Catalog

/// `latent-cli thumbs <folder>`: builds or refreshes a folder's thumbnail
/// cache ahead of time, so a large folder opens in the app with every
/// thumbnail already there. It opens (or creates) the folder's catalog,
/// reads the folder as the app does on opening, and makes every thumbnail
/// that is missing or stale, edited photos through the render pipeline,
/// exactly as the app's own background pass would.
enum ThumbsCommand {
    static let usage = """
    Usage: latent-cli thumbs <folder> [--include-subfolders]

      --include-subfolders   include every subfolder that awaits a decision
    """

    static func run(_ args: [String]) async -> Int32 {
        var folders: [String] = []
        var includeSubfolders = false
        for arg in args {
            if arg == "--include-subfolders" {
                includeSubfolders = true
            } else if arg.hasPrefix("--") {
                print("thumbs: unknown option \(arg)\n\n\(usage)")
                return 2
            } else {
                folders.append(arg)
            }
        }
        guard folders.count == 1 else {
            print(usage)
            return 2
        }
        let folder = URL(fileURLWithPath: folders[0], isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("thumbs: \(folder.path) isn't a folder")
            return 1
        }
        do {
            let catalog = try Catalog.open(at: folder)
            if includeSubfolders { try await catalog.setDefaultSubfolderMode(.included) }
            let report = try await catalog.reconcile()
            print("Read \(folder.path): \(report)")
            for undecided in report.undecidedSubfolders {
                print("  subfolder '\(undecided)' awaits a decision; pass --include-subfolders to include it")
            }
            // Without a GPU, edited photos keep their embedded previews,
            // as the app's pass does before its renderer is attached.
            let renderer: PipelineThumbnails? = (try? GPUContext()).map(PipelineThumbnails.init)
            if renderer == nil { print("Note: no Metal device; edited photos keep their unedited thumbnails") }
            let needed = try await catalog.thumbnailJobs().count
            print("\(needed) thumbnail\(needed == 1 ? "" : "s") to make")
            let progress = ProgressLine()
            let thumbs = try await catalog.generateMissingThumbnails(editedRenderer: renderer) { done, total in
                progress.show(done, total)
            }
            print("Thumbnails: \(thumbs)")
            for failure in thumbs.failures { print("  FAILED \(failure.relPath): \(failure.reason)") }
            return thumbs.failures.isEmpty ? 0 : 1
        } catch {
            print("thumbs: \(error)")
            return 1
        }
    }

    /// A line every tenth of the way, not one per photo.
    final class ProgressLine: @unchecked Sendable {
        private let lock = NSLock()
        private var lastTenth = 0
        func show(_ done: Int, _ total: Int) {
            guard total > 0 else { return }
            let tenth = done * 10 / total
            let changed: Bool = lock.withLock {
                guard tenth > lastTenth else { return false }
                lastTenth = tenth
                return true
            }
            if changed { print("  \(done) of \(total)") }
        }
    }
}

/// Thumbnails for edited photos, rendered as the app renders them
/// (`PipelineThumbnailRenderer` in latent-app): binned to just under the
/// thumbnail size, in the camera's orientation, cropped.
struct PipelineThumbnails: EditedThumbnailRenderer {
    let gpu: GPUContext

    func renderThumbnail(rawFileAt url: URL, editStackJSON: String) throws -> CGImage {
        let file = try RawFile(path: url.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        let parameters = try session.stackForThisImage(EditStack.decode(json: editStackJSON))
            .parameters(defaults: defaults)
        let longEdge = max(file.summary.rawWidth, file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / Double(2 * Thumbnailer.size)).rounded(.up)))
        let texture = try pipeline.render(session, scale: .binned(quads: quads),
                                          parameters: parameters, output: .file(.sRGB))
        let rotation = ImageRotation(libRawFlip: file.summary.orientation)
        return try Exporter(gpu: gpu).cgImage(from: texture, colorSpace: .sRGB, rotation: rotation,
                                              crop: parameters.crop)
    }
}
