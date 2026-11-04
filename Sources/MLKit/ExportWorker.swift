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
        /// With metadata, also keep where the photo was taken and the camera
        /// and lens serial numbers (`ExportMetadata.includeLocation`).
        public var includeLocation: Bool
        /// False never replaces a file at `destinationURL`, even one that
        /// appeared during the render: the export throws
        /// `SafeFileWriter.DestinationExists` instead.
        public var replacesExisting: Bool
        /// Title, caption, creator and copyright from the catalog; written
        /// only with `includeMetadata`.
        public var descriptive = ExportDescription()
        /// Image sizing (ExportSizing.swift). When set it decides the long
        /// edge, and `maxLongEdge` is ignored; nil keeps `maxLongEdge`.
        public var sizing: ExportSizing?
        /// JPEG Limit File Size: the largest file allowed, in bytes. The
        /// quality is lowered until the file fits. Nil, no limit.
        public var sizeLimitBytes: Int?
        /// How much metadata the file carries (ExportMetadataLevel.swift),
        /// when `includeMetadata` is on.
        public var metadataLevel: ExportMetadataLevel = .all

        public init(sourceURL: URL, destinationURL: URL, editStackJSON: String?, userRotation: Int,
                    settings: ExportSettings, colorSpace: ColorKit.OutputSpace, maxLongEdge: Int?,
                    keywords: [String] = [], rating: Int = 0, includeMetadata: Bool = true,
                    includeLocation: Bool = false, replacesExisting: Bool = true) {
            self.sourceURL = sourceURL; self.destinationURL = destinationURL
            self.editStackJSON = editStackJSON; self.userRotation = userRotation
            self.settings = settings; self.colorSpace = colorSpace; self.maxLongEdge = maxLongEdge
            self.keywords = keywords; self.rating = rating; self.includeMetadata = includeMetadata
            self.includeLocation = includeLocation; self.replacesExisting = replacesExisting
        }
    }

    public struct Outcome: Sendable, CustomStringConvertible {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let seconds: TimeInterval
        public let masksGenerated: Int
        /// Display names of the models that stood in for ones the edit
        /// names but this Mac lacks (docs/Retouch.md §5); empty when every
        /// mask was made with its own model.
        public let maskSubstitutions: [String]
        /// Where the time went, in seconds: "unpack", "masks", "render", "pack", "write".
        public let phases: [(String, TimeInterval)]

        public var description: String {
            let parts = phases.map { String(format: "%@ %.0f ms", $0.0, $0.1 * 1000) }
            return String(format: "%dx%d in %.0f ms (%@)", pixelWidth, pixelHeight, seconds * 1000,
                          parts.joined(separator: ", "))
        }
    }

    /// An export's pixels and metadata, ready to encode: everything
    /// `export` does before the file is written.
    ///
    /// `@unchecked Sendable`: immutable once made (see
    /// `Exporter.EncodableImage`).
    public struct Rendered: @unchecked Sendable {
        /// The file's pixels, watermark included, and any gain map.
        public let image: Exporter.EncodableImage
        /// What the file would carry besides pixels; nil when metadata is off.
        public let metadata: ExportMetadata?
        /// The request's settings with the watermark's tokens filled in.
        public let settings: ExportSettings
        public let masksGenerated: Int
        /// As `Outcome.maskSubstitutions`.
        public let maskSubstitutions: [String]
        public let phases: [(String, TimeInterval)]
        let start: Date
        /// What `finished` needs: the space the pixels are in, the source's
        /// name for the watermark's tokens, and the metadata as read,
        /// whether or not the file carries it.
        let colorSpace: ColorKit.OutputSpace
        let sourceName: String
        let readMetadata: ExportMetadata

        init(image: Exporter.EncodableImage, metadata: ExportMetadata?, settings: ExportSettings, masksGenerated: Int,
             maskSubstitutions: [String] = [], phases: [(String, TimeInterval)], start: Date,
             colorSpace: ColorKit.OutputSpace, sourceName: String, readMetadata: ExportMetadata) {
            self.image = image
            self.metadata = metadata
            self.settings = settings
            self.masksGenerated = masksGenerated
            self.maskSubstitutions = maskSubstitutions
            self.phases = phases
            self.start = start
            self.colorSpace = colorSpace
            self.sourceName = sourceName
            self.readMetadata = readMetadata
        }

        public var pixelWidth: Int { image.image.width }
        public var pixelHeight: Int { image.image.height }

        /// The file these pixels make at `settings` (another quality, say),
        /// in memory.
        public func encoded(with settings: ExportSettings) throws -> Data {
            try Exporter.encode(image, settings: settings, metadata: metadata)
        }

        /// This render as it would have come out with `watermark` (tokens
        /// not yet filled in) and these metadata switches, from one made
        /// without a watermark and with metadata on. The export sheet
        /// renders once that way and tries its settings on copies, since
        /// neither changes what the GPU renders.
        public func finished(watermark: ExportWatermark?, includeMetadata: Bool,
                             includeLocation: Bool, metadataLevel: ExportMetadataLevel? = nil) throws -> Rendered {
            var settings = self.settings
            settings.watermark = watermark?.resolved(fileName: sourceName,
                                                     captureDate: readMetadata.captureDate ?? Date())
            if settings.watermark?.isEmpty == true { settings.watermark = nil }
            var carried = readMetadata
            if let metadataLevel { carried.level = metadataLevel }
            carried.includeLocation = includeLocation && carried.level.allowsLocation
            return Rendered(image: try image.watermarked(settings.watermark, colorSpace: colorSpace),
                            metadata: includeMetadata ? carried : nil, settings: settings,
                            masksGenerated: masksGenerated, maskSubstitutions: maskSubstitutions, phases: phases,
                            start: start, colorSpace: colorSpace, sourceName: sourceName, readMetadata: readMetadata)
        }
    }

    public static func export(_ request: Request, gpu: GPUContext) async throws -> Outcome {
        let rendered = try await render(request, gpu: gpu)
        let mark = Date()
        if let limit = request.sizeLimitBytes, limit > 0, rendered.settings.format.supportsQuality {
            // Limit File Size: encoded in memory at falling qualities until
            // it fits, then written as any other file is.
            let fitted = try Exporter.encode(rendered.image, settings: rendered.settings, metadata: rendered.metadata,
                                             limitedTo: limit)
            try Exporter.write(data: fitted.data, to: request.destinationURL,
                               replacingExisting: request.replacesExisting)
        } else {
            try Exporter.write(cgImage: rendered.image.image, to: request.destinationURL, settings: rendered.settings,
                               metadata: rendered.metadata, gainMap: rendered.image.gainMap,
                               replacingExisting: request.replacesExisting)
        }
        let phases = rendered.phases + [("write", Date().timeIntervalSince(mark))]
        return Outcome(pixelWidth: rendered.pixelWidth, pixelHeight: rendered.pixelHeight,
                       seconds: Date().timeIntervalSince(rendered.start), masksGenerated: rendered.masksGenerated,
                       maskSubstitutions: rendered.maskSubstitutions, phases: phases)
    }

    /// The export's pixels and metadata without writing a file; the request's
    /// destination is not used. The export sheet encodes the result at
    /// several settings to estimate sizes and compare qualities, so what it
    /// shows is what the export writes.
    ///
    /// Stops between phases when its task is cancelled (the queue's tasks
    /// never are, so a started file is always finished).
    public static func render(_ request: Request, gpu: GPUContext) async throws -> Rendered {
        let start = Date()
        var phases: [(String, TimeInterval)] = []
        var mark = Date()
        func lap(_ name: String) { phases.append((name, Date().timeIntervalSince(mark))); mark = Date() }

        let file = try RawFile(path: request.sourceURL.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        lap("unpack")
        try Task.checkCancellation()

        // The edit, over this image's defaults — exactly as the editor
        // would reconstruct it.
        // A converted colour space (Adobe RGB, ProPhoto, an ICC profile) is
        // rendered in Rec. 2020 and converted by the exporter.
        let renderSpace = request.settings.colorProfile?.renderSpace ?? request.colorSpace
        let parameters: EditParameters
        do {
            parameters = try ExportPlan.parameters(editStackJSON: request.editStackJSON, session: session,
                                                   colorSpace: renderSpace)
        } catch {
            throw ExportWorkerError.unreadableEdit(error)
        }

        // Model-generated masks are not stored; make them again.
        let rotation = ExportPlan.rotation(for: file.summary, userRotation: request.userRotation)
        // Image sizing comes down to a long edge, which needs the crop.
        var maxLongEdge = request.maxLongEdge
        var enlarges = false
        if let sizing = request.sizing {
            (maxLongEdge, enlarges) = ExportPlan.target(for: sizing, rawWidth: file.summary.rawWidth,
                                                        rawHeight: file.summary.rawHeight, crop: parameters.crop,
                                                        rotation: rotation)
        }
        let masks = try await regenerateMasks(parameters.locals, session: session, pipeline: pipeline, gpu: gpu,
                                              rotation: rotation, geometry: parameters)
        // Nor are the touch-up region masks: built again the way the
        // editor built them, so the export smooths the same skin.
        try regenerateTouchUpMasks(parameters, session: session, pipeline: pipeline, gpu: gpu, rotation: rotation,
                                   name: request.sourceURL.lastPathComponent, logger: exportLogger)
        // And Lens Blur's depth map (LensBlurDepth.swift).
        let depthStandIn = try await regenerateDepth(parameters, session: session, pipeline: pipeline, gpu: gpu,
                                                     rotation: rotation, name: request.sourceURL.lastPathComponent)
        try await regenerateReflections(parameters, session: session, pipeline: pipeline, gpu: gpu,
                                        rotation: rotation, name: request.sourceURL.lastPathComponent)
        lap("masks")
        try Task.checkCancellation()

        // Neural denoise is computed, not stored: run it for the export.
        // Not for linear sources, which the denoiser refuses; the pipeline
        // doesn't blend a strength in for them either.
        if parameters.aiDenoise > 0, session.supportsAIDenoise, AIDenoiser.isAvailable {
            // Shared across the batch: loading the network per image cost
            // seconds each.
            let denoiser = try await AIDenoiser.shared()
            try await AIDenoiseWorker.run(session: session, pipeline: pipeline, gpu: gpu, denoiser: denoiser)
            lap("denoise")
            try Task.checkCancellation()
        }

        let scale = ExportPlan.scale(for: file.summary, crop: parameters.crop, maxLongEdge: maxLongEdge)
        let texture = try pipeline.render(session, scale: scale,
                                          parameters: parameters, output: .file(renderSpace))
        lap("render")
        try Task.checkCancellation()

        let s = file.summary
        var metadata = ExportMetadata()
        metadata.cameraMake = s.cameraMake.isEmpty ? nil : s.cameraMake
        metadata.cameraModel = s.cameraModel.isEmpty ? nil : s.cameraModel
        metadata.lensModel = session.lensCorrection(for: parameters)?.profileName ?? (s.lensModel.isEmpty ? nil : s.lensModel)
        metadata.iso = s.iso > 0 ? Int(s.iso) : nil
        metadata.shutter = s.shutter > 0 ? s.shutter : nil
        metadata.aperture = s.aperture > 0 ? s.aperture : nil
        metadata.focalLength = s.focalLength > 0 ? s.focalLength : nil
        metadata.captureDate = s.captureTime.timeIntervalSince1970 > 0 ? s.captureTime : nil
        metadata.level = request.metadataLevel
        metadata.keywords = request.metadataLevel.includesKeywordsAndRating ? request.keywords : []
        metadata.descriptive = request.descriptive.limited(to: request.metadataLevel)
        metadata.rating = request.metadataLevel.includesKeywordsAndRating ? request.rating : 0
        metadata.includeLocation = request.includeLocation && request.metadataLevel.allowsLocation
        if request.includeMetadata {
            // GPS, copyright, exposure details and the rest, read from the
            // raw in the decoder service. A file it can't read still gets
            // the summary fields above rather than failing the export.
            do {
                metadata.source = try SourceMetadata(path: request.sourceURL.path)
            } catch {
                exportLogger.error("source metadata unavailable for \(request.sourceURL.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .private)")
            }
        }

        // The watermark's tokens, for this image: its capture year (today's
        // when the raw has none) and its name.
        var settings = request.settings
        settings.enlarges = enlarges
        settings.watermark = request.settings.watermark?.resolved(
            fileName: request.sourceURL.deletingPathExtension().lastPathComponent,
            captureDate: metadata.captureDate ?? Date())
        if settings.watermark?.isEmpty == true { settings.watermark = nil }
        // A JPEG or TIFF holds nothing above SDR white for a gain map to
        // describe; one rendered with headroom would invent highlights.
        if session.isRenderedImage { settings.hdrGainMap = false }

        // Rotation, the final resize and the quantisation to 8 or 16 bits
        // all happen on the GPU inside the exporter; the CPU only reads the
        // bytes back, stamps the watermark into them and hands them on. A
        // gain map needs the edit rendered a second time with HDR headroom,
        // which the exporter asks for when it's ready.
        let image = try Exporter(gpu: gpu).encodableImage(
            texture, settings: settings, colorSpace: renderSpace, rotation: rotation,
            crop: parameters.crop, maxLongEdge: maxLongEdge, hdrHeadroom: parameters.hdrHeadroom,
            hdrRender: { output in
                try pipeline.render(session, scale: scale, parameters: parameters, output: output)
            })
        lap("pack")
        return Rendered(image: image, metadata: request.includeMetadata ? metadata : nil, settings: settings,
                        masksGenerated: masks.count, maskSubstitutions: masks.substituted + (depthStandIn.map { [$0] } ?? []),
                        phases: phases,
                        start: start, colorSpace: renderSpace,
                        sourceName: request.sourceURL.deletingPathExtension().lastPathComponent,
                        readMetadata: metadata)
    }

    /// What a model mask is made from, here and in the editor: the
    /// image's defaults (`defaults`, no locals) with the lens and keystone
    /// settings of the edit (`geometry`). A mask is sampled on the output
    /// grid those settings define, so it must be made on it; the look
    /// stays the camera's, so a mask never depends on the edits it drives.
    public static func modelMaskInputParameters(defaults: EditParameters, geometry: EditParameters) -> EditParameters {
        var p = defaults
        p.locals = []
        p.lensDistortion = geometry.lensDistortion
        p.lensTCA = geometry.lensTCA
        p.manualDistortion = geometry.manualDistortion
        p.perspective = geometry.perspective
        return p
    }

    /// Generates pixels for every AI and prompted local, the same way the
    /// editor does: from a ~1000px unrotated sRGB render of the defaults
    /// with the edit's geometry (`modelMaskInputParameters`).
    /// Each local runs the model its stored `modelVersion` names, resolved
    /// through the registry; `rotation` (the turn that makes the render
    /// upright) is passed to the subject models, which need it.
    /// `substituted` names the models the edit asked for that this Mac
    /// lacks, once each, in the order met (docs/Retouch.md §5).
    static func regenerateMasks(_ locals: [LocalAdjustment], session: ImageSession,
                                pipeline: RenderPipeline, gpu: GPUContext, rotation: ImageRotation = .none,
                                geometry: EditParameters? = nil,
                                registry: ModelRegistry = .shared) async throws -> (count: Int, substituted: [String]) {
        // Every model mask: a local's own shape and its shape components.
        let needed = locals.flatMap(\.modelElements)
        guard !needed.isEmpty else { return (0, []) }
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        let input = modelMaskInputParameters(defaults: defaults, geometry: geometry ?? defaults)
        let longEdge = max(session.file.summary.rawWidth, session.file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / 2048.0).rounded(.up)))
        let tex = try pipeline.render(session, scale: .binned(quads: quads), parameters: input,
                                      output: .file(.sRGB))
        let image = try Exporter(gpu: gpu).cgImage(from: tex, colorSpace: .sRGB)

        // One encoded image per click-to-select model the edit uses.
        var sessions: [String: SAM2Session] = [:]
        var count = 0
        var substituted: [String] = []
        func note(_ name: String) { if !substituted.contains(name) { substituted.append(name) } }
        for local in needed {
            // `local` is a mask element: its id keys the pixels.
            switch local.shape {
            case .ai(let kindName, let modelVersion):
                guard let kind = AIMaskKind(storedName: kindName) else { continue }
                let result = try await AIMaskGenerator.generate(kind, modelVersion: modelVersion, from: image,
                                                                rotation: rotation, registry: registry)
                session.setAIMask(result.mask, forLocal: local.id)
                count += 1
                if let name = result.substitutedModel { note(name) }
            case .prompted(let points, let modelVersion):
                guard !points.isEmpty else { continue }
                // The model named, else the bundled one, reported; with
                // neither the local masks nothing.
                let named = registry.installed(ModelRef(stored: modelVersion))
                    .flatMap { $0.manifest.kind == .promptedSegmentation ? $0 : nil }
                var chosen = named
                var models: SAM2Models?
                if let named { models = await registry.prompted(id: named.id) }
                if models == nil {
                    note(AIMaskGenerator.displayName(forMissing: modelVersion, registry: registry))
                    chosen = registry.defaultPrompted()
                    if let fallback = chosen, fallback.id != named?.id {
                        models = await registry.prompted(id: fallback.id)
                    }
                }
                guard let chosen, let models else {
                    exportLogger.error("no click-to-select model for a mask: it is empty")
                    continue
                }
                let sam: SAM2Session
                if let existing = sessions[chosen.id] {
                    sam = existing
                } else {
                    sam = try SAM2Session(models: models, image: image)
                    sessions[chosen.id] = sam
                }
                let prediction = try sam.predict(points: points.map(PromptPoint.init))
                session.setAIMask(prediction.mask, forLocal: local.id)
                count += 1
            default:
                continue
            }
        }
        return (count, substituted)
    }

    /// The touch-up region masks the edit's faces need, built from the
    /// analysis render and a seeded refit exactly as the editor builds
    /// them (`TouchUpRegions.regenerate`; docs/Retouch.md §9). Nothing
    /// happens for an edit without an enabled face and a slider. A face
    /// Vision cannot find again keeps its box and smooths nothing; the
    /// export has nowhere to say so, so the log keeps the fact.
    static func regenerateTouchUpMasks(_ parameters: EditParameters, session: ImageSession, pipeline: RenderPipeline,
                                       gpu: GPUContext, rotation: ImageRotation, name: String, logger: Logger) throws {
        guard parameters.touchUp.wantsMasks else { return }
        let missing = try TouchUpRegions.regenerate(parameters.touchUp, session: session, pipeline: pipeline, gpu: gpu,
                                                    parameters: parameters, rotation: rotation)
        for id in missing {
            let number = (parameters.touchUp.faces.firstIndex { $0.id == id } ?? 0) + 1
            logger.notice("\(name, privacy: .private): face \(number) could not be found again, so it is not retouched")
        }
    }
}
