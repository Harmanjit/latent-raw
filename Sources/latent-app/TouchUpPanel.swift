import SwiftUI
import PixelEngine

/// Touch-up (docs/Retouch.md §7), the content of `DisclosureGroup("Touch-up")`
/// after Sensor Dust: Find Faces, a row per face, the three sliders,
/// blemishes and the skin mask. Everything runs on this Mac; the footnote
/// says so where the button is.
struct TouchUpSection: View {
    @ObservedObject var model: EditorModel

    private var faces: [TouchUpFace] { model.parameters.touchUp.faces }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.touchUpToolActive) {
                    Text(model.touchUpToolActive ? "Touch-up: on" : "Touch-up…")
                }
                .toggleStyle(.button)
                .help("Show the faces and the blemish rings; click a ring to keep that spot, click skin to add one")
                Button {
                    model.findFaces()
                } label: {
                    if model.findingFaces {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Find Faces")
                    }
                }
                .disabled(model.findingFaces || model.findingBlemishes)
                .help("Find faces on this Mac. Nothing is sent anywhere")
                .accessibilityLabel("Find faces")
                .accessibilityValue(model.findingFaces ? "Looking for faces" : model.touchUpStatus)
                Spacer()
            }
            .controlSize(.small)

            if !model.touchUpStatus.isEmpty {
                Text(model.touchUpStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            ForEach(Array(faces.enumerated()), id: \.element.id) { index, face in
                faceRow(index: index, face: face)
            }

            row("Skin Smoothing", value: $model.parameters.touchUp.skinSmoothing,
                hint: "Softens the skin's fine texture on the enabled faces")
            row("Teeth Whitening", value: $model.parameters.touchUp.teethWhitening,
                hint: "Takes the yellow out of the teeth")
            row("Brighten Eyes", value: $model.parameters.touchUp.eyes,
                hint: "Lifts the whites and the irises")

            HStack(spacing: 8) {
                Toggle("Remove blemishes", isOn: $model.parameters.touchUp.blemishRemoval)
                    .help("Heal the blemishes found; off keeps the list without healing")
                    .accessibilityHint("Heals the blemishes Find Blemishes found")
                Button {
                    model.findBlemishes()
                } label: {
                    if model.findingBlemishes {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Find Blemishes")
                    }
                }
                .disabled(model.findingBlemishes || model.findingFaces || model.parameters.touchUp.enabledFaceIDs.isEmpty)
                .help("Look for spots on the enabled faces' skin on this Mac and heal each one; replaces the blemishes found last time; needs an enabled face")
                .accessibilityLabel("Find blemishes")
                .accessibilityValue(model.findingBlemishes ? "Looking for blemishes" : "")
                Spacer()
            }
            .controlSize(.small)

            HStack {
                let n = model.parameters.touchUp.blemishes.count
                Text(n == 0 ? "No blemishes. Find Blemishes looks for spots on the skin." : SpokenText.blemishCount(n))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if n > 0 {
                    Button("Clear") { model.clearBlemishes() }
                        .controlSize(.mini)
                        .help("Remove every blemish patch")
                        .accessibilityLabel("Clear all blemishes")
                }
            }

            Toggle("Show Skin Mask", isOn: $model.showSkinMask)
                .disabled(!model.parameters.touchUp.wantsMasks)
                .help("Tint the skin the sliders work on; needs an enabled face and a slider above 0")
                .accessibilityHint("Tints the skin the sliders work on")
                .controlSize(.small)

            Text("Find Faces looks for faces on this Mac. Nothing is sent anywhere.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.hasImage)
    }

    /// One face: its thumbnail and a switch, numbered left to right.
    private func faceRow(index: Int, face: TouchUpFace) -> some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail = model.faceThumbnails[face.id] {
                    Image(decorative: thumbnail, scale: 2)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "person.crop.square")
                        .resizable()
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
            Toggle("Face \(index + 1)", isOn: Binding(
                get: { model.parameters.touchUp.faces.first { $0.id == face.id }?.enabled ?? false },
                set: { on in
                    if let i = model.parameters.touchUp.faces.firstIndex(where: { $0.id == face.id }) {
                        model.parameters.touchUp.faces[i].enabled = on
                    }
                }))
                .help("Retouch this face")
                .accessibilityHint("Retouches this face")
            Spacer()
        }
        .controlSize(.small)
    }

    /// A 0…100 slider with a typed value, as the other panels' rows.
    private func row(_ title: String, value: Binding<Float>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: value, in: 0...100, format: SliderValueFormat(printf: "%.0f"), label: title)
            }
            ResettableSlider(value: value, in: 0...100, label: title,
                             format: SliderValueFormat(printf: "%.0f")) { value.wrappedValue = 0 }
                .help("Double-click to reset")
                .accessibilityHint(hint)
        }
        .disabled(faces.isEmpty)
    }
}
