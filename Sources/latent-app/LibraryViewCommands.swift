import SwiftUI
import Catalog
import PixelEngine

/// Photo › Flip Horizontal and Flip Vertical for the selection, View ›
/// Mirror Image Mode and View › Sort, under one `KeyCommand` case so the
/// tables they pass through (menus, enabling, perform) each gain one line.
enum LibraryViewCommand: Equatable {
    /// The selection flipped (Develop: the open image, through Transform).
    case flip(horizontal: Bool)
    /// Every image shown mirrored, for checking a composition with fresh
    /// eyes. A view only: nothing is written.
    case toggleMirrorImageMode
    case sort(LibrarySortKey)
    case reverseSortOrder
}

extension CommandState {
    func isEnabled(_ command: LibraryViewCommand) -> Bool {
        switch command {
        // As Rotate: the grid flips its selection, the other views the
        // image they show (Develop through the editor, so its history has it).
        case .flip: mode == .develop ? hasImage : mode == .library ? selectionCount > 0 : hasSelection
        case .toggleMirrorImageMode, .sort, .reverseSortOrder: true
        }
    }
}

/// Mirror Image Mode (View menu): the grid and Loupe draw every image
/// mirrored left to right. Lightroom keeps it for checking a composition
/// as a stranger would see it. Kept for the session only, so the library
/// never opens looking wrong.
@MainActor
final class MirrorImageMode: ObservableObject {
    static let shared = MirrorImageMode()
    @Published var isOn = false
}

extension CALayer {
    /// Sets the frame, then mirrors the layer about its centre (or not).
    /// The frame is set unturned: it is undefined under a transform.
    func setFrame(_ rect: CGRect, mirrored: Bool) {
        setAffineTransform(.identity)
        frame = rect
        setMirrored(mirrored)
    }

    /// Mirrors the layer left to right about its own centre, wherever its
    /// anchor is, or takes the mirror off. Leaves the frame alone, for a
    /// view's own layer, whose frame AppKit sets.
    func setMirrored(_ mirrored: Bool) {
        guard mirrored else { setAffineTransform(.identity); return }
        let w = bounds.width
        setAffineTransform(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: (1 - 2 * anchorPoint.x) * w, ty: 0))
    }
}

/// Photo › Flip Horizontal and Flip Vertical outside Develop: each target
/// image's stored edit flipped as Develop's Transform flip does it
/// (`EditStack.flipped`), in one undo step.
@MainActor
enum LibraryFlip {
    static func undoName(horizontal: Bool) -> String { horizontal ? "Flip Horizontal" : "Flip Vertical" }

    /// Flips the selection (or the primary alone) and returns what to
    /// tell the user. Images whose edit can't be read, or whose crop and
    /// masks still measure the old sensor readout, are skipped and named.
    static func run(_ library: Library, horizontal: Bool, onlyPrimary: Bool) async throws -> String {
        let targets = onlyPrimary ? [library.selectedImage].compactMap { $0 } : library.selectedImages
        let ids = Set(targets.compactMap(\.id))
        let outcome = try await library.transformSelectedEdits(
            onlyPrimary: onlyPrimary,
            schemaVersion: EditStack.schemaVersion, processVersion: EditStack.processVersion,
            undoName: undoName(horizontal: horizontal)
        ) { existing in
            let current = try existing.map { try EditStack.decode(json: $0) } ?? EditStack()
            let next = try current.flipped(horizontal: horizontal)
            return next == EditStack() ? nil : try next.encodeJSON()
        }
        // The editor, Survey and Compare show the stored edit again, as
        // after an undo.
        if outcome.changed > 0 { library.didRestoreImages?(ids, .edits) }
        return message(changed: outcome.changed, skipped: outcome.skipped, horizontal: horizontal)
    }

    static func message(changed n: Int, skipped: [String], horizontal: Bool) -> String {
        var text = "Flipped \(n) image\(n == 1 ? "" : "s") \(horizontal ? "horizontally" : "vertically")"
        if !skipped.isEmpty {
            text += " · skipped \(skipped.count) (open in Develop to flip): " + skipped.joined(separator: ", ")
        }
        return text
    }
}

/// View › Sort and Mirror Image Mode, and Photo's flips, as menu items.
struct LibraryViewMenuItems: View {
    let state: CommandState
    let item: (String, KeyCommand) -> AnyView
    let toggle: (String, KeyCommand, Bool) -> AnyView

    var body: some View {
        Menu("Sort") {
            ForEach(LibrarySortKey.allCases, id: \.self) { key in
                toggle(key.title, .libraryView(.sort(key)), state.sortKey == key)
            }
            Divider()
            item("Reverse Sort Order", .libraryView(.reverseSortOrder))
        }
        toggle("Mirror Image Mode", .libraryView(.toggleMirrorImageMode), state.mirrorImageMode)
    }
}

/// Photo › Flip Horizontal and Flip Vertical.
struct FlipMenuItems: View {
    let item: (String, KeyCommand) -> AnyView

    var body: some View {
        item("Flip Horizontal", .libraryView(.flip(horizontal: true)))
        item("Flip Vertical", .libraryView(.flip(horizontal: false)))
    }
}
