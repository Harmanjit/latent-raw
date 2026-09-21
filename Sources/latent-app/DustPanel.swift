import SwiftUI
import PixelEngine

/// Sensor Dust, under Spot Removal (docs/Retouch.md §6): Find Spots looks
/// for dust on this Mac and heals each spot; the Spots… tool shows them
/// as rings to correct by hand; Sensitivity and Spot Size re-detect from
/// the kept analysis while the tool is armed; Visualise Spots shows
/// faint shadows on screen; dust maps carry one photo's spots to others.
/// The content of the `DisclosureGroup("Sensor Dust")`, like RedEyeSection.
struct DustSection: View {
    @ObservedObject var model: EditorModel
    /// From dust map…: opens the Remove Dust sheet on the open image
    /// (ContentView presents it; the sheet's Remove calls `applyDustMap`).
    var fromDustMap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.findDustSpots()
                } label: {
                    if model.findingDust {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Find Spots")
                    }
                }
                .disabled(model.findingDust)
                .help("Look for sensor dust in this photo on this Mac and heal each spot; replaces the spots found last time")
                .accessibilityLabel("Find dust spots")
                .accessibilityValue(model.findingDust ? "Looking for dust spots" : "")
                Toggle(isOn: $model.dustToolActive) {
                    Text(model.dustToolActive ? "Spots: on" : "Spots…")
                }
                .toggleStyle(.button)
                .help("Show the spots; click a ring to remove a false one, click the image to add one")
                .accessibilityLabel("Dust spot tool")
                Spacer()
                Button("Clear") { model.clearDust() }
                    .disabled(model.parameters.dust.isEmpty)
                    .help("Remove every dust spot")
                    .accessibilityLabel("Clear all dust spots")
            }
            .controlSize(.small)

            sliderRow("Sensitivity", value: sensitivity, range: 0...100, format: "%.0f", defaultValue: 50)
                .help("Higher finds fainter and less round spots; lower keeps only the clearest")

            HStack(spacing: 8) {
                // fixedSize: the label keeps one line and the segmented
                // control gives way, rather than "Spot Size" wrapping
                // when the panel is narrow.
                Text("Spot Size").font(.subheadline).fixedSize().accessibilityHidden(true)
                Picker("Spot size", selection: size) {
                    ForEach(DustSpotSize.allCases, id: \.self) { band in
                        Text(band.displayName).tag(band)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 180)
                .help("How big the shadows are: Small 4 to 8, Medium 6 to 16, Large 12 to 40 pixels across the sensor, halved")
                .accessibilityHint("The size of dust shadow to look for")
                Spacer()
            }
            .controlSize(.small)

            Toggle("Visualise Spots", isOn: $model.visualiseSpots)
                .controlSize(.small)
                .help("Show faint dark spots as dark marks on a light image, on screen only; never in an export")
                .accessibilityHint("Shows the photo as a high-pass view where dust shadows stand out")
            sliderRow("Contrast", value: $model.visualiseThreshold, range: 0...1, format: "%.2f", defaultValue: 0.5)
                .disabled(!model.visualiseSpots)
                .help("How faint a shadow still shows in the visualisation")

            HStack(spacing: 8) {
                Button("From dust map…") { fromDustMap() }
                    .help("Look for the spots of a saved dust map in this photo and heal the ones that are there")
                    .accessibilityLabel("Heal dust from a dust map")
                Button("Save as dust map…") { model.saveDustMap() }
                    .disabled(model.parameters.dust.isEmpty || model.findingDust)
                    .help("Save these spots as a dust map for this camera, to remove the same dust from other photos")
                    .accessibilityLabel("Save the dust spots as a dust map")
                Spacer()
            }
            .controlSize(.small)

            let n = model.parameters.dust.count
            Text(n == 0 ? "No dust spots. Find Spots looks for sensor dust."
                 : "\(n) dust spot\(n == 1 ? "" : "s") · click a ring to remove one, click the image to add one")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.hasImage)
    }

    /// Sensitivity as the slider has it: a whole number, and a change
    /// re-detects while the tool is armed.
    private var sensitivity: Binding<Float> {
        Binding(get: { Float(model.dustSensitivity) },
                set: { value in
                    let sensitivity = Int(value.rounded())
                    guard sensitivity != model.dustSensitivity else { return }
                    model.dustSensitivity = sensitivity
                    model.redetectDustIfArmed()
                })
    }

    private var size: Binding<DustSpotSize> {
        Binding(get: { model.dustSize },
                set: { band in
                    guard band != model.dustSize else { return }
                    model.dustSize = band
                    model.redetectDustIfArmed()
                })
    }

    private func sliderRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
                           format: String, defaultValue: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: value, in: range, format: SliderValueFormat(printf: format), label: title)
            }
            ResettableSlider(value: value, in: range, label: title,
                             format: SliderValueFormat(printf: format)) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
        }
    }
}
