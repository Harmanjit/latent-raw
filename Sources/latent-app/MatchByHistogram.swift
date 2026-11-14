import SwiftUI
import Catalog
import PixelEngine
import RawCore

/// Photo › Match Exposures by Histogram…: the variant of Match Total
/// Exposures (MatchTotalExposures.swift, which works from shutter,
/// aperture and ISO and is unchanged) that looks at the pictures instead.
///
/// Each photo gets a small scene-linear analysis render of its edit before
/// exposure (`ExposurePicking.percentileLuminance`, no tone curve); the
/// luminance below which Percentile of its pixels fall is brought to the
/// target by its Exposure slider. The target is either a fixed level, in
/// stops from 18% grey, or the lead photo's own percentile with its
/// Exposure applied, in which case the lead keeps its edit.
///
/// It reads every raw, so it runs on the `SelectionJobQueue` like Remove
/// Dust, taking the GPU slot, and writes every photo's edit at the end as
/// one Library undo group, skipping any photo edited meanwhile.
final class HistogramExposureMatchJob: SelectionJob, @unchecked Sendable {
    enum Target: Sendable {
        /// Stops from 18% grey.
        case stops(Float)
        /// The lead photo, as stored.
        case lead(url: URL, imageID: Int64, storedJSON: String?, name: String)
    }

    let percentile: Float
    let target: Target
    private let lock = NSLock()
    /// The scene-linear luminance every photo's percentile is brought to.
    private var targetLuminance: Float?

    init(percentile: Float, target: Target) {
        self.percentile = percentile
        self.target = target
    }

    let title = "Matching exposures"
    let outputKind = OutputJobs.Kind.batchEdit
    let undoName = "Match Exposures by Histogram"

    func prepare(gpu: GPUContext, progress: @Sendable (MergeProgress) -> Void) async throws {
        switch target {
        case .stops(let ev):
            lock.withLock { targetLuminance = 0.18 * exp2(ev) }
        case .lead(let url, _, let json, let name):
            progress(MergeProgress(fraction: 0, stage: "Measuring \(name)"))
            let session = try ImageSession(file: try RawFile(path: url.path), gpu: gpu)
            let parameters = try ExportPlan.parameters(editStackJSON: json, session: session, colorSpace: .sRGB)
            guard let level = try ExposurePicking.percentileLuminance(
                session: session, pipeline: RenderPipeline(gpu: gpu), gpu: gpu,
                parameters: parameters, percentile: percentile), level > ExposurePicking.darkestUsable else {
                throw HistogramMatchError.leadTooDark(name)
            }
            lock.withLock { targetLuminance = level * exp2(parameters.exposureEV) }
        }
    }

    func process(_ input: SelectionJobInput, gpu: GPUContext) async throws -> SelectionJobResult {
        guard let goal = lock.withLock({ targetLuminance }) else { return SelectionJobResult() }
        if case .lead(_, let leadID, _, _) = target, input.record.id == leadID { return SelectionJobResult() }
        let session = try ImageSession(file: try RawFile(path: input.fileURL.path), gpu: gpu)
        let parameters = try ExportPlan.parameters(editStackJSON: input.storedJSON, session: session, colorSpace: .sRGB)
        try Task.checkCancellation()
        guard let level = try ExposurePicking.percentileLuminance(
                session: session, pipeline: RenderPipeline(gpu: gpu), gpu: gpu,
                parameters: parameters, percentile: percentile),
              let ev = ExposurePicking.exposure(patch: level, target: goal) else {
            return SelectionJobResult(note: "\(input.record.fileName) is too dark at that percentile to measure, so it was left alone")
        }
        guard ev != parameters.exposureEV else { return SelectionJobResult() }
        // Only Exposure changes; the stored stack is otherwise kept as it
        // was, frame and geometry included.
        return SelectionJobResult(newJSON: .some(try ExposureMatching.settingExposure(ev, inEditJSON: input.storedJSON)),
                                  count: 1)
    }

    func summary(changed: Int, counted: Int, skipped: Int, elapsed: TimeInterval) -> String {
        var text = "Matched the exposure of \(changed) photo\(changed == 1 ? "" : "s") by histogram"
        text += String(format: elapsed < 10 ? " in %.1f s" : " in %.0f s", elapsed)
        if skipped > 0 { text += " · \(skipped) skipped" }
        return text
    }

    func announcement(changed: Int) -> String {
        "Exposure matching finished: \(changed) photo\(changed == 1 ? "" : "s") changed"
    }
}

enum HistogramMatchError: Error, LocalizedError, Equatable {
    case leadTooDark(String)

    var errorDescription: String? {
        switch self {
        case .leadTooDark(let name):
            "\(name) is too dark at that percentile to match the others to. Try a higher percentile."
        }
    }
}

/// The dialog's state.
@MainActor
final class HistogramMatchSheetModel: ObservableObject, Identifiable {
    let id = UUID()
    let records: [ImageRecord]
    let lead: ImageRecord?
    /// 1…99.
    @Published var percentile: Double = 50
    @Published var fromLead = true
    /// Stops from 18% grey, −3…3.
    @Published var targetStops: Double = 0

    init(records: [ImageRecord], lead: ImageRecord?) {
        self.records = records
        self.lead = lead
        fromLead = lead != nil
    }

    /// Reads the lead's stored edit, then starts the job on `queue` after
    /// the editor's pending edit is saved.
    func start(queue: SelectionJobQueue, model: EditorModel, library: Library) {
        guard let gpu = model.gpu, let catalog = library.catalog else { return }
        model.flushPendingSave()
        let percentile = Float(percentile / 100)
        let records = records
        if fromLead, let lead, let leadID = lead.id, let url = library.fileURL(for: lead) {
            Task { @MainActor in
                do {
                    let json = try await catalog.storedEdit(forImageID: leadID)?.json
                    let job = HistogramExposureMatchJob(percentile: percentile,
                                                        target: .lead(url: url, imageID: leadID, storedJSON: json,
                                                                      name: lead.fileName))
                    Self.begin(job, queue: queue, records: records, library: library, gpu: gpu)
                } catch {
                    library.lastError = "Match Exposures by Histogram couldn’t read \(lead.fileName)’s edit: \(error.localizedDescription)"
                }
            }
        } else {
            Self.begin(HistogramExposureMatchJob(percentile: percentile, target: .stops(Float(targetStops))),
                       queue: queue, records: records, library: library, gpu: gpu)
        }
    }

    private static func begin(_ job: HistogramExposureMatchJob, queue: SelectionJobQueue, records: [ImageRecord],
                              library: Library, gpu: GPUContext) {
        if !queue.start(job, records: records, library: library, gpu: gpu) {
            library.lastError = "Match Exposures by Histogram couldn’t start: an export or another job is using the "
                + "graphics processor, or the photos are no longer in the open folder."
        }
    }
}

/// Opens the dialog over the selection; shared so ContentView needs only
/// one line for the sheet.
@MainActor
final class HistogramMatchPresenter: ObservableObject {
    static let shared = HistogramMatchPresenter()
    @Published var sheet: HistogramMatchSheetModel?

    func present(library: Library) {
        let records = library.selectedImages
        guard records.count >= 2 else { return }
        sheet = HistogramMatchSheetModel(records: records, lead: library.selectedImage)
    }
}

struct HistogramMatchSheet: View {
    @ObservedObject var model: HistogramMatchSheetModel
    let onMatch: (HistogramMatchSheetModel) -> Void
    let canMatch: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Match Exposures by Histogram").font(.headline)
            Text("Sets each photo’s Exposure so the same share of its pixels falls below one brightness. Unlike Match Total Exposures it reads the pictures, so it works without shutter, aperture and ISO, and evens out changing light.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Percentile:")
                Slider(value: $model.percentile, in: 1...99, step: 1)
                    .accessibilityLabel("Percentile")
                    .accessibilityValue("\(Int(model.percentile)) percent")
                Text("\(Int(model.percentile))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .help("50% matches the median brightness; a higher percentile matches the highlights, a lower one the shadows")
            Picker("Target:", selection: $model.fromLead) {
                Text("The lead photo" + (model.lead.map { " (\($0.fileName))" } ?? "")).tag(true)
                    .disabled(model.lead == nil)
                Text("A fixed level").tag(false)
            }
            .pickerStyle(.radioGroup)
            if !model.fromLead {
                HStack {
                    Text("Level:")
                    Slider(value: $model.targetStops, in: -3...3, step: 0.1)
                        .accessibilityLabel("Target level")
                        .accessibilityValue(String(format: "%+.1f stops from 18 percent grey", model.targetStops))
                    Text(String(format: "%+.1f EV", model.targetStops)).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                .help("Stops above or below 18% grey that the percentile is brought to")
            }
            Text("\(model.records.count) photos selected" + (model.fromLead ? "; the lead keeps its edit" : ""))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Match") {
                    onMatch(model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canMatch || (model.fromLead && model.lead == nil))
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

extension View {
    /// The Match Exposures by Histogram sheet, for ContentView.
    func histogramMatchSheet(queue: SelectionJobQueue, model: EditorModel, library: Library, canMatch: Bool) -> some View {
        modifier(HistogramMatchSheetHost(queue: queue, model: model, library: library, canMatch: canMatch))
    }
}

private struct HistogramMatchSheetHost: ViewModifier {
    @ObservedObject var presenter = HistogramMatchPresenter.shared
    let queue: SelectionJobQueue
    let model: EditorModel
    let library: Library
    let canMatch: Bool

    func body(content: Content) -> some View {
        content.sheet(item: $presenter.sheet) { sheet in
            HistogramMatchSheet(model: sheet, onMatch: { $0.start(queue: queue, model: model, library: library) },
                                canMatch: canMatch)
                .motionFollowsAccessibility()
        }
    }
}
