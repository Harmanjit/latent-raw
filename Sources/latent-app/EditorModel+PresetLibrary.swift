import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixelEngine

/// Managing presets: import and export, rename, duplicate, update from the
/// open photo, the groups and note a user preset holds. Built-ins stay
/// read-only. Every change reloads the list everywhere (`PresetCatalog`).
extension EditorModel {
    /// Reads the store again, for the editor and every menu.
    func reloadPresets() {
        presets = PresetStore.load()
        PresetCatalog.shared.update(presets)
    }

    func renamePreset(_ preset: Preset, to name: String) {
        do {
            let renamed = try PresetStore.rename(preset, to: name, among: presets)
            guard renamed.name != preset.name else { return }
            PresetCatalog.shared.renamed(from: preset.name, to: renamed.name)
            KeyboardSettings.shared.presetRenamed(from: preset.name, to: renamed.name)
            reloadPresets()
            status = "Renamed preset “\(preset.name)” to “\(renamed.name)”"
        } catch {
            reportFailure("Renaming preset “\(preset.name)”", error)
        }
    }

    func duplicatePreset(_ preset: Preset) {
        do {
            let copy = try PresetStore.duplicate(preset, among: presets)
            reloadPresets()
            status = "Duplicated preset as “\(copy.name)”"
        } catch {
            reportFailure("Duplicating preset “\(preset.name)”", error)
        }
    }

    /// The preset's groups captured again from the open photo; its name,
    /// groups and note stay.
    func updatePresetFromCurrentEdit(_ preset: Preset) {
        guard hasImage, !preset.isBuiltIn else { return }
        var updated = Preset(name: preset.name, groups: preset.groups, stack: EditStack(parameters: parameters))
        updated.details = preset.details
        do {
            try PresetStore.save(updated)
            reloadPresets()
            status = "Updated preset “\(preset.name)” from the current edit"
        } catch {
            reportFailure("Updating preset “\(preset.name)”", error)
        }
    }

    /// Narrows the groups a user preset holds (Manage Presets).
    func restrictPreset(_ preset: Preset, to groups: Set<EditGroup>) {
        guard groups != preset.groups else { return }
        do {
            _ = try PresetStore.restrict(preset, to: groups)
            reloadPresets()
        } catch {
            reportFailure("Changing preset “\(preset.name)”", error)
        }
    }

    func setPresetDetails(_ preset: Preset, _ details: String) {
        guard !preset.isBuiltIn else { return }
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = preset
        changed.details = trimmed.isEmpty ? nil : trimmed
        guard changed.details != preset.details else { return }
        do {
            try PresetStore.save(changed)
            reloadPresets()
        } catch {
            reportFailure("Changing preset “\(preset.name)”", error)
        }
    }

    // MARK: Files

    static var presetFileTypes: [UTType] {
        [UTType(filenameExtension: PresetStore.fileExtension, conformingTo: .json) ?? .json, .json]
    }

    /// Import…: preset files chosen in an open panel, copied into the
    /// store; a name already taken gets a number.
    func importPresetsWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.presetFileTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose Latent preset files to import"
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        var imported: [String] = []
        var failures: [String] = []
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                imported += try PresetStore.importFile(data, existing: presets + imported.map { name in
                    Preset(name: name, groups: [], stack: EditStack())
                })
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reloadPresets()
        if !failures.isEmpty {
            lastError = "Some presets couldn’t be imported. " + failures.joined(separator: " ")
        }
        status = imported.count == 1 ? "Imported preset “\(imported[0])”" : "Imported \(imported.count) presets"
        Announcement.post(status)
    }

    /// Export…: the presets written to one file chosen in a save panel.
    func exportPresetsWithPanel(_ chosen: [Preset]) {
        guard !chosen.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.presetFileTypes[0]]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (chosen.count == 1 ? chosen[0].leafName : "Latent Presets")
            .replacingOccurrences(of: "/", with: "-") + "." + PresetStore.fileExtension
        panel.message = chosen.count == 1 ? "Export “\(chosen[0].name)”" : "Export \(chosen.count) presets"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PresetStore.exportData(chosen).write(to: url, options: .atomic)
            status = chosen.count == 1 ? "Exported preset “\(chosen[0].name)”" : "Exported \(chosen.count) presets"
        } catch {
            reportFailure("Exporting presets", error)
        }
    }

    // MARK: Panels

    /// A preset from a panel's own menu, on the open photo at the Presets
    /// panel's Amount, re-blendable as Apply Preset is.
    func applyPresetInEditor(_ preset: Preset) {
        guard hasImage else { return }
        let base = EditStack(parameters: parameters)
        let amount = PresetAmountSession.amount
        apply(stack(applying: preset.stack, groups: preset.groups, amount: amount), groups: preset.groups)
        rememberPresetApplication(base: base, preset: preset)
        status = "Applied preset “\(preset.name)”"
    }
}
