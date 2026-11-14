import SwiftUI
import AppKit
import ColorKit
import PixelEngine

/// The four margins, when they aren't locked together, in the chosen unit.
struct PrintMarginFields: View {
    @Binding var settings: PrintLayoutSettings

    var body: some View {
        let unit = settings.marginUnit ?? .automatic()
        LabeledContent("Margins") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    field("Top", \.top, unit: unit)
                    field("Bottom", \.bottom, unit: unit)
                }
                GridRow {
                    field("Left", \.left, unit: unit)
                    field("Right", \.right, unit: unit)
                }
            }
        }
    }

    private func field(_ title: String, _ side: WritableKeyPath<LayoutInsets, Double>, unit: PrintMarginUnit) -> some View {
        HStack(spacing: 4) {
            Text(title).frame(width: 46, alignment: .trailing).accessibilityHidden(true)
            TextField(title, value: Binding(
                get: { (settings.margins[keyPath: side] / unit.points * 100).rounded() / 100 },
                set: { value in
                    var margins = settings.margins
                    margins[keyPath: side] = min(max(value * unit.points, PrintLayoutSettings.marginRange.lowerBound),
                                                 PrintLayoutSettings.marginRange.upperBound)
                    settings.customMargins = margins
                }), format: .number.precision(.fractionLength(0...2)))
                .frame(width: 56)
                .accessibilityLabel("\(title) margin in \(unit.symbol)")
            Text(unit.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

/// Lock the four margins together, and the unit they're shown in.
struct PrintMarginOptions: View {
    @Binding var settings: PrintLayoutSettings

    var body: some View {
        HStack {
            Toggle("Same on all sides", isOn: Binding(
                get: { settings.marginsLocked },
                set: { locked in
                    if locked {
                        // The largest side, so nothing moves into the picture.
                        let m = settings.margins
                        settings.margin = (max(m.top, m.left, m.bottom, m.right) / 3).rounded() * 3
                        settings.customMargins = nil
                    } else {
                        settings.customMargins = LayoutInsets(all: settings.margin)
                    }
                }))
                .help("Off, each side of the paper gets its own margin")
            Picker("Units", selection: $settings.marginUnit) {
                Text("Automatic").tag(PrintMarginUnit?.none)
                ForEach(PrintMarginUnit.allCases) { Text($0.symbol).tag(PrintMarginUnit?.some($0)) }
            }
            .fixedSize()
            .accessibilityLabel("Margin units")
        }
    }
}

/// The printer or paper profile `.icc` prints into: Soft Proof's list of
/// installed and added profiles, and Add Profile… for another file. The
/// choice keeps a bookmark of its own, apart from Soft Proof's.
struct PrintProfilePicker: View {
    @Binding var settings: PrintLayoutSettings
    @ObservedObject private var library = ProofProfileLibrary.shared

    var body: some View {
        LabeledContent("Printer profile") {
            Menu(settings.printProfileName ?? "Choose…") {
                if !library.added.isEmpty {
                    ForEach(library.added) { profile in Button(profile.name) { choose(profile.url) } }
                    Divider()
                }
                ForEach(library.installed) { profile in Button(profile.name) { choose(profile.url) } }
                Divider()
                Button("Add Profile…") { addProfile() }
            }
            .fixedSize()
            .accessibilityLabel("Printer profile")
            .help("The printer and paper profile the photos are converted into, whatever Soft Proof shows")
        }
        .task { await library.loadInstalled() }
    }

    private func choose(_ url: URL) {
        guard let data = PrintProfileBookmarks.bookmark(for: url) else { return }
        settings.printProfileBookmark = data
        settings.printProfileName = url.deletingPathExtension().lastPathComponent
    }

    private func addProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "icc"), .init(filenameExtension: "icm")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a printer or paper ICC profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.add(url)
        choose(url)
    }
}

/// The print-only preset and output sharpening.
struct PrintExtrasSection: View {
    @Binding var settings: PrintLayoutSettings
    @ObservedObject private var catalog = PresetCatalog.shared

    var body: some View {
        LabeledContent("Preset") {
            PresetStylePicker(style: $settings.presetStyle, presets: catalog.presets, purpose: "print")
        }
        LabeledContent("Sharpening") {
            HStack {
                Picker("Sharpening", selection: Binding(
                    get: { settings.sharpening?.strength },
                    set: { strength in
                        settings.sharpening = strength.map {
                            OutputSharpening(medium: settings.sharpening?.medium ?? .glossy, strength: $0)
                        }
                    })) {
                    Text("None").tag(OutputSharpening.Strength?.none)
                    ForEach(OutputSharpening.Strength.allCases, id: \.self) {
                        Text($0.title).tag(OutputSharpening.Strength?.some($0))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Print sharpening")
                Picker("Paper", selection: Binding(
                    get: { settings.sharpening?.medium ?? .glossy },
                    set: { medium in settings.sharpening?.medium = medium })) {
                    Text(OutputSharpening.Medium.matte.title).tag(OutputSharpening.Medium.matte)
                    Text(OutputSharpening.Medium.glossy.title).tag(OutputSharpening.Medium.glossy)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(settings.sharpening == nil)
                .accessibilityLabel("Paper for sharpening")
            }
            .help("A final sharpen for the paper, at the printer's resolution, as Export's Output Sharpening. The photo's own edit is unchanged.")
        }
    }

    /// The panel's summary lines for these.
    static func summary(_ settings: PrintLayoutSettings) -> [(name: String, value: String)] {
        var lines: [(name: String, value: String)] = []
        if let style = settings.presetStyle {
            lines.append(("Preset", "\(style.presetName) (\(style.mode.title), \(String(format: "%.0f%%", style.amount * 100)))"))
        }
        if let sharpening = settings.sharpening {
            lines.append(("Sharpening", "\(sharpening.strength.title), \(sharpening.medium.title)"))
        }
        return lines
    }
}
