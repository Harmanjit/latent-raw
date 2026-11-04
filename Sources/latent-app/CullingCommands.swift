import SwiftUI
import AppKit
import Catalog

/// Photo › Auto Advance: after a star, flag or label, move on to the next
/// photo, as Lightroom does. Kept for the next launch.
@MainActor
final class CullingPreferences: ObservableObject {
    static let shared = CullingPreferences(defaults: .standard)
    nonisolated static let autoAdvanceKey = "latent.culling.autoAdvance"

    private let defaults: UserDefaults

    @Published var autoAdvance: Bool {
        didSet { defaults.set(autoAdvance, forKey: Self.autoAdvanceKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        autoAdvance = defaults.bool(forKey: Self.autoAdvanceKey)
    }
}

extension KeyCommand {
    /// A star, flag or label: what Auto Advance moves on after.
    var isCulling: Bool {
        switch self {
        case .rate, .pick, .reject, .unflag, .label: true
        default: false
        }
    }
}

/// How a key press reaches the culling commands, beyond the table.
///
/// Lightroom's Shift variants: Shift with a star, flag or label key sets it
/// and moves on once, whatever Auto Advance says. Caps Lock turns the same
/// keys into their advancing form for as long as it is on. Shift-1 types
/// "!", so the key is also read without Shift (`unshifted`) to find it.
enum CullingKeys {
    /// The command to run for `press`, and one to run instead if the first
    /// declines (Shift-X is Compare's Make Select; elsewhere it rejects and
    /// moves on). Nil when the key means nothing.
    static func commands(for press: BareKeyPress, unshifted: BareKeyPress?,
                         capsLock: Bool) -> (first: KeyCommand, fallback: KeyCommand?)? {
        let base = KeyCommand.command(for: press)
        if let base, base.isCulling {
            return (capsLock ? .advance(base) : base, nil)
        }
        if press.shift, let unshifted, !unshifted.shift,
           let inner = KeyCommand.command(for: unshifted), inner.isCulling {
            let advancing = KeyCommand.advance(inner)
            return base.map { ($0, advancing) } ?? (advancing, nil)
        }
        // A key two scoped commands share: the second runs when the first
        // is unavailable here (it passes the key through).
        let shared = Shortcuts.commands(for: press)
        return base.map { ($0, shared.count > 1 ? shared[1] : nil) }
    }

    /// The key as typed without Shift, when Shift is held.
    static func unshiftedPress(of event: NSEvent) -> BareKeyPress? {
        guard event.modifierFlags.contains(.shift),
              let characters = event.characters(byApplyingModifiers: []) else { return nil }
        return BareKeyPress(charactersIgnoringModifiers: characters, shift: false,
                            command: false, option: false, control: false)
    }
}

/// The culling commands ContentView hands over: stars, flags and labels
/// (with Auto Advance), the Select commands and Refine Photos.
@MainActor
struct CullingCommands {
    let library: Library
    /// Loupe, Compare and Develop change the image shown, not the grid's
    /// whole selection.
    let onlyPrimary: Bool
    /// The next photo: an arrow key's step.
    let advance: @MainActor () -> Void

    /// Sets a star, flag or label and, with `advancing`, moves on. The
    /// photos to change are read first: the write runs a moment later, by
    /// when the selection has already moved to the next photo.
    func perform(_ command: KeyCommand, advancing: Bool) {
        let targets = library.cullingTargets(onlyPrimary: onlyPrimary)
        let library = library
        switch command {
        case .rate(let stars):
            library.perform("Rating") { try await library.setRating(stars, targets: targets) }
        case .pick, .reject, .unflag:
            let flag: ImageFlag = command == .pick ? .picked : command == .reject ? .rejected : .none
            library.perform("Flagging") { try await library.setFlag(flag, targets: targets) }
        case .label(let label):
            // Toggles by the primary, as the key always has.
            let next = ColorLabel.label(afterChoosing: label, current: library.selectedImage?.label)
            library.perform("Labelling") { try await library.setLabel(next, targets: targets) }
        default:
            return
        }
        if advancing, !targets.isEmpty { advance() }
    }

    func select(_ selection: CullingSelection) {
        library.applySelection(selection)
    }

    /// Refine Photos, after saying what it will do. Undo puts every flag back.
    func refine() {
        let plan = RefinePlan(visible: library.visibleImages)
        let alert = NSAlert()
        guard !plan.isEmpty else {
            alert.messageText = "Nothing to refine"
            alert.informativeText = "Every photo shown is already rejected."
            alert.runModal()
            return
        }
        alert.messageText = "Refine Photos?"
        alert.informativeText = Self.refineSummary(plan) + " Rejected photos stay rejected. You can undo this."
        alert.addButton(withTitle: "Refine")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let library = library
        library.perform("Refine Photos") { _ = try await library.refinePhotos() }
    }

    /// "12 unflagged photos will be rejected, and 3 picked photos will be unflagged."
    static func refineSummary(_ plan: RefinePlan) -> String {
        let r = plan.rejectedCount, u = plan.unflaggedCount
        let rejected = r == 1 ? "1 unflagged photo will be rejected" : "\(r) unflagged photos will be rejected"
        let unflagged = u == 1 ? "1 picked photo will be unflagged" : "\(u) picked photos will be unflagged"
        switch (r, u) {
        case (_, 0): return rejected + "."
        case (0, _): return unflagged + "."
        default: return rejected + ", and " + unflagged + "."
        }
    }
}

/// Edit's Select commands, as in Lightroom's Library.
struct CullingSelectMenu: View {
    let item: (String, KeyCommand) -> AnyView

    var body: some View {
        Divider()
        item("Select None", .select(.none))
        item("Invert Selection", .select(.invert))
        Menu("Select by Flag") {
            item("Picked", .select(.flag(.picked)))
            item("Unflagged", .select(.flag(.none)))
            item("Rejected", .select(.flag(.rejected)))
        }
        Menu("Select by Rating") {
            ForEach(0...5, id: \.self) { stars in
                item(stars == 0 ? "No Stars" : stars == 1 ? "1 Star" : "\(stars) Stars", .select(.rating(stars)))
            }
        }
        Menu("Select by Colour Label") {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                item(label.title, .select(.label(label)))
            }
            Divider()
            item("No Label", .select(.label(nil)))
        }
        item("Deselect Unflagged", .select(.deselectUnflagged))
    }
}
