import SwiftUI
import PixelEngine

extension EditorModel {
    // MARK: - Flat-field correction

    /// The open photo's flat-field correction needs its reference's gain
    /// map, which this Mac may not hold yet (a catalog from another Mac, a
    /// cleared cache): made from the reference beside the photo, off the
    /// main thread, then the photo is drawn again.
    func ensureFlatFieldGainMap() {
        guard let flat = parameters.flatField, let url = sourceURL, let gpu = gpuContext,
              FlatFieldCache.shared.gainMap(for: flat.hash) == nil,
              FlatFieldCache.shared.failure(for: flat.hash) == nil else { return }
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                FlatFieldCache.shared.ensureGainMap(for: flat, photo: url, gpu: gpu)
            }.value
            guard let self else { return }
            self.objectWillChange.send()
            if found, self.parameters.flatField?.hash == flat.hash { self.rerender() }
        }
    }

    /// What the panel says about the correction when it can't apply it.
    var flatFieldProblem: String? {
        guard let flat = parameters.flatField, FlatFieldCache.shared.gainMap(for: flat.hash) == nil else { return nil }
        return FlatFieldCache.shared.failure(for: flat.hash).map { $0 + " The correction is off." }
            ?? "Measuring the reference…"
    }

    func removeFlatField() {
        guard parameters.flatField != nil else { return }
        parameters.flatField = nil
        status = "Flat-field correction removed"
    }

    // MARK: - Upright Mode, pasted

    /// After a paste or preset that brought an Upright mode without its
    /// matrix: the mode's analysis, run on this photo.
    func analysePastedUpright(_ stack: EditStack, groups: Set<EditGroup>) {
        guard stack.wantsUprightAnalysis(groups: groups), let mode = uprightMode, mode != .guided,
              parameters.perspective.upright?.matrix == nil else { return }
        setUpright(mode)
    }
}

/// The flat-field part of the Lens Corrections panel: the reference in
/// use, its Amount and a way to take it off. Choosing a reference is
/// Photo › Flat-Field Correction…, which works over a selection.
struct FlatFieldSection: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSubheading(title: "Flat-Field")
            if let flat = model.parameters.flatField {
                HStack {
                    Text(flat.referenceName)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .help(flat.reference)
                    Spacer()
                    Button("Remove") { model.removeFlatField() }
                        .help("Take the flat-field correction off this photo")
                }
                DetailSliderRow(title: "Amount", value: Binding(
                    get: { model.parameters.flatField?.amount ?? 0 },
                    set: { model.parameters.flatField?.amount = $0 }),
                    range: 0...1, format: "%.0f", scale: 100, defaultValue: 1,
                    help: "How much of the reference's falloff and colour cast is taken out.",
                    label: "Flat-field amount")
                if let problem = model.flatFieldProblem {
                    Text(problem)
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("None. Photo › Flat-Field Correction… applies a reference shot through a diffuser.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.parameters.flatField?.hash) { model.ensureFlatFieldGainMap() }
    }
}
