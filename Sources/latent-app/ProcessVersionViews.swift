import SwiftUI
import Catalog
import PixelEngine

// MARK: - Process menu (Calibration)

/// Calibration's Process menu: which rendering generation the open photo
/// uses (`ProcessVersion`). Choosing another version changes the photo's
/// edit like any slider, with its own undo step.
struct ProcessVersionMenu: View {
    @ObservedObject var model: EditorModel
    @AppStorage(ProcessUpdatePrompt.dontShowKey) private var dontShow = false

    var body: some View {
        HStack {
            Text("Process").font(.subheadline)
            Spacer()
            Menu(ProcessVersion.title(for: model.parameters.processVersion)) {
                ForEach(ProcessVersion.all.reversed()) { version in
                    Toggle(ProcessVersion.title(for: version.id), isOn: Binding(
                        get: { model.parameters.processVersion == version.id },
                        set: { on in if on { model.parameters.processVersion = version.id } }))
                }
                Divider()
                Toggle("Offer to Update Older Photos", isOn: Binding(get: { !dontShow }, set: { dontShow = !$0 }))
            }
            .fixedSize()
            .controlSize(.small)
            .accessibilityLabel("Process version")
        }
        .help(ProcessVersion.all.count == 1
              ? "Latent has one process version so far; an edit made today will render the same after a future rendering change"
              : "The rendering generation this photo's edit uses; new edits use the current one")
    }
}

// MARK: - Update Process Version dialog

/// When the Update Process Version dialog is offered: on an edit of a
/// photo whose process version is older than the current one, once per
/// photo in a session, unless the user said not to show it again.
enum ProcessUpdatePrompt {
    static let dontShowKey = "latent.processUpdate.dontShow"

    /// `old` and `new` are the parameters either side of a change on the
    /// same photo. A change of the process version itself (the menu, the
    /// dialog's own preview) never asks.
    static func shouldAsk(old: EditParameters, new: EditParameters, alreadyAsked: Bool, dontShow: Bool,
                          current: ProcessVersion = .current) -> Bool {
        guard !dontShow, !alreadyAsked, old != new, old.processVersion == new.processVersion else { return false }
        return ProcessVersion.isOutdated(new.processVersion, current: current)
    }
}

/// Watches the open photo's edits and offers the dialog (Lightroom's
/// Update Process Version): update this photo, or with the option every
/// photo in the filmstrip, to the current version; preview it first; and
/// don't show it again.
struct ProcessUpdatePromptModifier: ViewModifier {
    @ObservedObject var model: EditorModel
    let library: Library
    @AppStorage(ProcessUpdatePrompt.dontShowKey) private var dontShow = false
    @State private var trackedURL: URL?
    @State private var asked: Set<URL> = []
    @State private var request: Request?

    struct Request: Identifiable {
        let id = UUID()
        let fromVersion: String
    }

    func body(content: Content) -> some View {
        content
            .onAppear { trackedURL = model.sourceURL }
            .onChange(of: model.parameters) { old, new in
                // Opening another photo sets its parameters in the same
                // pass as its URL: that is a load, not an edit.
                guard let url = model.sourceURL, url == trackedURL else {
                    trackedURL = model.sourceURL
                    return
                }
                guard request == nil,
                      ProcessUpdatePrompt.shouldAsk(old: old, new: new, alreadyAsked: asked.contains(url),
                                                    dontShow: dontShow) else { return }
                asked.insert(url)
                request = Request(fromVersion: new.processVersion)
            }
            .sheet(item: $request) { request in
                ProcessUpdateDialog(model: model, library: library, fromVersion: request.fromVersion,
                                    dontShow: $dontShow) { self.request = nil }
            }
    }
}

struct ProcessUpdateDialog: View {
    @ObservedObject var model: EditorModel
    let library: Library
    let fromVersion: String
    @Binding var dontShow: Bool
    let dismiss: () -> Void
    @State private var updateAll = false
    @State private var preview = false

    private var current: ProcessVersion { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update Process Version").font(.headline)
            Text("This photo was edited with \(ProcessVersion.title(for: fromVersion)). "
                 + "Updating to \(current.title), the current one, renders it with Latent's newest processing; "
                 + "it may look different. Your slider settings are kept.")
                .fixedSize(horizontal: false, vertical: true)
            let changes = ProcessVersion.changes(from: fromVersion)
            if !changes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(changes, id: \.self) { Text("• " + $0).font(.caption) }
                }
            }
            Toggle("Preview the update on this photo", isOn: $preview)
                .onChange(of: preview) { _, on in
                    model.parameters.processVersion = on ? current.id : fromVersion
                }
            Toggle("Update all filmstrip photos", isOn: $updateAll)
                .help("Also update every photo the filmstrip shows whose edit uses an older version")
            Toggle("Don’t show again", isOn: $dontShow)
                .help("Calibration’s Process menu can offer it again, and still updates a photo by hand")
            HStack {
                Spacer()
                Button("Cancel") {
                    model.parameters.processVersion = fromVersion
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Update") {
                    model.parameters.processVersion = current.id
                    if updateAll { ProcessVersionUpdater.updateFilmstrip(library: library, model: model) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(width: 420)
    }
}

/// Brings the stored edits of every photo the filmstrip shows up to the
/// current process version, as one Library undo step. The photo open in
/// the editor is left to the editor, which has already updated it.
@MainActor
enum ProcessVersionUpdater {
    static func updateFilmstrip(library: Library, model: EditorModel) {
        let open = model.catalogImageID
        let records = library.visibleImages.filter { $0.id != nil && $0.id != open }
        guard !records.isEmpty, library.catalog != nil else { return }
        model.flushPendingSave()
        library.perform("Updating the process version") {
            var edits: [Int64: String?] = [:], expected: [Int64: String?] = [:]
            for record in records {
                guard let id = record.id,
                      let json = try? await library.editStack(for: record),
                      let updated = try? EditStack.updatingProcess(json: json) else { continue }
                edits[id] = .some(updated)
                expected[id] = .some(json)
            }
            guard !edits.isEmpty else { return }
            try await library.setEdits(edits, expecting: expected, schemaVersion: EditStack.schemaVersion,
                                       processVersion: EditStack.processVersion,
                                       undoName: "Update Process Version (\(edits.count) Images)")
        }
    }
}

// MARK: - Previous (Paste Settings From Previous)

/// The photo selected before the current one, for Lightroom's Previous:
/// paste all its settings onto this one. Belongs to the folder it was
/// selected in, so opening another folder forgets it.
struct PreviousPhoto: Equatable {
    private(set) var imageID: Int64?
    private(set) var folder: URL?

    mutating func selectionChanged(from old: Int64?, to new: Int64?, folder: URL?) {
        if folder != self.folder { imageID = nil; self.folder = folder }
        if let old, old != new { imageID = old }
    }

    /// The previous photo, if it belongs to `folder` and isn't `current`.
    func id(in folder: URL?, current: Int64?) -> Int64? {
        guard let imageID, folder == self.folder, imageID != current else { return nil }
        return imageID
    }
}

extension EditGroup {
    /// What Previous carries: everything but the retouching that belongs to
    /// one frame (spot patches and red-eye, sensor dust, touch-up's faces
    /// and blemishes), which would land in the wrong places on another.
    static let previousGroups: Set<EditGroup> = Set(EditGroup.allCases).subtracting([.heal, .dust, .touchUp])
}

// MARK: - Preset Amount

/// The Presets panel's Amount (`PresetAmount`), kept between launches,
/// and the last preset applied in the editor, so moving the slider right
/// after applying one re-blends it live, as Lightroom's does.
@MainActor
final class PresetAmountSession {
    static let shared = PresetAmountSession()
    static let amountKey = "latent.presetAmount"

    static var amount: Float {
        let stored = Float(UserDefaults.standard.object(forKey: amountKey) as? Double ?? 1)
        guard stored.isFinite else { return PresetAmount.full }
        return min(max(stored, PresetAmount.range.lowerBound), PresetAmount.range.upperBound)
    }

    struct Applied {
        let url: URL
        let base: EditStack
        let preset: EditStack
        let groups: Set<EditGroup>
        var result: EditParameters
    }
    var applied: Applied?
}

extension EditorModel {
    /// After the editor applied `preset` over `base` (its stack beforehand).
    func rememberPresetApplication(base: EditStack, preset: Preset) {
        guard let url = sourceURL else { return }
        PresetAmountSession.shared.applied = .init(url: url, base: base, preset: preset.stack,
                                                   groups: preset.groups, result: parameters)
    }

    /// The editor's stack with `stack`'s `groups` applied at `amount`, for
    /// `apply(_:groups:)`.
    func stack(applying stack: EditStack, groups: Set<EditGroup>, amount: Float) -> EditStack {
        EditStack(parameters: parameters).applying(onThisImage(stack), groups: groups, amount: amount,
                                                   defaults: defaultParameters)
    }

    /// The Amount slider moved: re-blend the last preset, if it is still
    /// the photo's last change. Returns false when there is none to.
    @discardableResult
    func reblendLastPreset(amount: Float) -> Bool {
        guard var applied = PresetAmountSession.shared.applied, applied.url == sourceURL,
              applied.result == parameters else { return false }
        let s = applied.base.applying(onThisImage(applied.preset), groups: applied.groups, amount: amount, defaults: defaultParameters)
        apply(s, groups: applied.groups)
        applied.result = parameters
        PresetAmountSession.shared.applied = applied
        return true
    }
}
