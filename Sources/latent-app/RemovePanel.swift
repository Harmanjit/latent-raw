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

/// Fill and Blur (HealModes.swift), under Spot Removal: a second mode
/// picker beside Heal, Clone and Remove, and the selected mode's options,
/// Fill's colour and brightness or Blur's radius. Both work with the Spot
/// and Brush shapes and take Feather and Opacity like the other modes.
struct HealFillBlurOptions: View {
    @ObservedObject var model: EditorModel

    private var mode: HealPatch.Mode { model.activeHealMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Paint").font(.subheadline).accessibilityHidden(true)
                Picker("Fill or blur mode", selection: Binding(
                    get: { mode == .fill || mode == .blur ? mode : nil },
                    set: { if let picked = $0 { model.activeHealMode = picked } })) {
                    Text("Fill").tag(HealPatch.Mode?.some(.fill))
                    Text("Blur").tag(HealPatch.Mode?.some(.blur))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                .help("Fill: paint a colour over the spot. Blur: soften what is under it. Neither has a source to place")
                Spacer()
            }
            if mode == .fill {
                HStack(spacing: 8) {
                    Text("Colour").font(.subheadline).accessibilityHidden(true)
                    Spacer()
                    ColorPicker("Fill colour", selection: Binding(
                        get: { model.activeFillCGColour },
                        set: { model.activeFillCGColour = $0 }), supportsOpacity: false)
                        .labelsHidden()
                        .help("The colour Fill paints. The photo's tone and colour edits still apply on top, so it shows approximately")
                }
                DetailSliderRow(title: "Brightness", value: Binding(
                    get: { model.activeFillBrightness }, set: { model.activeFillBrightness = $0 }),
                    range: HealPatch.fillBrightnessRange, format: "%+.1f EV",
                    help: "Brightens or darkens the fill colour, in stops.",
                    label: "Fill brightness")
            }
            if mode == .blur {
                DetailSliderRow(title: "Blur Radius", value: Binding(
                    get: { model.activeBlurRadiusPixels }, set: { model.activeBlurRadiusPixels = $0 }),
                    range: 1...200, format: "%.0f px", defaultValue: model.defaultBlurRadiusPixels,
                    help: "How far the blur spreads, in sensor pixels.",
                    label: "Blur radius")
            }
        }
        .controlSize(.small)
        .disabled(!model.hasImage)
    }
}

/// The next Fill or Blur patch's settings, remembered between launches
/// like the panel's other choices; the selected patch's own win while one
/// is selected (`EditorModel.activeFillColour` and the rest).
enum HealModeDefaults {
    private static let colourKey = "healFillColour"
    private static let brightnessKey = "healFillBrightness"
    private static let blurKey = "healBlurRadius"

    static var fillColour: SIMD3<Float> {
        get {
            let stored = UserDefaults.standard.array(forKey: colourKey) as? [Double] ?? []
            guard stored.count == 3, stored.allSatisfy(\.isFinite) else { return HealPatch.defaultFillColour }
            return SIMD3(Float(stored[0]), Float(stored[1]), Float(stored[2]))
        }
        set { UserDefaults.standard.set([Double(newValue.x), Double(newValue.y), Double(newValue.z)], forKey: colourKey) }
    }

    static var fillBrightness: Float {
        get { UserDefaults.standard.object(forKey: brightnessKey) == nil ? 0 : UserDefaults.standard.float(forKey: brightnessKey) }
        set { UserDefaults.standard.set(newValue, forKey: brightnessKey) }
    }

    static var blurRadius: Float {
        get {
            let v = UserDefaults.standard.float(forKey: blurKey)
            return v > 0 && v <= HealPatch.maximumBlurRadius ? v : HealPatch.defaultBlurRadius
        }
        set { UserDefaults.standard.set(newValue, forKey: blurKey) }
    }
}
