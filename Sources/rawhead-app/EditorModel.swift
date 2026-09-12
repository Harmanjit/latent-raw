import Foundation
import Metal
import SwiftUI
import UniformTypeIdentifiers
import RawCore
import ColorKit
import PixelEngine

/// The editor's state: which image is open, what the adjustments are, and
/// the most recent rendered result.
///
/// @MainActor because it drives the UI and owns the Metal texture the view
/// draws. Viewport rendering runs synchronously on the main thread, which is
/// defensible only because it measures around 6ms — inside a frame. Export
/// is far too slow for that and runs on `ExportService`, an actor that owns
/// its own session so nothing mutable is shared across the boundary.
///
/// `init` deliberately doesn't throw: SwiftUI's @StateObject takes a
/// non-throwing autoclosure, so a throwing initializer can't be used there
/// without a force-try that would crash on exactly the failure it claims to
/// handle. Setup failure is held in `setupError` and surfaced in the UI.
@MainActor
final class EditorModel: ObservableObject {
    @Published var parameters = EditParameters() {
        didSet { if parameters != oldValue { rerender() } }
    }
    @Published private(set) var texture: MTLTexture?
    @Published private(set) var histogram: Histogram?
    @Published private(set) var status = "Open a raw file to begin"
    @Published private(set) var imageTitle: String?
    @Published private(set) var lastRenderMs: Double = 0

    /// Export settings persist across exports within a session, so a second
    /// export doesn't mean re-choosing format and quality.
    @Published var exportSettings = ExportSettings()
    @Published private(set) var isExporting = false

    /// The camera's own white balance, for the "As Shot" button and for
    /// showing the user where the camera set things.
    @Published private(set) var asShotWhiteBalance = ColorKit.WhiteBalance()

    /// Non-nil when Metal setup failed, in which case nothing else works.
    let setupError: String?

    private let gpuContext: GPUContext?
    private let pipeline: RenderPipeline?
    private let presenterInstance: Presenter?
    private let histogramCalculator: HistogramCalculator?
    private let exportService: ExportService?
    private var session: ImageSession?
    private var sourceURL: URL?

    /// The long-edge pixel count the viewport needs. Updated by the Metal
    /// view as the window resizes, so the render tracks the actual display
    /// size rather than a fixed guess (DESIGN.md §8.2).
    private var viewportDimension = 2560

    init() {
        do {
            let gpu = try GPUContext()
            self.gpuContext = gpu
            self.pipeline = RenderPipeline(gpu: gpu)
            self.presenterInstance = Presenter(gpu: gpu)
            self.histogramCalculator = try? HistogramCalculator(gpu: gpu)
            self.exportService = ExportService(gpu: gpu)
            self.setupError = nil
        } catch {
            self.gpuContext = nil
            self.pipeline = nil
            self.presenterInstance = nil
            self.histogramCalculator = nil
            self.exportService = nil
            self.setupError = String(describing: error)
            self.status = "Metal setup failed"
        }
    }

    var isReady: Bool { gpuContext != nil }
    var device: MTLDevice? { gpuContext?.device }
    var presenter: Presenter? { presenterInstance }
    var hasImage: Bool { session != nil }

    /// The temperature slider works in negated mired rather than Kelvin, so
    /// its travel is perceptually even — see ColorKit for the reasoning.
    var temperatureSliderBinding: Binding<Float> {
        Binding(
            get: { ColorKit.sliderValue(forTemperature: self.parameters.whiteBalance.temperature) },
            set: { self.parameters.whiteBalance.temperature = ColorKit.temperature(forSliderValue: $0) }
        )
    }

    /// The slider's range, centred on this image's as-shot temperature so
    /// the starting point is always mid-travel and both directions shift by
    /// equal amounts.
    var temperatureSliderRange: ClosedRange<Float> {
        ColorKit.temperatureSliderRange(asShotTemperature: asShotWhiteBalance.temperature)
    }

    func showOpenPanel() {
        guard isReady else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a raw file"
        // Raw formats mostly lack registered UTTypes, so filter loosely and
        // let RawFile reject anything LibRaw can't read.
        panel.allowedContentTypes = [UTType.image]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        guard let gpu = gpuContext else { return }
        status = "Opening \(url.lastPathComponent)…"
        do {
            let file = try RawFile(path: url.path)
            let newSession = try ImageSession(file: file, gpu: gpu)
            session = newSession
            sourceURL = url
            imageTitle = url.lastPathComponent
            asShotWhiteBalance = newSession.asShotWhiteBalance

            // Start from the camera's own white balance, expressed as
            // temperature and tint so the sliders show something meaningful
            // rather than a default the photo was never shot under.
            var fresh = EditParameters()
            fresh.whiteBalance = newSession.asShotWhiteBalance
            parameters = fresh   // triggers rerender via didSet

            if newSession.profile == nil {
                status = "No colour profile for \(file.summary.cameraModel) — cannot render"
            } else {
                status = "\(file.summary.cameraMake) \(file.summary.cameraModel) · " +
                         "\(file.summary.rawWidth)×\(file.summary.rawHeight)"
            }
            rerender()
        } catch {
            session = nil
            sourceURL = nil
            texture = nil
            histogram = nil
            imageTitle = nil
            status = "Could not open: \(error)"
        }
    }

    /// Called by the Metal view when the drawable size changes. Re-renders
    /// only on a meaningful change, so dragging a window edge doesn't
    /// trigger a render for every intermediate pixel width.
    func updateViewport(longEdge: Int) {
        let rounded = max(256, (longEdge / 128) * 128)
        guard rounded != viewportDimension else { return }
        viewportDimension = rounded
        rerender()
    }

    func rerender() {
        guard let session, let pipeline else { return }
        let start = Date()
        do {
            let rendered = try pipeline.render(session,
                                                scale: .fitting(maxDimension: viewportDimension),
                                                parameters: parameters)
            texture = rendered
            lastRenderMs = Date().timeIntervalSince(start) * 1000

            // Measured separately from the render time above, so the number
            // in the status bar stays comparable to the Phase 1 target.
            histogram = histogramCalculator?.compute(from: rendered)
        } catch {
            status = "Render failed: \(error)"
        }
    }

    // MARK: - Export

    func showExportPanel() {
        guard hasImage, let sourceURL else { return }

        let panel = NSSavePanel()
        panel.message = "Export image"
        panel.allowedContentTypes = [exportSettings.format.contentType]
        panel.nameFieldStringValue = sourceURL
            .deletingPathExtension().lastPathComponent
            + "." + exportSettings.format.fileExtension

        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url)
    }

    /// Hands the work to `ExportService`, which opens its own copy of the
    /// file so the viewport's session is untouched.
    ///
    /// Only plain values cross the actor boundary — two URLs, the edit
    /// parameters and the export settings, all Sendable. Nothing mutable is
    /// shared, which is what makes this safe rather than merely quiet.
    func export(to destination: URL) {
        guard let exportService, let sourceURL else { return }
        let settings = exportSettings
        let params = parameters

        isExporting = true
        status = "Exporting at full resolution…"

        Task {
            do {
                let elapsed = try await exportService.export(from: sourceURL,
                                                              to: destination,
                                                              parameters: params,
                                                              settings: settings)
                isExporting = false
                status = String(format: "Exported %@ in %.1fs",
                                 destination.lastPathComponent, elapsed)
            } catch {
                isExporting = false
                status = "Export failed: \(error)"
            }
        }
    }

    func resetWhiteBalance() {
        parameters.whiteBalance = asShotWhiteBalance
    }

    func resetAdjustments() {
        var fresh = EditParameters()
        fresh.whiteBalance = asShotWhiteBalance
        parameters = fresh
    }
}
