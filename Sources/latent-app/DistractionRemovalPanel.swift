import SwiftUI
import PixelEngine
import MLKit

/// Distraction Removal (docs/wiki/Develop.md, "Reflections"), the content
/// of `DisclosureGroup("Distraction Removal")`: the Reflections amount,
/// from the photo as shot to a reflection-removal model's picture. The
/// model is the user's own (Settings › AI › Models); without one the
/// slider is off and the panel says how to add one. Nothing is faked.
struct DistractionRemovalSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state: ReflectionState

    init(model: EditorModel) {
        self.model = model
        self.state = model.reflectionState
    }

    private var removal: ReflectionRemoval { model.parameters.reflections }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Reflections").font(.subheadline).accessibilityHidden(true)
                    Spacer()
                    if state.building { ProgressView().controlSize(.mini) }
                    SliderValueField(value: amount, in: 0...100, format: SliderValueFormat(printf: "%.0f"),
                                     label: "Reflections")
                }
                ResettableSlider(value: amount, in: 0...100, label: "Reflections",
                                 format: SliderValueFormat(printf: "%.0f")) { model.setReflectionAmount(0) }
                    .help("How much of the reflection in a window or glass to take away; double-click to reset")
                    .accessibilityHint("0 leaves the photo as shot; 100 takes the model's result whole")
            }
            .disabled(!state.modelAvailable && !removal.isActive)

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!model.hasImage)
        .onAppear { model.refreshReflectionModelAvailability() }
    }

    private var amount: Binding<Float> {
        Binding(get: { removal.amount }, set: { model.setReflectionAmount($0) })
    }

    private var caption: String {
        if !state.modelAvailable { return EditorModel.reflectionNoModelMessage }
        if !state.status.isEmpty { return state.status }
        return "Runs a reflection removal model on this Mac when the amount leaves 0."
    }
}
