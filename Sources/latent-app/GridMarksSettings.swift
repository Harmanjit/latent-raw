import SwiftUI
import Catalog

/// View › Grid Marks, kept in the preferences. Always, the default, is the
/// grid as it has always looked.
@MainActor
final class GridMarksSettings: ObservableObject {
    static let shared = GridMarksSettings()
    static let defaultsKey = "latent.gridMarks"

    @Published var mode: GridMarksMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.defaultsKey) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = GridMarksMode(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .always
    }
}

/// The View › Grid Marks submenu.
struct GridMarksMenu: View {
    @ObservedObject private var settings = GridMarksSettings.shared

    var body: some View {
        Picker("Grid Marks", selection: $settings.mode) {
            ForEach(GridMarksMode.allCases, id: \.self) { mode in
                Text(Self.menuTitle(mode)).tag(mode)
            }
        }
        .pickerStyle(.menu)
    }

    static func menuTitle(_ mode: GridMarksMode) -> String {
        switch mode {
        case .always: "Always"
        case .onHover: "On Hover"
        case .minimal: "Minimal (Flag and Label)"
        case .extended: "Extended (with Exposure and ISO)"
        }
    }
}
