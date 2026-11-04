import CoreGraphics
import Foundation
import PixelEngine
import MLKit

/// What the editor knows about Distraction Removal › Reflections beyond
/// the edit: the gain map's job, which model made it, and whether one is
/// installed at all. Its own object, like LensBlurState, so the editor
/// gains one stored property.
@MainActor
final class ReflectionState: ObservableObject {
    /// "Removing reflections…", what made the map, or why it failed.
    @Published var status = ""
    @Published var building = false
    /// What made the session's gain map; nil until one is made.
    @Published var source: String?
    /// Whether a reflection-removal model is installed, read on open and
    /// whenever the panel appears (after Settings may have added one).
    @Published var modelAvailable = false

    var task: Task<Void, Never>?
    /// The lens and keystone settings the map was made on.
    var geometryKey: String?
    var geometryTask: Task<Void, Never>?
    var sessionID: ObjectIdentifier?
}

/// Maps already made, by photo, geometry and model, so going back to a
/// photo doesn't run the model again. A handful only: each is a model's
/// output, a megabyte or so.
@MainActor
enum ReflectionMapCache {
    static let capacity = 6
    private static var entries: [(key: String, map: ReflectionMap)] = []

    static func map(for key: String) -> ReflectionMap? {
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let hit = entries.remove(at: i)
        entries.append(hit)
        return hit.map
    }

    static func store(_ map: ReflectionMap, for key: String) {
        entries.removeAll { $0.key == key }
        entries.append((key, map))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    static func removeAll() { entries = [] }
}

// Reflections in the editor (docs/wiki/Develop.md, "Reflections"). The
// gain map is derived, never stored, exactly as Lens Blur's depth map:
// made from the analysis render on a detached task, applied only if the
// same image is still open on the same lens and keystone grid, and made
// again after a geometry change. Without a model nothing is made and the
// panel says how to add one.
extension EditorModel {
    private func reflectionStateForSession() -> ReflectionState? {
        guard let session else { return nil }
        let state = reflectionState
        let id = ObjectIdentifier(session)
        if state.sessionID != id {
            state.task?.cancel()
            state.task = nil
            state.geometryTask?.cancel()
            state.geometryTask = nil
            state.sessionID = id
            state.geometryKey = nil
            state.source = nil
            state.building = false
            state.status = ""
            state.modelAvailable = ReflectionRemovalMaker.isAvailable()
        }
        return state
    }

    /// The cache key for the open photo's map, or nil for an image outside
    /// the catalogue (made again each time it opens).
    private func reflectionCacheKey(source: String) -> String? {
        guard let catalogImageID else { return nil }
        return "\(catalogImageID)|\(Self.touchUpGeometryKey(of: parameters))|\(source)"
    }

    /// Called from `parameters`' didSet with the previous value.
    func reflectionParametersDidChange(from old: EditParameters) {
        guard hasImage, let session, let state = reflectionStateForSession() else { return }
        let removal = parameters.reflections
        guard removal.isActive else { return }
        if !session.hasReflectionMap {
            if state.task == nil { buildReflectionMap() }
            return
        }
        if removal.model != old.reflections.model, let wanted = removal.model, wanted != state.source {
            buildReflectionMap()
            return
        }
        let key = Self.touchUpGeometryKey(of: parameters)
        guard key != Self.touchUpGeometryKey(of: old) else { return }
        state.geometryTask?.cancel()
        state.geometryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.touchUpGeometryDebounce)
            guard let self, !Task.isCancelled else { return }
            self.reflectionState.geometryTask = nil
            if Self.touchUpGeometryKey(of: self.parameters) != self.reflectionState.geometryKey {
                self.buildReflectionMap()
            }
        }
    }

    /// On open: an edit with reflections removed needs its map.
    func regenerateReflectionMapIfNeeded() {
        guard hasImage, let session, let state = reflectionStateForSession() else { return }
        guard parameters.reflections.isActive, !session.hasReflectionMap, state.task == nil else { return }
        buildReflectionMap()
    }

    /// Reads the registry again (the panel calls this as it appears, so a
    /// model added in Settings is picked up) and makes the map if the edit
    /// wanted one that couldn't be made before.
    func refreshReflectionModelAvailability() {
        guard let state = reflectionStateForSession() else { return }
        state.modelAvailable = ReflectionRemovalMaker.isAvailable()
        if state.modelAvailable { regenerateReflectionMapIfNeeded() }
    }

    /// Makes the gain map for the open image with the model the edit names
    /// (or the installed one in its place) and puts it on the session.
    func buildReflectionMap() {
        guard let session, let pipeline, let gpu = gpuContext, let state = reflectionStateForSession() else { return }
        state.task?.cancel()
        state.task = nil
        state.modelAvailable = ReflectionRemovalMaker.isAvailable()
        guard state.modelAvailable else {
            session.setReflectionMap(nil)
            state.building = false
            state.status = Self.reflectionNoModelMessage
            return
        }
        let key = Self.touchUpGeometryKey(of: parameters)
        let stored = parameters.reflections.model
        let wanted = stored ?? ReflectionRemovalMaker.defaultSource()
        if let wanted, let cacheKey = reflectionCacheKey(source: wanted), let cached = ReflectionMapCache.map(for: cacheKey) {
            session.setReflectionMap(cached)
            state.geometryKey = key
            state.source = cached.source
            state.status = "Reflections removed with \(ReflectionRemovalMaker.displayName(of: cached.source))."
            rerender()
            return
        }
        let image: CGImage
        do {
            image = try ExportWorker.depthInputImage(session: session, pipeline: pipeline, gpu: gpu,
                                                     defaults: defaultParameters, geometry: parameters)
        } catch {
            state.status = "Reflections could not be removed: \(error)"
            return
        }
        let input = SendableImage(cgImage: image)
        let rotation = self.rotation
        state.building = true
        state.status = "Removing reflections…"
        let builder = Self.reflectionBuilder
        state.task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await builder(input, rotation, stored)
            }.value
            guard let self, !Task.isCancelled, self.session === session else { return }
            let state = self.reflectionState
            state.task = nil
            state.building = false
            switch result {
            case .failure(let error):
                state.status = "Reflections could not be removed: \(error)"
                self.status = state.status
            case .success(nil):
                session.setReflectionMap(nil)
                state.status = Self.reflectionNoModelMessage
            case .success(let made?):
                guard Self.touchUpGeometryKey(of: self.parameters) == key else {
                    self.buildReflectionMap()
                    return
                }
                session.setReflectionMap(made.map)
                if let cacheKey = self.reflectionCacheKey(source: made.map.source) {
                    ReflectionMapCache.store(made.map, for: cacheKey)
                }
                state.geometryKey = key
                state.source = made.map.source
                let name = ReflectionRemovalMaker.displayName(of: made.map.source)
                state.status = made.substitutedModel.map { "Reflections removed with \(name), because \($0) is not installed." }
                    ?? "Reflections removed with \(name)."
                Announcement.post(state.status)
                self.rerender()
            }
        }
    }

    static let reflectionNoModelMessage = "Reflection removal needs a model. Convert one with "
        + "scripts/convert_reflection_removal.py, then add it in Settings › AI › Models."

    /// The builder, replaceable so tests can stand a drawn map in for a model.
    typealias ReflectionBuilder = @Sendable (SendableImage, ImageRotation, String?) async
        -> Result<ReflectionRemovalMaker.Result?, Error>

    static let liveReflectionBuilder: ReflectionBuilder = { image, rotation, stored in
        do {
            return .success(try await ReflectionRemovalMaker.make(from: image.cgImage, rotation: rotation, stored: stored))
        } catch {
            return .failure(error)
        }
    }

    static var reflectionBuilder: ReflectionBuilder = liveReflectionBuilder

    /// The Amount slider: the first move off zero also records the model.
    func setReflectionAmount(_ amount: Float) {
        var removal = parameters.reflections
        removal.amount = amount.isFinite ? min(max(amount, 0), 100) : 0
        if removal.isActive, removal.model == nil {
            removal.model = reflectionState.source ?? ReflectionRemovalMaker.defaultSource()
        }
        parameters.reflections = removal
    }
}
