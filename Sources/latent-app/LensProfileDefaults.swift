import Foundation
import Combine
import Catalog
import LensKit

/// Keeps the process-wide table of remembered lens profiles
/// (`LensProfileOverrides`) in step with the open catalog's
/// `lens_overrides`, and saves the editor's "Use for All Photos From This
/// Lens" into it.
///
/// The choice is a catalog change, so it is undone the way the Library's
/// are: Edit ▸ Undo in the Library (Develop's Undo steps through the
/// photo's own edit history). The profile picked for one photo is part of
/// that photo's edit and undoes in Develop like any slider.
@MainActor
final class LensProfileDefaults {
    static let shared = LensProfileDefaults()

    private weak var library: Library?
    private weak var model: EditorModel?
    private var subscription: AnyCancellable?

    /// Follows `library`'s catalog and serves `model`. Calling it again
    /// with the same pair changes nothing.
    func attach(library: Library, model: EditorModel) {
        if self.library !== library {
            self.library = library
            // A turn later: the folder changes as the new catalog lands.
            subscription = library.$folderURL.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reload() }
            }
        }
        self.model = model
        model.onRememberLensProfile = { [weak self] lensModel, key in self?.remember(lensModel, for: key) }
        reload()
    }

    /// Loads the open catalog's choices (none without a catalog).
    func reload() {
        guard let catalog = library?.catalog else {
            LensProfileOverrides.replaceAll([:])
            model?.lensProfileDefaultsDidChange()
            return
        }
        library?.perform("Reading lens profile choices") { [weak self] in
            let rows = try await catalog.lensOverrides()
            guard let self, self.library?.catalog === catalog else { return }
            var table: [LensProfileOverrides.Key: String] = [:]
            for row in rows { table[LensProfileOverrides.Key(camera: row.camera, lens: row.lensID)] = row.lensfunModel }
            LensProfileOverrides.replaceAll(table)
            self.model?.lensProfileDefaultsDidChange()
        }
    }

    /// Saves `lensModel` (nil: automatic) for `key` in the open catalog,
    /// with an undo that puts back what was there.
    func remember(_ lensModel: String?, for key: LensProfileOverrides.Key) {
        guard let library, let catalog = library.catalog else { return }
        set(lensModel, for: key, in: catalog, library: library, actionName: "Lens Profile for This Lens")
    }

    private func set(_ lensModel: String?, for key: LensProfileOverrides.Key, in catalog: Catalog,
                     library: Library, actionName: String) {
        // What the undo puts back. Taken now, and the undo filed now when
        // this runs as an undo or redo, so it lands on the opposite stack.
        let opposite = LensProfileOverrides.model(for: key)
        let fileUndo = library.undoRegistration(actionName, in: catalog) { [weak self] library, catalog in
            self?.set(opposite, for: key, in: catalog, library: library, actionName: actionName)
        }
        library.perform("Saving the lens profile") { [weak self] in
            try await catalog.exchangeLensOverride(lensModel, camera: key.camera, lensID: key.lens)
            LensProfileOverrides.set(lensModel, for: key)
            // The photo's own choice now matches the remembered one, so it
            // goes back to following it.
            if let model = self?.model, model.parameters.lensProfile == lensModel { model.parameters.lensProfile = nil }
            self?.model?.lensProfileDefaultsDidChange()
            fileUndo(opposite != lensModel)
        }
    }
}
