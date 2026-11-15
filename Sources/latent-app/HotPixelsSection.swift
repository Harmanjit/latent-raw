import SwiftUI
import PixelEngine
import RawCore

/// Detail › Hot Pixels (docs/wiki/Develop.md, "Hot Pixels"): a switch,
/// which pixels count, the threshold, and how many photosites the render
/// replaced, like Sensor Dust's status line. Only for a raw: a JPEG, TIFF
/// or merged DNG has no sensor mosaic left to clean.
struct HotPixelsSection: View {
    @Bindable var model: EditorModel

    /// Whether the open image has a Bayer mosaic to test.
    private var hasMosaic: Bool { model.session?.sourceKind == .bayer }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSubheading(title: "Hot Pixels")
            Toggle("Remove hot pixels", isOn: Binding(
                get: { model.parameter(\.hotPixels) != nil },
                set: { model.parameters.hotPixels = $0 ? (model.parameters.hotPixels ?? HotPixelRemoval()) : nil }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Replaces stuck and hot photosites, the single bright red, green or blue dots of long exposures, with the median of their neighbours, before demosaicing")
            if let removal = model.parameter(\.hotPixels) {
                Picker("Hot pixel mode", selection: Binding(
                    get: { removal.mode },
                    set: { model.parameters.hotPixels?.mode = $0 })) {
                    ForEach(HotPixelRemoval.Mode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .help("Stuck Pixels Only replaces a photosite brighter than all of its neighbours; Also Dim Outliers also brings clusters of warm pixels down to their neighbours")
                .accessibilityLabel("Hot pixel mode")
                DetailSliderRow(title: "Threshold", value: Binding(
                    get: { model.parameters.hotPixels?.threshold ?? HotPixelRemoval.defaultThreshold },
                    set: { model.parameters.hotPixels?.threshold = $0 }),
                    range: 0...100, format: "%.0f", defaultValue: HotPixelRemoval.defaultThreshold,
                    help: "How much brighter than its neighbours a photosite must be to be replaced. Lower finds more.",
                    label: "Hot pixel threshold")
                Text(status(for: removal))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!hasMosaic)
    }

    private func status(for removal: HotPixelRemoval) -> String {
        guard let fixed = model.session?.hotPixelsFixed(for: removal) else { return "Counting…" }
        return fixed == 1 ? "1 pixel fixed" : "\(fixed.formatted()) pixels fixed"
    }
}
