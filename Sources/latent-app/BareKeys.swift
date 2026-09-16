import SwiftUI
import AppKit

/// A key pressed without Command, Option or Control: the single keys that
/// step through images, switch modes, rate and flag.
///
/// Kept apart from NSEvent so the table below reads as plain data.
struct BareKeyPress: Equatable {
    enum Key: Equatable {
        /// A printable key, lowercased; space is " ".
        case character(Character)
        case leftArrow, rightArrow, returnKey, delete, escape
        /// F2 (Rename), with or without fn.
        case f2
        case upArrow, downArrow
    }

    var key: Key
    var shift: Bool

    init(_ key: Key, shift: Bool = false) {
        self.key = key
        self.shift = shift
    }

    /// Reads a key press from the characters it produces ignoring modifiers.
    /// Nil when Command, Option or Control is held, since those belong to
    /// menus and buttons.
    init?(charactersIgnoringModifiers characters: String,
          shift: Bool, command: Bool, option: Bool, control: Bool) {
        guard !command, !option, !control,
              characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0xF702: key = .leftArrow
        case 0xF703: key = .rightArrow
        case 0xF700: key = .upArrow
        case 0xF701: key = .downArrow
        case 0x0D: key = .returnKey
        case 0x1B: key = .escape
        case 0xF705: key = .f2
        // The Delete key reports DEL; SwiftUI's KeyEquivalent.delete is
        // backspace. Either means the same key.
        case 0x7F, 0x08: key = .delete
        default:
            // Shift-X can report "X" or "x", so letters compare lowercased
            // with Shift kept aside.
            key = .character(Character(String(scalar).lowercased()))
        }
        self.shift = shift
    }
}

/// Every command the keyboard and the menu bar can give, whatever keys
/// (if any) reach it. The keys themselves are in `Shortcuts.all`, one
/// table for single keys and Command shortcuts alike; Lightroom's keys, so
/// muscle memory carries over. `ContentView.perform(_:)` runs them all.
enum KeyCommand: Equatable {
    case step(Int), openSelection
    case library, develop, loupe, compare, toggleLoupe, toggleZoom
    case rate(Int), pick, reject, unflag
    case beforeAfter, crop, heal, deleteHeal, disarmTools
    case redEye
    case makeSelect
    /// Survey (N), and taking its focused pane away.
    case survey, removeFromSurvey
    // Reached from the menus, most with a Command shortcut as well.
    case openFolder, openFile, export, exportOpenImage
    case print, contactSheet
    /// Photo › Photo Merge › HDR…: the selected bracket merged into one DNG.
    case photoMergeHDR
    /// Photo › Photo Merge › HDR Merge Without Dialog: the same, straight
    /// away, with the options the dialog was last left with.
    case photoMergeHDRWithoutDialog
    /// Photo › Photo Merge › Panorama…: the selected sweep stitched into
    /// one DNG beside the first photo.
    case photoMergePanorama
    /// Photo › Photo Merge › HDR Panorama… (experimental): a bracket at
    /// each position, merged and then stitched.
    case photoMergeHDRPanorama
    case slideshow, editExternally
    case undo, redo, copySettings, pasteSettings
    case rotate(Int), zoomIn, zoomOut, zoomToFit, zoomToActualSize
    case autoAdjust, clearFilter, swapCompare, revealInFinder
    case addMask(NewMask), toggleMaskOverlay
    /// [ and ]: the armed brush or spot patch, a step smaller or larger.
    case toolSize(Int)
    /// Files: rename the selected image, move or copy the selection to a
    /// folder, and Back / Forward between the folders opened.
    case rename, moveToFolder, copyToFolder, back, forward
    /// F: the image alone, full screen. The second display's Loupe is menu only.
    case fullScreenImage, secondaryDisplay
    /// Arrow keys on a zoomed-in image, when Settings has them pan.
    case panImage(PanDirection)

    enum NewMask: Equatable { case linear, radial, brush }
    enum PanDirection: Equatable { case left, right, up, down }

    static func command(for press: BareKeyPress) -> KeyCommand? {
        Shortcuts.command(for: press)
    }
}

/// What has the keyboard in the window, as far as single keys care.
enum KeyFocus: Equatable {
    /// A field editor (any text field being typed in) or an editable text view.
    case text
    /// A button, checkbox, switch, pop-up or segmented control. With Full
    /// Keyboard Access, Tab moves focus to these and Space presses them.
    case control
    /// A table or outline, such as the folder sidebar once Tab or VoiceOver
    /// gives it the keyboard (a click doesn't).
    case list
    /// A slider, reached with Tab under Full Keyboard Access.
    case slider
    /// Anything else, the thumbnail grid and the image among them: single
    /// keys are commands there.
    case other

    @MainActor init(_ responder: NSResponder?) {
        switch responder {
        case let text as NSText where text.isEditable: self = .text
        case is NSButton, is NSSegmentedControl, is NSSwitch: self = .control
        // NSOutlineView is a table view.
        case is NSTableView: self = .list
        case is NSSlider: self = .slider
        default: self = .other
        }
    }
}

extension BareKeyPress {
    /// Whether the key is for whatever has focus rather than for the
    /// command table: the keys that control uses. Text takes every key. A
    /// focused control takes Space and Return, which press it; the arrows
    /// still step through images, since such a control does nothing with
    /// them. A list takes the arrows (← and → collapse and expand an
    /// outline), Return and Space (the sidebar opens the selected folder)
    /// and typed characters, which jump to the row they start; Escape and
    /// Delete stay commands. A slider takes the arrows, which move it.
    func belongs(to focus: KeyFocus) -> Bool {
        switch focus {
        case .text: return true
        case .control: return !shift && (key == .character(" ") || key == .returnKey)
        case .list: return key != .escape && key != .delete
        case .slider: return [.leftArrow, .rightArrow, .upArrow, .downArrow].contains(key)
        case .other: return false
        }
    }
}

/// Offers the window's bare key presses to `handler`, unless they belong to
/// something else.
///
/// Hidden SwiftUI buttons with a modifier-less keyboardShortcut used to do
/// this, but they don't know about text fields. Typed letters reached the
/// field, yet the arrows went to the buttons ahead of it (in the Keywords or
/// search field they stepped to another image and the cursor stayed put),
/// and Return and Escape still fired the buttons, so Return in the Keywords
/// field also opened the editor. A button can't decline a key
/// once it matches, so a local event monitor looks first and lets the event
/// go on untouched while text is being edited or a control has focus (see
/// `KeyFocus`), a sheet or modal is up, or the key is for another window.
/// `perform` returns false to let a key through as well.
///
/// It also reports when typing starts and stops in the window, for the
/// Edit menu: Undo there undoes typing while a field has the keyboard.
struct BareKeyMonitor: NSViewRepresentable {
    let perform: @MainActor (KeyCommand) -> Bool
    var onTextFocusChange: (@MainActor (Bool) -> Void)?

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.perform = perform
        view.onTextFocusChange = onTextFocusChange
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.perform = perform
        view.onTextFocusChange = onTextFocusChange
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var perform: (@MainActor (KeyCommand) -> Bool)?
        var onTextFocusChange: (@MainActor (Bool) -> Void)?
        private var monitor: Any?
        private var responderObservation: NSKeyValueObservation?
        private var editingText = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.offer(event) ?? false }
                return consumed ? nil : event
            }
            responderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.firstResponderChanged(window.firstResponder) }
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            responderObservation = nil
        }

        /// Passed on a turn later: the first responder can change in the
        /// middle of a SwiftUI update, which must not change state itself.
        private func firstResponderChanged(_ responder: NSResponder?) {
            let editing = KeyFocus(responder) == .text
            guard editing != editingText else { return }
            editingText = editing
            Task { @MainActor [weak self] in
                guard let self, self.editingText == editing else { return }
                self.onTextFocusChange?(editing)
            }
        }

        private func offer(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  let characters = event.charactersIgnoringModifiers else { return false }
            let flags = event.modifierFlags
            guard let press = BareKeyPress(charactersIgnoringModifiers: characters,
                                           shift: flags.contains(.shift), command: flags.contains(.command),
                                           option: flags.contains(.option), control: flags.contains(.control)),
                  !press.belongs(to: KeyFocus(window.firstResponder)),
                  let command = KeyCommand.command(for: press) else { return false }
            return perform?(command) ?? false
        }
    }
}
