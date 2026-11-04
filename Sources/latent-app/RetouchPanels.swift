import SwiftUI
import PixelEngine

/// Spot / Brush for the spot removal tool, under Spot Removal.
struct HealShapePicker: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Shape").font(.subheadline).accessibilityHidden(true)
            Picker("Spot removal shape", selection: $model.healShape) {
                Text("Spot").tag(HealShape.spot)
                Text("Brush").tag(HealShape.brush)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .help("Spot: click a blemish. Brush: paint along a wire, hair or dust streak; its source is placed beside it, drag the dot to move it")
            .accessibilityHint("Brush paints a stroke along a long blemish")
            Spacer()
        }
        .controlSize(.small)
        .disabled(!model.hasImage)
    }
}

/// Red-eye removal, under Spot Removal. Y arms the tool; Auto finds eyes.
struct RedEyeSection: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.redEyeToolActive) {
                    Text(model.redEyeToolActive ? "Red-Eye: on" : "Red-Eye…")
                }
                .toggleStyle(.button)
                .help("Arm the tool, then click a red pupil; drag to size the circle, drag its rim to resize it (Y)")
                Button {
                    model.redEyeToolActive = true
                    model.autoDetectRedEyes()
                } label: {
                    if model.detectingRedEyes {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Auto")
                    }
                }
                .disabled(model.detectingRedEyes)
                .help("Find faces on this Mac and fix the pupils that are red")
                .accessibilityLabel("Auto red-eye")
                .accessibilityValue(model.detectingRedEyes ? "Looking for red eyes" : "")
                Spacer()
                Button("Delete") { model.deleteSelectedRedEye() }
                    .disabled(model.selectedRedEye == nil)
                    .help("Remove the selected spot (⌫)")
                    .accessibilityLabel("Delete red-eye spot")
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Picker("Eye type", selection: Binding(get: { model.activeRedEyeKind },
                                                      set: { model.activeRedEyeKind = $0 })) {
                    Text("Red Eye").tag(RedEyeSpot.Kind.human)
                    Text("Pet Eye").tag(RedEyeSpot.Kind.pet)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Red Eye fixes a person's flash-red pupil. Pet Eye replaces an animal's glowing green, yellow or white pupil with a dark one")
                .accessibilityLabel("Eye type")
                Spacer()
                if model.activeRedEyeKind == .pet {
                    Toggle("Add Catchlight", isOn: Binding(get: { model.activePetEyeCatchlight },
                                                           set: { model.activePetEyeCatchlight = $0 }))
                        .toggleStyle(.checkbox)
                        .help("Adds a small highlight to the dark pupil, up and to the left, so the eye looks alive")
                }
            }
            .controlSize(.small)

            row("Pupil Size", value: Binding(get: { model.activeRedEyeRadiusPixels },
                                             set: { model.activeRedEyeRadiusPixels = $0 }),
                range: 2...400, format: "%.0f px", defaultValue: model.redEyeDefaultRadiusPixels)
            row("Darken", value: Binding(get: { model.activeRedEyeStrength },
                                         set: { model.activeRedEyeStrength = $0 }),
                range: 0...1, format: "%.2f", defaultValue: 1)
                .disabled(model.selectedRedEye == nil)

            HStack {
                let n = model.parameters.redEyes.count
                Text(n == 0 ? "No red-eye spots. Click a red pupil, or Auto; for a pet, choose Pet Eye and circle its pupil."
                     : "\(n) red-eye spot\(n == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if n > 0 {
                    Button("Clear all") { model.clearRedEyes() }
                        .controlSize(.mini)
                        .accessibilityLabel("Clear all red-eye spots")
                }
            }
        }
        .disabled(!model.hasImage)
    }

    private func row(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
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

extension EditorModel {
    /// The default pupil circle, in sensor pixels.
    var redEyeDefaultRadiusPixels: Float {
        RedEyeSpot.defaultRadius * Float(min(sensorSize.width, sensorSize.height))
    }
}
