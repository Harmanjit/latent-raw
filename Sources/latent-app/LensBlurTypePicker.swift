import SwiftUI
import PixelEngine

/// Lens Blur's blur type (LensBlurTypes.swift), under Amount: Bokeh (the
/// depth-driven disc, as before), Gaussian or Motion, and Motion's angle.
/// Amount is the Gaussian's radius and the streak's length. Gaussian and
/// Motion keep the focus range sharp over a depth map, and blur the whole
/// frame evenly until one exists.
struct LensBlurTypePicker: View {
    @ObservedObject var model: EditorModel

    private var blur: LensBlur { model.parameters.lensBlur }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Type").font(.subheadline).accessibilityHidden(true)
                Spacer()
                Picker("Blur type", selection: Binding(
                    get: { blur.effectiveBlurType },
                    set: { model.parameters.lensBlur.blurType = $0 == .bokeh ? nil : $0 })) {
                    ForEach(LensBlur.BlurType.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Bokeh draws discs sized by depth; Gaussian is a plain softening; Motion streaks along an angle. Amount sets the Gaussian's radius and the streak's length")
                .accessibilityLabel("Blur type")
            }
            .controlSize(.small)
            .disabled(!blur.isActive)

            if blur.effectiveBlurType == .motion {
                DetailSliderRow(title: "Angle", value: Binding(
                    get: { blur.effectiveMotionAngle },
                    set: { model.parameters.lensBlur.motionAngle = $0 == 0 ? nil : $0 }),
                    range: 0...179, format: "%.0f°",
                    help: "The direction of the streak: 0° is horizontal, 90° vertical.",
                    label: "Motion angle")
                    .controlSize(.small)
                    .disabled(!blur.isActive)
            }
            if blur.effectiveBlurType != .bokeh {
                Text("Without a depth map the whole frame is blurred; with one, the focus range stays sharp.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
