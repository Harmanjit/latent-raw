import Foundation
import CoreGraphics
import PixelEngine
import os

private let reflectionLogger = Logger(subsystem: "com.latent.app", category: "reflections")

/// The gain map Distraction Removal › Reflections applies, made the same
/// way in the editor and in every export (docs/wiki/Develop.md,
/// "Reflections"). Only ever from a reflection-removal model the user
/// added: without one there is no map and the stage does nothing.
public enum ReflectionRemovalMaker {
    public struct Result: Sendable {
        public let map: ReflectionMap
        /// The display name of the model the edit names but this Mac
        /// lacks, when another installed one stood in; nil otherwise.
        public let substitutedModel: String?
        public let seconds: TimeInterval

        public init(map: ReflectionMap, substitutedModel: String?, seconds: TimeInterval) {
            self.map = map
            self.substitutedModel = substitutedModel
            self.seconds = seconds
        }
    }

    /// Whether any reflection-removal model is installed: the panel's
    /// slider is live only then.
    public static func isAvailable(registry: ModelRegistry = .shared) -> Bool {
        registry.defaultReflectionRemoval() != nil
    }

    /// The model a NEW amount records, or nil with none installed.
    public static func defaultSource(registry: ModelRegistry = .shared) -> String? {
        registry.defaultReflectionRemoval()?.modelVersion
    }

    public static func displayName(of source: String?, registry: ModelRegistry = .shared) -> String {
        guard let source else { return "no model" }
        guard let ref = ModelRef(stored: source) else { return source }
        return registry.entry(id: ref.id)?.manifest.displayName ?? ref.id
    }

    /// The model `stored` names when it is installed, else the default one
    /// (reported as standing in), else nil.
    static func model(for stored: String?, registry: ModelRegistry) -> (entry: ModelEntry, substituted: String?)? {
        let named = stored.flatMap(ModelRef.init(stored:))
        if let installed = registry.installed(named), installed.manifest.kind == .reflectionRemoval {
            return (installed, nil)
        }
        guard let fallback = registry.defaultReflectionRemoval() else { return nil }
        let substituted = (stored != nil && named != nil && fallback.id != named?.id)
            ? displayName(of: stored, registry: registry) : nil
        return (fallback, substituted)
    }

    /// The gain map of `image` (sensor orientation; `rotation` makes it
    /// upright) from the model `stored` names, or the installed one in its
    /// place. Nil when no reflection model is installed or it won't load
    /// (logged by the registry): nothing is faked.
    public static func make(from image: CGImage, rotation: ImageRotation = .none, stored: String?,
                            registry: ModelRegistry = .shared) async throws -> Result? {
        let start = Date()
        guard let chosen = model(for: stored, registry: registry),
              let remover = await registry.reflectionRemover(id: chosen.entry.id) else { return nil }
        let map = try remover.gainMap(for: image, rotation: rotation)
        return Result(map: map, substitutedModel: chosen.substituted, seconds: Date().timeIntervalSince(start))
    }
}

extension ExportWorker {
    /// The gain map an active Reflections amount needs, made from the
    /// analysis render the depth map uses and set on the session. Nothing
    /// happens while the amount is 0; with no model installed the session
    /// gets no map and the export goes out without the correction, which
    /// is logged.
    static func regenerateReflections(_ parameters: EditParameters, session: ImageSession, pipeline: RenderPipeline,
                                      gpu: GPUContext, rotation: ImageRotation, name: String,
                                      registry: ModelRegistry = .shared) async throws {
        guard parameters.reflections.isActive else { return }
        let image = try depthInputImage(session: session, pipeline: pipeline, gpu: gpu, geometry: parameters)
        guard let result = try await ReflectionRemovalMaker.make(from: image, rotation: rotation,
                                                                 stored: parameters.reflections.model,
                                                                 registry: registry) else {
            session.setReflectionMap(nil)
            reflectionLogger.notice("\(name, privacy: .private): no reflection removal model is installed, so the export has no reflection removal")
            return
        }
        session.setReflectionMap(result.map)
        if let missing = result.substitutedModel {
            reflectionLogger.notice("\(name, privacy: .private): \(missing, privacy: .public) is not installed, so reflections were removed with \(ReflectionRemovalMaker.displayName(of: result.map.source, registry: registry), privacy: .public)")
        }
    }
}
