import SwiftUI
import Combine
import Catalog
import PixelEngine

/// Panes that zoom and pan together: `EditorModel.linkedGroup`.
@MainActor
protocol LinkedPaneGroup: AnyObject {
    var linkedPanes: [EditorModel] { get }
}

/// Survey (N): two to four selected images side by side, each in a pane of
/// its own. Which images and which pane has the keyboard are
/// `SurveyPanes`; this holds a view-only editor model per pane, links
/// their views while Sync is on, and lets go of them when they aren't
/// needed.
///
/// A pane's model never writes: it opens its image with no catalog id, as
/// Compare's Select pane does. Rating and flag keys reach the catalog
/// through the primary selection, which is the focused pane.
///
/// Memory. Each pane is a full image session, sensor plane and all. On a
/// Mac with 8 GB or less (`MemoryPolicy`) a pane gives back its pooled
/// textures once each render is on screen, keeping only the sensor plane
/// and the layers it shows, and leaving Survey closes every pane's image.
/// With more memory the panes keep their images when Survey is left (but
/// not their pooled textures), so coming back is instant, until the system
/// asks for memory, which closes them (`EditorModel.isOffScreen`).
@MainActor
final class SurveyModel: ObservableObject, LinkedPaneGroup {
    /// What is shown, nil before the first survey and after `closeAll`.
    @Published private(set) var panes: SurveyPanes?
    /// Panes zoom and pan together, matched by position in each picture.
    @Published var syncsView = true {
        didSet {
            guard syncsView != oldValue else { return }
            relink()
            // Turning Sync on lines the others up with the focused pane.
            if syncsView, let focused = focusedModel {
                let view = focused.relativeView
                for pane in linkedPanes where pane !== focused { pane.takeLinkedView(view) }
            }
        }
    }
    /// The shown images' average width per unit height, for the layout.
    @Published private(set) var imageAspect: CGFloat = 1.5

    /// One model per pane, by image id.
    private(set) var models: [Int64: EditorModel] = [:]
    /// Survey is on screen.
    private(set) var isShowing = false
    let policy: MemoryPolicy

    private var focusObservation: AnyCancellable?
    private var renderObservations: [ObjectIdentifier: AnyCancellable] = [:]

    init(policy: MemoryPolicy = .current) {
        self.policy = policy
    }

    var linkedPanes: [EditorModel] { (panes?.ids ?? []).compactMap { models[$0] } }

    var focusedModel: EditorModel? { panes.flatMap { models[$0.focusedID] } }

    /// The pane model showing `id`, if one does (shown or kept since).
    func model(for id: Int64?) -> EditorModel? { id.flatMap { models[$0] } }

    // MARK: - Showing and leaving

    /// Shows `new`. Each pane keeps its model if it had one, else takes a
    /// model no longer needed (its image closed first, so the pane never
    /// shows another photo under this one's caption) or a new one. `open`
    /// then gets every pane, focused first, to open or refresh its image.
    func show(_ new: SurveyPanes, open: @MainActor (Int64, EditorModel) -> Void) {
        isShowing = true
        var spare = models.filter { !new.ids.contains($0.key) }.map(\.value)
        var next: [Int64: EditorModel] = [:]
        for id in new.ids {
            if let kept = models[id] {
                next[id] = kept
            } else if let reused = spare.popLast() {
                reused.closeImage()
                next[id] = reused
            } else {
                next[id] = makePane()
            }
            next[id]?.isOffScreen = false
        }
        for model in spare { release(model) }
        models = next
        panes = new
        relink()
        observeFocus()
        updateImageAspect()
        let order = [new.focusedID] + new.ids.filter { $0 != new.focusedID }
        for id in order { if let model = models[id] { open(id, model) } }
    }

    /// Survey is no longer on screen. See the type's comment for what the
    /// panes keep.
    func end() {
        guard isShowing else { return }
        isShowing = false
        focusObservation = nil
        for model in models.values {
            model.linkedGroup = nil
            model.showingBefore = false
        }
        guard policy.keepsIdleImages else {
            closeAll()
            return
        }
        for model in models.values {
            model.isOffScreen = true
            if !model.aiDenoiseRunning { model.session?.releasePooledTextures() }
        }
    }

    /// Closes every pane's image and forgets the panes: leaving Survey on
    /// a small Mac, and before another folder opens (the ids belong to
    /// the catalog being left).
    func closeAll() {
        for model in models.values { release(model) }
        models = [:]
        panes = nil
        isShowing = false
        focusObservation = nil
    }

    // MARK: - Focus and removal

    /// Focuses the pane showing `id`. False when nothing changed.
    @discardableResult
    func focus(_ id: Int64) -> Bool {
        guard var panes, panes.focusedID != id, panes.focus(id) else { return false }
        self.panes = panes
        observeFocus()
        return true
    }

    /// ← and →. False when the focus was already at that end.
    @discardableResult
    func moveFocus(by offset: Int) -> Bool {
        guard var panes, panes.moveFocus(by: offset) else { return false }
        self.panes = panes
        observeFocus()
        return true
    }

    /// Takes `id`'s pane away and closes its image.
    @discardableResult
    func remove(_ id: Int64) -> Bool {
        guard var panes, panes.remove(id) else { return false }
        self.panes = panes
        if let model = models.removeValue(forKey: id) { release(model) }
        observeFocus()
        updateImageAspect()
        return true
    }

    /// Follows a selection changed elsewhere (see `SurveyPanes.follow`),
    /// closing the images of panes that went. True when anything changed.
    @discardableResult
    func follow(selected: Set<Int64>, primary: Int64?) -> Bool {
        guard var panes else { return false }
        let before = panes
        for id in panes.follow(selected: selected, primary: primary) {
            if let model = models.removeValue(forKey: id) { release(model) }
        }
        guard panes != before else { return false }
        self.panes = panes
        observeFocus()
        updateImageAspect()
        return true
    }

    // MARK: - Panes

    private func makePane() -> EditorModel {
        let model = EditorModel()
        // No histogram is on screen for a pane.
        model.measuresScopes = false
        renderObservations[ObjectIdentifier(model)] = Publishers.Merge(
            model.$preview.dropFirst().map { _ in () },
            model.$tile.dropFirst().map { _ in () }
        )
        .sink { [weak self, weak model] in
            guard let self, let model else { return }
            // Published before the render assigns it: act once it has.
            Task { @MainActor in self.paneRendered(model) }
        }
        return model
    }

    private func release(_ model: EditorModel) {
        model.closeImage()
        model.linkedGroup = nil
        renderObservations[ObjectIdentifier(model)] = nil
    }

    /// After each of a pane's renders: on a small Mac its pooled textures
    /// go (the layers on screen hold their own), and so does the analysis
    /// render nothing measures.
    private func paneRendered(_ model: EditorModel) {
        guard models.values.contains(where: { $0 === model }) else { return }
        updateImageAspect()
        guard !policy.keepsIdleImages, model.hasImage, !model.aiDenoiseRunning else { return }
        model.session?.releasePooledTextures()
        model.analysisTexture = nil
    }

    private func relink() {
        let group: (any LinkedPaneGroup)? = isShowing && syncsView ? self : nil
        for model in models.values { model.linkedGroup = group }
    }

    /// The status bar's zoom readout is the focused pane's, so its changes
    /// are this model's changes.
    private func observeFocus() {
        focusObservation = focusedModel?.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    private func updateImageAspect() {
        let sizes = linkedPanes.filter(\.hasImage).map(\.imageSize).filter { $0.width > 0 && $0.height > 0 }
        guard !sizes.isEmpty else { return }
        let mean = sizes.map { $0.width / $0.height }.reduce(0, +) / CGFloat(sizes.count)
        let rounded = (mean * 100).rounded() / 100
        if rounded != imageAspect { imageAspect = rounded }
    }
}

// MARK: - From the library

extension SurveyModel {
    /// Surveys the library's selection, opening each pane's image with its
    /// stored edit, and makes the focused pane the primary selection. False,
    /// with nothing changed, unless two to four images are selected.
    func begin(library: Library, onFailure: @escaping @MainActor (String, any Error) -> Void) -> Bool {
        guard let panes = SurveyPanes(selected: library.selectedImageIDs, primary: library.selectedImageID,
                                      order: library.visibleImages.compactMap(\.id)) else { return false }
        let catalog = library.catalog
        show(panes) { id, model in
            guard let record = library.images.first(where: { $0.id == id }),
                  let url = library.fileURL(for: record) else { return }
            Task { @MainActor [weak self] in
                let stack: String?
                do {
                    stack = try await library.editStack(for: record)
                } catch {
                    onFailure("Reading the edit for \(record.fileName)", error)
                    return
                }
                // Left, removed or another folder opened meanwhile.
                guard let self, self.isShowing, self.models[id] === model, library.catalog === catalog else { return }
                if model.hasImage, model.sourceURL == url {
                    model.showStoredEdit(stack, userRotation: record.userRotation)
                } else {
                    model.open(url: url, userRotation: record.userRotation, catalogImageID: nil, editStackJSON: stack)
                }
            }
        }
        writeSelection(to: library)
        return true
    }

    /// Makes the library's selection the panes, led by the focused one.
    func writeSelection(to library: Library) {
        guard let panes else { return }
        library.setSelection(Set(panes.ids), primary: panes.focusedID)
    }

    /// What VoiceOver says when the keyboard moves the focus.
    func announceFocus(in library: Library) {
        guard let id = panes?.focusedID, let record = library.images.first(where: { $0.id == id }) else { return }
        Announcement.post(SpokenText.image(name: record.fileName, rating: record.rating, flag: record.flag,
                                           isEdited: library.editedImageIDs.contains(id)))
    }
}

extension EditorModel {
    /// For a view-only pane that kept its image while away: the stored
    /// edit and rotation as they are now, which Develop, a paste or a
    /// rotation in the grid may have changed.
    func showStoredEdit(_ json: String?, userRotation: Int) {
        guard hasImage else { return }
        setUserRotation(userRotation)
        var next = defaultParameters
        if let json {
            do {
                next = try EditStack.decode(json: json).parameters(defaults: defaultParameters)
                if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
            } catch {
                reportFailure("Reading the stored edit for \(imageTitle ?? "the image")", error)
                return
            }
        }
        if next != parameters { parameters = next }
    }
}
