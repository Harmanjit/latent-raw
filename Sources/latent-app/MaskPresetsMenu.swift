import SwiftUI
import PixelEngine

/// The mask presets on disk (`MaskPresetStore.standard`), shared by every
/// editor window. Kept in memory and reloaded after each change so the
/// menu never reads the folder while it draws.
@MainActor
final class MaskPresetLibrary: ObservableObject {
    static let shared = MaskPresetLibrary(store: .standard)

    let store: MaskPresetStore
    @Published private(set) var presets: [MaskPreset] = []

    init(store: MaskPresetStore) {
        self.store = store
        presets = store.load()
    }

    func reload() { presets = store.load() }

    /// Saves `local` as a new preset; throws for an empty or taken name.
    @discardableResult
    func save(_ local: LocalAdjustment, name: String) throws -> MaskPreset {
        defer { reload() }
        return try store.saveNew(local, name: name).preset
    }

    func rename(_ preset: MaskPreset, to name: String) throws {
        defer { reload() }
        _ = try store.rename(preset, to: name)
    }

    func delete(_ preset: MaskPreset) throws {
        defer { reload() }
        try store.delete(named: preset.name)
    }
}

extension EditorModel {
    /// Adds the preset's mask to this photo as a new mask (never replacing
    /// one), selects it and starts any model masks it has generating from
    /// this photo's pixels. False when there is no image or no room.
    @discardableResult
    func applyMaskPreset(_ preset: MaskPreset) -> Bool {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else {
            if hasImage { status = "A photo can have at most \(LocalAdjustment.maximumCount) masks" }
            return false
        }
        let local = preset.instantiate()
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        regenerateMissingAIMasks()
        status = "Added mask preset “\(preset.name)”"
        return true
    }
}

/// The Mask Presets menu beside Masks in the mask panel: save the
/// selected mask under a name, add a saved one to this photo, and rename
/// or delete them.
struct MaskPresetsMenu: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var library: MaskPresetLibrary = .shared
    @State private var saving = false
    @State private var renaming: MaskPreset?
    @State private var deleting: MaskPreset?
    @State private var errorText: String?

    var body: some View {
        Menu("Presets") {
            Button("Save Selected Mask as Preset…") { saving = true }
                .disabled(model.selectedLocal == nil)
            Divider()
            if library.presets.isEmpty {
                Text("No mask presets yet")
            } else {
                ForEach(library.presets) { preset in
                    Button(preset.name) { model.applyMaskPreset(preset) }
                        .disabled(!model.hasImage || model.parameters.locals.count >= LocalAdjustment.maximumCount)
                        .help("Add this mask to the photo")
                }
                Divider()
                Menu("Rename") {
                    ForEach(library.presets) { preset in Button(preset.name) { renaming = preset } }
                }
                Menu("Delete") {
                    ForEach(library.presets) { preset in Button(preset.name) { deleting = preset } }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save the selected mask as a preset, or add a saved mask to this photo")
        #if DEBUG
        .snapshotHook(.maskPresetSave, $saving)
        #endif
        .sheet(isPresented: $saving) {
            if let local = model.selectedLocal {
                MaskPresetSaveSheet(local: local, library: library) { saving = false }
            }
        }
        .sheet(item: $renaming) { preset in
            MaskPresetRenameSheet(preset: preset, library: library) { renaming = nil }
        }
        .confirmationDialog("Delete the mask preset “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let preset = deleting {
                    do { try library.delete(preset) } catch { errorText = error.localizedDescription }
                }
                deleting = nil
            }
        } message: {
            Text("Its file is deleted. Masks already added from it stay as they are.")
        }
        .alert("Mask preset", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }
}

/// Names a new mask preset and says what it will keep: every shape,
/// range and slider, with brush strokes and model masks stored
/// resolution-independently; and lists any component that can't travel
/// to another photo (a linked mask), which is left out.
struct MaskPresetSaveSheet: View {
    let local: LocalAdjustment
    let library: MaskPresetLibrary
    let done: () -> Void
    @State private var name = ""
    @State private var errorText: String?

    var body: some View {
        let skipped = MaskPreset.skippedComponents(of: local)
        let hasBrushOrModel = local.maskElements.contains { element in
            switch element.shape {
            case .brush, .ai, .prompted: return true
            default: return false
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Mask Preset").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(save)
                .accessibilityLabel("Preset name")
            Text("Saves “\(local.name)”: its shapes, ranges and adjustment sliders. Adding the preset to a photo adds a new mask.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hasBrushOrModel {
                Text("Brush strokes are kept as drawn, in proportion to the frame. Subject and Click to Select masks are kept as their kind and clicks, and are made again from each photo they are added to.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !skipped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Left out of the preset:", systemImage: "exclamationmark.triangle")
                        .font(.caption.bold())
                    ForEach(Array(skipped.enumerated()), id: \.offset) { _, item in
                        Text("• " + item.explanation).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { if name.isEmpty { name = local.name } }
    }

    private func save() {
        do {
            try library.save(local, name: name)
            done()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Renames a mask preset.
struct MaskPresetRenameSheet: View {
    let preset: MaskPreset
    let library: MaskPresetLibrary
    let done: () -> Void
    @State private var name = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Mask Preset").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(rename)
                .accessibilityLabel("Preset name")
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Rename", action: rename).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = preset.name }
    }

    private func rename() {
        do {
            try library.rename(preset, to: name)
            done()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
