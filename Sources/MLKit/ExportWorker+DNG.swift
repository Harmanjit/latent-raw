import Foundation
import CoreGraphics
import Metal
import RawCore
import PixelEngine
import ColorKit
import os

private let dngLogger = Logger(subsystem: "com.latent.app", category: "export")

/// What a DNG export puts in the file.
public enum DNGExportContent: String, Codable, CaseIterable, Sendable {
    /// The scene-referred part of the edit baked in, the look left for the
    /// DNG's own edit (`ExportPlan.sceneReferred`). What DNG export always did.
    case sceneReferred
    /// The whole edit baked in, under the inverse of the default tone
    /// curve, so the DNG opens in Latent looking like the edit
    /// (`RenderedDNGExport.BakedLook`).
    case fullLook
    /// The original as a DNG, unedited: a DNG original is copied byte for
    /// byte; any other raw is demosaiced and written as a linear DNG at
    /// the defaults. Not a mosaic-preserving conversion.
    case original

    public var title: String {
        switch self {
        case .sceneReferred: "Edits baked in, look editable"
        case .fullLook: "Full look baked in"
        case .original: "Original raw as DNG"
        }
    }

    /// Whether `url` is already a DNG, which `.original` copies as it is.
    public static func isDNG(_ url: URL) -> Bool { url.pathExtension.lowercased() == "dng" }
}

extension ExportWorker {
    /// A photo rendered for DNG export (Render to DNG): its scene-referred
    /// edit baked into linear Rec. 2020 light, cropped and upright
    /// (`ExportPlan.sceneReferred`), and a preview of how the DNG opens.
    ///
    /// `@unchecked Sendable`: the texture is finished and only read after
    /// this is made; the summary and preview are immutable.
    public struct SceneLinearRender: @unchecked Sendable {
        /// rgba16Float, private storage, full size.
        public let texture: MTLTexture
        public let summary: RawSummary
        /// The DNG as it will open (its look reset to the defaults), sRGB,
        /// for the file's preview and thumbnail.
        public let preview: CGImage
        public let maskSubstitutions: [String]
        /// The lens as the raw named it, matched profile or not.
        public let lensModel: String?
        /// The raw's colour matrix (`RawFile.cameraToXYZMatrixRaw`).
        public let cameraToXYZ: [Float]?
    }

    /// The longest edge of a DNG's preview image.
    public static let dngPreviewLongEdge = 1600

    /// Opens the raw, rebuilds its edit over the defaults (masks and AI
    /// denoise as an export makes them), and renders the scene-referred
    /// part at full size into scene-linear light.
    ///
    /// `content` `.fullLook` renders the whole edit into display-referred
    /// linear Rec. 2020 instead (SDR white at 1, for
    /// `RenderedDNGExport.BakedLook`), with its preview the edit as it
    /// looks; `.original` renders the defaults, uncropped, ignoring the edit.
    public static func renderSceneLinear(sourceURL: URL, editStackJSON: String?, userRotation: Int,
                                         gpu: GPUContext,
                                         content: DNGExportContent = .sceneReferred) async throws -> SceneLinearRender {
        let file = try RawFile(path: sourceURL.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        try Task.checkCancellation()
        let edit: EditParameters
        do {
            edit = try ExportPlan.parameters(editStackJSON: content == .original ? nil : editStackJSON,
                                             session: session, colorSpace: .rec2020)
        } catch {
            throw ExportWorkerError.unreadableEdit(error)
        }
        // A flat-field correction needs its reference's gain map on this Mac.
        FlatFieldCache.shared.ensureGainMap(for: edit.flatField, photo: sourceURL, gpu: gpu)
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        defaults.outputSpace = .rec2020
        let parameters = content == .fullLook ? edit : ExportPlan.sceneReferred(edit, defaults: defaults)

        let rotation = ExportPlan.rotation(for: file.summary, userRotation: content == .original ? 0 : userRotation)
        let masks = try await regenerateMasks(parameters.locals, session: session, pipeline: pipeline, gpu: gpu,
                                              rotation: rotation, geometry: parameters)
        if !masks.substituted.isEmpty {
            dngLogger.notice("\(sourceURL.lastPathComponent, privacy: .private): DNG masks made without \(masks.substituted.joined(separator: ", "), privacy: .public)")
        }
        var substituted = masks.substituted
        if content == .fullLook {
            // The look's own masks, as an image export makes them.
            try regenerateTouchUpMasks(parameters, session: session, pipeline: pipeline, gpu: gpu, rotation: rotation,
                                       name: sourceURL.lastPathComponent, logger: dngLogger)
            if let standIn = try await regenerateDepth(parameters, session: session, pipeline: pipeline, gpu: gpu,
                                                       rotation: rotation, name: sourceURL.lastPathComponent) {
                substituted.append(standIn)
            }
        }
        try Task.checkCancellation()
        if parameters.aiDenoise > 0, session.supportsAIDenoise, AIDenoiser.isAvailable {
            let denoiser = try await AIDenoiser.shared()
            try await AIDenoiseWorker.run(session: session, pipeline: pipeline, gpu: gpu, denoiser: denoiser)
            try Task.checkCancellation()
        }

        let exporter = Exporter(gpu: gpu)
        // Copied out of the pipeline's pool before the preview render,
        // which would reuse the same output texture.
        let linear = try pipeline.render(session, scale: .full, parameters: parameters,
                                         output: content == .fullLook ? .hdrFile(.rec2020, headroom: 1) : .sceneLinear)
        let texture = try exporter.sceneLinearTexture(from: linear, rotation: rotation, crop: parameters.crop)

        // The preview: the baked part with this build's default look, which
        // is how the DNG opens; with the full look baked in, the edit itself.
        var look = parameters
        look.outputSpace = .sRGB
        if content != .fullLook {
            look.contrast = defaults.contrast
            look.greyPoint = defaults.greyPoint
        }
        let previewScale = ExportPlan.scale(for: file.summary, crop: parameters.crop, maxLongEdge: dngPreviewLongEdge)
        let display = try pipeline.render(session, scale: previewScale, parameters: look, output: .file(.sRGB))
        let preview = try exporter.cgImage(from: display, colorSpace: .sRGB, rotation: rotation, crop: parameters.crop,
                                           maxLongEdge: dngPreviewLongEdge)
        let s = file.summary
        return SceneLinearRender(texture: texture, summary: s, preview: preview,
                                 maskSubstitutions: substituted,
                                 lensModel: session.lensCorrection?.profileName ?? (s.lensModel.isEmpty ? nil : s.lensModel),
                                 cameraToXYZ: file.cameraToXYZMatrixRaw)
    }
}
