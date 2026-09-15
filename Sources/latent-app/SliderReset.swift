import SwiftUI
import AppKit

/// A slider that snaps to its default on double-click, optionally with a
/// number field beside it.
///
/// SwiftUI's Slider on macOS is an NSSlider underneath, and NSSlider runs
/// a private mouse-tracking loop from mouseDown, so SwiftUI gestures
/// layered on top never see the clicks. Going to AppKit directly is the
/// only reliable way: the subclass looks at the click count before
/// handing the event to the normal tracking.
///
/// `label` and `format` tell VoiceOver what the slider is and how to read
/// its value; without them it reads a number formatted from the range.
/// `accessibilityValue` overrides the reading for a slider whose position
/// isn't the value shown (temperature travels in mired, reads in Kelvin).
/// `showsField` puts a `SliderValueField` after the slider, for rows that
/// show the value there; rows with the value above the slider place a
/// `SliderValueField` themselves.
struct ResettableSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let label: String?
    let format: SliderValueFormat
    let showsField: Bool
    let accessibilityValue: String?
    let reset: () -> Void

    init(value: Binding<Float>, in range: ClosedRange<Float>, label: String? = nil,
         format: SliderValueFormat? = nil, showsField: Bool = false, accessibilityValue: String? = nil,
         reset: @escaping () -> Void) {
        _value = value
        self.range = range
        self.label = label
        self.format = format ?? .derived(from: range)
        self.showsField = showsField
        self.accessibilityValue = accessibilityValue
        self.reset = reset
    }

    var body: some View {
        if showsField {
            HStack(spacing: 6) {
                slider
                SliderValueField(value: $value, in: range, format: format, label: label)
            }
        } else {
            slider
        }
    }

    private var slider: some View {
        DoubleClickSliderView(value: $value, range: range, label: label,
                              valueText: accessibilityValue ?? format.text(value), reset: reset)
    }
}

/// How a slider's value reads as text: in the field, and to VoiceOver.
struct SliderValueFormat: Equatable, Sendable {
    /// Digits after the decimal point.
    var decimals: Int
    /// Whether positive values show a plus sign, for sliders centred on 0.
    var signed: Bool
    /// Written straight after the number, with its own spacing: " EV",
    /// " px", "°", "%".
    var unit: String
    /// Displayed number = value x scale (100 shows 0...1 as percent).
    var scale: Float

    init(decimals: Int = 2, signed: Bool = false, unit: String = "", scale: Float = 1) {
        self.decimals = max(0, min(decimals, 6))
        self.signed = signed
        self.unit = unit
        self.scale = scale == 0 ? 1 : scale
    }

    /// From a printf format like the rows already use: "%+.2f EV",
    /// "%.0f px", "%.2f°". Anything unrecognised gives two decimals.
    init(printf: String, scale: Float = 1) {
        guard let percent = printf.firstIndex(of: "%"),
              let f = printf[percent...].firstIndex(where: { $0 == "f" }) else {
            self.init(scale: scale)
            return
        }
        let spec = printf[printf.index(after: percent)..<f]
        var decimals = 6
        if let dot = spec.firstIndex(of: ".") {
            decimals = Int(spec[spec.index(after: dot)...]) ?? 0
        }
        let unit = String(printf[printf.index(after: f)...]).replacingOccurrences(of: "%%", with: "%")
        self.init(decimals: decimals, signed: spec.contains("+"), unit: unit, scale: scale)
    }

    /// A sensible reading for a slider nobody described: fewer decimals
    /// the wider the range, and a sign when it runs either side of 0.
    static func derived(from range: ClosedRange<Float>) -> SliderValueFormat {
        let span = range.upperBound - range.lowerBound
        let decimals = span >= 100 ? 0 : span >= 10 ? 1 : span >= 1 ? 2 : 3
        return SliderValueFormat(decimals: decimals, signed: range.lowerBound < 0 && range.upperBound > 0)
    }

    /// The number alone, as the field shows it.
    func number(_ value: Float) -> String {
        var shown = Double(value * scale)
        // No "-0.00": a value that rounds to zero reads as zero.
        if (shown * pow(10, Double(decimals))).rounded() == 0 { shown = 0 }
        return String(format: signed ? "%+.\(decimals)f" : "%.\(decimals)f", shown)
    }

    /// The number with its unit, for VoiceOver.
    func text(_ value: Float) -> String { number(value) + unit }

    /// The value typed as `text`, clamped to `range`, or nil when it isn't
    /// a number. The unit may be typed or left out, a comma works as the
    /// decimal point, and the typographic minus as a minus.
    func value(from text: String, in range: ClosedRange<Float>) -> Float? {
        var s = text.trimmingCharacters(in: .whitespaces)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespaces)
        if !trimmedUnit.isEmpty, s.lowercased().hasSuffix(trimmedUnit.lowercased()) {
            s.removeLast(trimmedUnit.count)
        }
        s = s.replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("+") { s.removeFirst() }
        guard let typed = Double(s), typed.isFinite else { return nil }
        return min(max(Float(typed) / scale, range.lowerBound), range.upperBound)
    }

    /// One step of the arrow keys: the last digit shown.
    var step: Float { Float(pow(10, -Double(decimals))) / scale }
}

/// The slider itself.
private struct DoubleClickSliderView: NSViewRepresentable {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let label: String?
    let valueText: String
    let reset: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> DoubleClickSlider {
        let slider = DoubleClickSlider()
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.doubleValue = Double(value)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.onDoubleClick = { context.coordinator.parent.reset() }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: DoubleClickSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        if abs(slider.doubleValue - Double(value)) > 1e-6 { slider.doubleValue = Double(value) }
        slider.isEnabled = context.environment.isEnabled
        if let label, slider.accessibilityLabel() != label { slider.setAccessibilityLabel(label) }
        if slider.accessibilityValueDescription() != valueText { slider.setAccessibilityValueDescription(valueText) }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: DoubleClickSliderView
        init(_ parent: DoubleClickSliderView) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) {
            parent.value = Float(sender.doubleValue)
        }
    }
}

final class DoubleClickSlider: NSSlider {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}

/// A slider's value as plain text that becomes a field when clicked.
///
/// Return or Tab applies what was typed, clamped to the range; Escape
/// puts the value back; the arrow keys step it by the last digit shown
/// (ten with Shift). Typed values go through the same binding as the
/// slider, so they land in the edit history the same way.
struct SliderValueField: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: SliderValueFormat
    let label: String?

    init(value: Binding<Float>, in range: ClosedRange<Float>, format: SliderValueFormat? = nil,
         label: String? = nil) {
        _value = value
        self.range = range
        self.format = format ?? .derived(from: range)
        self.label = label
    }

    var body: some View {
        HStack(spacing: 0) {
            NumberField(value: $value, range: range, format: format,
                        label: accessibilityName)
                .frame(width: fieldWidth)
            if !format.unit.trimmingCharacters(in: .whitespaces).isEmpty {
                // With its own spacing, so it reads as the old text did.
                Text(format.unit)
                    .font(.system(size: Self.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .help("Click to type a value")
    }

    static let fontSize: CGFloat = 10

    /// Wide enough for the longest value in the range, and a digit more.
    private var fieldWidth: CGFloat {
        let longest = max(format.number(range.lowerBound).count, format.number(range.upperBound).count)
        return CGFloat(longest + 1) * 6.5 + 6
    }

    private var accessibilityName: String {
        let unit = format.unit.trimmingCharacters(in: .whitespaces)
        let name = label ?? "Value"
        return unit.isEmpty ? name : "\(name) (\(unit))"
    }
}

private struct NumberField: NSViewRepresentable {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: SliderValueFormat
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: format.number(value))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .textBackgroundColor
        field.alignment = .right
        field.font = .monospacedSystemFont(ofSize: SliderValueField.fontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = context.environment.isEnabled
        if field.accessibilityLabel() != label { field.setAccessibilityLabel(label) }
        // Never overwrite what is being typed.
        if field.currentEditor() == nil {
            let shown = format.number(value)
            if field.stringValue != shown { field.stringValue = shown }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NumberField
        weak var field: NSTextField?
        private var cancelling = false

        init(_ parent: NumberField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field else { return }
            field.drawsBackground = true
            field.textColor = .labelColor
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field else { return }
            if !cancelling { commit(field.stringValue) }
            cancelling = false
            field.stringValue = parent.format.number(parent.value)
            field.drawsBackground = false
            field.textColor = .secondaryLabelColor
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                cancelling = true
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.moveUp(_:)): nudge(textView, by: 1); return true
            case #selector(NSResponder.moveDown(_:)): nudge(textView, by: -1); return true
            case #selector(NSResponder.moveUpAndModifySelection(_:)): nudge(textView, by: 10); return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)): nudge(textView, by: -10); return true
            default: return false
            }
        }

        /// Applies typed text. Text still showing the current value is left
        /// alone, so clicking in and out never rounds the value to the
        /// digits displayed.
        private func commit(_ text: String) {
            guard text != parent.format.number(parent.value),
                  let typed = parent.format.value(from: text, in: parent.range) else { return }
            if typed != parent.value { parent.value = typed }
        }

        private func nudge(_ textView: NSTextView, by steps: Float) {
            let format = parent.format, range = parent.range
            let start = format.value(from: textView.string, in: range) ?? parent.value
            let next = min(max(start + steps * format.step, range.lowerBound), range.upperBound)
            parent.value = next
            textView.string = format.number(next)
            textView.selectAll(nil)
        }
    }
}
