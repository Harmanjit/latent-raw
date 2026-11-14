import Foundation
import PixelEngine

/// Apply a develop preset at export, as darktable's style on export: a
/// black-and-white set or a web look from the same edits, without touching
/// them. The preset is merged into a copy of each photo's edit, with the
/// Presets panel's Amount blend, just before the render; the edit in the
/// catalog and its sidecar never change.
extension ExportPreset {
    /// The edit a file is rendered from: `json` with the export's preset
    /// applied, or `json` itself when there is none, the preset has been
    /// deleted, or the file is a DNG (whose section hides the choice).
    func styledEditStackJSON(_ json: String?, lookup: (String) -> Preset? = PresetStore.preset(named:)) -> String? {
        guard fileKind == .image, let presetStyle else { return json }
        return presetStyle.applied(to: json, lookup: lookup)
    }

    /// What the sheet says about the choice, for its summary and tooltip.
    var presetStyleSummary: String? {
        guard let presetStyle else { return nil }
        let amount = String(format: "%.0f%%", presetStyle.amount * 100)
        return "\(presetStyle.presetName) (\(presetStyle.mode.title), \(amount))"
    }
}
