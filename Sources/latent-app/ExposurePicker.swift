import SwiftUI
import AppKit
import PixelEngine

// The Exposure eyedropper and Black Offset, under the Exposure slider.
//
// The eyedropper arms like the White Balance Selector (`ToneTool.exposure`):
// click, or drag a rectangle, over an area and Exposure is set so that
// area's scene-linear luminance before exposure lands on the target, 18%
// grey unless Option-click on the button chose another. One parameter
// change, so one undo step. The engine side is ExposurePicking.swift.

extension EditorModel {
    static let exposurePickTargetKey = "exposurePickerTarget"

    /// The eyedropper's target, remembered across launches.
    static var exposurePickTarget: ExposurePicking.Target {
        get {
            guard let data = UserDefaults.standard.data(forKey: exposurePickTargetKey),
                  let target = try? JSONDecoder().decode(ExposurePicking.Target.self, from: data) else { return .middleGrey }
            return target
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: exposurePickTargetKey)
            }
        }
    }

    /// Arm or put away the Exposure eyedropper.
    func toggleExposurePicker() {
        toneTool = toneTool == .exposure ? .none : .exposure
    }

    /// The press ended: measure the area between where it began and ended
    /// (a click reads a small square) and set Exposure from it.
    func exposurePickEnded() {
        guard let drag = exposurePickDrag else { return }
        exposurePickDrag = nil
        guard let session, let pipeline, let gpuContext, hasImage else { return }
        let a = sensorNormalized(drag.start), b = sensorNormalized(drag.end)
        let area = CGRect(x: CGFloat(min(a.x, b.x)), y: CGFloat(min(a.y, b.y)),
                          width: CGFloat(abs(a.x - b.x)), height: CGFloat(abs(a.y - b.y)))
        do {
            let analysis = try ExposurePicking.analysisLuminances(session: session, pipeline: pipeline,
                                                                  gpu: gpuContext, parameters: parameters)
            guard let patch = ExposurePicking.meanLuminance(in: area, width: analysis.width, height: analysis.height,
                                                            luminances: analysis.luminances) else {
                status = "Click on the photo to set the exposure from it."
                return
            }
            let target = Self.exposurePickTarget
            guard let ev = ExposurePicking.exposure(patch: patch, target: target.luminance(greyPoint: parameters.greyPoint)) else {
                status = "That area is too dark to measure. Pick something lighter."
                return
            }
            parameters.exposureEV = ev
            let limited = abs(ev) >= 5 ? " (the slider's limit)" : ""
            status = String(format: "Exposure set to %+.2f EV%@, bringing the picked area to %@.",
                            ev, limited, target.title)
            // Like the White Balance Selector, it puts itself away.
            toneTool = .none
        } catch {
            status = "Couldn't read the picked area: \(error.localizedDescription)"
        }
    }
}

/// Under the Exposure slider: the eyedropper (Option-click for its target)
/// and an Advanced disclosure holding Black Offset. Neither replaces a
/// control the panel already has.
struct ExposureToolsRow: View {
    @Bindable var model: EditorModel
    @State private var choosingTarget = false
    @State private var advancedExpanded = false
    @State private var target: ExposurePicking.Target = EditorModel.exposurePickTarget
    @State private var customPercent: Float = 18

    private var armed: Bool { model.toneTool == .exposure }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    ColourSliderRow(title: "Black Offset", value: model.parameterBinding(\.blackOffset),
                                    range: EditParameters.blackOffsetRange,
                                    format: SliderValueFormat(decimals: 3, signed: true),
                                    help: "Subtracts a little light everywhere, in linear light, right after Exposure: above zero deepens the blacks, below zero lifts them. Blacks still works as before on top.")
                        .padding(.top, 4)
                } label: {
                    Text("Advanced").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    if NSEvent.modifierFlags.contains(.option) {
                        target = EditorModel.exposurePickTarget
                        if case .custom(let v) = target { customPercent = v * 100 }
                        choosingTarget = true
                    } else {
                        model.toggleExposurePicker()
                    }
                } label: {
                    Image(systemName: "eyedropper")
                        .foregroundStyle(armed ? Color.accentColor : Color.primary)
                }
                .controlSize(.small)
                .accessibilityLabel("Exposure eyedropper")
                .accessibilityValue(armed ? "on, target \(target.title)" : "off, target \(target.title)")
                .accessibilityAction(named: "Choose target") { choosingTarget = true }
                .help("Exposure eyedropper: click or drag over an area to bring it to \(target.title). Option-click to choose the target.")
                .popover(isPresented: $choosingTarget, arrowEdge: .bottom) { targetPicker }
            }
        }
        .disabled(!model.hasImage)
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exposure Eyedropper Target").font(.headline)
            Picker("Target", selection: Binding(
                get: { target.kind },
                set: { kind in
                    switch kind {
                    case 0: target = .middleGrey
                    case 1: target = .displayHalf
                    default: target = .custom(customPercent / 100)
                    }
                    EditorModel.exposurePickTarget = target
                })) {
                Text("18% grey (scene)").tag(0)
                Text("50% of the display (Mid Grey)").tag(1)
                Text("Custom").tag(2)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if target.kind == 2 {
                HStack {
                    Text("Scene luminance").font(.caption)
                    SliderValueField(value: Binding(get: { customPercent }, set: { v in
                        customPercent = min(max(v, 0.5), 100)
                        target = .custom(customPercent / 100)
                        EditorModel.exposurePickTarget = target
                    }), in: 0.5...100, format: SliderValueFormat(decimals: 1, unit: "%"), label: "Custom target")
                }
            }
            Text("The picked area's light before Exposure is brought to this level.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
    }
}

private extension ExposurePicking.Target {
    var kind: Int {
        switch self {
        case .middleGrey: return 0
        case .displayHalf: return 1
        case .custom: return 2
        }
    }
}
