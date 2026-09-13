import SwiftUI
import AppKit

/// A slider that snaps to its default on double-click.
///
/// SwiftUI's Slider on macOS is an NSSlider underneath, and NSSlider runs
/// a private mouse-tracking loop from mouseDown, so SwiftUI gestures
/// layered on top never see the clicks. Going to AppKit directly is the
/// only reliable way: the subclass looks at the click count before
/// handing the event to the normal tracking.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let reset: () -> Void

    init(value: Binding<Float>, in range: ClosedRange<Float>, reset: @escaping () -> Void) {
        _value = value
        self.range = range
        self.reset = reset
    }

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
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(_ parent: ResettableSlider) { self.parent = parent }
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
