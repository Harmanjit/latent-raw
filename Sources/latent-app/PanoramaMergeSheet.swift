import SwiftUI
import Catalog
import MergeKit

/// The Panorama dialog's state (Photo › Photo Merge › Panorama…): the engine
/// measures the selected photos, works out where each one points, then the
/// dialog shows the stitch, lists the photos in the order they were taken,
/// and says how big the result will be — or why they aren't a panorama.
///
/// **Options.** Projection, Auto Crop and Auto Settings start as they were
/// last left (`PanoramaMergePreferences`). Projection decides the shape of
/// the whole canvas, so changing it works the layout out again — the engine
/// keeps the photos it decoded and the cameras it solved, so that costs a
/// canvas and a crop, not another read of every raw. Auto Crop only changes
/// the crop the result opens with, and Auto Settings only its first edit.
///
/// **Agreeing to a smaller panorama.** A sweep can easily want more pixels
/// than this Mac can edit. Latent never refuses it (Harman's rule): the
/// dialog says what would have been made, what will be made instead and
/// why, and the merge waits until that is agreed to (`acceptsDownsampling`,
/// never remembered between dialogs).
///
/// **The preview** is the engine's `preview`: the stitch itself, made small.
/// It follows the options that change the picture, a moment after the last
/// change (`previewDelay`), and a newer change cancels the preview under way.
///
/// Kept apart from the view so the tests can walk it through each state
/// with a fake engine.
@MainActor
final class PanoramaMergeSheetModel: ObservableObject, Identifiable {
    enum Phase {
        /// The engine is reading the photos and working out the layout.
        case analysing
        case ready(PanoramaMergeAnalysis)
        /// Why these photos can't be stitched, in words for the dialog.
        case failed(String)
    }

    /// One photo of the sweep as the list shows it, in capture order.
    struct Row: Identifiable, Equatable {
        /// Its index in `PanoramaMergeAnalysis.frames`.
        let id: Int
        let fileName: String
        /// The catalog's row, for the thumbnail; nil if the engine named a
        /// file that isn't one of the selection.
        let record: ImageRecord?
        /// "1/250 s · ƒ/8 · ISO 100".
        let exposure: String
        /// How much this photo is brightened or darkened to match the
        /// others: "+0.3 EV", "0 EV"; empty when it is left out.
        let brightness: String
        /// Where it points across the panorama: "34° left", "centre",
        /// "12° right"; empty when it is left out.
        let direction: String
        /// True when no accepted pair joined it to the rest.
        let isLeftOut: Bool
        /// What VoiceOver reads for the whole row.
        let spoken: String
    }

    /// The photos being merged, in the grid's order.
    let records: [ImageRecord]
    @Published private(set) var phase: Phase = .analysing
    /// The file name the result will get, once planned: "DSC_0107-Pano.dng".
    /// Planned again when the merge starts, since a file may arrive meanwhile.
    @Published private(set) var destinationName: String?

    /// How the directions are flattened onto the panorama. Changing it
    /// measures the photos again: the canvas, its size and the warnings all
    /// depend on it.
    @Published var projection: PanoramaProjection {
        didSet {
            guard projection != oldValue else { return }
            preferences.projection = projection
            reanalyse()
        }
    }
    /// Open the result with the blank edges cropped away (an undoable crop
    /// edit, so nothing is thrown away).
    @Published var autoCrop: Bool {
        didSet {
            guard autoCrop != oldValue else { return }
            preferences.autoCrop = autoCrop
            schedulePreview()
        }
    }
    /// Open the result with Develop's Auto Adjust applied, as the HDR
    /// dialog's option does.
    @Published var autoSettings: Bool {
        didSet { preferences.autoSettings = autoSettings }
    }
    /// Whether the user has agreed to the panorama being made smaller.
    /// Only asked for (and only needed) when the analysis says the full
    /// size can't be edited on this Mac; never remembered.
    @Published var acceptsDownsampling = false

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
    static let projectionKey = PanoramaMergePreferences.projectionKey
    static let autoCropKey = PanoramaMergePreferences.autoCropKey
    static let autoSettingsKey = PanoramaMergePreferences.autoSettingsKey
    /// How long after an option changes the preview starts, so clicking
    /// through the projections makes one preview, not four.
    static let previewDelay = Duration.milliseconds(150)

    /// The engine that measures the photos, and stitches them on Merge.
    let engine: any PanoramaMerging
    private let urls: [URL]
    /// Plans the result's name from its first joined photo; nil when it can't.
    private let planDestination: (ImageRecord) async -> String?
    private let preferences: PanoramaMergePreferences
    private var analysis: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Bumped for every preview asked for, so only the newest one shows.
    private var previewGeneration = 0
    private var naming: Task<Void, Never>?

    /// `urls` are the files of `records`, in the same order.
    ///
    /// - Parameter defaults: where the options are remembered; tests pass
    ///   a suite of their own.
    init(records: [ImageRecord], urls: [URL], engine: any PanoramaMerging, defaults: UserDefaults = .standard,
         planDestination: @escaping (ImageRecord) async -> String?) {
        self.records = records
        self.urls = urls
        self.engine = engine
        self.planDestination = planDestination
        let preferences = PanoramaMergePreferences(defaults: defaults)
        self.preferences = preferences
        projection = preferences.projection
        autoCrop = preferences.autoCrop
        autoSettings = preferences.autoSettings
    }

    /// The options the merge runs with.
    var options: PanoramaMergeOptions {
        PanoramaMergeOptions(projection: projection, autoCrop: autoCrop, autoSettings: autoSettings)
    }

    /// Starts measuring the photos; `phase` follows. Once only (changing
    /// the projection starts again by itself).
    ///
    /// - Parameter after: an analysis being thrown away, waited for before
    ///   this one starts. Two analyses would share one GPU and one set of
    ///   measurements in the engine, and only compete.
    func start(after previous: Task<Void, Never>? = nil) {
        guard analysis == nil else { return }
        let engine = engine, urls = urls, options = options
        analysis = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let result = try await engine.analyse(urls, options: options)
                guard let self, !Task.isCancelled else { return }
                // The name before the list, so the dialog doesn't grow a
                // line a moment after it has appeared.
                var name: String?
                if let reference = self.record(for: result.frames, at: Self.referenceIndex(result)) {
                    name = await self.planDestination(reference)
                }
                guard !Task.isCancelled else { return }
                self.destinationName = name
                // A size agreed to is agreed to for that size only.
                self.acceptsDownsampling = false
                self.phase = .ready(result)
                self.schedulePreview(after: nil)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    /// Stops an analysis or preview under way and lets the engine free what
    /// it kept for previews (the dialog was closed, by Cancel or Merge).
    func cancel() {
        analysis?.cancel()
        previewTask?.cancel()
        naming?.cancel()
        isUpdatingPreview = false
        Task { [engine] in await engine.releasePreviews() }
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
        // The one being thrown away is waited for first, as `schedulePreview`
        // waits for the preview it replaces: the engine stops it at its next
        // pair or tile, and two would only fight over the same GPU.
        start(after: running)
    }

    var analysisResult: PanoramaMergeAnalysis? {
        if case .ready(let result) = phase { return result }
        return nil
    }

    /// The photo the result is named after: the first one, in capture
    /// order, that the engine joined to the rest.
    static func referenceIndex(_ result: PanoramaMergeAnalysis) -> Int {
        result.frames.firstIndex { !$0.leftOut } ?? 0
    }

    /// That photo's catalog row.
    var referenceRecord: ImageRecord? {
        guard let result = analysisResult else { return nil }
        return record(for: result.frames, at: Self.referenceIndex(result))
    }

    /// The records in the engine's order (capture order), for the recipe.
    var recordsInFrameOrder: [ImageRecord?] {
        guard let result = analysisResult else { return [] }
        return result.frames.indices.map { record(for: result.frames, at: $0) }
    }

    // MARK: - Preview

    /// Makes a preview for the current options, `delay` after the last
    /// change (nil: at once, for the first after measuring). A preview
    /// already under way is cancelled and waited for first: its GPU work
    /// stops at its next tile, and two would only compete.
    func schedulePreview(after delay: Duration? = PanoramaMergeSheetModel.previewDelay) {
        guard let result = analysisResult else { return }
        previewTask?.cancel()
        let previous = previewTask
        previewGeneration += 1
        let generation = previewGeneration
        let engine = engine, options = options, longEdge = previewLongEdge
        isUpdatingPreview = true
        previewTask = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let image = try await engine.preview(result, options: options, longEdge: longEdge)
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
        return isUpdatingPreview ? "updating" : "up to date"
    }

    // MARK: - What the dialog shows

    var rows: [Row] {
        guard let result = analysisResult else { return [] }
        return result.frames.enumerated().map { index, frame in
            let exposure = MetadataFormat.exposureLine(shutter: frame.exposureSeconds, aperture: frame.aperture,
                                                       iso: Int(frame.iso.rounded()), focal: nil)
            let brightness = frame.leftOut ? "" : Self.evText(frame.gainStops)
            let direction = frame.leftOut ? "" : Self.directionText(frame.yawPitchRoll?.x)
            var spoken = [frame.url.lastPathComponent]
            spoken += exposure.components(separatedBy: " · ").filter { !$0.isEmpty }
            if frame.leftOut {
                spoken.append("left out of the panorama")
            } else {
                spoken.append(Self.spokenDirection(frame.yawPitchRoll?.x))
                spoken.append(Self.spokenBrightness(frame.gainStops))
            }
            return Row(id: index, fileName: frame.url.lastPathComponent,
                       record: record(for: result.frames, at: index), exposure: exposure,
                       brightness: brightness, direction: direction, isLeftOut: frame.leftOut,
                       spoken: spoken.joined(separator: ", "))
        }
    }

    /// The analysing line: "Measuring 17 photos…".
    var analysingText: String { "Measuring \(records.count) photos…" }

    /// "12,224 × 2,096 (26 MP)": the size of the picture that opens, which
    /// is the stitched canvas with Auto Crop off and the cropped rectangle
    /// with it on (it is on by default). The preview above the row shows
    /// the same picture.
    var sizeText: String? {
        openedSize.map { Self.pixelSize($0.width, $0.height) }
    }

    /// The size the result opens at, in pixels.
    var openedSize: (width: Int, height: Int)? {
        guard let result = analysisResult else { return nil }
        guard autoCrop, let cropped = Self.croppedSize(result) else {
            return (result.outputSize.width, result.outputSize.height)
        }
        return cropped
    }

    /// Auto Crop's rectangle in the output's own pixels; nil when it would
    /// crop nothing (the solver found no rectangle, or it is the whole
    /// canvas). Worked out as the merge works it out: the layout's
    /// rectangle is in canvas pixels at scale 1, so it scales with the
    /// output.
    static func croppedSize(_ result: PanoramaMergeAnalysis) -> (width: Int, height: Int)? {
        let rect = result.layout.autoCropRect, size = result.outputSize
        guard rect.width >= 1, rect.height >= 1, size.width > 0, size.height > 0 else { return nil }
        let width = max(1, min(size.width, Int((rect.width * size.scale).rounded(.down))))
        let height = max(1, min(size.height, Int((rect.height * size.scale).rounded(.down))))
        guard width < size.width || height < size.height else { return nil }
        return (width, height)
    }

    /// Said under Size when Auto Crop is on and really crops: the file
    /// still holds the whole stitch, because Auto Crop is an undoable crop
    /// edit and nothing is thrown away. Without it Size and File size, which
    /// is the file's, would look like they disagreed.
    var wholeCanvasNote: String? {
        guard autoCrop, let result = analysisResult, Self.croppedSize(result) != nil else { return nil }
        return "Auto Crop hides the blank edges. The whole "
            + "\(Self.pixelCount(result.outputSize.width, result.outputSize.height)) stitch stays in the file."
    }

    /// "About 245.3 MB": the file, which holds the whole stitch whether or
    /// not Auto Crop is on.
    var estimatedSizeText: String? {
        analysisResult.map { "About " + MetadataFormat.fileSize($0.estimatedOutputBytes) }
    }

    /// "185° across, 34° tall".
    var coverageText: String? {
        guard let result = analysisResult else { return nil }
        return "\(Self.degrees(result.widthDegrees)) across, \(Self.degrees(result.heightDegrees)) tall"
    }

    /// The projection the merge will really use: the picked one, or what
    /// Automatic chose once the photos have been measured.
    var resolvedProjection: PanoramaProjection {
        guard projection == .automatic, let result = analysisResult else { return projection }
        return result.layout.canvas.projection
    }

    /// The line under the projection picker.
    var projectionHint: String {
        guard projection == .automatic else { return Self.hint(for: projection) }
        guard analysisResult != nil else { return Self.hint(for: .automatic) }
        return "Latent chose \(Self.name(for: resolvedProjection)). " + Self.hint(for: resolvedProjection)
    }

    /// The size the panorama will be made smaller to, when it must be;
    /// nil when it can be merged whole.
    var downsampling: PanoramaOutputSize? {
        guard let result = analysisResult else { return nil }
        for warning in result.warnings {
            if case .downsampled(let size) = warning { return size }
        }
        // An engine that forgot to warn is still not allowed to surprise us.
        return result.outputSize.needsDownsampling ? result.outputSize : nil
    }

    /// The sentence the user has to agree to, or nil when the panorama fits.
    var downsampleText: String? {
        downsampling.map { Self.text(for: .downsampled(outputSize: $0), frames: []) }
    }

    /// Whether Merge waits for the smaller size to be agreed to.
    var needsDownsamplingConsent: Bool { downsampling != nil }

    /// The label on the agreement: "Merge at 43%".
    var consentLabel: String? {
        downsampling.map { "Merge at \(Self.percent($0.scale))" }
    }

    /// The Merge button: "Merge", or "Merge at 43%" when the panorama is
    /// being made smaller, so the button itself says what it will do.
    var mergeButtonTitle: String { consentLabel ?? "Merge" }

    /// Whether Merge can be pressed: the photos are measured, and a smaller
    /// panorama has been agreed to if it is one.
    var canMerge: Bool {
        analysisResult != nil && (!needsDownsamplingConsent || acceptsDownsampling)
    }

    /// The photos that couldn't be joined, by name, for the list's mark and
    /// the warning.
    var leftOutNames: [String] {
        analysisResult.map { $0.frames.filter(\.leftOut).map { $0.url.lastPathComponent } } ?? []
    }

    /// The analysis's warnings in plain words, without the downsampling one,
    /// which has its own agreement above them.
    var warnings: [String] {
        guard let result = analysisResult else { return [] }
        return result.warnings.compactMap { warning in
            if case .downsampled = warning { return nil }
            return Self.text(for: warning, frames: result.frames)
        }
    }

    /// Said whatever the state: the merge reads the raw files themselves.
    static let editsNotice = PhotoMergeText.editsNotice

    // MARK: - Words

    /// A warning in plain words.
    static func text(for warning: PanoramaMergeWarning, frames: [PanoramaMergeFrame]) -> String {
        switch warning {
        case .framesLeftOut(let indices):
            let names = indices.compactMap { frames.indices.contains($0) ? frames[$0].url.lastPathComponent : nil }
            guard !names.isEmpty else {
                return "Some photos couldn’t be joined to the others, so they’re left out of the panorama."
            }
            return names.count == 1
                ? "\(names[0]) couldn’t be joined to the others, so it’s left out. It probably doesn’t overlap "
                    + "them enough: a panorama needs about 30% overlap between neighbouring shots."
                : "\(names.count) photos couldn’t be joined to the others, so they’re left out: \(list(names)). "
                    + "They probably don’t overlap the rest enough: a panorama needs about 30% overlap between "
                    + "neighbouring shots."
        case .downsampled(let size):
            return "This panorama would be \(pixelCount(size.fullWidth, size.fullHeight)) pixels "
                + "(\(megapixels(size.fullWidth, size.fullHeight))). The largest this Mac can edit is "
                + "\(pixelCount(size.width, size.height)) (\(megapixels(size.width, size.height))), "
                + "\(limitText(size.limit)), so the photos will be merged at \(percent(size.scale))."
        case .unevenExposure(let stops):
            return "These photos are \(stopsText(stops)) apart in brightness even after evening them out, "
                + "so seams may still show. Shoot a panorama with the exposure set by hand."
        case .largeParallax(let pixels):
            return "The photos line up to about \(max(1, Int(pixels.rounded()))) px. Things close to the camera "
                + "may look doubled: that happens when the camera moves sideways instead of turning on the spot."
        }
    }

    /// What the dialog says when the photos can't be measured.
    static func message(for error: Error) -> String {
        if let panorama = error as? PanoramaError, let description = panorama.errorDescription { return description }
        return "These photos couldn’t be read for a panorama. \(error.localizedDescription)"
    }

    /// "29,195 × 7,664 (224 MP)".
    static func pixelSize(_ width: Int, _ height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        return "\(pixelCount(width, height)) (\(megapixels(width, height)))"
    }

    /// "29,195 × 7,664", grouped so a nine-digit panorama can be read.
    static func pixelCount(_ width: Int, _ height: Int) -> String {
        "\(grouped(width)) × \(grouped(height))"
    }

    /// "224 MP"; a decimal only below 10 MP, where it says something.
    static func megapixels(_ width: Int, _ height: Int) -> String {
        let mp = Double(width) * Double(height) / 1_000_000
        return mp >= 10 ? "\(Int(mp.rounded())) MP" : String(format: "%.1f MP", mp)
    }

    /// "29195" as "29,195". Grouped by hand rather than by a formatter: a
    /// pixel count reads the same in every locale, as the rest of Latent's
    /// sizes do.
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var grouped = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        return (value < 0 ? "-" : "") + grouped
    }

    /// "43%": the scale as the dialog and the button say it.
    static func percent(_ scale: Double) -> String {
        "\(max(1, Int((min(max(scale, 0), 1) * 100).rounded())))%"
    }

    /// Why the panorama can't be made whole.
    static func limitText(_ limit: PanoramaOutputSize.Limit) -> String {
        switch limit {
        case .memory: "limited by memory"
        case .textureSide: "limited by the largest picture the graphics processor can hold"
        case .none: "limited by this Mac"
        }
    }

    /// The brightness correction as the list shows it: "+0.3 EV", "0 EV".
    static func evText(_ stops: Double) -> String {
        let tenths = (stops * 10).rounded() / 10
        guard tenths != 0 else { return "0 EV" }
        return (tenths > 0 ? "+" : "-") + number(abs(tenths)) + " EV"
    }

    /// The same for VoiceOver, which reads "-0.3" unreliably.
    static func spokenBrightness(_ stops: Double) -> String {
        let tenths = (stops * 10).rounded() / 10
        guard tenths != 0 else { return "no brightness correction" }
        return "\(tenths > 0 ? "brightened" : "darkened") by \(stopsText(tenths))"
    }

    /// Where a photo points across the panorama: "34° left", "centre",
    /// "12° right". Nil yaw (a photo left out) gives "".
    static func directionText(_ yawDegrees: Double?) -> String {
        guard let yaw = yawDegrees else { return "" }
        let whole = Int(yaw.rounded())
        guard whole != 0 else { return "centre" }
        return "\(abs(whole))° \(whole > 0 ? "right" : "left")"
    }

    /// The same, spoken: "points 12 degrees right of centre".
    static func spokenDirection(_ yawDegrees: Double?) -> String {
        guard let yaw = yawDegrees else { return "direction unknown" }
        let whole = Int(yaw.rounded())
        guard whole != 0 else { return "points at the centre of the panorama" }
        return "points \(abs(whole)) degrees \(whole > 0 ? "right" : "left") of centre"
    }

    /// "185°", to a whole degree.
    static func degrees(_ value: Double) -> String { "\(max(0, Int(value.rounded())))°" }

    /// "1 stop", "0.3 stops", "2 stops".
    static func stopsText(_ stops: Double) -> String {
        let text = number(abs(stops))
        return "\(text) \(text == "1" ? "stop" : "stops")"
    }

    /// A number to a tenth, without a trailing ".0": "2", "0.7".
    private static func number(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// The picker's names. Nonisolated so the library panel can name a
    /// stored panorama's projection with the same words the dialog used.
    nonisolated static func name(for projection: PanoramaProjection) -> String {
        switch projection {
        case .automatic: "Automatic"
        case .perspective: "Perspective"
        case .cylindrical: "Cylindrical"
        case .spherical: "Spherical"
        }
    }

    /// One line saying what each projection is for.
    static func hint(for projection: PanoramaProjection) -> String {
        switch projection {
        case .automatic: "Latent picks the shape that suits the sweep."
        case .perspective: "Straight lines stay straight; only for a narrow sweep."
        case .cylindrical: "Wraps around like a label on a can; upright things stay upright."
        case .spherical: "Bends both ways; for very tall sweeps or a full circle."
        }
    }

    // MARK: - Matching the engine's files to the catalog

    private func record(for frames: [PanoramaMergeFrame], at index: Int) -> ImageRecord? {
        guard frames.indices.contains(index) else { return nil }
        let wanted = HDRMergeSheetModel.comparablePath(frames[index].url)
        guard let position = urls.firstIndex(where: { HDRMergeSheetModel.comparablePath($0) == wanted })
        else { return nil }
        return records[position]
    }
}

extension PanoramaMergeSheetModel.Phase: Equatable {
    /// The analysis isn't `Equatable` as a whole (it carries an engine's
    /// measurements); what the dialog shows of it is.
    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.analysing, .analysing): true
        case (.ready(let x), .ready(let y)):
            x.frames == y.frames && x.layout == y.layout && x.outputSize == y.outputSize
        case (.failed(let x), .failed(let y)): x == y
        default: false
        }
    }
}

/// Words both Photo Merge dialogs say.
enum PhotoMergeText {
    /// Neither merge reads the catalog's edits: both start from the files.
    static let editsNotice = "The merge starts from the original raw files. Edits you made to these photos aren’t used."
}

/// The Panorama dialog: the stitch on top; below it the photos in the order
/// they were taken (with where each one points and how much it is
/// brightened) beside the options and what the merge will make; then the
/// agreement to a smaller panorama if it needs one, the warnings, and the
/// buttons.
///
/// **Fits the smallest window.** The app's window can be 900 x 600 points,
/// and a sheet taller than its window is cut off at the top. So the preview
/// gives way first (it shrinks to `previewMinHeight`), the list of photos
/// scrolls beyond `visibleRows`, and the notes scroll beyond a couple of
/// lines; the snapshot harness's `panoramamerge` step checks it at that size.
struct PanoramaMergeSheet: View {
    @ObservedObject var model: PanoramaMergeSheetModel
    /// The thumbnail of a photo in the list.
    let thumbnail: (ImageRecord) async -> CGImage?
    /// Merge was pressed with this analysis and these options; the dialog
    /// closes itself.
    let onMerge: (PanoramaMergeAnalysis, PanoramaMergeOptions) -> Void
    /// Merge is refused while another GPU job (an export, a merge) runs.
    var canMerge = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    /// Rows shown before the list scrolls. A panorama is often a dozen
    /// photos or more, so it usually scrolls.
    private static let visibleRows = 3
    private static let rowHeight: CGFloat = 46
    /// The label column of the options and details, the same width in both.
    private static let labelWidth: CGFloat = 90
    static let width: CGFloat = 720
    /// The preview's height when there is room, and the least it shrinks to.
    /// Shorter than the HDR sheet's, both because a panorama is wide and
    /// flat and because this sheet carries the agreement to a smaller size
    /// as well: at 900 x 600 points the whole sheet has to fit.
    static let previewHeight: CGFloat = 150
    static let previewMinHeight: CGFloat = 80
    /// Notes shown before they scroll: two warnings of two lines each, the
    /// usual most, fit whole.
    private static let notesHeight: CGFloat = 72
    /// The right-hand column's width: the options and the details.
    private static let optionsWidth: CGFloat = 346

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Panorama")
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
                consent
                notes
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Can’t merge: \(message)")
            }
            HStack(alignment: .center, spacing: 12) {
                Text(PanoramaMergeSheetModel.editsNotice)
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
            // Twice the points on a Retina display; the engine stops at the
            // size it kept anyway.
            model.previewLongEdge = Int(640 * max(1, displayScale))
        }
        .onDisappear { model.cancel() }
    }

    /// The panorama as it will open, or a placeholder until the first
    /// preview. A picture being replaced stays, dimmed while the photos are
    /// measured again, with a spinner in its corner.
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
        .accessibilityLabel("Preview of the panorama")
        .accessibilityValue(model.spokenPreview)
        .accessibilityAddTraits(.isImage)
    }

    private var frameList: some View {
        let rows = model.rows
        let list = VStack(spacing: 0) {
            ForEach(rows) { row in
                PanoramaFrameRow(row: row, thumbnail: thumbnail)
                    .frame(height: Self.rowHeight)
                if row.id != rows.last?.id { Divider() }
            }
        }
        return Group {
            if rows.count > Self.visibleRows {
                // Half a row more than fits shows that the list scrolls.
                ScrollView { list }
                    .frame(height: Self.rowHeight * (CGFloat(Self.visibleRows) + 0.5))
            } else {
                list
            }
        }
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photos to stitch, in the order they were taken")
        .help("The photos in the order they were taken, with where each one points and how much its brightness "
              + "is corrected. Photos that couldn’t be joined are marked Left out.")
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            if let size = model.sizeText { detail("Size", size) }
            if let note = model.wholeCanvasNote {
                GridRow {
                    Color.clear.frame(width: Self.labelWidth, height: 1)
                        .accessibilityHidden(true)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Size: \(note)")
                }
            }
            if let coverage = model.coverageText { detail("Sweep", coverage) }
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

    /// Projection with its one-line hint, Auto Crop and Auto Settings;
    /// shown while the photos are read too, so the controls don't jump when
    /// the list arrives.
    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Projection").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                // A pop-up, not a segmented control: four projection names
                // side by side don't fit beside their label at this width.
                Picker("Projection", selection: $model.projection) {
                    ForEach(PanoramaProjection.allCases, id: \.self) { projection in
                        Text(PanoramaMergeSheetModel.name(for: projection)).tag(projection)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .accessibilityLabel("Projection")
                .accessibilityValue(PanoramaMergeSheetModel.name(for: model.projection))
                .accessibilityHint("How the photos are flattened onto the panorama. "
                                   + "Changing it works out the shape again.")
                .help("How the directions the camera pointed are flattened into one picture. "
                      + "Changing it works out the panorama's shape again.")
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
                    .accessibilityHint("Opens the panorama cropped to the largest rectangle with no blank edges. "
                                       + "Undo in Develop brings the edges back.")
                    .help("A stitched panorama has ragged, empty edges. Auto Crop opens the result cropped to the "
                          + "largest rectangle inside the picture. It is an ordinary crop edit: undo it, or drag "
                          + "it out again, in Develop.")
            }
            GridRow {
                Text("Auto Settings").foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Toggle("Open the result auto adjusted", isOn: $model.autoSettings)
                    .accessibilityLabel("Auto Settings")
                    .accessibilityHint("Applies Auto Adjust to the panorama as its first edit, which you can undo.")
                    .help("Applies Develop’s Auto Adjust (⌘U) to the panorama as its first edit. "
                          + "Undo in Develop takes it back to the merge as it came out.")
            }
        }
        .font(.callout)
        .frame(width: Self.optionsWidth, alignment: .leading)
    }

    /// The agreement to a smaller panorama: what would have been made, what
    /// will be, why, and a switch that has to be turned on to merge.
    @ViewBuilder private var consent: some View {
        if let text = model.downsampleText, let label = model.consentLabel {
            VStack(alignment: .leading, spacing: 6) {
                Label(text, systemImage: "arrow.down.right.and.arrow.up.left")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(text)
                Toggle(label, isOn: $model.acceptsDownsampling)
                    .accessibilityLabel("Agree to merge at \(PanoramaMergeSheetModel.percent(model.downsampling?.scale ?? 1))")
                    .accessibilityHint("The panorama is merged smaller, at a size this Mac can edit.")
                    .help("Latent never refuses a panorama for its size: it merges it as large as this Mac can edit.")
            }
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
        }
    }

    /// The warnings; they scroll beyond a couple of lines.
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
                                   : "Closes the dialog and stitches in the background; progress shows in the "
                                     + "library panel.")
                .help(canMerge ? "Stitch in the background; progress shows under Export in the library panel."
                               : "Wait for the export or merge under way to finish.")
            }
        }
        .fixedSize()
    }
}

/// One photo in the list: thumbnail, name, exposure, where it points and
/// its brightness correction, read by VoiceOver as one line. A photo that
/// couldn't be joined is dimmed and marked "Left out".
private struct PanoramaFrameRow: View {
    let row: PanoramaMergeSheetModel.Row
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
                Text(row.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.isLeftOut ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text(row.exposure)
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
                Text(row.brightness)
                    .monospacedDigit()
                    .frame(minWidth: 52, alignment: .trailing)
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
