import SwiftUI
import PixelEngine

/// Undo/redo, the list of steps, and named snapshots.
struct HistoryPanel: View {
    @Bindable var model: EditorModel
    @State private var snapshotName = ""
    @State private var showingSnapshotSheet = false
    /// Compare…: the two sides picked in its sheet.
    @State private var showingCompareSheet = false
    @State private var compareLeft: ComparisonSource = .current
    @State private var compareRight: ComparisonSource = .current

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// The snapshot becomes the Before, shown in a split when one image
    /// was showing (DevelopViewState).
    private func compareAsBefore(_ snapshot: EditSnapshot) {
        let views = DevelopViewState.shared
        views.attach(main: model, library: MainWindowModels.shared.library)
        views.compareSnapshot(snapshot)
    }

    /// Compare… opens with `left` (a snapshot's context menu), else the
    /// newest snapshot, else the step before the current one, on the left,
    /// and Current on the right.
    private func openCompareSheet(left: ComparisonSource? = nil) {
        let snapshots = model.snapshots
        if let left {
            compareLeft = left
        } else if let last = snapshots.last {
            compareLeft = .snapshot(last.id)
        } else if model.history.cursor > 0 {
            compareLeft = .historyStep(model.history.steps[model.history.cursor - 1].id)
        } else {
            compareLeft = .current
        }
        compareRight = .current
        showingCompareSheet = true
    }

    /// The two sides show against each other in Develop's Before/After layout.
    private func startComparison() {
        let views = DevelopViewState.shared
        views.attach(main: model, library: MainWindowModels.shared.library)
        views.startComparison(left: compareLeft, right: compareRight)
        showingCompareSheet = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Undo") { model.undo() }.disabled(!model.canUndo)
                Button("Redo") { model.redo() }.disabled(!model.canRedo)
                Spacer()
                Button("Compare…") { openCompareSheet() }
                    .disabled(!model.hasImage)
                    .help("Compare two snapshots, or a snapshot and a history step, side by side")
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
                    let isBefore = model.beforeSnapshotName == snapshot.name
                    HStack {
                        Button(snapshot.name) { model.restoreSnapshot(snapshot) }.buttonStyle(.plain)
                            .accessibilityHint("Restores this snapshot")
                        Spacer()
                        // Compare as Before, or Clear Before when it is the Before.
                        Button {
                            if isBefore { model.resetBefore() } else { compareAsBefore(snapshot) }
                        } label: {
                            Image(systemName: isBefore ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        }
                        .buttonStyle(.plain).foregroundStyle(isBefore ? Color.accentColor : .secondary)
                        .help(isBefore ? "Clear Before: back to the unedited photo"
                                       : "Compare as Before: show this snapshot beside the current edit")
                        .accessibilityLabel(isBefore ? "Clear Before" : "Compare snapshot \(snapshot.name) as Before")
                        Button { model.deleteSnapshot(snapshot) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Delete this snapshot")
                            .accessibilityLabel("Delete snapshot \(snapshot.name)")
                    }
                    .font(.caption)
                    .contextMenu {
                        Button("Restore Snapshot") { model.restoreSnapshot(snapshot) }
                        Button("Compare as Before") { compareAsBefore(snapshot) }
                        Button("Compare…") { openCompareSheet(left: .snapshot(snapshot.id)) }
                        if model.hasCustomBefore {
                            Button("Clear Before") { model.resetBefore() }
                        }
                    }
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
        #if DEBUG
        .snapshotHook(.snapshotCompare, Binding(get: { showingCompareSheet },
                                                set: { if $0 { openCompareSheet() } else { showingCompareSheet = false } }))
        #endif
        .sheet(isPresented: $showingCompareSheet) {
            let choices = model.comparisonChoices
            VStack(alignment: .leading, spacing: 12) {
                Text("Compare").font(.headline)
                ComparisonSourcePicker(title: "Left / top", choices: choices, selection: $compareLeft)
                ComparisonSourcePicker(title: "Right / bottom", choices: choices, selection: $compareRight)
                Text("Shown in the Before/After layout, each pane named. The edit itself doesn't change.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { showingCompareSheet = false }.keyboardShortcut(.cancelAction)
                    Button("Compare") { startComparison() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(compareLeft == compareRight)
                }
            }
            .padding(20).frame(width: 380)
        }
    }
}
