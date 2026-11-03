import SwiftUI
import PixelEngine

/// The tooltip of the Heal / Clone / Remove picker.
enum HealModeHelp {
    static let text = "Heal: copy texture from a source and match it to the surroundings. "
        + "Clone: copy a source exactly. Remove: fill from around the spot, with no source to place"
}

/// Remove's options, under Spot Removal while Remove is the mode: Detect
/// Objects, and for the selected Remove patch, detecting again or going
/// back to the brushed area.
struct RemoveOptions: View {
    @ObservedObject var model: EditorModel

    private var selectedRemoval: HealPatch? {
        guard let patch = model.selectedHeal, patch.mode == .remove else { return nil }
        return patch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Detect Objects", isOn: $model.removeDetectsObjects)
                    .toggleStyle(.checkbox)
                    .disabled(!model.detectObjectsAvailable)
                    .help(model.detectObjectsAvailable
                          ? "Brush roughly over an object; its outline is found on this Mac and filled, keeping the background the brush also covered"
                          : "Needs a click-to-select model (Settings > Models)")
                    .accessibilityHint("Refines each new Remove stroke to the outline of the object under it")
                Spacer()
                if let patch = selectedRemoval, model.detectingObjectIDs.contains(patch.id) {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Detecting the object")
                }
            }
            if let patch = selectedRemoval {
                HStack(spacing: 8) {
                    Button("Detect Object") { model.detectObjectForSelectedPatch() }
                        .disabled(!model.detectObjectsAvailable || model.detectingObjectIDs.contains(patch.id))
                        .help("Find the outline of the object under the selected patch and fill that")
                        .accessibilityLabel("Detect object for the selected patch")
                    Button("Use Brush") { model.useBrushForSelectedPatch() }
                        .disabled(patch.objectMask == nil)
                        .help("Forget the detected outline and fill the whole brushed area")
                        .accessibilityLabel("Fill the brushed area instead of the detected outline")
                    Spacer()
                }
                Text(patch.objectMask == nil ? "Fills the brushed area" : "Fills the detected outline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .disabled(!model.hasImage)
    }
}
