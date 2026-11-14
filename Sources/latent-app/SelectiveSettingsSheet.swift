import SwiftUI
import PixelEngine

/// What Copy Settings…, Paste Settings… and Load Settings from File… ask:
/// which groups of the edit to take. `onChoose` does the rest.
struct SelectiveSettingsRequest: Identifiable {
    enum Purpose: Equatable {
        case copy, paste
        /// Load Settings from File…, with the file's name.
        case load(String)

        /// The remembered choice is per purpose (all loads share one).
        var memoryKey: String {
            switch self {
            case .copy: "copy"
            case .paste: "paste"
            case .load: "load"
            }
        }
    }

    let id = UUID()
    let purpose: Purpose
    /// The groups the source carries (the clipboard's, the file's); nil
    /// when every group comes from a whole edit (Copy).
    var available: Set<EditGroup>?
    let onChoose: @MainActor (Set<EditGroup>) -> Void

    init(purpose: Purpose, available: Set<EditGroup>? = nil, onChoose: @escaping @MainActor (Set<EditGroup>) -> Void) {
        self.purpose = purpose
        self.available = available
        self.onChoose = onChoose
    }

    var title: String {
        switch purpose {
        case .copy: "Copy Settings"
        case .paste: "Paste Settings"
        case .load(let name): "Load Settings from “\(name)”"
        }
    }

    var actionTitle: String {
        switch purpose {
        case .copy: "Copy"
        case .paste: "Paste"
        case .load: "Load"
        }
    }
}

/// The last groups ticked in the selective sheet, per purpose. Separate
/// from the Presets & Clipboard checklist (`EditorModel.pasteGroups`),
/// which Copy Settings and Paste Settings keep using as they always have.
enum SelectiveSettingsMemory {
    static func key(_ purpose: SelectiveSettingsRequest.Purpose) -> String {
        "latent.selectiveSettings.\(purpose.memoryKey)"
    }

    /// The look groups at first for copy and paste, as Copy Settings starts;
    /// every group for a file, which is a whole edit.
    static func groups(for purpose: SelectiveSettingsRequest.Purpose,
                       defaults: UserDefaults = .standard) -> Set<EditGroup> {
        if let raw = defaults.array(forKey: key(purpose)) as? [String] {
            return Set(raw.compactMap(EditGroup.init(rawValue:)))
        }
        if case .load = purpose { return Set(EditGroup.allCases) }
        return EditGroup.lookGroups
    }

    static func remember(_ groups: Set<EditGroup>, for purpose: SelectiveSettingsRequest.Purpose,
                         defaults: UserDefaults = .standard) {
        defaults.set(groups.map(\.rawValue).sorted(), forKey: key(purpose))
    }
}

/// A checklist of the edit's groups, with All and None, that remembers the
/// last choice: darktable's selective copy and paste, Lightroom's Copy
/// Settings dialog.
struct SelectiveSettingsSheet: View {
    let request: SelectiveSettingsRequest
    @State private var chosen: Set<EditGroup>
    @Environment(\.dismiss) private var dismiss

    init(request: SelectiveSettingsRequest) {
        self.request = request
        _chosen = State(initialValue: SelectiveSettingsMemory.groups(for: request.purpose))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            if request.available != nil {
                Text("A ticked group the source doesn’t set is put back to its default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("All") { chosen = Set(EditGroup.allCases) }
                Button("None") { chosen = [] }
                Spacer()
                Text("\(chosen.count) of \(EditGroup.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(EditGroup.allCases) { group in
                        Toggle(isOn: Binding(get: { chosen.contains(group) },
                                             set: { on in if on { chosen.insert(group) } else { chosen.remove(group) } })) {
                            HStack(spacing: 4) {
                                Text(group.displayName)
                                if let available = request.available, !available.contains(group) {
                                    Text("(not set)").foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.actionTitle) {
                    SelectiveSettingsMemory.remember(chosen, for: request.purpose)
                    let groups = chosen
                    dismiss()
                    request.onChoose(groups)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
