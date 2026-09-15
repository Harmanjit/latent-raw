import SwiftUI
import PixelEngine

extension EditorModel {
    // MARK: - Copy / paste / presets

    /// The clipboard is a partial edit stack, kept as JSON on the system
    /// pasteboard so it also crosses app instances. Custom type plus a
    /// plain-text copy for humans.
    static let pasteboardType = NSPasteboard.PasteboardType("com.latent.editstack+json")

    /// Copies the current edit (restricted to `pasteGroups`).
    func copySettings() {
        guard hasImage else { return }
        let stack = EditStack(parameters: parameters).restricted(to: pasteGroups)
        guard let json = try? stack.encodeJSON() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: Self.pasteboardType)
        pb.setString(json, forType: .string)
        status = "Copied \(pasteGroups.count) group\(pasteGroups.count == 1 ? "" : "s") of settings"
    }

    /// The stack on the pasteboard, if any.
    static func clipboardStack() -> EditStack? {
        let pb = NSPasteboard.general
        guard let json = pb.string(forType: pasteboardType) ?? pb.string(forType: .string),
              let stack = try? EditStack.decode(json: json) else { return nil }
        return stack
    }

    /// Applies a partial stack to the open image.
    func apply(_ stack: EditStack, groups: Set<EditGroup>) {
        guard hasImage else { return }
        let current = EditStack(parameters: parameters)
        // An old clipboard or preset stack's geometry is read as if it came
        // from a camera with this image's border: the best guess there is,
        // and exact for the usual case of syncing between frames of one body.
        var next = current.merged(with: onThisImage(stack), groups: groups).parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        parameters = next
    }

    func pasteSettings() {
        guard let stack = Self.clipboardStack() else { status = "Nothing to paste"; return }
        apply(stack, groups: pasteGroups.intersection(stack.presentGroups).union(pasteGroups.subtracting(stack.presentGroups)))
        status = "Pasted settings"
    }

    func applyPreset(_ preset: Preset) {
        apply(preset.stack, groups: preset.groups)
        status = "Applied preset “\(preset.name)”"
    }

    func savePreset(named name: String, groups: Set<EditGroup>) {
        guard hasImage, !name.isEmpty else { return }
        let preset = Preset(name: name, groups: groups, stack: EditStack(parameters: parameters))
        do {
            try PresetStore.save(preset)
            presets = PresetStore.load()
            status = "Saved preset “\(name)”"
        } catch {
            status = "Could not save preset: \(error)"
        }
    }

    func deletePreset(_ preset: Preset) {
        guard !preset.isBuiltIn else { return }
        do { try PresetStore.delete(named: preset.name) } catch { reportFailure("Deleting preset “\(preset.name)”", error) }
        presets = PresetStore.load()
    }
}
