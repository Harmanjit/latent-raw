import Foundation
import CoreGraphics
import PixelEngine
import os

private let depthLogger = Logger(subsystem: "com.latent.app", category: "lensblur")

/// The depth map Lens Blur reads, made the same way in the editor and in
/// every export (docs/wiki/Develop.md, "Lens Blur").
///
/// With a depth model installed (Settings › AI › Models; none is bundled,
/// see scripts/convert_depth_anything.py) the map is the model's relative
/// depth, its edges snapped to the picture's by the guided filter the
/// subject masks use. Without one it is two planes: the subject, from the
/// subject model Settings picks, near; everything else far. That keeps
/// the feature working on every Mac, at the cost of a background that is
/// all one distance.
public enum LensBlurDepth {
    public struct Result: Sendable {
        public let depth: DepthMap
        /// The display name of the depth model the edit names but this Mac
        /// lacks, when another source stood in; nil otherwise.
        public let substitutedModel: String?
        public let seconds: TimeInterval

        public init(depth: DepthMap, substitutedModel: String?, seconds: TimeInterval) {
            self.depth = depth
            self.substitutedModel = substitutedModel
            self.seconds = seconds
        }
    }

    /// The source a NEW blur records: the installed depth model, else the
    /// two planes from the subject mask.
    public static func defaultSource(registry: ModelRegistry = .shared) -> String {
        registry.defaultDepth()?.modelVersion ?? LensBlur.subjectDepthVersion
    }

    /// A short name for the source, for the panel: "Depth Anything V2
    /// Small" or "Subject (two planes)".
    public static func displayName(of source: String?, registry: ModelRegistry = .shared) -> String {
        guard let source, source != LensBlur.subjectDepthVersion else { return "Subject (two planes)" }
        guard let ref = ModelRef(stored: source) else { return source }
        return registry.entry(id: ref.id)?.manifest.displayName ?? ref.id
    }

    /// The depth of `image` (sensor orientation; `rotation` makes it
    /// upright), from the source `stored` names: that depth model when it
    /// is installed; the two planes when it names them; otherwise the
    /// default source, reported as standing in for a missing model.
    public static func make(from image: CGImage, rotation: ImageRotation = .none, stored: String?,
                            registry: ModelRegistry = .shared) async throws -> Result {
        let start = Date()
        let named = stored.flatMap(ModelRef.init(stored:))
        var substituted: String?
        var entry: ModelEntry?
        if stored == LensBlur.subjectDepthVersion {
            entry = nil
        } else if let installed = registry.installed(named), installed.manifest.kind == .depth {
            entry = installed
        } else {
            entry = registry.defaultDepth()
            if let stored, named != nil, entry?.id != named?.id {
                substituted = displayName(of: stored, registry: registry)
            }
        }
        if let entry {
            if let model = await registry.depth(id: entry.id) {
                let raw = try model.estimate(image, rotation: rotation)
                let refined = refine(raw, guide: image)
                return Result(depth: DepthMap(bitmap: refined, source: entry.modelVersion), substitutedModel: substituted,
                              seconds: Date().timeIntervalSince(start))
            }
            // Installed but failed to load (logged by the registry): the
            // two planes stand in, and say so.
            substituted = entry.manifest.displayName
        }
        let subject = try await AIMaskGenerator.generate(.subject, modelVersion: registry.defaultSubject().modelVersion,
                                                         from: image, rotation: rotation, registry: registry)
        return Result(depth: DepthMap.twoPlane(fromSubject: subject.mask), substitutedModel: substituted,
                      seconds: Date().timeIntervalSince(start))
    }

    /// The model's coarse map snapped to the picture's edges: the guided
    /// filter at up to 1024 px on the long edge, where a hair's edge in
    /// the picture is still visible and the filter takes a few tens of
    /// milliseconds.
    static func refine(_ map: MaskBitmap, guide image: CGImage) -> MaskBitmap {
        let longEdge = max(image.width, image.height)
        let scale = min(1, 1024 / Double(max(longEdge, 1)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let guide = scaled(image, width: width, height: height) else { return map }
        return GuidedMaskRefiner.refine(map, guide: guide, radius: 6, epsilon: 2e-3)
    }

    private static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width, image.height == height { return image }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

extension ExportWorker {
    /// The depth map an active Lens Blur needs, made from the same
    /// analysis render the masks use (the defaults with the edit's lens
    /// and keystone settings, ~2000 px, unrotated) and set on the session.
    /// Nothing happens while the blur is off. Returns the stand-in's name
    /// when the edit's depth model is missing here, which is also logged.
    @discardableResult
    static func regenerateDepth(_ parameters: EditParameters, session: ImageSession, pipeline: RenderPipeline,
                                gpu: GPUContext, rotation: ImageRotation, name: String,
                                registry: ModelRegistry = .shared) async throws -> String? {
        guard parameters.lensBlur.isActive else { return nil }
        let image = try depthInputImage(session: session, pipeline: pipeline, gpu: gpu, geometry: parameters)
        let result = try await LensBlurDepth.make(from: image, rotation: rotation,
                                                  stored: parameters.lensBlur.depthModel, registry: registry)
        session.setDepthMap(result.depth)
        if let missing = result.substitutedModel {
            depthLogger.notice("\(name, privacy: .private): \(missing, privacy: .public) is not installed, so the lens blur's depth came from \(LensBlurDepth.displayName(of: result.depth.source, registry: registry), privacy: .public)")
        }
        return result.substitutedModel
    }

    /// The picture the depth is made from: as the model masks' (an sRGB
    /// render of the image's defaults on the edit's lens and keystone
    /// grid, about 2000 px on the long edge, unrotated), so the depth map
    /// lands on the grid the render samples it on.
    public static func depthInputImage(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                                       defaults: EditParameters? = nil, geometry: EditParameters) throws -> CGImage {
        var base = defaults ?? EditParameters()
        if defaults == nil { base.whiteBalance = session.asShotWhiteBalance }
        let input = modelMaskInputParameters(defaults: base, geometry: geometry)
        let longEdge = max(session.file.summary.rawWidth, session.file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / 2048.0).rounded(.up)))
        defer { session.releasePooledTextures(in: .analysis) }
        return try session.withTexturePool(.analysis) {
            let texture = try pipeline.render(session, scale: .binned(quads: quads), parameters: input,
                                              output: .file(.sRGB))
            return try Exporter(gpu: gpu).cgImage(from: texture, colorSpace: .sRGB)
        }
    }
}
