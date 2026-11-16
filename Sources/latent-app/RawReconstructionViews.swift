import SwiftUI
import ColorKit
import PixelEngine

// The raw-decoding controls added beside existing panels: the camera's own
// white balance presets in the White Balance menu, Highlight
// Reconstruction's method, and the Lens Corrections switch for a DNG's
// embedded corrections. The engine side is CameraWhiteBalanceChoices.swift,
// HighlightInpaint.swift and DNGOpcodeCorrections.swift.

extension EditorModel {
    // MARK: - Camera white balance presets

    /// The open photo's camera presets; empty when its file records none.
    var cameraWhiteBalanceChoices: [CameraWhiteBalanceChoice] { session?.cameraWhiteBalanceChoices ?? [] }

    static let cameraWhiteBalanceTagPrefix = "camera:"

    /// The menu tag of the camera preset the current setting is, if any.
    var cameraWhiteBalanceTag: String? {
        let wb = parameter(\.whiteBalance)
        guard !wb.isAsShot else { return nil }
        return cameraWhiteBalanceChoices.first {
            abs($0.balance.temperature - wb.temperature) < 0.5 && abs($0.balance.tint - wb.tint) < 0.05
        }.map { Self.cameraWhiteBalanceTagPrefix + $0.id }
    }

    /// Sets the camera preset a menu tag names.
    func applyCameraWhiteBalance(tag: String) {
        guard hasImage, tag.hasPrefix(Self.cameraWhiteBalanceTagPrefix) else { return }
        let id = String(tag.dropFirst(Self.cameraWhiteBalanceTagPrefix.count))
        if let choice = cameraWhiteBalanceChoices.first(where: { $0.id == id }) {
            parameters.whiteBalance = choice.balance
        }
    }

    // MARK: - Embedded DNG corrections

    /// What the open DNG's opcodes correct, or nil when it has none Latent applies.
    var embeddedDNGCorrectionsDescription: String? {
        guard let corrections = session?.dngCorrections else { return nil }
        return corrections.summaryDescription
    }
}

/// Highlight Reconstruction's method: today's blend, or Inpaint Opposed.
struct HighlightMethodPicker: View {
    @Bindable var model: EditorModel

    var body: some View {
        Picker("Method", selection: model.parameterBinding(\.highlightMethod)) {
            ForEach(HighlightReconstructionMethod.allCases, id: \.self) { method in
                Text(method.displayName).tag(method)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .accessibilityLabel("Highlight reconstruction method")
        .help("Blend pulls clipped channels towards neutral. Inpaint Opposed rebuilds them from the other channels and the colour around the clipped areas, so blown skies and skin keep some colour.")
    }
}

/// The Lens Corrections panel's switch for a DNG's own corrections, shown
/// only for a DNG that carries some.
struct EmbeddedDNGCorrectionsToggle: View {
    @Bindable var model: EditorModel

    var body: some View {
        if let description = model.embeddedDNGCorrectionsDescription {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Apply embedded DNG corrections", isOn: model.parameterBinding(\.embeddedDNGCorrections))
                    .help("Applies the corrections the camera wrote into this DNG (\(description)). Its lens model replaces the profile while on; a flat-field reference, if the photo has one, replaces its shading map.")
                Text("This DNG corrects \(description).")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
