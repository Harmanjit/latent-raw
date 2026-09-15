import SwiftUI
import PixelEngine

/// Undo/redo, the list of steps, and named snapshots.
struct HistoryPanel: View {
    @ObservedObject var model: EditorModel
    @State private var snapshotName = ""
    @State private var showingSnapshotSheet = false

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Undo") { model.undo() }.disabled(!model.canUndo)
                Button("Redo") { model.redo() }.disabled(!model.canRedo)
                Spacer()
                Button("Snapshot…") { showingSnapshotSheet = true }.disabled(!model.hasImage)
            }
            .controlSize(.small)

            // Newest first, current highlighted. Click to jump.
            let steps = Array(model.history.steps.enumerated().reversed())
            VStack(spacing: 1) {
                ForEach(steps, id: \.element.id) { index, step in
                    HStack {
                        Text(step.label).font(.caption).lineLimit(1)
                        Spacer()
                        Text(Self.time.string(from: step.date)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .background(index == model.history.cursor ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 3))
                    .selectionOutline(index == model.history.cursor, cornerRadius: 3)
                    .opacity(index > model.history.cursor ? 0.5 : 1)   // redo-able steps are dimmed
                    .contentShape(Rectangle())
                    .onTapGesture { model.jumpToHistory(index: index) }
                    // A row VoiceOver can press, saying which step is current
                    // and which are undone.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(step.label)
                    .accessibilityValue(index == model.history.cursor ? "current"
                                        : index > model.history.cursor ? "undone" : "")
                    .accessibilityAddTraits(index == model.history.cursor ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { model.jumpToHistory(index: index) }
                }
            }

            if !model.snapshots.isEmpty {
                Text("Snapshots").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(model.snapshots) { snapshot in
                    HStack {
                        Button(snapshot.name) { model.restoreSnapshot(snapshot) }.buttonStyle(.plain)
                            .accessibilityHint("Restores this snapshot")
                        Spacer()
                        Button { model.deleteSnapshot(snapshot) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Delete this snapshot")
                            .accessibilityLabel("Delete snapshot \(snapshot.name)")
                    }
                    .font(.caption)
                }
            }
        }
        .sheet(isPresented: $showingSnapshotSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save snapshot").font(.headline)
                TextField("Name", text: $snapshotName)
                Text("A named copy of the current edit, kept with this image.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showingSnapshotSheet = false }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        model.saveSnapshot(named: snapshotName.trimmingCharacters(in: .whitespaces))
                        snapshotName = ""; showingSnapshotSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(snapshotName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20).frame(width: 340)
        }
    }
}
