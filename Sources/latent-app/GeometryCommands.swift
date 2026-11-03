import SwiftUI
import PixelEngine

/// Develop › Transform and Photo › Reset to Camera Orientation: the
/// geometry commands, under one `KeyCommand` case so the tables they pass
/// through (menus, shortcuts, enabling) each gain one line.
enum GeometryCommand: Equatable {
    /// O and ⇧O while cropping: the next composition guide, and the next
    /// way round for the spiral and the triangle.
    case cycleCropGuide, rotateCropGuide
    case autoStraighten
    case flipHorizontal, flipVertical
    /// An Upright mode, or nil for Off.
    case upright(UprightCorrection.Mode?)
    /// The selection's own quarter turns taken away, back to what the
    /// camera recorded.
    case resetOrientation
}

extension CommandState {
    func isEnabled(_ command: GeometryCommand) -> Bool {
        switch command {
        case .cycleCropGuide, .rotateCropGuide: mode == .develop && hasImage && cropToolActive
        case .autoStraighten, .flipHorizontal, .flipVertical, .upright: mode == .develop && hasImage
        case .resetOrientation: hasSelection
        }
    }
}

extension EditorModel {
    /// The geometry commands that act on the open image alone.
    func perform(_ command: GeometryCommand) {
        switch command {
        case .cycleCropGuide: CropToolPreferences.cycleGuide()
        case .rotateCropGuide: CropToolPreferences.rotateGuide()
        case .autoStraighten: autoStraighten()
        case .flipHorizontal: flip(horizontal: true)
        case .flipVertical: flip(horizontal: false)
        case .upright(let mode): setUpright(mode)
        case .resetOrientation: break   // the Library's: ContentView sends it there
        }
    }
}

/// Develop › Transform.
struct TransformMenu: View {
    let item: (String, KeyCommand) -> AnyView

    var body: some View {
        Menu("Transform") {
            item("Auto Straighten", .geometry(.autoStraighten))
            item("Flip Horizontal", .geometry(.flipHorizontal))
            item("Flip Vertical", .geometry(.flipVertical))
            Divider()
            item("Upright Off", .geometry(.upright(nil)))
            ForEach(UprightCorrection.Mode.allCases) { mode in
                item("Upright \(mode.title)", .geometry(.upright(mode)))
            }
            Divider()
            item("Cycle Crop Guide Overlay", .geometry(.cycleCropGuide))
            item("Rotate Crop Guide Overlay", .geometry(.rotateCropGuide))
        }
    }
}
