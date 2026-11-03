import Foundation
import CoreGraphics
import PixelEngine
import MLKit

/// What the Colour Range eyedropper reads: a scene-linear render of the
/// whole frame without the local adjustments, kept while nothing outside
/// the masks changes, so a run of clicks costs one render.
struct ColourSampleCache {
    var key: EditParameters
    var width: Int
    var height: Int
    var pixels: [Float16]
}

/// The kinds of component the Add, Subtract and Intersect menus offer.
enum MaskComponentKind {
    case brush, linear, radial, colourRange, luminanceRange
    case subject(ModelEntry)
    case aiClass(AIMaskKind)
    case clickToSelect(ModelEntry)
    case objects(ModelEntry)
}

extension EditorModel {
    // MARK: - The element the tools work on

    /// The selected local's own shape, or its selected component when
    /// that is a shape (a range has no shape for the tools to draw).
    var activeMaskElement: MaskElement? {
        guard let local = selectedLocal else { return nil }
        if let id = selectedMaskComponentID, let element = local.maskElements.first(where: { $0.id == id }) {
            return element
        }
        return local.maskElements.first
    }

    /// The selected component, if one is.
    var selectedMaskComponent: MaskComponent? {
        guard let local = selectedLocal, let id = selectedMaskComponentID else { return nil }
        return local.components.first { $0.id == id }
    }

    func setActiveMaskShape(_ shape: MaskShape) {
        guard let i = selectedLocalIndex, i < parameters.locals.count, let element = activeMaskElement else { return }
        parameters.locals[i].setShape(shape, ofElement: element.id)
    }

    // MARK: - New masks of the newer kinds

    /// A Colour Range mask: the whole image intersected with colours
    /// picked by the eyedropper, which is armed at once.
    func addColourRangeMask() {
        addRangeMask(name: "Colour Range", source: .colour(ColourRange()))
        maskTool = .colourSample
    }

    /// A Luminance Range mask: the whole image narrowed to a band of tones.
    func addLuminanceRangeMask() {
        addRangeMask(name: "Luminance Range", source: .luminance(LuminanceRange(low: 0.5, high: 1, feather: 0.1)))
    }

    private func addRangeMask(name: String, source: MaskComponentSource) {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        var local = LocalAdjustment(name: "\(name) \(parameters.locals.count + 1)", shape: .whole)
        let component = MaskComponent(mode: .intersect, source: source)
        local.components = [component]
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        selectedMaskComponentID = component.id
        showMaskOverlay = true
    }

    /// Select Objects: a click-to-select mask prompted by a dragged box.
    func addObjectsMask(model entry: ModelEntry) {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        addPromptedMask(model: entry)
        if let i = selectedLocalIndex { parameters.locals[i].name = "Object \(parameters.locals.count)" }
        maskTool = .box
    }

    // MARK: - Components

    var canAddMaskComponent: Bool {
        guard let local = selectedLocal else { return false }
        return local.components.count < MaskComponent.maximumPerMask
    }

    /// Adds a component to the selected local, selects it and arms the
    /// tool that places it; a model mask starts generating.
    func addMaskComponent(_ kind: MaskComponentKind, mode: MaskCombineMode) {
        guard let i = selectedLocalIndex, i < parameters.locals.count, canAddMaskComponent else { return }
        let source: MaskComponentSource
        var tool = MaskTool.none
        switch kind {
        case .brush:
            source = .shape(.brush(strokes: [])); tool = .brush
        case .linear:
            source = .shape(.linear(start: SIMD2(0.5, 0.0), end: SIMD2(0.5, 0.5))); tool = .linear
        case .radial:
            source = .shape(.radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.3, 0.3), feather: 0.5)); tool = .radial
        case .colourRange:
            source = .colour(ColourRange()); tool = .colourSample
        case .luminanceRange:
            source = .luminance(LuminanceRange(low: 0.5, high: 1, feather: 0.1))
        case .subject(let entry):
            source = .shape(.ai(kind: AIMaskKind.subject.rawValue, modelVersion: entry.modelVersion))
        case .aiClass(let kind):
            source = .shape(.ai(kind: kind.rawValue, modelVersion: kind.modelVersion))
        case .clickToSelect(let entry):
            source = .shape(.prompted(points: [], modelVersion: entry.modelVersion)); tool = .prompt
        case .objects(let entry):
            source = .shape(.prompted(points: [], modelVersion: entry.modelVersion)); tool = .box
        }
        let component = MaskComponent(mode: mode, source: source)
        parameters.locals[i].components.append(component)
        selectedMaskComponentID = component.id
        showMaskOverlay = true
        if let element = parameters.maskElement(id: component.id), element.shape.isModelGenerated {
            if case .prompted(_, let version) = element.shape {
                if let id = promptModelID(for: version) { ensurePromptSession(for: id) }
            } else {
                generateAIMask(for: element)
            }
        }
        maskTool = tool
    }

    func removeMaskComponent(_ id: UUID) {
        guard let i = selectedLocalIndex, i < parameters.locals.count else { return }
        parameters.locals[i].components.removeAll { $0.id == id }
        if selectedMaskComponentID == id { selectedMaskComponentID = nil }
        maskTool = .none
    }

    // MARK: - Housekeeping

    /// A copy of the mask at `index` right after it, selected. Model
    /// masks bring their pixels along, so nothing is generated again.
    func duplicateLocal(at index: Int, invert: Bool = false) {
        guard index < parameters.locals.count, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        let original = parameters.locals[index]
        let copy = invert ? original.duplicatedAndInverted() : original.duplicated()
        if let session {
            for (from, to) in zip(original.maskElements, copy.maskElements) where from.shape.isModelGenerated {
                if let pixels = session.aiMask(forLocal: from.id) { session.setAIMask(pixels, forLocal: to.id) }
                modelMaskShapes[to.id] = modelMaskShapes[from.id]
                modelMaskGeometry[to.id] = modelMaskGeometry[from.id]
            }
        }
        parameters.locals.insert(copy, at: index + 1)
        selectedLocalIndex = index + 1
    }

    /// Whether any mask has nothing in it.
    var hasEmptyMasks: Bool { !parameters.emptyLocalIndices.isEmpty }

    /// Removes every mask with nothing in it (no strokes, no clicks, a
    /// gradient never dragged out), in one undoable step.
    func deleteEmptyMasks() {
        let empty = Set(parameters.emptyLocalIndices)
        guard !empty.isEmpty else { return }
        let selectedID = selectedLocal?.id
        maskTool = .none
        parameters.locals = parameters.locals.enumerated().filter { !empty.contains($0.offset) }.map(\.element)
        selectedLocalIndex = selectedID.flatMap { id in parameters.locals.firstIndex { $0.id == id } }
    }

    func toggleHidden(at index: Int) {
        guard index < parameters.locals.count else { return }
        parameters.locals[index].hidden.toggle()
    }

    // MARK: - Colour Range eyedropper

    /// Adds the colour under `point` (normalised output coordinates) to
    /// the selected Colour Range component, as the mask sees it: before
    /// any local adjustment. Up to five samples; a sixth replaces the last.
    func sampleColour(at point: SIMD2<Float>) {
        guard let i = selectedLocalIndex, i < parameters.locals.count,
              let id = selectedMaskComponentID,
              let c = parameters.locals[i].components.firstIndex(where: { $0.id == id }),
              case .colour(var range) = parameters.locals[i].components[c].source,
              let working = workingColour(at: point) else { return }
        let sample = ColourRange.sample(working: working, contrast: parameters.contrast,
                                        greyPoint: parameters.greyPoint, toneRanges: parameters.toneRanges)
        if range.samples.count >= ColourRange.maximumSamples { range.samples.removeLast() }
        range.samples.append(sample)
        parameters.locals[i].components[c].source = .colour(range)
        status = String(format: "Colour sample %d: hue %.0f°, saturation %.0f%%",
                        range.samples.count, sample.hue, sample.saturation * 100)
    }

    /// The scene-linear working-space colour at a normalised point, from
    /// a small render of the edit without its locals.
    private func workingColour(at point: SIMD2<Float>) -> SIMD3<Float>? {
        guard let session, let pipeline, let gpu = gpuContext else { return nil }
        var key = parameters
        key.locals = []
        if colourSampleCache?.key != key {
            let longEdge = max(session.file.summary.rawWidth, session.file.summary.rawHeight)
            let quads = max(1, Int((Double(longEdge) / 2048.0).rounded(.up)))
            defer { session.releasePooledTextures(in: .analysis) }
            do {
                let cache = try session.withTexturePool(.analysis) { () -> ColourSampleCache in
                    let tex = try pipeline.render(session, scale: .binned(quads: quads), parameters: key, output: .sceneLinear)
                    return ColourSampleCache(key: key, width: tex.width, height: tex.height,
                                             pixels: try TextureReadback.float16Pixels(of: tex, gpu: gpu))
                }
                colourSampleCache = cache
            } catch {
                status = "Colour sample failed: \(error)"
                return nil
            }
        }
        guard let cache = colourSampleCache, cache.width > 0, cache.height > 0 else { return nil }
        // A 3×3 average, so one noisy pixel doesn't set the colour.
        let cx = min(max(Int(point.x * Float(cache.width)), 1), cache.width - 2)
        let cy = min(max(Int(point.y * Float(cache.height)), 1), cache.height - 2)
        var sum = SIMD3<Float>(repeating: 0)
        for dy in -1...1 { for dx in -1...1 {
            let o = ((cy + dy) * cache.width + (cx + dx)) * 4
            sum += SIMD3(Float(cache.pixels[o]), Float(cache.pixels[o + 1]), Float(cache.pixels[o + 2]))
        } }
        return sum / 9
    }

    func clearColourSamples() {
        guard let i = selectedLocalIndex, i < parameters.locals.count, let id = selectedMaskComponentID,
              let c = parameters.locals[i].components.firstIndex(where: { $0.id == id }),
              case .colour(var range) = parameters.locals[i].components[c].source else { return }
        range.samples = []
        parameters.locals[i].components[c].source = .colour(range)
    }

    // MARK: - Select Objects

    /// The dragged box becomes the selection's two box corners (any
    /// clicks it already had stay), and SAM is asked for the object.
    func finishObjectBox(_ box: CGRect) {
        guard box.width > 0.005, box.height > 0.005,
              let element = activeMaskElement, case .prompted(let points, let version) = element.shape else { return }
        let corners = [MaskPromptPoint(x: Float(box.minX), y: Float(box.minY), corner: 1),
                       MaskPromptPoint(x: Float(box.maxX), y: Float(box.maxY), corner: 2)]
        setActiveMaskShape(.prompted(points: points.filter { $0.corner == nil } + corners, modelVersion: version))
        if let updated = activeMaskElement { updatePromptedMask(for: updated) }
    }

}
