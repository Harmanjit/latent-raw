import SwiftUI
import AppKit
import ColorKit
import PixelEngine

/// The Soft Proof group: what to proof against, how (rendering intent,
/// paper and ink, black point compensation), which gamut warnings to paint
/// and in what colours, what Before shows, and a proof copy of the edit.
/// Everything but the proof copy is a view setting, never part of the edit.
struct SoftProofPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var profiles = ProofProfileLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Soft proof", isOn: $model.proofEnabled)
                .toggleStyle(.switch).controlSize(.small)
                .help("Show the photo as it will look in the target below (S)")
            targetMenu
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

            Toggle("Black Point Compensation", isOn: $model.proofOptions.blackPointCompensation)
                .toggleStyle(.checkbox).controlSize(.small)
                .help(model.proofTarget.isICC && model.proofOptions.intent == .relativeColorimetric
                      ? "Map the photo's black to the paper's deepest black so shadows keep their detail. Off shows them blocked up, as a conversion without it prints them"
                      : "Only for Relative Colorimetric with a printer or paper profile; Perceptual maps black itself")
                .disabled(!model.proofTarget.isICC || model.proofOptions.intent != .relativeColorimetric)

            warningRow("Destination gamut warning", isOn: $model.gamutWarning,
                       colour: colourBinding(\.destination),
                       help: "Paint the colours the target can't reproduce")
            warningRow("Monitor gamut warning", isOn: $model.monitorGamutWarning,
                       colour: colourBinding(\.monitor),
                       help: "Paint the colours of the proof this screen can't show")
            if model.gamutWarningColours != .standard {
                Button("Reset Warning Colours") { model.gamutWarningColours = .standard }
                    .controlSize(.small).buttonStyle(.link)
                    .help("Back to red for the destination and blue for the monitor, as in Lightroom")
            }

            Toggle("Before shows the unproofed edit", isOn: $model.proofBeforeShowsUnproofed)
                .toggleStyle(.checkbox).controlSize(.small)
                .help("While proofing, Before (\\) shows the edit as it is without the proof, to compare with the proof. Off, Before is the photo before editing")

            if let screen = EditorModel.monitorProfileDescription() {
                Text("Screen: \(screen)").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("The screen the editor is on and the colour profile macOS shows it with, which the monitor gamut warning reads")
            }

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
        .task { await profiles.loadInstalled() }
    }

    /// sRGB, Display P3, the profiles added, the Mac's installed profiles,
    /// and Add Profile… for one from anywhere else.
    private var targetMenu: some View {
        Menu {
            targetButton("sRGB", .sRGB)
            targetButton("Display P3", .displayP3)
            if !profiles.added.isEmpty {
                Divider()
                ForEach(profiles.added) { targetButton($0.name, .icc($0.url)) }
            }
            if !profiles.installed.isEmpty {
                Menu("Installed Profiles") {
                    ForEach(profiles.installed) { targetButton($0.name, .icc($0.url)) }
                }
            }
            Divider()
            Button("Add Profile…") { model.chooseProofProfile() }
            if !profiles.added.isEmpty {
                Menu("Remove from Menu") {
                    ForEach(profiles.added) { profile in
                        Button(profile.name) { profiles.remove(profile) }
                    }
                }
            }
        } label: {
            Text(model.proofTarget.displayName)
        }
        .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
        .accessibilityLabel("Soft proof target")
        .accessibilityValue(model.proofTarget.displayName)
    }

    private func targetButton(_ title: String, _ target: SoftProofTarget) -> some View {
        Button {
            model.selectProofTarget(target)
        } label: {
            if model.proofTarget == target { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    /// A warning's checkbox with the colour it paints in.
    private func warningRow(_ title: String, isOn: Binding<Bool>, colour: Binding<Color>, help: String) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox).controlSize(.small)
            Spacer()
            ColorPicker("\(title) colour", selection: colour, supportsOpacity: false)
                .labelsHidden().controlSize(.small)
        }
        .help(help)
    }

    /// One warning colour as a colour well edits it, in sRGB.
    private func colourBinding(_ key: WritableKeyPath<GamutWarningColours, SIMD3<Float>>) -> Binding<Color> {
        Binding(
            get: {
                let c = model.gamutWarningColours[keyPath: key]
                return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
            },
            set: { colour in
                guard let ns = NSColor(colour).usingColorSpace(.sRGB) else { return }
                model.gamutWarningColours[keyPath: key] = SIMD3(Float(ns.redComponent), Float(ns.greenComponent),
                                                                Float(ns.blueComponent))
            })
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
