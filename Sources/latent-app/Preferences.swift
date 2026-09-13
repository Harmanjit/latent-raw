import SwiftUI
import AppKit
import Catalog
import MLKit

/// App-wide preferences, backed by UserDefaults, with the ⌘, window.
///
/// One shared object rather than scattered @AppStorage, so the few
/// places that need a value at runtime (the viewport surround, the
/// export sheet's defaults, the ML compute choice) read the same source
/// the window edits, and update live.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    enum Accent: String, CaseIterable, Identifiable {
        case system, blue, teal, green, amber, orange, red, pink, purple, graphite
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var color: Color? {
            switch self {
            case .system: nil
            case .blue: .blue
            case .teal: .teal
            case .green: .green
            case .amber: .yellow
            case .orange: .orange
            case .red: .red
            case .pink: .pink
            case .purple: .purple
            case .graphite: .gray
            }
        }
    }

    /// The grey around the image, as an sRGB level. Lightroom's default
    /// is a dark grey; some people judge shadows better on black, prints
    /// better on light grey.
    enum Surround: String, CaseIterable, Identifiable {
        case black, dark, medium, light, white
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var level: Double {
            switch self {
            case .black: 0.0
            case .dark: 0.12
            case .medium: 0.3
            case .light: 0.6
            case .white: 0.92
            }
        }
    }

    enum MLCompute: String, CaseIterable, Identifiable {
        case gpu, all, cpu
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gpu: "CPU and GPU (default)"
            case .all: "Allow Neural Engine (may hang on macOS 15.7)"
            case .cpu: "CPU only"
            }
        }
    }

    private let defaults = UserDefaults.standard

    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "latent.appearance"); applyAppearance() } }
    @Published var accent: Accent { didSet { defaults.set(accent.rawValue, forKey: "latent.accent") } }
    @Published var surround: Surround { didSet { defaults.set(surround.rawValue, forKey: "latent.surround") } }
    @Published var showRenderTimings: Bool { didSet { defaults.set(showRenderTimings, forKey: "latent.showRenderTimings") } }
    @Published var defaultSubfolderMode: SubfolderMode { didSet { defaults.set(defaultSubfolderMode.rawValue, forKey: "latent.defaultSubfolderMode") } }
    @Published var defaultExportFolder: URL? { didSet { defaults.set(defaultExportFolder, forKey: "latent.defaultExportFolder") } }
    @Published var mlCompute: MLCompute { didSet { defaults.set(mlCompute.rawValue, forKey: CoreMLStore.computePreferenceKey) } }

    private init() {
        appearance = Appearance(rawValue: defaults.string(forKey: "latent.appearance") ?? "") ?? .system
        accent = Accent(rawValue: defaults.string(forKey: "latent.accent") ?? "") ?? .system
        surround = Surround(rawValue: defaults.string(forKey: "latent.surround") ?? "") ?? .dark
        showRenderTimings = defaults.object(forKey: "latent.showRenderTimings") as? Bool ?? true
        defaultSubfolderMode = SubfolderMode(rawValue: defaults.string(forKey: "latent.defaultSubfolderMode") ?? "") ?? .ask
        defaultExportFolder = defaults.url(forKey: "latent.defaultExportFolder")
        mlCompute = MLCompute(rawValue: defaults.string(forKey: CoreMLStore.computePreferenceKey) ?? "") ?? .gpu
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    /// The surround in the drawable's linear encoding.
    var surroundLinear: Float { Float(pow(surround.level, 2.2)) }
    var surroundColor: Color { Color(white: surround.level) }
    var surroundNSColor: NSColor { NSColor(white: surround.level, alpha: 1) }
}

/// The Preferences window (⌘,).
struct PreferencesView: View {
    @ObservedObject var prefs = AppPreferences.shared

    var body: some View {
        TabView {
            appearanceTab.tabItem { Label("Appearance", systemImage: "paintpalette") }
            exportTab.tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            libraryTab.tabItem { Label("Library", systemImage: "photo.on.rectangle") }
            aiTab.tabItem { Label("AI", systemImage: "cpu") }
        }
        .frame(width: 520)
        .padding(20)
    }

    private var appearanceTab: some View {
        Form {
            Picker("Theme", selection: $prefs.appearance) {
                ForEach(AppPreferences.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Accent colour", selection: $prefs.accent) {
                ForEach(AppPreferences.Accent.allCases) { Text($0.title).tag($0) }
            }
            Picker("Image surround", selection: $prefs.surround) {
                ForEach(AppPreferences.Surround.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("A neutral grey next to the image keeps your eye honest about its shadows and highlights; black flatters dark tones, light grey predicts a print.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show render timings in the status bar", isOn: $prefs.showRenderTimings)
        }
        .formStyle(.grouped)
    }

    private var exportTab: some View {
        Form {
            HStack {
                Text("Default folder")
                Spacer()
                Text(prefs.defaultExportFolder?.path ?? "Ask each time")
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { prefs.defaultExportFolder = url }
                }
                if prefs.defaultExportFolder != nil {
                    Button("Clear") { prefs.defaultExportFolder = nil }
                }
            }
            Text("The export sheet starts here. Naming, format and size defaults are the last ones you used, and saved presets are in the sheet itself.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var libraryTab: some View {
        Form {
            Picker("Subfolders in a new catalog", selection: $prefs.defaultSubfolderMode) {
                Text("Ask").tag(SubfolderMode.ask)
                Text("Include").tag(SubfolderMode.included)
                Text("Keep separate").tag(SubfolderMode.independent)
            }
            Text("Applies when a folder is opened for the first time; each catalog remembers its own answer after that.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var aiTab: some View {
        Form {
            Picker("Core ML compute", selection: $prefs.mlCompute) {
                ForEach(AppPreferences.MLCompute.allCases) { Text($0.title).tag($0) }
            }
            Text("Takes effect the next time a model loads. The Neural Engine is fastest when it works, but its compiler hangs on some macOS 15 builds, which is why the default stays on the GPU.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
