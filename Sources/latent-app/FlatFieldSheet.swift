import SwiftUI
import UniformTypeIdentifiers
import Catalog
import PixelEngine

/// The Flat-Field Correction dialog's state (Photo › Flat-Field
/// Correction…): the photos it applies to, which reference, and how much.
/// The reference is one of the selected photos, as marked in the grid by
/// selecting it with the rest, or any raw chosen with Choose File….
@MainActor
final class FlatFieldSheetModel: ObservableObject, Identifiable {
    let id = UUID()
    /// The photos the dialog was opened on, and their files, in step.
    let records: [ImageRecord]
    let urls: [URL]

    /// Which selected photo is the reference, or nil.
    @Published var referenceIndex: Int?
    /// A file chosen from disk instead; wins over `referenceIndex`.
    @Published var referenceFile: URL?
    /// The Amount the photos get, 0…100.
    @Published var amount: Double = 100

    init(records: [ImageRecord], urls: [URL]) {
        precondition(records.count == urls.count)
        self.records = records
        self.urls = urls
        // A reference is usually a frame of its own among the selection,
        // named so: one whose file name says "flat" is taken as it.
        referenceIndex = urls.firstIndex { $0.lastPathComponent.lowercased().contains("flat") }
    }

    var referenceURL: URL? { referenceFile ?? referenceIndex.map { urls[$0] } }

    /// The photos the correction is written to: all but the reference.
    var targets: [ImageRecord] {
        guard let reference = referenceURL?.standardizedFileURL else { return records }
        return zip(records, urls).filter { $0.1.standardizedFileURL != reference }.map(\.0)
    }

    var canApply: Bool { referenceURL != nil && !targets.isEmpty }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Flat-Field Reference"
        panel.message = "A raw shot through a diffuser with the same lens, focal length and aperture"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = urls.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        referenceFile = url
    }

    /// The job this dialog asks for, or nil when it can't go ahead yet.
    func job() -> FlatFieldJob? {
        guard canApply, let referenceURL else { return nil }
        return FlatFieldJob(referenceURL: referenceURL, amount: Float(amount / 100))
    }

    /// Starts the job on `queue` after the editor's pending edit is saved;
    /// says so when the GPU is taken.
    func start(queue: SelectionJobQueue, model: EditorModel, library: Library) {
        guard let job = job(), let gpu = model.gpu else { return }
        model.flushPendingSave()
        if !queue.start(job, records: targets, library: library, gpu: gpu) {
            library.lastError = "Flat-field correction couldn’t start: an export or another job is using the "
                + "graphics processor, or the photos are no longer in the open folder."
        }
    }
}

struct FlatFieldSheet: View {
    @ObservedObject var model: FlatFieldSheetModel
    let onApply: (FlatFieldSheetModel) -> Void
    let canApply: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Flat-Field Correction").font(.headline)
            Text("Takes out the vignetting and colour cast a reference frame records: shoot a diffuser (or a "
                 + "plain, evenly lit surface) with the same lens, focal length and aperture, then pick it here.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Reference:", selection: Binding(
                get: { model.referenceFile == nil ? model.referenceIndex ?? -1 : -2 },
                set: { choice in
                    if choice == -2 { model.chooseFile() } else { model.referenceFile = nil; model.referenceIndex = choice >= 0 ? choice : nil }
                })) {
                Text("Choose…").tag(-1)
                if model.records.count > 1 {
                    Section("Selected photos") {
                        ForEach(model.records.indices, id: \.self) { i in
                            Text(model.records[i].fileName).tag(i)
                        }
                    }
                }
                Text(model.referenceFile.map { "File: \($0.lastPathComponent)" } ?? "Other File…").tag(-2)
            }
            .accessibilityLabel("Flat-field reference")

            HStack {
                Text("Amount")
                Slider(value: $model.amount, in: 0...100)
                    .accessibilityLabel("Flat-field amount")
                Text("\(Int(model.amount.rounded()))").monospacedDigit().frame(width: 32, alignment: .trailing)
            }

            Text(model.canApply
                 ? "Applies to \(model.targets.count) photo\(model.targets.count == 1 ? "" : "s"). Photos from a sensor of another shape are left alone."
                 : "Pick a reference to apply it to the other selected photos.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply || !canApply)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
