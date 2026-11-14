import SwiftUI
import AppKit
import PixelEngine

/// The viewing aids' commands (View, Develop and Help menus), under one
/// `KeyCommand` case so the tables they pass through (menus, enabling,
/// perform, the keymap) each gain one line, as `ViewCommand` does.
enum ViewingCommand: Equatable {
    /// View › Focus Peaking, Show Raw Clipping, Colour Assessment and High
    /// Quality Preview.
    case toggleFocusPeaking, toggleRawClipping, toggleColourAssessment, toggleHighQualityPreview
    /// Develop › Straighten: the straighten angle moved by this many tenths
    /// of a degree, one undo step each.
    case straighten(tenths: Int)
    /// Develop › Focus Exposure: the Tone panel opened and its Exposure
    /// value ready for typing.
    case focusExposure
    /// Help › Show Shortcuts Overlay, and Show Welcome.
    case toggleShortcutsOverlay, showWelcome
}

/// What the menus need of the viewing state, for their ticks.
struct ViewingCommandState: Equatable {
    var focusPeaking = false
    var rawClipping = false
    var colourAssessment = false
    var highQualityPreview = false
    var shortcutsOverlay = false

    init() {}

    @MainActor
    init(_ settings: ViewingSettings) {
        focusPeaking = settings.focusPeaking
        rawClipping = settings.rawClipping
        colourAssessment = settings.colourAssessment
        highQualityPreview = settings.highQualityPreview
        shortcutsOverlay = settings.shortcutsOverlayShown
    }
}

extension CommandState {
    func isEnabled(_ command: ViewingCommand) -> Bool {
        switch command {
        // View settings, which can be set before an image is open.
        case .toggleFocusPeaking, .toggleColourAssessment, .toggleHighQualityPreview,
             .toggleShortcutsOverlay, .showWelcome: true
        // On Develop's image, as the clipping overlay (J) is; turning raw
        // clipping off is always allowed.
        case .toggleRawClipping: (mode == .develop && hasImage) || viewing.rawClipping
        case .straighten, .focusExposure: mode == .develop && hasImage
        }
    }
}

/// Runs the viewing commands for ContentView.
@MainActor
enum ViewingCommands {
    /// `editor` is Develop's model; `expandTone` opens the Tone panel,
    /// whose state ContentView keeps.
    static func perform(_ command: ViewingCommand, editor: EditorModel,
                        settings: ViewingSettings = .shared, expandTone: () -> Void) {
        switch command {
        case .toggleFocusPeaking:
            settings.focusPeaking.toggle()
        case .toggleRawClipping:
            settings.rawClipping.toggle()
            settings.setPrimaryEditor(editor)
            if editor.hasImage { editor.rerender() }
        case .toggleColourAssessment:
            settings.colourAssessment.toggle()
        case .toggleHighQualityPreview:
            settings.highQualityPreview.toggle()
            settings.setPrimaryEditor(editor)
            editor.highQualityPreviewSettingChanged()
        case .straighten(let tenths):
            editor.nudgeStraighten(by: Float(tenths) / 10)
        case .focusExposure:
            expandTone()
            ExposureFieldFocus.focusSoon()
        case .toggleShortcutsOverlay:
            settings.shortcutsOverlayShown.toggle()
        case .showWelcome:
            settings.welcomeShown = true
        }
    }
}

/// Develop › Focus Exposure: puts the keyboard in the Tone panel's
/// Exposure value, as clicking it would. The field is found by the name
/// VoiceOver reads for it, the topmost of that name in the window (the
/// Tone panel sits above the masks, whose own Exposure shares the name).
@MainActor
enum ExposureFieldFocus {
    static let fieldName = "Exposure (EV)"

    /// A moment later, so a panel that was just opened has laid out.
    static func focusSoon(in window: NSWindow? = nil) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow,
                  let field = field(in: window) else { return }
            field.scrollToVisible(field.bounds)
            window.makeFirstResponder(field)
        }
    }

    static func field(in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        return fields(named: fieldName, under: root)
            .max { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }
    }

    static func fields(named name: String, under view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable, field.accessibilityLabel() == name, !field.isHiddenOrHasHiddenAncestor {
            found.append(field)
        }
        for subview in view.subviews { found += fields(named: name, under: subview) }
        return found
    }
}

// MARK: - Menus

/// View › Focus Peaking, Show Raw Clipping, Colour Assessment and High
/// Quality Preview.
struct ViewingMenuItems: View {
    let state: ViewingCommandState
    let toggle: (String, KeyCommand, Bool) -> AnyView

    var body: some View {
        toggle("Focus Peaking", .viewing(.toggleFocusPeaking), state.focusPeaking)
        toggle("Show Raw Clipping", .viewing(.toggleRawClipping), state.rawClipping)
        toggle("Colour Assessment", .viewing(.toggleColourAssessment), state.colourAssessment)
        toggle("High Quality Preview", .viewing(.toggleHighQualityPreview), state.highQualityPreview)
    }
}

/// Develop › Straighten, and Focus Exposure.
struct StraightenMenuItems: View {
    let item: (String, KeyCommand) -> AnyView

    var body: some View {
        Menu("Straighten") {
            item("Straighten −0.1°", .viewing(.straighten(tenths: -1)))
            item("Straighten +0.1°", .viewing(.straighten(tenths: 1)))
            item("Straighten −1°", .viewing(.straighten(tenths: -10)))
            item("Straighten +1°", .viewing(.straighten(tenths: 10)))
        }
        item("Focus Exposure", .viewing(.focusExposure))
    }
}

/// Help › Show Shortcuts Overlay and Show Welcome.
struct ViewingHelpMenuItems: View {
    let state: ViewingCommandState
    let item: (String, KeyCommand) -> AnyView
    let toggle: (String, KeyCommand, Bool) -> AnyView

    var body: some View {
        toggle("Show Shortcuts Overlay", .viewing(.toggleShortcutsOverlay), state.shortcutsOverlay)
        item("Show Welcome", .viewing(.showWelcome))
    }
}
