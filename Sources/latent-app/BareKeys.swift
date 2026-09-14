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
        case 0x0D: key = .returnKey
        case 0x1B: key = .escape
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

/// Every single-key command in the app, in one table. Lightroom's keys, so
/// muscle memory carries over.
enum KeyCommand: Equatable {
    case step(Int), openSelection
    case library, develop, loupe, compare, toggleLoupe, toggleZoom
    case rate(Int), pick, reject, unflag
    case beforeAfter, crop, heal, deleteHeal, disarmTools
    case makeSelect

    static func command(for press: BareKeyPress) -> KeyCommand? {
        if press.shift {
            return press.key == .character("x") ? .makeSelect : nil
        }
        switch press.key {
        case .rightArrow: return .step(1)
        case .leftArrow: return .step(-1)
        case .returnKey: return .openSelection
        case .delete: return .deleteHeal
        case .escape: return .disarmTools
        case .character(let c):
            switch c {
            case "g": return .library
            case "d": return .develop
            case "e": return .loupe
            case "c": return .compare
            case " ": return .toggleLoupe
            case "z": return .toggleZoom
            case "p": return .pick
            case "x": return .reject
            case "u": return .unflag
            case "\\": return .beforeAfter
            case "r": return .crop
            case "h": return .heal
            default:
                if let stars = c.wholeNumberValue, (0...5).contains(stars), c.isASCII { return .rate(stars) }
                return nil
            }
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
/// go on untouched while text is being edited, a sheet or modal is up, or
/// the key is for another window. `perform` returns false to let a key
/// through as well.
struct BareKeyMonitor: NSViewRepresentable {
    let perform: @MainActor (KeyCommand) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.perform = perform
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.perform = perform
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var perform: (@MainActor (KeyCommand) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.offer(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// A field editor (any text field being typed in) or an editable
        /// text view as first responder means the keys are for the text.
        private func offer(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  (window.firstResponder as? NSText)?.isEditable != true,
                  let characters = event.charactersIgnoringModifiers else { return false }
            let flags = event.modifierFlags
            guard let press = BareKeyPress(charactersIgnoringModifiers: characters,
                                           shift: flags.contains(.shift), command: flags.contains(.command),
                                           option: flags.contains(.option), control: flags.contains(.control)),
                  let command = KeyCommand.command(for: press) else { return false }
            return perform?(command) ?? false
        }
    }
}
