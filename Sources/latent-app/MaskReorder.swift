import SwiftUI
import PixelEngine

/// Reordering masks and their components: drag a row onto another to put
/// it there, or Move Up and Move Down from its context menu (and as
/// VoiceOver actions). Order matters: masks apply one after another, and
/// each component joins the mask built above it. Every move is one
/// undoable step (`EditorModel.moveLocal`, `moveMaskComponent`).
///
/// The rows are plain stacks rather than a `List`, so the drag is a
/// `draggable` / `dropDestination` pair carrying the row's id with a
/// prefix of its own, which nothing else in the app accepts.
enum MaskDragPayload {
    static let maskPrefix = "latent-mask:"
    static let componentPrefix = "latent-mask-component:"

    static func id(from items: [String], prefix: String) -> UUID? {
        guard let item = items.first, item.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(item.dropFirst(prefix.count)))
    }
}

/// A mask row in the Local Adjustments list.
struct MaskRowReorder: ViewModifier {
    @ObservedObject var model: EditorModel
    let index: Int
    let id: UUID

    func body(content: Content) -> some View {
        content
            .draggable(MaskDragPayload.maskPrefix + id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = MaskDragPayload.id(from: items, prefix: MaskDragPayload.maskPrefix),
                      let from = model.parameters.locals.firstIndex(where: { $0.id == dragged }),
                      let to = model.parameters.locals.firstIndex(where: { $0.id == id }), from != to else { return false }
                model.moveLocal(from: from, to: to)
                return true
            }
            .accessibilityAction(named: "Move Up") { model.moveLocal(from: index, to: index - 1) }
            .accessibilityAction(named: "Move Down") { model.moveLocal(from: index, to: index + 1) }
    }

    /// Move Up and Move Down, for the row's own context menu.
    @ViewBuilder
    static func menuItems(model: EditorModel, index: Int) -> some View {
        Button("Move Up") { model.moveLocal(from: index, to: index - 1) }
            .disabled(index == 0)
        Button("Move Down") { model.moveLocal(from: index, to: index + 1) }
            .disabled(index >= model.parameters.locals.count - 1)
    }
}

/// A component row in a mask's Components list. The first shape stays
/// first; the components after it reorder among themselves.
struct MaskComponentReorder: ViewModifier {
    @ObservedObject var model: EditorModel
    let index: Int
    let id: UUID
    let offset: Int
    let count: Int

    func body(content: Content) -> some View {
        content
            .draggable(MaskDragPayload.componentPrefix + id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard index < model.parameters.locals.count,
                      let dragged = MaskDragPayload.id(from: items, prefix: MaskDragPayload.componentPrefix),
                      dragged != id,
                      model.parameters.locals[index].components.contains(where: { $0.id == dragged }),
                      let to = model.parameters.locals[index].components.firstIndex(where: { $0.id == id })
                else { return false }
                model.moveMaskComponent(dragged, to: to, inLocal: index)
                return true
            }
            .contextMenu {
                Button("Move Up") { model.moveMaskComponent(id, to: offset - 1, inLocal: index) }
                    .disabled(offset == 0)
                Button("Move Down") { model.moveMaskComponent(id, to: offset + 1, inLocal: index) }
                    .disabled(offset >= count - 1)
            }
            .accessibilityAction(named: "Move Up") { model.moveMaskComponent(id, to: offset - 1, inLocal: index) }
            .accessibilityAction(named: "Move Down") { model.moveMaskComponent(id, to: offset + 1, inLocal: index) }
    }
}
