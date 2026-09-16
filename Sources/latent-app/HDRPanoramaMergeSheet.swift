import SwiftUI
import Catalog
import MergeKit

/// The HDR Panorama dialog's state (Photo › Photo Merge › HDR Panorama…,
/// experimental): the engine sorts the selected photos into positions,
/// works out where each position points, and the dialog shows what it
/// found, both parents' options and how big the result will be — or why
/// these photos aren't an HDR panorama.
///
/// **Experimental, and it says so.** No real HDR panorama exists to check
/// Latent against (none is freely licensed and none has been shot for it),
/// so the dialog says so in a sentence the user can't miss, and
/// docs/wiki/Photo-Merge.md repeats it.
///
/// **No preview.** The HDR dialog previews reduced frames and the Panorama
/// dialog previews the real stitch of reduced frames; an HDR panorama's
/// preview would have to merge every position first, which is most of the
/// work. Rather than show something that isn't what the merge will make,
/// this dialog shows the positions it found and says what it will do.
///
/// **What re-measures.** Projection changes the canvas, so it measures
/// again; Auto Align and Deghost belong to the per-position merges, which
/// happen after Merge, so they don't.
///
/// Kept apart from the view so tests can walk it through each state with a
/// fake engine.
@MainActor
final class HDRPanoramaMergeSheetModel: ObservableObject, Identifiable {
    enum Phase {
        case analysing
        case ready(HDRPanoramaAnalysis)
        /// Why these photos can't be merged, in words for the dialog.
        case failed(String)
    }

    /// One position as the list shows it.
    struct Row: Identifiable, Equatable {
        /// Its index in `HDRPanoramaAnalysis.grouping.positions`.
        let id: Int
        /// "Position 1".
        let title: String
        /// The catalog row of the position's reference photo, for the
        /// thumbnail; nil when it isn't one of the selection.
        let record: ImageRecord?
        /// "3 photos · P00-0.dng – P00-2.dng".
        let photos: String
        /// "−2, 0, +2 EV", or "already merged" / "not bracketed".
        let exposures: String
        /// Where it points: "34° left", "centre".
        let direction: String
        /// True when the panorama couldn't join this position to the rest.
        let isLeftOut: Bool
        /// What VoiceOver reads for the whole row.
        let spoken: String
    }

    /// The photos being merged, in the grid's order.
    let records: [ImageRecord]
    @Published private(set) var phase: Phase = .analysing
    /// The file name the result will get: "DSC_0107-HDRPano.dng".
    @Published private(set) var destinationName: String?

    /// Line the frames of each bracket up before merging them.
    @Published var autoAlign: Bool {
        didSet { preferences.autoAlign = autoAlign }
    }
    /// How hard each bracket's merge looks for things that moved.
    @Published var deghost: DeghostAmount {
        didSet { preferences.deghost = deghost }
    }
    /// How the positions are flattened onto the panorama. Changing it
    /// measures again: the canvas, its size and the warnings depend on it.
    @Published var projection: PanoramaProjection {
        didSet {
            guard projection != oldValue else { return }
            preferences.projection = projection
            reanalyse()
        }
    }
    @Published var autoCrop: Bool {
        didSet { preferences.autoCrop = autoCrop }
    }
    @Published var autoSettings: Bool {
        didSet { preferences.autoSettings = autoSettings }
    }
    /// Whether the user has agreed to the panorama being made smaller.
    /// Never remembered, as the Panorama dialog's isn't.
    @Published var acceptsDownsampling = false

    /// The engine that measures the photos, and merges them on Merge.
    let engine: any HDRPanoramaMerging
    private let urls: [URL]
    /// Plans the result's name from the photo it will be named after.
    private let planDestination: (ImageRecord) async -> String?
    private let preferences: HDRPanoramaMergePreferences
    private var analysis: Task<Void, Never>?

    /// The sentence that must appear wherever this merge does.
    static let experimentalNotice =
        "Experimental: HDR Panorama has never been checked on a real HDR panorama, because nobody has shot one for "
        + "Latent yet. Look at the result before you trust it."

    /// `urls` are the files of `records`, in the same order.
    init(records: [ImageRecord], urls: [URL], engine: any HDRPanoramaMerging, defaults: UserDefaults = .standard,
         planDestination: @escaping (ImageRecord) async -> String?) {
        self.records = records
        self.urls = urls
        self.engine = engine
        self.planDestination = planDestination
        let preferences = HDRPanoramaMergePreferences(defaults: defaults)
        self.preferences = preferences
        autoAlign = preferences.autoAlign
        deghost = preferences.deghost
        projection = preferences.projection
        autoCrop = preferences.autoCrop
        autoSettings = preferences.autoSettings
    }

    /// The options the merge runs with.
    var options: HDRPanoramaOptions {
        HDRPanoramaOptions(hdr: HDRMergeOptions(deghost: deghost, autoAlign: autoAlign),
                           panorama: PanoramaMergeOptions(projection: projection, autoCrop: autoCrop,
                                                          autoSettings: autoSettings))
    }

    /// Starts measuring the photos; `phase` follows. Once only (changing
    /// the projection starts again by itself).
    ///
    /// - Parameter after: an analysis being thrown away, waited for before
    ///   this one starts, as in the Panorama dialog: two would share one
    ///   GPU and only compete.
    func start(after previous: Task<Void, Never>? = nil) {
        guard analysis == nil else { return }
        let engine = engine, urls = urls, options = options
        analysis = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let result = try await engine.analyse(urls, options: options)
                guard let self, !Task.isCancelled else { return }
                var name: String?
                if let reference = self.referenceRecord(of: result) {
                    name = await self.planDestination(reference)
                }
                guard !Task.isCancelled else { return }
                self.destinationName = name
                // A size agreed to is agreed to for that size only.
                self.acceptsDownsampling = false
                self.phase = .ready(result)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    /// Stops an analysis under way and lets the engine free what it kept
    /// (the dialog was closed, by Cancel or Merge).
    func cancel() {
        analysis?.cancel()
        Task { [engine] in await engine.releasePreviews() }
    }

    private func reanalyse() {
        guard let running = analysis else { return }
        running.cancel()
        analysis = nil
        phase = .analysing
        start(after: running)
    }

    var analysisResult: HDRPanoramaAnalysis? {
        if case .ready(let result) = phase { return result }
        return nil
    }

    // MARK: - What the dialog shows

    var analysingText: String { "Sorting \(records.count) photos into positions…" }

    /// "3 exposures at each of 5 positions, from the repeating exposures".
    var groupingText: String? {
        guard let result = analysisResult else { return nil }
        return "\(result.grouping.summaryText), \(result.grouping.evidence.text)."
    }

    var rows: [Row] {
        guard let result = analysisResult else { return [] }
        return result.grouping.positions.enumerated().map { index, position in
            let frames = position.frames.compactMap { result.photos.indices.contains($0) ? result.photos[$0] : nil }
            let names = frames.map { $0.url.lastPathComponent }
            let photos = frames.count == 1 ? (names.first ?? "")
                : "\(frames.count) photos · \(names.first ?? "") – \(names.last ?? "")"
            let exposures: String
            if position.alreadyMerged {
                exposures = "already merged"
            } else if frames.count == 1 {
                exposures = "not bracketed"
            } else {
                exposures = Self.exposureSpread(frames)
            }
            let panoramaFrame = self.panoramaFrame(of: position, in: result)
            let leftOut = panoramaFrame?.leftOut ?? false
            let direction = leftOut ? "" : PanoramaMergeSheetModel.directionText(panoramaFrame?.yawPitchRoll?.x)
            var spoken = ["Position \(index + 1)", photos, exposures]
            spoken.append(leftOut ? "left out of the panorama"
                          : PanoramaMergeSheetModel.spokenDirection(panoramaFrame?.yawPitchRoll?.x))
            return Row(id: index, title: "Position \(index + 1)",
                       record: self.record(for: frames.first?.url), photos: photos, exposures: exposures,
                       direction: direction, isLeftOut: leftOut, spoken: spoken.joined(separator: ", "))
        }
    }

    /// The exposures of one bracket relative to its middle frame, as the
    /// HDR dialog writes stops: "-2 EV, 0 EV, +2 EV".
    static func exposureSpread(_ frames: [HDRPanoramaPhoto]) -> String {
        let stops = frames.compactMap(\.lightStops).sorted()
        guard stops.count == frames.count, !stops.isEmpty else { return "\(frames.count) exposures" }
        let middle = stops[(stops.count - 1) / 2]
        return stops.map { HDRMergeSheetModel.evText($0 - middle) }.joined(separator: ", ")
    }

    /// The Deghost picker's names, as the HDR dialog spells them.
    static func name(for amount: DeghostAmount) -> String {
        switch amount {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// "12,482 × 3,276 (41 MP)".
    var sizeText: String? {
        analysisResult.map { PanoramaMergeSheetModel.pixelSize($0.panorama.outputSize.width,
                                                               $0.panorama.outputSize.height) }
    }

    var estimatedSizeText: String? {
        analysisResult.map { "About " + MetadataFormat.fileSize($0.estimatedOutputBytes) }
    }

    /// "185° across, 34° tall".
    var coverageText: String? {
        guard let result = analysisResult else { return nil }
        return "\(PanoramaMergeSheetModel.degrees(result.panorama.widthDegrees)) across, "
            + "\(PanoramaMergeSheetModel.degrees(result.panorama.heightDegrees)) tall"
    }

    /// What the merged brackets need while it runs; nil when nothing is
    /// merged (every position was merged before).
    var scratchText: String? {
        guard let result = analysisResult, result.estimatedScratchBytes > 0 else { return nil }
        return MetadataFormat.fileSize(result.estimatedScratchBytes) + ", given back at the end"
    }

    var projectionHint: String {
        guard projection == .automatic else { return PanoramaMergeSheetModel.hint(for: projection) }
        guard let result = analysisResult else { return PanoramaMergeSheetModel.hint(for: .automatic) }
        let chosen = result.panorama.layout.canvas.projection
        return "Latent chose \(PanoramaMergeSheetModel.name(for: chosen)). "
            + PanoramaMergeSheetModel.hint(for: chosen)
    }

    /// The size the panorama will be made smaller to, when it must be.
    var downsampling: PanoramaOutputSize? {
        guard let result = analysisResult else { return nil }
        for warning in result.warnings {
            if case .panorama(.downsampled(let size)) = warning { return size }
        }
        return result.panorama.outputSize.needsDownsampling ? result.panorama.outputSize : nil
    }

    var downsampleText: String? {
        downsampling.map { PanoramaMergeSheetModel.text(for: .downsampled(outputSize: $0), frames: []) }
    }

    var needsDownsamplingConsent: Bool { downsampling != nil }

    var consentLabel: String? {
        downsampling.map { "Merge at \(PanoramaMergeSheetModel.percent($0.scale))" }
    }

    var mergeButtonTitle: String { consentLabel ?? "Merge" }

    var canMerge: Bool {
        analysisResult != nil && (!needsDownsamplingConsent || acceptsDownsampling)
    }

    /// The analysis's warnings in plain words, without the downsampling one
    /// (which has its own agreement above them).
    var warnings: [String] {
        guard let result = analysisResult else { return [] }
        return result.warnings.compactMap { warning in
            if case .panorama(.downsampled) = warning { return nil }
            return warning.message(result)
        }
    }

    static let editsNotice = PhotoMergeText.editsNotice

    /// What the dialog says when the photos can't be sorted or measured.
    static func message(for error: Error) -> String {
        if let hdrPanorama = error as? HDRPanoramaError, let description = hdrPanorama.errorDescription {
            return description
        }
        if let panorama = error as? PanoramaError, let description = panorama.errorDescription { return description }
        if let hdr = error as? HDRMergeError, let description = hdr.errorDescription { return description }
        return "These photos couldn’t be read for an HDR panorama. \(error.localizedDescription)"
    }

    // MARK: - Matching the engine's files to the catalog

    /// The catalog rows in the engine's order (capture order), for the recipe.
    var recordsInPhotoOrder: [ImageRecord?] {
        guard let result = analysisResult else { return [] }
        return result.photos.map { record(for: $0.url) }
    }

    /// The photo the result is named after.
    func referenceRecord(of result: HDRPanoramaAnalysis) -> ImageRecord? {
        guard let index = result.referencePhotoIndex, result.photos.indices.contains(index) else { return nil }
        return record(for: result.photos[index].url)
    }

    /// The stitch's frame for a position: the panorama's analysis lists one
    /// frame per position, named by that position's reference photo.
    private func panoramaFrame(of position: HDRPanoramaGrouping.Position,
                               in result: HDRPanoramaAnalysis) -> PanoramaMergeFrame? {
        guard result.photos.indices.contains(position.reference) else { return nil }
        let wanted = HDRMergeSheetModel.comparablePath(result.photos[position.reference].url)
        return result.panorama.frames.first { HDRMergeSheetModel.comparablePath($0.url) == wanted }
    }

    private func record(for url: URL?) -> ImageRecord? {
        guard let url else { return nil }
        let wanted = HDRMergeSheetModel.comparablePath(url)
        guard let position = urls.firstIndex(where: { HDRMergeSheetModel.comparablePath($0) == wanted })
        else { return nil }
        return records[position]
    }
}

/// The HDR Panorama dialog: what the photos were sorted into, both parents'
/// options, what will be made, the agreement to a smaller panorama if it
/// needs one, the warnings, and the buttons. The word Experimental sits at
/// the top, where it can't be missed.
struct HDRPanoramaMergeSheet: View {
    @ObservedObject var model: HDRPanoramaMergeSheetModel
    /// The thumbnail of a position's first photo.
    let thumbnail: (ImageRecord) async -> CGImage?
    /// Merge was pressed with this analysis and these options; the dialog
    /// closes itself.
    let onMerge: (HDRPanoramaAnalysis, HDRPanoramaOptions) -> Void
    /// Merge is refused while another GPU job (an export, a merge) runs.
    var canMerge = true
    @Environment(\.dismiss) private var dismiss

    private static let visibleRows = 4
    private static let rowHeight: CGFloat = 46
    private static let labelWidth: CGFloat = 90
    private static let optionsWidth: CGFloat = 346
    private static let notesHeight: CGFloat = 72
    static let width: CGFloat = 720

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("HDR Panorama")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Experimental")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.22), in: Capsule())
            }
            Text(HDRPanoramaMergeSheetModel.experimentalNotice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch model.phase {
            case .analysing:
                HStack(alignment: .top, spacing: 16) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                            .accessibilityHidden(true)
                        Text(model.analysingText)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.analysingText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    options
                }
            case .ready:
                if let grouping = model.groupingText {
                    Text(grouping)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Positions found: \(grouping)")
                }
                HStack(alignment: .top, spacing: 16) {
                    positionList
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 10) {
                        options
                        details
                    }
                    .fixedSize()
                }
                consent
                notes
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Can’t merge: \(message)")
            }
            HStack(alignment: .center, spacing: 12) {
                Text(HDRPanoramaMergeSheetModel.editsNotice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                buttons
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .onDisappear { model.cancel() }
    }

    private var positionList: some View {
        let rows = model.rows
        let list = VStack(spacing: 0) {
            ForEach(rows) { row in
                HDRPanoramaPositionRow(row: row, thumbnail: thumbnail)
                    .frame(height: Self.rowHeight)
                if row.id != rows.last?.id { Divider() }
            }
        }
        return Group {
            if rows.count > Self.visibleRows {
                ScrollView { list }
                    .frame(height: Self.rowHeight * (CGFloat(Self.visibleRows) + 0.5))
            } else {
                list
            }
        }
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Positions, in the order they were taken")
        .help("The positions Latent found, with the photos at each one and the exposures they were shot at. "
              + "Each position is merged to HDR, then the results are stitched.")
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            if let size = model.sizeText { detail("Size", size) }
            if let coverage = model.coverageText { detail("Sweep", coverage) }
            if let estimate = model.estimatedSizeText { detail("File size", estimate) }
            if let scratch = model.scratchText { detail("Scratch", scratch) }
            detail("Saved as", model.destinationName ?? "—")
        }
        .font(.callout)
        .frame(width: Self.optionsWidth, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    /// Both parents' options: Auto Align and Deghost for the brackets,
    /// Projection, Auto Crop and Auto Settings for the stitch.
    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Auto Align").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Toggle("Line up each bracket’s frames", isOn: $model.autoAlign)
                    .accessibilityLabel("Auto Align")
                    .accessibilityHint("Lines the frames of each bracket up before merging that position.")
                    .help("Lines the frames of each bracket up before merging them. Leave it on unless every "
                          + "bracket was shot on a tripod.")
            }
            GridRow {
                Text("Deghost").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Picker("Deghost", selection: $model.deghost) {
                    ForEach(DeghostAmount.allCases, id: \.self) { amount in
                        Text(HDRPanoramaMergeSheetModel.name(for: amount)).tag(amount)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("Deghost")
                .accessibilityValue(HDRPanoramaMergeSheetModel.name(for: model.deghost))
                .help("How hard each position’s merge looks for things that moved between its frames.")
            }
            GridRow {
                Text("Projection").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Picker("Projection", selection: $model.projection) {
                    ForEach(PanoramaProjection.allCases, id: \.self) { projection in
                        Text(PanoramaMergeSheetModel.name(for: projection)).tag(projection)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .accessibilityLabel("Projection")
                .accessibilityValue(PanoramaMergeSheetModel.name(for: model.projection))
                .accessibilityHint("How the positions are flattened onto the panorama. "
                                   + "Changing it measures the photos again.")
            }
            GridRow {
                Color.clear.frame(width: Self.labelWidth, height: 1)
                    .accessibilityHidden(true)
                Text(model.projectionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Projection: \(model.projectionHint)")
            }
            GridRow {
                Text("Auto Crop").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Toggle("Hide the blank edges", isOn: $model.autoCrop)
                    .accessibilityLabel("Auto Crop")
                    .help("Opens the result cropped to the largest rectangle with no blank edges. "
                          + "It is an ordinary crop edit: undo it in Develop.")
            }
            GridRow {
                Text("Auto Settings").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Toggle("Open the result auto adjusted", isOn: $model.autoSettings)
                    .accessibilityLabel("Auto Settings")
                    .help("Applies Develop’s Auto Adjust to the result as its first edit.")
            }
        }
        .font(.callout)
        .frame(width: Self.optionsWidth, alignment: .leading)
    }

    @ViewBuilder private var consent: some View {
        if let text = model.downsampleText, let label = model.consentLabel {
            VStack(alignment: .leading, spacing: 6) {
                Label(text, systemImage: "arrow.down.right.and.arrow.up.left")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(text)
                Toggle(label, isOn: $model.acceptsDownsampling)
                    .accessibilityLabel("Agree to merge at "
                                        + PanoramaMergeSheetModel.percent(model.downsampling?.scale ?? 1))
                    .help("Latent never refuses a panorama for its size: it merges it as large as this Mac can edit.")
            }
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private var notes: some View {
        let warnings = model.warnings
        let content = VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Warning: \(warning)")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        if warnings.count > 2 {
            ScrollView { content }
                .frame(height: Self.notesHeight)
        } else {
            content
        }
    }

    private var buttons: some View {
        HStack {
            if case .failed = model.phase {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel") {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(model.mergeButtonTitle) {
                    guard let analysis = model.analysisResult else { return }
                    onMerge(analysis, model.options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canMerge || !canMerge)
                .accessibilityHint(model.needsDownsamplingConsent && !model.acceptsDownsampling
                                   ? "Agree to the smaller size first."
                                   : "Closes the dialog and merges in the background; progress shows in the "
                                     + "library panel.")
                .help(canMerge ? "Merge in the background; progress shows under Export in the library panel."
                               : "Wait for the export or merge under way to finish.")
            }
        }
        .fixedSize()
    }
}

/// One position in the list: the thumbnail of its first photo, what it
/// holds, its exposures and where it points, read by VoiceOver as one line.
private struct HDRPanoramaPositionRow: View {
    let row: HDRPanoramaMergeSheetModel.Row
    let thumbnail: (ImageRecord) async -> CGImage?
    @State private var image: CGImage?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 50, height: 36)
            .opacity(row.isLeftOut ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .fontWeight(.medium)
                    Text(row.photos)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(row.exposures)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if row.isLeftOut {
                Text("Left out")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.22), in: Capsule())
                    .fixedSize()
            } else {
                Text(row.direction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 58, alignment: .trailing)
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
        .task(id: row.record?.id) {
            guard let record = row.record else { return }
            image = await thumbnail(record)
        }
    }
}
