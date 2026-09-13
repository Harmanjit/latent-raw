import Foundation
import CoreGraphics
import RawCore
import PixelEngine
import LensKit
import ColorKit

/// One export, start to finish, on any thread: open the raw, rebuild the
/// edit (including any model-generated masks), render at the right
/// scale, resize, rotate, write with metadata.
///
/// Lives in MLKit rather than PixelEngine because a faithful export must
/// regenerate AI masks, and only MLKit knows how. The app's queue calls
/// this once per image; the CLI could too.
public enum ExportWorker {
    public struct Request: Sendable {
        public var sourceURL: URL
        public var destinationURL: URL
        public var editStackJSON: String?
        public var userRotation: Int
        public var settings: ExportSettings
        public var colorSpace: ColorKit.OutputSpace
        /// Long edge in pixels; nil for full size.
        public var maxLongEdge: Int?
        public var keywords: [String]
        public var rating: Int

        public init(sourceURL: URL, destinationURL: URL, editStackJSON: String?, userRotation: Int,
                    settings: ExportSettings, colorSpace: ColorKit.OutputSpace, maxLongEdge: Int?,
                    keywords: [String] = [], rating: Int = 0) {
            self.sourceURL = sourceURL; self.destinationURL = destinationURL
            self.editStackJSON = editStackJSON; self.userRotation = userRotation
            self.settings = settings; self.colorSpace = colorSpace; self.maxLongEdge = maxLongEdge
            self.keywords = keywords; self.rating = rating
        }
    }

    public struct Outcome: Sendable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let seconds: TimeInterval
        public let masksGenerated: Int
    }

    public static func export(_ request: Request, gpu: GPUContext) async throws -> Outcome {
        let start = Date()
        let file = try RawFile(path: request.sourceURL.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        // The edit, over this image's defaults — exactly as the editor
        // would reconstruct it.
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        var parameters = defaults
        if let json = request.editStackJSON, let stack = try? EditStack.decode(json: json) {
            parameters = stack.parameters(defaults: defaults)
            if parameters.whiteBalance.isAsShot { parameters.whiteBalance = defaults.whiteBalance }
        }
        parameters.outputSpace = request.colorSpace

        // Model-generated masks are not stored; make them again.
        let masksGenerated = try await regenerateMasks(parameters.locals, session: session, pipeline: pipeline, gpu: gpu)

        // Scale: bin as far as the target allows (cheaper and a correct
        // box filter), never below it; full resolution otherwise.
        let sensorLong = max(file.summary.rawWidth, file.summary.rawHeight)
        var scale = RenderScale.full
        if let target = request.maxLongEdge, target > 0 {
            let quads = sensorLong / (2 * target)
            if quads >= 1 { scale = .binned(quads: quads) }
        }
        let texture = try pipeline.render(session, scale: scale, parameters: parameters,
                                          output: .file(request.colorSpace))
        let rotation = ImageRotation(libRawFlip: file.summary.orientation).rotated(by: request.userRotation)

        let s = file.summary
        var metadata = ExportMetadata()
        metadata.cameraMake = s.cameraMake.isEmpty ? nil : s.cameraMake
        metadata.cameraModel = s.cameraModel.isEmpty ? nil : s.cameraModel
        metadata.lensModel = session.lensCorrection?.profileName ?? (s.lensModel.isEmpty ? nil : s.lensModel)
        metadata.iso = s.iso > 0 ? Int(s.iso) : nil
        metadata.shutter = s.shutter > 0 ? s.shutter : nil
        metadata.aperture = s.aperture > 0 ? s.aperture : nil
        metadata.focalLength = s.focalLength > 0 ? s.focalLength : nil
        metadata.captureDate = s.captureTime.timeIntervalSince1970 > 0 ? s.captureTime : nil
        metadata.keywords = request.keywords
        metadata.rating = request.rating

        let exporter = Exporter(gpu: gpu)
        let width: Int, height: Int
        if let target = request.maxLongEdge, target > 0 {
            // Resize path: 8-bit CGImage, resampled to the exact size.
            let image = Exporter.resized(try exporter.cgImage(from: texture, colorSpace: request.colorSpace,
                                                              rotation: rotation), maxLongEdge: target)
            try Exporter.write(cgImage: image, to: request.destinationURL, settings: request.settings,
                               metadata: metadata)
            width = image.width; height = image.height
        } else {
            // Full size keeps the 16-bit path for TIFF.
            try exporter.write(texture, to: request.destinationURL, settings: request.settings,
                               colorSpace: request.colorSpace, rotation: rotation, metadata: metadata)
            let swap = rotation.swapsAxes
            width = swap ? texture.height : texture.width
            height = swap ? texture.width : texture.height
        }
        return Outcome(pixelWidth: width, pixelHeight: height,
                       seconds: Date().timeIntervalSince(start), masksGenerated: masksGenerated)
    }

    /// Generates pixels for every AI and prompted local, the same way the
    /// editor does: from a ~1000px unrotated sRGB render of the defaults.
    static func regenerateMasks(_ locals: [LocalAdjustment], session: ImageSession,
                                pipeline: RenderPipeline, gpu: GPUContext) async throws -> Int {
        let needed = locals.filter { $0.shape.isModelGenerated }
        guard !needed.isEmpty else { return 0 }
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        let longEdge = max(session.file.summary.rawWidth, session.file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / 2048.0).rounded(.up)))
        let tex = try pipeline.render(session, scale: .binned(quads: quads), parameters: defaults,
                                      output: .file(.sRGB))
        let image = try Exporter(gpu: gpu).cgImage(from: tex, colorSpace: .sRGB)

        var sam: SAM2Session?
        var count = 0
        for local in needed {
            switch local.shape {
            case .ai(let kindName, _):
                guard let kind = AIMaskKind(storedName: kindName) else { continue }
                let result = try await AIMaskGenerator.generate(kind, from: image)
                session.setAIMask(result.mask, forLocal: local.id)
                count += 1
            case .prompted(let points, _):
                guard !points.isEmpty else { continue }
                if sam == nil, let models = await SAM2Models.shared.value {
                    sam = try SAM2Session(models: models, image: image)
                }
                guard let sam else { continue }
                let prediction = try sam.predict(points: points.map { PromptPoint(x: $0.x, y: $0.y, foreground: $0.foreground) })
                session.setAIMask(prediction.mask, forLocal: local.id)
                count += 1
            default:
                continue
            }
        }
        return count
    }
}
