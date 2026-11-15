import SwiftUI
import PixelEngine

/// The selected mask's own tone equalizer (LocalToneEqualizer.swift): the
/// panel's nine band sliders in a compact strip, inside a group that starts
/// closed and opens once a band is moved, with a Reset. The bands read the
/// global tone equalizer's mask (its Masking tab), so each moves the same
/// tones as the panel's band of that stop, but only inside this mask.
struct MaskToneEqualizerControls: View {
    @Binding var local: LocalAdjustment
    @State private var open = false

    /// The strip's slider height: shorter than the panel's 120.
    static let bandHeight: CGFloat = 64

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { open || local.hasToneEqualizerBands }, set: { open = $0 })) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<ToneEqualizer.bandCount, id: \.self) { i in
                        ToneEqualizerBandSlider(value: band(i), zone: ToneEqualizer.zones[i], height: Self.bandHeight)
                            .frame(maxWidth: .infinity)
                    }
                }
                HStack {
                    Text("Reads the Tone Equalizer's mask; only this mask's area moves.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reset") { local.toneEqualizerBands = nil }
                        .controlSize(.small)
                        .disabled(!local.hasToneEqualizerBands)
                        .help("Every band of this mask's tone equalizer back to 0")
                        .accessibilityLabel("Reset the tone equalizer inside the mask")
                }
            }
            .padding(.top, 4)
        } label: { Text("Tone Equalizer").font(.caption.weight(.semibold)) }
        .accessibilityLabel("Tone Equalizer inside the mask")
    }

    /// One band, stored through `setToneEqualizerBand` so all-zero bands
    /// go back to nil and the edit stays as it was.
    private func band(_ i: Int) -> Binding<Float> {
        Binding(get: { local.toneEqualizerBand(i) }, set: { local.setToneEqualizerBand(i, to: $0) })
    }
}
