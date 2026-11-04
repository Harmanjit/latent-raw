import SwiftUI
import AppKit
import Catalog

extension ColorLabel {
    /// The system's own colours, so a label looks like the Finder tag of
    /// the same name and follows Increase Contrast and dark mode.
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// The key that sets it, for tooltips: "6", or nil for purple.
    var keyHint: String? {
        Shortcuts.shortcut(for: .label(self))?.glyphs
    }
}

extension SpokenText {
    /// "red label", "label Approved", or "" for none: what VoiceOver adds
    /// to an image's description.
    static func label(_ stored: String?) -> String {
        guard let text = stored?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return "" }
        if let color = ColorLabel(xmpLabel: text) { return "\(color.title.lowercased()) label" }
        return "label \(text)"
    }
}

/// The dot a grid cell shows for its colour label, left of the stars. A
/// custom label (one another application named) is a hollow ring, as a
/// Finder tag without a colour is.
final class LabelDotView: NSView {
    var label: String? {
        didSet { if label != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let text = label, !text.isEmpty else { return }
        let side = min(bounds.width, bounds.height)
        let rect = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        if let color = ColorLabel(xmpLabel: text) {
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

/// Five coloured dots and a clear button, for the Library panel: the
/// visible, clickable version of keys 6 to 9. Clicking the label a photo
/// already has takes it off.
struct ColorLabelPicker: View {
    /// The primary image's stored label.
    let current: String?
    let onChoose: (ColorLabel?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                let isOn = ColorLabel(xmpLabel: current) == label
                Button {
                    onChoose(label)
                } label: {
                    Circle()
                        .fill(label.color)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(isOn ? 0.9 : 0), lineWidth: 2)
                                    .frame(width: 16, height: 16))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(for: label, isOn: isOn))
                .accessibilityLabel("\(label.title) label")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            if let current, !current.isEmpty, ColorLabel(xmpLabel: current) == nil {
                Text(current)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("A label another application gave this photo")
            }
            Spacer(minLength: 0)
            Button {
                onChoose(nil)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(current?.isEmpty ?? true)
            .help("Remove the label")
            .accessibilityLabel("Remove label")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Colour label")
    }

    private func help(for label: ColorLabel, isOn: Bool) -> String {
        let key = label.keyHint.map { " (\($0))" } ?? ""
        return isOn ? "Remove the \(label.title.lowercased()) label\(key)" : "\(label.title) label\(key)"
    }
}

/// The filter bar's label menu: any number of labels, plus No Label and
/// Custom Label; an image passes with any one of those chosen.
struct LabelFilterMenu: View {
    @Binding var selection: Set<LabelFilterChoice>

    var body: some View {
        Menu {
            Button("Any") { selection = [] }
            Divider()
            ForEach(LabelFilterChoice.all, id: \.self) { choice in
                Button {
                    if selection.contains(choice) { selection.remove(choice) } else { selection.insert(choice) }
                } label: {
                    if selection.contains(choice) {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            Text(summary)
                .lineLimit(1)
                .frame(maxWidth: 140)
        }
        .help("Show only images with these colour labels")
        .accessibilityLabel("Label")
        .accessibilityValue(spokenSelection)
    }

    /// "Label", "Red", "Red, Blue", "3 labels".
    private var summary: String {
        let chosen = LabelFilterChoice.all.filter(selection.contains)
        switch chosen.count {
        case 0: return "Label"
        case 1, 2: return chosen.map(\.title).joined(separator: ", ")
        default: return "\(chosen.count) labels"
        }
    }

    private var spokenSelection: String {
        selection.isEmpty ? "Any"
            : LabelFilterChoice.all.filter(selection.contains).map(\.title).joined(separator: ", ")
    }
}
