import SwiftUI
import Catalog
import MergeKit

/// The HDR Merge dialog's state (Photo › Photo Merge › HDR…): the engine
/// measures the selected photos, then the dialog lists them with what the
/// merge will make, or says why they can't be merged.
///
/// Kept apart from the view so the tests can walk it through each state
/// with a fake engine.
@MainActor
final class HDRMergeSheetModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// The engine is reading the photos.
        case analysing
        case ready(HDRMergeAnalysis)
        /// Why these photos can't be merged, in words for the dialog.
        case failed(String)
    }

    /// One photo of the bracket as the list shows it.
    struct Row: Identifiable, Equatable {
        /// Its index in `HDRMergeAnalysis.frames`.
        let id: Int
        let fileName: String
        /// The catalog's row, for the thumbnail; nil if the engine named a
        /// file that isn't one of the selection.
        let record: ImageRecord?
        /// "1/250 s · ƒ/8 · ISO 100".
        let exposure: String
        /// Relative to the reference frame: "+2 EV", "0 EV", "-2 EV".
        let ev: String
        let isReference: Bool
        /// What VoiceOver reads for the whole row.
        let spoken: String
    }

    /// The photos being merged, in the grid's order.
    let records: [ImageRecord]
    @Published private(set) var phase: Phase = .analysing
    /// The file name the result will get, once planned: "DSC_0107-HDR.dng".
    /// Planned again when the merge starts, since a file may arrive meanwhile.
    @Published private(set) var destinationName: String?

    /// The engine that measures the photos, and merges them on Merge.
    let engine: any HDRMerging
    private let urls: [URL]
    /// Plans the result's name from its reference photo; nil when it can't.
    private let planDestination: (ImageRecord) async -> String?
    private var analysis: Task<Void, Never>?

    /// `urls` are the files of `records`, in the same order.
    init(records: [ImageRecord], urls: [URL], engine: any HDRMerging,
         planDestination: @escaping (ImageRecord) async -> String?) {
        self.records = records
        self.urls = urls
        self.engine = engine
        self.planDestination = planDestination
    }

    /// Starts measuring the photos; `phase` follows. Once only.
    func start() {
        guard analysis == nil else { return }
        let engine = engine, urls = urls
        analysis = Task { [weak self] in
            do {
                let result = try await engine.analyse(urls)
                guard let self, !Task.isCancelled else { return }
                // The name before the list, so the dialog doesn't grow a
                // line a moment after it has appeared.
                var name: String?
                if let reference = self.record(for: result.frames, at: result.referenceIndex) {
                    name = await self.planDestination(reference)
                }
                guard !Task.isCancelled else { return }
                self.destinationName = name
                self.phase = .ready(result)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    /// Stops an analysis under way (the dialog was closed).
    func cancel() {
        analysis?.cancel()
    }

    var analysisResult: HDRMergeAnalysis? {
        if case .ready(let result) = phase { return result }
        return nil
    }

    /// The reference photo's catalog row, which names the result.
    var referenceRecord: ImageRecord? {
        analysisResult.flatMap { record(for: $0.frames, at: $0.referenceIndex) }
    }

    /// The records in the engine's order (brightest first), for the recipe.
    var recordsInFrameOrder: [ImageRecord?] {
        guard let result = analysisResult else { return [] }
        return result.frames.indices.map { record(for: result.frames, at: $0) }
    }

    var rows: [Row] {
        guard let result = analysisResult, result.frames.indices.contains(result.referenceIndex) else { return [] }
        let referenceEV = result.frames[result.referenceIndex].relativeEV
        return result.frames.enumerated().map { index, frame in
            let stops = frame.relativeEV - referenceEV
            let exposure = MetadataFormat.exposureLine(shutter: frame.exposureSeconds, aperture: frame.aperture,
                                                       iso: Int(frame.iso.rounded()), focal: nil)
            let isReference = index == result.referenceIndex
            var spoken = [frame.url.lastPathComponent]
            spoken += exposure.components(separatedBy: " · ").filter { !$0.isEmpty }
            spoken.append(isReference ? "reference" : Self.spokenEV(stops))
            return Row(id: index, fileName: frame.url.lastPathComponent,
                       record: record(for: result.frames, at: index), exposure: exposure,
                       ev: Self.evText(stops), isReference: isReference, spoken: spoken.joined(separator: ", "))
        }
    }

    /// "6016 × 4016 (24.2 MP)".
    var sizeText: String? {
        analysisResult.map { MetadataFormat.dimensions(width: $0.width, height: $0.height) }
    }

    /// "About 139.5 MB".
    var estimatedSizeText: String? {
        analysisResult.map { "About " + MetadataFormat.fileSize($0.estimatedOutputBytes) }
    }

    var warnings: [String] {
        guard let result = analysisResult else { return [] }
        return result.warnings.map { Self.text(for: $0, frames: result.frames) }
    }

    /// The analysing line: "Analysing 3 photos…".
    var analysingText: String { "Analysing \(records.count) photos…" }

    /// Said whatever the state: the merge reads the raw files themselves.
    static let editsNotice = "The merge starts from the original raw files. Edits you made to these photos aren’t used."

    // MARK: - Words

    /// Stops as the list shows them, to a tenth: "+2 EV", "+0.7 EV",
    /// "0 EV", "-2 EV".
    static func evText(_ stops: Double) -> String {
        let tenths = (stops * 10).rounded() / 10
        guard tenths != 0 else { return "0 EV" }
        return (tenths > 0 ? "+" : "-") + number(abs(tenths)) + " EV"
    }

    /// A number of stops to a tenth, without a trailing ".0": "2", "0.7".
    private static func number(_ stops: Double) -> String {
        let tenths = (stops * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    /// The same for VoiceOver, which reads "-2" unreliably: "2 stops
    /// brighter", "0.7 stops darker", "same exposure".
    static func spokenEV(_ stops: Double) -> String {
        let tenths = (stops * 10).rounded() / 10
        guard tenths != 0 else { return "same exposure as the reference" }
        return "\(stopsText(tenths)) \(tenths > 0 ? "brighter" : "darker") than the reference"
    }

    /// A warning in plain words.
    static func text(for warning: HDRMergeWarning, frames: [HDRMergeFrame]) -> String {
        switch warning {
        case .framesLookMisaligned(let shift):
            // Whole pixels, and never "0 px": the engine only warns about a
            // shift it can see.
            let pixels = max(1, Int(shift.rounded()))
            return "These photos don’t line up exactly (up to \(pixels) px apart). Photo Merge doesn’t align "
                + "handheld brackets yet, so edges may look doubled. For now, use brackets shot on a tripod."
        case .exposureMetadataDisagrees(let index, let exif, let measured):
            let name = frames.indices.contains(index) ? frames[index].url.lastPathComponent : "One photo"
            let apart = abs(measured - exif)
            return "\(name) looks \(stopsText(apart)) \(measured < exif ? "darker" : "brighter") than its "
                + "camera settings say. Photo Merge uses the brightness it measured."
        case .smallExposureRange(let stops):
            return "These photos are only \(stopsText(stops)) apart, so the merge adds little. "
                + "HDR works best with photos 2 stops apart."
        }
    }

    /// "1 stop", "0.3 stops", "2 stops".
    static func stopsText(_ stops: Double) -> String {
        let text = number(abs(stops))
        return "\(text) \(text == "1" ? "stop" : "stops")"
    }

    /// What the dialog says when the photos can't be analysed.
    static func message(for error: Error) -> String {
        if let merge = error as? HDRMergeError, let description = merge.errorDescription { return description }
        return "These photos couldn’t be read for an HDR merge. \(error.localizedDescription)"
    }

    // MARK: - Matching the engine's files to the catalog

    private func record(for frames: [HDRMergeFrame], at index: Int) -> ImageRecord? {
        guard frames.indices.contains(index) else { return nil }
        let wanted = Self.comparablePath(frames[index].url)
        guard let position = urls.firstIndex(where: { Self.comparablePath($0) == wanted }) else { return nil }
        return records[position]
    }

    /// The engine may hand URLs back resolved (/private/var for /var).
    private static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The HDR Merge dialog. Sized to its content: a few lines while the photos
/// are read, then the list and what the merge will make, or the reason
/// they can't be merged with only Close.
struct HDRMergeSheet: View {
    @ObservedObject var model: HDRMergeSheetModel
    /// The thumbnail of a photo in the list.
    let thumbnail: (ImageRecord) async -> CGImage?
    /// Merge was pressed with this analysis; the dialog closes itself.
    let onMerge: (HDRMergeAnalysis) -> Void
    /// Merge is refused while another GPU job (an export, a merge) runs.
    var canMerge = true
    @Environment(\.dismiss) private var dismiss

    /// Rows shown before the list scrolls: a bracket is usually 3 to 5.
    private static let visibleRows = 5
    private static let rowHeight: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HDR Merge")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .analysing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                        .accessibilityHidden(true)
                    Text(model.analysingText)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.analysingText)
            case .ready:
                frameList
                details
                warnings
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Can’t merge: \(message)")
            }
            Text(HDRMergeSheetModel.editsNotice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { model.cancel() }
    }

    private var frameList: some View {
        let rows = model.rows
        let list = VStack(spacing: 0) {
            ForEach(rows) { row in
                HDRMergeFrameRow(row: row, thumbnail: thumbnail)
                    .frame(height: Self.rowHeight)
                if row.id != rows.last?.id { Divider() }
            }
        }
        return Group {
            if rows.count > Self.visibleRows {
                ScrollView { list }
                    .frame(height: Self.rowHeight * CGFloat(Self.visibleRows) + 24)
            } else {
                list
            }
        }
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photos to merge, brightest first")
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            if let size = model.sizeText { detail("Size", size) }
            if let estimate = model.estimatedSizeText { detail("File size", estimate) }
            detail("Saved as", model.destinationName ?? "—")
        }
        .font(.callout)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    @ViewBuilder private var warnings: some View {
        ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Warning: \(warning)")
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            if case .failed = model.phase {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel") {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    guard let analysis = model.analysisResult else { return }
                    onMerge(analysis)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.analysisResult == nil || !canMerge)
                .accessibilityHint("Closes the dialog and merges in the background; progress shows in the library panel.")
                .help(canMerge ? "Merge in the background; progress shows under Export in the library panel."
                               : "Wait for the export or merge under way to finish.")
            }
        }
    }
}

/// One photo in the list: thumbnail, name, exposure, stops and the
/// Reference badge, read by VoiceOver as one line.
private struct HDRMergeFrameRow: View {
    let row: HDRMergeSheetModel.Row
    let thumbnail: (ImageRecord) async -> CGImage?
    @State private var image: CGImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 56, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.exposure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if row.isReference {
                Text("Reference")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .fixedSize()
            }
            Text(row.ev)
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
        .task(id: row.record?.id) {
            guard let record = row.record else { return }
            image = await thumbnail(record)
        }
    }
}
