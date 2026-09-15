import Foundation
import CoreGraphics
import RawCore
import PixelEngine
import LensKit
import ColorKit
import os

private let exportLogger = Logger(subsystem: "com.latent.app", category: "export")

/// One export, start to finish, on any thread: open the raw, rebuild the
/// edit (including any model-generated masks), render at the right
/// scale, resize, rotate, write with metadata.
///
/// Lives in MLKit rather than PixelEngine because a faithful export must
/// regenerate AI masks, and only MLKit knows how. The app's queue calls
/// this once per image; the CLI could too.
public enum ExportWorkerError: Error, CustomStringConvertible {
    case unreadableEdit(Error)
    public var description: String {
        switch self {
        case .unreadableEdit(let e): "the stored edit could not be read (\(e)); not exported unedited"
        }
    }
}

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
        /// False writes pixels only: no camera, date, location, keywords or rating.
        public var includeMetadata: Bool

        public init(sourceURL: URL, destinationURL: URL, editStackJSON: String?, userRotation: Int,
                    settings: ExportSettings, colorSpace: ColorKit.OutputSpace, maxLongEdge: Int?,
                    keywords: [String] = [], rating: Int = 0, includeMetadata: Bool = true) {
            self.sourceURL = sourceURL; self.destinationURL = destinationURL
            self.editStackJSON = editStackJSON; self.userRotation = userRotation
            self.settings = settings; self.colorSpace = colorSpace; self.maxLongEdge = maxLongEdge
            self.keywords = keywords; self.rating = rating; self.includeMetadata = includeMetadata
        }
    }

    public struct Outcome: Sendable, CustomStringConvertible {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let seconds: TimeInterval
        public let masksGenerated: Int
        /// Where the time went, in seconds: "unpack", "masks", "render", "write".
        public let phases: [(String, TimeInterval)]

        public var description: String {
            let parts = phases.map { String(format: "%@ %.0f ms", $0.0, $0.1 * 1000) }
            return String(format: "%dx%d in %.0f ms (%@)", pixelWidth, pixelHeight, seconds * 1000,
                          parts.joined(separator: ", "))
        }
    }

    public static func export(_ request: Request, gpu: GPUContext) async throws -> Outcome {
        let start = Date()
        var phases: [(String, TimeInterval)] = []
        var mark = Date()
        func lap(_ name: String) { phases.append((name, Date().timeIntervalSince(mark))); mark = Date() }

        let file = try RawFile(path: request.sourceURL.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        lap("unpack")

        // The edit, over this image's defaults — exactly as the editor
        // would reconstruct it.
        let parameters: EditParameters
        do {
            parameters = try ExportPlan.parameters(editStackJSON: request.editStackJSON, session: session,
                                                   colorSpace: request.colorSpace)
        } catch {
            throw ExportWorkerError.unreadableEdit(error)
        }

        // Model-generated masks are not stored; make them again.
        let masksGenerated = try await regenerateMasks(parameters.locals, session: session, pipeline: pipeline, gpu: gpu)
        lap("masks")

        // Neural denoise is computed, not stored: run it for the export.
        if parameters.aiDenoise > 0, AIDenoiser.isAvailable {
            let denoiser = try await AIDenoiser.load()
            try await AIDenoiseWorker.run(session: session, pipeline: pipeline, gpu: gpu, denoiser: denoiser)
            lap("denoise")
        }

        let scale = ExportPlan.scale(for: file.summary, maxLongEdge: request.maxLongEdge)
        let texture = try pipeline.render(session, scale: scale,
                                          parameters: parameters, output: .file(request.colorSpace))
        let rotation = ExportPlan.rotation(for: file.summary, userRotation: request.userRotation)
        lap("render")

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
        if request.includeMetadata {
            // GPS, copyright, exposure details and the rest, read from the
            // raw in the decoder service. A file it can't read still gets
            // the summary fields above rather than failing the export.
            do {
                metadata.source = try SourceMetadata(path: request.sourceURL.path)
            } catch {
                exportLogger.error("source metadata unavailable for \(request.sourceURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // Rotation, the final resize and the quantisation to 8 or 16 bits
        // all happen on the GPU inside the exporter; the CPU only hands the
        // bytes to the encoder. A gain map needs the edit rendered a second
        // time with HDR headroom, which the exporter asks for when it's ready.
        let exporter = Exporter(gpu: gpu)
        let written = try exporter.write(texture, to: request.destinationURL, settings: request.settings,
                                         colorSpace: request.colorSpace, rotation: rotation,
                                         crop: parameters.crop,
                                         metadata: request.includeMetadata ? metadata : nil,
                                         maxLongEdge: request.maxLongEdge,
                                         hdrRender: { output in
                                             try pipeline.render(session, scale: scale, parameters: parameters, output: output)
                                         })
        lap("write")
        return Outcome(pixelWidth: written.width, pixelHeight: written.height,
                       seconds: Date().timeIntervalSince(start), masksGenerated: masksGenerated,
                       phases: phases)
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
