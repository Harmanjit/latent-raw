import SwiftUI
import ColorKit
import PixelEngine

/// The Soft Proof group: what to proof against, how (rendering intent,
/// paper and ink), which gamut warnings to paint, and a proof copy of the
/// edit. Everything but the proof copy is a view setting, never part of
/// the edit.
struct SoftProofPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Soft proof", isOn: $model.proofEnabled)
                .toggleStyle(.switch).controlSize(.small)
                .help("Show the photo as it will look in the target below")
            Picker("Soft proof target", selection: Binding(
                get: { model.proofTarget == .sRGB ? 0 : model.proofTarget == .displayP3 ? 1 : 2 },
                set: { v in
                    if v == 0 { model.proofTarget = .sRGB }
                    else if v == 1 { model.proofTarget = .displayP3 }
                    else { model.chooseProofProfile() }
                })) {
                Text("sRGB").tag(0)
                Text("Display P3").tag(1)
                Text(model.proofTarget.isICC ? model.proofTarget.displayName + "…" : "ICC profile…").tag(2)
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.small)
            .help("The colour space, printer or paper profile to proof against")

            HStack {
                Text("Intent").font(.subheadline).accessibilityHidden(true)
                Spacer()
                Picker("Rendering intent", selection: $model.proofOptions.intent) {
                    ForEach(RenderingIntent.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                .accessibilityLabel("Rendering intent")
            }
            .help(model.proofTarget.isICC ? model.proofOptions.intent.help
                  : "sRGB and Display P3 clip out-of-gamut colours the same way with either intent")
            .disabled(!model.proofTarget.isICC)

            Toggle("Simulate Paper & Ink", isOn: $model.proofOptions.simulatePaperAndInk)
                .toggleStyle(.checkbox).controlSize(.small)
                .help(model.proofTarget.isICC
                      ? "Show the paper's white and the ink's black as they really are: duller, as a print looks beside a screen"
                      : "Only for printer and paper profiles")
                .disabled(!model.proofTarget.isICC)

            Toggle("Destination gamut warning (red)", isOn: $model.gamutWarning)
                .toggleStyle(.checkbox).controlSize(.small)
                .help("Paint red the colours the target can't reproduce")
            Toggle("Monitor gamut warning (blue)", isOn: $model.monitorGamutWarning)
                .toggleStyle(.checkbox).controlSize(.small)
                .help("Paint blue the colours of the proof this screen can't show")

            if !model.proofStatus.isEmpty {
                Text(model.proofStatus).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(model.hasProofCopy ? "Update Proof Copy" : "Create Proof Copy") { model.createProofCopy() }
                .controlSize(.small)
                .disabled(!model.proofEnabled)
                .help("Keep the edit as it is now as the snapshot “\(EditorModel.proofCopyName(for: model.proofTarget))”, the version adjusted for this target")
                .accessibilityLabel(model.hasProofCopy ? "Update proof copy" : "Create proof copy")

            Text("Shows what the file or print will look like in the target's gamut. HDR headroom is off while proofing.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!model.hasImage)
    }
}

/// HDR Limit: the ceiling of this photo's HDR rendition, in stops above
/// SDR white. Part of the edit, so it is undoable and copied with Tone.
struct HDRLimitSlider: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let format = "%.1f stops"
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("HDR Limit").font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: $model.parameters.hdrLimitStops, in: HDRLimit.range,
                                 format: SliderValueFormat(printf: format), label: "HDR Limit")
            }
            ResettableSlider(value: $model.parameters.hdrLimitStops, in: HDRLimit.range, label: "HDR Limit",
                             format: SliderValueFormat(printf: format)) {
                model.parameters.hdrLimitStops = HDRLimit.defaultStops
            }
            .help("How far above white this photo's highlights may reach on an HDR screen and in a gain-map export. Double-click to reset")
        }
        .disabled(!model.hasImage)
    }
}
