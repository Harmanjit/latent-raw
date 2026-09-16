import SwiftUI
import Catalog
import MergeKit

/// The HDR Merge dialog's state (Photo › Photo Merge › HDR…): the engine
/// measures the selected photos, then the dialog lists them with what the
/// merge will make, or says why they can't be merged.
///
/// **Options.** Auto Align, Deghost and Auto Settings start as they were
/// last left (`HDRMergePreferences`, as Lightroom remembers its merge
/// options). Auto Align is measured during the analysis, so turning it on
/// or off analyses the photos again; Deghost only matters to the merge;
/// Auto Settings only to the result's first edit. Clicking a photo in the
/// list makes it the reference, for this merge only.
///
/// **The preview** (Phase 7) is the engine's `preview`: the merge itself,
/// made small from frames the engine kept while analysing. It follows every
/// option that changes the picture (Auto Align once the photos are measured
/// again, Deghost, the reference and the overlay), a moment after the last
/// change (`previewDelay`), and a newer change cancels the preview under way.
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
        /// Whether the row shows its colour in the deghost overlay
        /// (`HDRDeghostOverlay.colour(forFrame: id)`).
        let showsOverlayColour: Bool
    }

    /// The photos being merged, in the grid's order.
    let records: [ImageRecord]
    @Published private(set) var phase: Phase = .analysing
    /// The file name the result will get, once planned: "DSC_0107-HDR.dng".
    /// Planned again when the merge starts, since a file may arrive meanwhile.
    @Published private(set) var destinationName: String?
    /// Line the photos up before merging. Changing it analyses them again.
    @Published var autoAlign: Bool {
        didSet {
            guard autoAlign != oldValue else { return }
            preferences.autoAlign = autoAlign
            reanalyse()
        }
    }
    /// How hard the merge looks for things that moved.
    @Published var deghost: DeghostAmount {
        didSet {
            guard deghost != oldValue else { return }
            preferences.deghost = deghost
            schedulePreview()
        }
    }
    /// Open the result with Develop's Auto Adjust applied (Lightroom's Auto
    /// Settings): the job stores it as the result's first edit.
    @Published var autoSettings: Bool {
        didSet { preferences.autoSettings = autoSettings }
    }
    /// Draw where deghosting left photos out over the preview. Only with a
    /// Deghost level; not remembered, since it only helps to look.
    @Published var showDeghostOverlay = false {
        didSet {
            guard showDeghostOverlay != oldValue, deghost != .none else { return }
            schedulePreview()
        }
    }
    /// The photo the user made the reference, by file (the analysis lists
    /// frames by index, and measuring again could list them anew); nil
    /// for the engine's choice.
    @Published private(set) var pickedReference: URL?

    /// The latest preview; kept while a newer one is made, so the picture
    /// doesn't blink.
    @Published private(set) var preview: CGImage?
    /// Whether a preview is being made for the current options.
    @Published private(set) var isUpdatingPreview = false
    /// Why the last preview failed, in words for the dialog.
    @Published private(set) var previewProblem: String?
    /// The preview's long edge in pixels: the view sets it for its display.
    var previewLongEdge = 1024

    /// Where the options are remembered between dialogs.
    static let autoAlignKey = HDRMergePreferences.autoAlignKey
    static let deghostKey = HDRMergePreferences.deghostKey
    static let autoSettingsKey = HDRMergePreferences.autoSettingsKey
    /// How long after an option changes the preview starts, so clicking
    /// through the Deghost levels makes one preview, not four.
    static let previewDelay = Duration.milliseconds(150)

    /// The engine that measures the photos, and merges them on Merge.
    let engine: any HDRMerging
    private let urls: [URL]
    /// Plans the result's name from its reference photo; nil when it can't.
    private let planDestination: (ImageRecord) async -> String?
    private let preferences: HDRMergePreferences
    private var analysis: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Bumped for every preview asked for, so only the newest one shows.
    private var previewGeneration = 0
    private var naming: Task<Void, Never>?

    /// `urls` are the files of `records`, in the same order.
    ///
    /// - Parameter defaults: where the options are remembered; tests pass
    ///   a suite of their own.
    init(records: [ImageRecord], urls: [URL], engine: any HDRMerging, defaults: UserDefaults = .standard,
         planDestination: @escaping (ImageRecord) async -> String?) {
        self.records = records
        self.urls = urls
        self.engine = engine
        self.planDestination = planDestination
        let preferences = HDRMergePreferences(defaults: defaults)
        self.preferences = preferences
        autoAlign = preferences.autoAlign
        deghost = preferences.deghost
        autoSettings = preferences.autoSettings
    }

    /// The options the merge runs with. The reference is only given when
    /// the user picked another than the engine's.
    var options: HDRMergeOptions {
        let picked = analysisResult.flatMap { result in
            referenceIndex.flatMap { $0 == result.referenceIndex ? nil : $0 }
        }
        return HDRMergeOptions(referenceIndex: picked, deghost: deghost, autoAlign: autoAlign)
    }

    /// The reference frame the merge will use: the picked one, else the
    /// engine's; nil until the photos are measured.
    var referenceIndex: Int? {
        guard let result = analysisResult else { return nil }
        if let pickedReference,
           let index = result.frames.firstIndex(where: { Self.comparablePath($0.url) == Self.comparablePath(pickedReference) }) {
            return index
        }
        return result.frames.indices.contains(result.referenceIndex) ? result.referenceIndex : nil
    }

    /// Makes frame `index` the reference (a click on its row); the result's
    /// name and the preview follow.
    func useAsReference(_ index: Int) {
        guard let result = analysisResult, result.frames.indices.contains(index), index != referenceIndex else { return }
        pickedReference = result.frames[index].url
        planName()
        schedulePreview()
    }

    /// Starts measuring the photos; `phase` follows. Once only (changing
    /// Auto Align starts again by itself).
    func start() {
        guard analysis == nil else { return }
        let engine = engine, urls = urls, options = options
        analysis = Task { [weak self] in
            do {
                let result = try await engine.analyse(urls, options: options)
                guard let self, !Task.isCancelled else { return }
                // The name before the list, so the dialog doesn't grow a
                // line a moment after it has appeared.
                var name: String?
                if let reference = self.record(for: result.frames, at: self.reference(in: result)) {
                    name = await self.planDestination(reference)
                }
                guard !Task.isCancelled else { return }
                self.destinationName = name
                self.phase = .ready(result)
                self.schedulePreview(after: nil)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    /// The picked reference's index in `result`, else the engine's choice.
    private func reference(in result: HDRMergeAnalysis) -> Int {
        guard let pickedReference else { return result.referenceIndex }
        return result.frames.firstIndex { Self.comparablePath($0.url) == Self.comparablePath(pickedReference) }
            ?? result.referenceIndex
    }

    /// Stops an analysis or preview under way and lets the engine free what
    /// it kept for previews (the dialog was closed, by Cancel or Merge).
    func cancel() {
        analysis?.cancel()
        previewTask?.cancel()
        naming?.cancel()
        isUpdatingPreview = false
        engine.releasePreviews()
    }

    /// Plans the result's name again, for a new reference.
    private func planName() {
        naming?.cancel()
        guard let reference = referenceRecord else { return }
        naming = Task { [weak self] in
            guard let name = await self?.planDestination(reference), !Task.isCancelled else { return }
            self?.destinationName = name
        }
    }

    // MARK: - Preview

    /// Makes a preview for the current options, `delay` after the last
    /// change (nil: at once, for the first after measuring). A preview
    /// already under way is cancelled and waited for first: its GPU work
    /// stops at its next frame, and two would only compete.
    func schedulePreview(after delay: Duration? = HDRMergeSheetModel.previewDelay) {
        guard let result = analysisResult else { return }
        previewTask?.cancel()
        let previous = previewTask
        previewGeneration += 1
        let generation = previewGeneration
        let engine = engine, options = options, longEdge = previewLongEdge
        let overlay = showDeghostOverlay && deghost != .none
        isUpdatingPreview = true
        previewTask = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let image = try await engine.preview(result, options: options, longEdge: longEdge,
                                                     showDeghostOverlay: overlay)
                guard let self, !Task.isCancelled, self.previewGeneration == generation else { return }
                self.preview = image
                self.previewProblem = nil
                self.isUpdatingPreview = false
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError),
                      self.previewGeneration == generation else { return }
                self.previewProblem = "The preview couldn’t be made. " + Self.message(for: error)
                self.isUpdatingPreview = false
            }
        }
    }

    /// Returns once the latest preview asked for has finished (tests).
    func waitForPreview() async {
        while let task = previewTask {
            await task.value
            if task == previewTask { return }
        }
    }

    /// What VoiceOver says of the preview.
    var spokenPreview: String {
        if previewProblem != nil { return "not available" }
        if preview == nil { return "being made" }
        var words = isUpdatingPreview ? "updating" : "up to date"
        if showDeghostOverlay, deghost != .none {
            words += ", with the deghost overlay: areas taken from one photo are outlined and tinted in that photo’s colour"
        }
        return words
    }

    /// Throws away the analysis, whether done or under way, and measures
    /// the photos again with the current options. Only once the dialog has
    /// started: setting the options beforehand just sets them.
    private func reanalyse() {
        guard let running = analysis else { return }
        running.cancel()
        // The picture stays, dimmed, until the new measurements preview.
        previewTask?.cancel()
        analysis = nil
        phase = .analysing
        start()
    }

    var analysisResult: HDRMergeAnalysis? {
        if case .ready(let result) = phase { return result }
        return nil
    }

    /// The reference photo's catalog row, which names the result.
    var referenceRecord: ImageRecord? {
        guard let result = analysisResult, let index = referenceIndex else { return nil }
        return record(for: result.frames, at: index)
    }

    /// The records in the engine's order (brightest first), for the recipe.
    var recordsInFrameOrder: [ImageRecord?] {
        guard let result = analysisResult else { return [] }
        return result.frames.indices.map { record(for: result.frames, at: $0) }
    }

    var rows: [Row] {
        guard let result = analysisResult, let reference = referenceIndex else { return [] }
        let referenceEV = result.frames[reference].relativeEV
        let overlay = showDeghostOverlay && deghost != .none
        return result.frames.enumerated().map { index, frame in
            let stops = frame.relativeEV - referenceEV
            let exposure = MetadataFormat.exposureLine(shutter: frame.exposureSeconds, aperture: frame.aperture,
                                                       iso: Int(frame.iso.rounded()), focal: nil)
            let isReference = index == reference
            var spoken = [frame.url.lastPathComponent]
            spoken += exposure.components(separatedBy: " · ").filter { !$0.isEmpty }
            spoken.append(isReference ? "reference" : Self.spokenEV(stops))
            if overlay { spoken.append("overlay colour \(HDRDeghostOverlay.colourName(forFrame: index))") }
            return Row(id: index, fileName: frame.url.lastPathComponent,
                       record: record(for: result.frames, at: index), exposure: exposure,
                       ev: Self.evText(stops), isReference: isReference, spoken: spoken.joined(separator: ", "),
                       showsOverlayColour: overlay)
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

    /// The analysis's warnings for the reference in use (which frames Auto
    /// Align can't line up depends on it).
    var warnings: [String] {
        guard let result = analysisResult, let reference = referenceIndex else { return [] }
        return result.warnings(reference: reference).map { Self.text(for: $0, frames: result.frames) }
    }

    /// Said when Auto Align moved the photos by a pixel or so or more:
    /// "Photo Merge aligned these photos (up to 17 px)." A note, not a
    /// warning: this is Auto Align doing its job. Nothing is said for the
    /// fraction of a pixel a tripod bracket usually moves.
    var alignmentNote: String? {
        guard let result = analysisResult, let reference = referenceIndex else { return nil }
        let largest = result.alignmentShifts(reference: reference).compactMap { $0 }.max() ?? 0
        guard largest >= Self.notedShiftPixels else { return nil }
        return "Photo Merge aligned these photos (up to \(max(1, Int(largest.rounded()))) px)."
    }

    /// The smallest shift the dialog mentions.
    static let notedShiftPixels = 0.5

    /// The analysing line: "Analysing 3 photos…".
    var analysingText: String { "Analysing \(records.count) photos…" }

    /// Said whatever the state: the merge reads the raw files themselves.
    /// The Panorama dialog says the same (`PhotoMergeText`).
    static let editsNotice = PhotoMergeText.editsNotice

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
            return "These photos don’t line up exactly (up to \(pixels) px apart), so edges may look doubled. "
                + "Turn on Auto Align to line them up."
        case .frameCouldNotBeAligned(let index, let leftOut):
            let name = frames.indices.contains(index) ? frames[index].url.lastPathComponent : "One photo"
            return leftOut
                ? "Photo Merge couldn’t align \(name), so it’s left out of the merge."
                : "Photo Merge couldn’t align \(name), but it looks close, so it’s merged as it is. "
                    + "Edges may look slightly doubled."
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
    static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The HDR Merge dialog: the preview on top; below it the photos (click
/// one to make it the reference) beside the options and what the merge
/// will make; then any warnings, and the buttons.
///
/// **Fits the smallest window.** The app's window can be 900 x 600 points,
/// and a sheet taller than its window is cut off at the top. So the preview
/// gives way first (it shrinks to `previewMinHeight`), the list of photos
/// scrolls beyond `visibleRows`, and the notes scroll beyond a few lines;
/// the snapshot harness's `hdrmerge` step checks it at that size.
struct HDRMergeSheet: View {
    @ObservedObject var model: HDRMergeSheetModel
    /// The thumbnail of a photo in the list.
    let thumbnail: (ImageRecord) async -> CGImage?
    /// Merge was pressed with this analysis, these options and whether to
    /// apply Auto Settings; the dialog closes itself.
    let onMerge: (HDRMergeAnalysis, HDRMergeOptions, Bool) -> Void
    /// Merge is refused while another GPU job (an export, a merge) runs.
    var canMerge = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    /// Rows shown before the list scrolls: most brackets are 3.
    private static let visibleRows = 3
    private static let rowHeight: CGFloat = 46
    /// The label column of the options and details, the same width in both.
    private static let labelWidth: CGFloat = 90
    static let width: CGFloat = 720
    /// The preview's height when there is room, and the least it shrinks to.
    static let previewHeight: CGFloat = 230
    static let previewMinHeight: CGFloat = 110
    /// Notes shown before they scroll.
    private static let notesHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HDR Merge")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .analysing:
                previewArea
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
                previewArea
                HStack(alignment: .top, spacing: 16) {
                    frameList
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 10) {
                        options
                        details
                    }
                    .fixedSize()
                }
                notes
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Can’t merge: \(message)")
            }
            HStack(alignment: .center, spacing: 12) {
                Text(HDRMergeSheetModel.editsNotice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                buttons
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .onAppear {
            // Twice the points on a Retina display; the engine stops at its
            // kept frames' size anyway.
            model.previewLongEdge = Int(512 * max(1, displayScale))
        }
        .onDisappear { model.cancel() }
    }

    /// The merge as it will open, or a placeholder until the first preview.
    /// A picture being replaced stays, dimmed while the photos are measured
    /// again, with a spinner in its corner.
    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .underPageBackgroundColor))
            if let image = model.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .opacity(model.phase == .analysing ? 0.5 : 1)
            } else if let problem = model.previewProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                ProgressView().controlSize(.small)
            }
            if model.preview != nil, model.isUpdatingPreview || model.phase == .analysing {
                ProgressView().controlSize(.small)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if model.preview != nil, let problem = model.previewProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: Self.previewMinHeight, idealHeight: Self.previewHeight, maxHeight: Self.previewHeight)
        .layoutPriority(-1)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the merged photo")
        .accessibilityValue(model.spokenPreview)
        .accessibilityAddTraits(.isImage)
    }

    private var frameList: some View {
        let rows = model.rows
        let list = VStack(spacing: 0) {
            ForEach(rows) { row in
                HDRMergeFrameRow(row: row, thumbnail: thumbnail) { model.useAsReference(row.id) }
                    .frame(height: Self.rowHeight)
                if row.id != rows.last?.id { Divider() }
            }
        }
        return Group {
            if rows.count > Self.visibleRows {
                // Half a row more than fits shows that the list scrolls; the
                // reference starts in view.
                ScrollViewReader { scroller in
                    ScrollView { list }
                        .frame(height: Self.rowHeight * (CGFloat(Self.visibleRows) + 0.5))
                        .onAppear {
                            if let reference = rows.first(where: \.isReference) {
                                scroller.scrollTo(reference.id, anchor: .center)
                            }
                        }
                }
            } else {
                list
            }
        }
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photos to merge, brightest first")
        .help("Click a photo to make it the reference: the merge opens with its exposure and takes its name.")
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            if let size = model.sizeText { detail("Size", size) }
            if let estimate = model.estimatedSizeText { detail("File size", estimate) }
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

    /// The right-hand column's width: the options and the details.
    private static let optionsWidth: CGFloat = 346

    /// Auto Align, Deghost with its overlay, and Auto Settings; shown while
    /// the photos are read too, so the controls don't jump when the list
    /// arrives.
    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Auto Align").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Toggle("Line up photos shot without a tripod", isOn: $model.autoAlign)
                    .accessibilityLabel("Auto Align")
                    .accessibilityHint("Lines the photos up before merging. Changing it measures the photos again.")
                    .help("Lines the photos up before merging, for brackets shot without a tripod. "
                          + "Photos that didn’t move are left as they are. Changing it measures the photos again.")
            }
            GridRow {
                Text("Deghost").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Picker("Deghost", selection: $model.deghost) {
                    Text("None").tag(DeghostAmount.none)
                    Text("Low").tag(DeghostAmount.low)
                    Text("Medium").tag(DeghostAmount.medium)
                    Text("High").tag(DeghostAmount.high)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .accessibilityLabel("Deghost")
                .accessibilityHint("Keeps things that moved between the photos, such as people, leaves or waves, "
                                   + "from showing more than once.")
                .help("Keeps things that moved between the photos (people, leaves, waves) from showing more than once. "
                      + "Low catches only big changes; High also catches faint ones, but takes more of the picture "
                      + "from a single, noisier photo.")
            }
            GridRow {
                Color.clear.frame(width: Self.labelWidth, height: 1)
                    .accessibilityHidden(true)
                Toggle("Show Deghost Overlay", isOn: $model.showDeghostOverlay)
                    .disabled(model.deghost == .none)
                    .accessibilityHint("Outlines the areas deghosting took from one photo, tinted in that photo’s "
                                       + "colour in the list.")
                    .help("Outlines the areas deghosting took from a single photo, tinted in the colour shown "
                          + "beside that photo. Needs a Deghost level.")
            }
            GridRow {
                Text("Auto Settings").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Toggle("Open the result auto adjusted", isOn: $model.autoSettings)
                    .accessibilityLabel("Auto Settings")
                    .accessibilityHint("Applies Auto Adjust to the merged photo as its first edit, which you can undo.")
                    .help("Applies Develop’s Auto Adjust (⌘U) to the merged photo as its first edit. "
                          + "Undo in Develop takes it back to the merge as it came out.")
            }
        }
        .font(.callout)
        .frame(width: Self.optionsWidth, alignment: .leading)
    }

    /// Auto Align's note, then the warnings; they scroll beyond a few lines.
    @ViewBuilder private var notes: some View {
        let warnings = model.warnings
        let note = model.alignmentNote
        let content = VStack(alignment: .leading, spacing: 4) {
            if let note {
                Label(note, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(note)
            }
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Warning: \(warning)")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        if warnings.count + (note == nil ? 0 : 1) > 2 {
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
                Button("Merge") {
                    guard let analysis = model.analysisResult else { return }
                    onMerge(analysis, model.options, model.autoSettings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.analysisResult == nil || !canMerge)
                .accessibilityHint("Closes the dialog and merges in the background; progress shows in the library panel.")
                .help(canMerge ? "Merge in the background; progress shows under Export in the library panel."
                               : "Wait for the export or merge under way to finish.")
            }
        }
        .fixedSize()
    }
}

/// One photo in the list: thumbnail, name, exposure, stops and the
/// Reference badge, read by VoiceOver as one line. Clicking it makes it the
/// reference; with the deghost overlay on, it shows its overlay colour.
private struct HDRMergeFrameRow: View {
    let row: HDRMergeSheetModel.Row
    let thumbnail: (ImageRecord) async -> CGImage?
    let useAsReference: () -> Void
    @State private var image: CGImage?

    var body: some View {
        Button(action: useAsReference) {
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
                if row.showsOverlayColour {
                    let colour = HDRDeghostOverlay.colour(forFrame: row.id)
                    Circle()
                        .fill(Color(.sRGB, red: Double(colour.red) / 255, green: Double(colour.green) / 255,
                                    blue: Double(colour.blue) / 255))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.6), lineWidth: 1))
                        .frame(width: 10, height: 10)
                        .help("Areas taken from this photo are tinted \(HDRDeghostOverlay.colourName(forFrame: row.id)) "
                              + "in the preview.")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.exposure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
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
                    .frame(minWidth: 48, alignment: .trailing)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
        .accessibilityAddTraits(row.isReference ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(row.isReference ? "" : "Makes this photo the reference.")
        .accessibilityAction(named: "Use as reference", useAsReference)
        .task(id: row.record?.id) {
            guard let record = row.record else { return }
            image = await thumbnail(record)
        }
    }
}
