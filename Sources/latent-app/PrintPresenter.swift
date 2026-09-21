import AppKit
import SwiftUI
import Catalog
import PixelEngine
import MLKit

/// Print (⌘P): the system print panel as a sheet on the main window, with
/// Latent's layout section and the panel's live preview. The selection
/// prints in Library, the open image elsewhere.
@MainActor
enum PrintPresenter {
    /// Operations under way. A print outlives the command that started it
    /// (the job runs on after the panel closes), so something must hold it.
    private(set) static var sessions: [PrintSession] = []

    /// Gathers the pictures (reading their edits), then shows the panel.
    static func present(openImage: Bool, model: EditorModel, library: Library) {
        guard let gpu = model.gpu, let window = NSApp.mainWindow, window.attachedSheet == nil else { return }
        let proof = proofProfile(for: model)
        Task {
            do {
                let items: [SheetItem]
                if openImage, let item = try SheetItems.openImage(model: model, library: library) {
                    items = [item]
                } else {
                    items = try await SheetItems.selection(library: library, model: model)
                }
                guard !items.isEmpty, window.attachedSheet == nil else { return }
                // The job keeps its renderer to itself; the one made last
                // is the one the pages were rendered with, and it knows
                // which photos needed a stand-in model.
                let renderers = PrintRenderers()
                let session = PrintSession(
                    items: items, thumbnails: SheetPreviewImages.libraryThumbnails(library),
                    makeRenderer: { profile in
                        // 16-bit Display P3 at the printer's resolution,
                        // AI denoise included: a print shows it.
                        let renderer = SheetRenderer(gpu: gpu, colorSpace: .displayP3, bitsPerComponent: 16,
                                                     aiDenoiseFrom: 0, profile: profile,
                                                     cacheBudget: PrintRenderPolicy.cacheBudget)
                        renderers.made(renderer)
                        return renderer
                    },
                    // Previews of what has no thumbnail render small and in
                    // sRGB; they are never printed.
                    previewRenderer: SheetRenderer(gpu: gpu, colorSpace: .sRGB, bitsPerComponent: 8,
                                                   aiDenoiseFrom: .max, profile: nil, cacheBudget: 32 << 20),
                    proofProfile: proof)
                sessions.append(session)
                session.run(on: window) { finished, success in
                    sessions.removeAll { $0 === finished }
                    // A photo that couldn't be rendered is an empty cell on
                    // paper; the panel's preview, from thumbnails, showed it.
                    // One printed with a stand-in model looked right in the
                    // preview too, so that is said as well.
                    guard success else { return }
                    let substituted = renderers.last?.maskSubstitutions ?? [:]
                    if let message = PrintSession.printedMessage(unrendered: finished.job.unrenderedNames,
                                                                 substitutions: substituted) {
                        model.lastError = message
                        Announcement.post(message, priority: .high)
                    }
                }
            } catch {
                model.reportFailure("Reading the edits to print", error)
            }
        }
    }

    /// The printer or paper profile to print into: Soft Proof's, while
    /// soft proofing is on. A profile proofed against earlier and turned
    /// off since isn't what the user expects the print to look like.
    static func proofProfile(for model: EditorModel) -> SheetProfile? {
        guard model.proofEnabled, case .icc(let url) = model.proofTarget else { return nil }
        return SheetProfile(url: url)
    }

    /// The window title of a print: the one picture's name, or "12 Photos".
    nonisolated static func jobTitle(for items: [SheetItem]) -> String {
        items.count == 1 ? items[0].name : "\(items.count) Photos"
    }
}

/// One print operation and what it needs until it finishes.
@MainActor
final class PrintSession: NSObject {
    let job: PrintJob
    let view: PrintPageView
    let accessory: PrintAccessoryController
    let operation: NSPrintOperation
    private var completion: ((PrintSession, Bool) -> Void)?
    private let jobs: OutputJobs
    /// Set while the job renders for the printer (see `OutputJobs`).
    private(set) var runningJob: UUID?
    private var isFinished = false

    /// `makeRenderer` renders for the printer, for a colour choice (the
    /// proof profile or none); `previewRenderer` renders small previews of
    /// what has no thumbnail.
    init(items: [SheetItem], thumbnails: @escaping SheetThumbnailSource,
         makeRenderer: @escaping @Sendable (SheetProfile?) -> SheetRenderer, previewRenderer: SheetRenderer?,
         proofProfile: SheetProfile?, store: PrintLayoutStore = PrintLayoutStore(),
         printInfo shared: NSPrintInfo = .shared, jobs: OutputJobs = .shared) {
        // A copy of the shared print info, so Page Setup's paper, scale and
        // printer apply, with its margins cleared: the layout keeps its own
        // margins, and each page rectangle is the whole printable area.
        let info = (shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        job = PrintJob(items: items, settings: store.settings, paper: PrintPaper(printInfo: info),
                       proofProfile: proofProfile, makeRenderer: makeRenderer,
                       makePreview: { job in
                           SheetPreviewImages(renderer: previewRenderer, thumbnail: thumbnails,
                                              onReady: { [weak job] in job?.previewDidChange() })
                       })
        view = PrintPageView(job: job)
        accessory = PrintAccessoryController(job: job, store: store)
        operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = PrintPresenter.jobTitle(for: items)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // The job renders every picture at the printer's resolution; on a
        // thread of its own the app stays usable meanwhile, and the
        // progress panel counts the pages with Cancel.
        operation.canSpawnSeparateThread = true
        let panel = operation.printPanel
        panel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling,
                                 .showsPreview])
        panel.addAccessoryController(accessory)
        self.jobs = jobs
        super.init()
    }

    /// `completion` gets whether the job was printed (not cancelled).
    func run(on window: NSWindow, completion: @escaping (PrintSession, Bool) -> Void) {
        self.completion = completion
        job.onPrintingStarted {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.printingStarted() } }
        }
        operation.runModal(for: window, delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    /// AppKit calls this when the job is done (or the panel was cancelled),
    /// possibly from the print thread; the rest happens on the main thread.
    @objc nonisolated func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                                contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finish(success: success) }
        }
    }

    /// The panel has closed and the pages are being rendered: from here
    /// until `finish`, the job counts as running.
    func printingStarted() {
        guard runningJob == nil, !isFinished else { return }
        runningJob = jobs.begin(.print, name: PrintPresenter.jobTitle(for: job.items))
    }

    func finish(success: Bool) {
        if success {
            NSPrintInfo.shared = Self.pageSetup(from: operation.printInfo, keeping: NSPrintInfo.shared)
        }
        isFinished = true
        // A print cancelled in its panel never started: let go of the
        // handler, which holds this session.
        job.onPrintingStarted(nil)
        if let runningJob { jobs.end(runningJob) }
        runningJob = nil
        completion?(self, success)
        completion = nil
    }

    /// What to tell the user after a print: the empty cells, then the
    /// photos printed with a stand-in model ("2 photos used Apple Vision
    /// because BiRefNet General is not installed"); nil when neither.
    nonisolated static func printedMessage(unrendered: [String], substitutions: [String: [String]],
                                           registry: ModelRegistry = .shared) -> String? {
        let missing = Array(Set(substitutions.values.flatMap { $0 })).sorted()
        let sentences = [unrenderedMessage(unrendered),
                         MaskSubstitutions.pageSentence(photos: substitutions.count, missing: missing, registry: registry)]
            .compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: ". ")
    }

    /// What to tell the user about photos that printed as empty cells.
    nonisolated static func unrenderedMessage(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: "\(names[0]) couldn’t be rendered and printed as an empty cell"
        default: "\(names.count) photos couldn’t be rendered and printed as empty cells: "
            + names.joined(separator: ", ")
        }
    }

    /// Page Setup after a print: the printer, paper, orientation and scale
    /// chosen in the panel, as in other Mac apps, and nothing else. The
    /// operation's print info also holds this job's copies, page range and
    /// destination (a PDF's file), which must not become the next print's
    /// starting point; nor may its cleared margins.
    static func pageSetup(from chosen: NSPrintInfo, keeping shared: NSPrintInfo) -> NSPrintInfo {
        let result = (shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        result.printer = chosen.printer
        if let name = chosen.paperName { result.paperName = name }
        result.paperSize = chosen.paperSize
        result.orientation = chosen.orientation
        result.scalingFactor = chosen.scalingFactor
        return result
    }
}

/// The layout settings the accessory's form edits.
@MainActor
final class PrintAccessoryModel: ObservableObject {
    @Published var settings: PrintLayoutSettings {
        didSet { if settings != oldValue { onChange?(settings) } }
    }
    let proofProfileName: String?
    var onChange: ((PrintLayoutSettings) -> Void)?

    init(settings: PrintLayoutSettings, proofProfileName: String?) {
        self.settings = settings
        self.proofProfileName = proofProfileName
    }
}

/// Latent's section of the print panel: pictures per page, fit or fill,
/// auto-rotate, margins, spacing, captions and colour, beside the system's
/// paper and printer settings, with the panel's own live preview.
///
/// The panel redraws its preview when a key path named by
/// `keyPathsForValuesAffectingPreview` changes. Every setting feeds one
/// counter, `layoutRevision`, bumped after the job has the new settings;
/// preview pictures arriving bump it too.
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    let model: PrintAccessoryModel
    private let job: PrintJob
    private let store: PrintLayoutStore

    @objc dynamic var layoutRevision = 0

    init(job: PrintJob, store: PrintLayoutStore) {
        self.job = job
        self.store = store
        model = PrintAccessoryModel(settings: job.currentSettings, proofProfileName: job.proofProfile?.name)
        super.init(nibName: nil, bundle: nil)
        // The panel already has a "Layout" section (pages per sheet, borders).
        title = "Photo Layout"
        model.onChange = { [weak self] settings in self?.settingsChanged(settings) }
        job.onPreviewReady { [weak self] in self?.layoutRevision += 1 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let host = NSHostingView(rootView: PrintAccessoryView(model: model).motionFollowsAccessibility())
        host.frame.size = host.fittingSize
        view = host
    }

    private func settingsChanged(_ settings: PrintLayoutSettings) {
        job.update(settings: settings)
        store.settings = settings
        layoutRevision += 1
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["layoutRevision"]
    }

    /// The lines under this section in the panel's summary (Show Details off).
    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        Self.summary(model.settings, proofProfileName: model.proofProfileName)
            .map { [.itemName: $0.name, .itemDescription: $0.value] }
    }

    static func summary(_ settings: PrintLayoutSettings, proofProfileName: String?) -> [(name: String, value: String)] {
        [
            ("Photos per Page", "\(settings.imagesPerPage)"),
            ("Scaling", settings.scaling == .fit ? "Fit" : "Fill"),
            ("Margins", PrintLength.text(points: settings.margin)),
            ("Spacing", PrintLength.text(points: settings.spacing)),
            ("Captions", settings.caption.title),
            ("Auto-Rotate", settings.autoRotate ? "On" : "Off"),
            ("Colour", colorTitle(settings.color == .proofProfile && proofProfileName != nil ? .proofProfile : .displayP3,
                                  proofProfileName: proofProfileName)),
        ]
    }

    static func colorTitle(_ choice: PrintLayoutSettings.ColorChoice, proofProfileName: String?) -> String {
        switch choice {
        case .displayP3: "Display P3 (wide gamut)"
        case .proofProfile: proofProfileName.map { "Soft proof profile: \($0)" } ?? "Display P3 (wide gamut)"
        }
    }
}

struct PrintAccessoryView: View {
    @ObservedObject var model: PrintAccessoryModel

    var body: some View {
        Form {
            Picker("Photos per page", selection: $model.settings.imagesPerPage) {
                ForEach(PageLayout.imagesPerPageChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            .fixedSize()
            Picker("Scaling", selection: $model.settings.scaling) {
                Text("Fit").tag(LayoutScaling.fit)
                Text("Fill").tag(LayoutScaling.fill)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityHint("Fit shows each whole photo; Fill covers its cell and crops the overflow")
            Toggle("Rotate photos to fill the cells", isOn: $model.settings.autoRotate)
            LabeledContent("Margins") {
                lengthSlider($model.settings.margin, range: PrintLayoutSettings.marginRange, label: "Margins")
            }
            LabeledContent("Spacing") {
                lengthSlider($model.settings.spacing, range: PrintLayoutSettings.spacingRange, label: "Spacing")
            }
            Picker("Captions", selection: $model.settings.caption) {
                ForEach(CaptionContent.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Picker("Colour", selection: Binding(
                // Without a proof profile the choice can only be Display P3;
                // the remembered choice comes back when one is set again.
                get: { model.proofProfileName == nil ? .displayP3 : model.settings.color },
                set: { model.settings.color = $0 })) {
                Text(PrintAccessoryController.colorTitle(.displayP3, proofProfileName: nil)).tag(PrintLayoutSettings.ColorChoice.displayP3)
                if let name = model.proofProfileName {
                    Text(PrintAccessoryController.colorTitle(.proofProfile, proofProfileName: name))
                        .tag(PrintLayoutSettings.ColorChoice.proofProfile)
                }
            }
            .fixedSize()
            .disabled(model.proofProfileName == nil)
            .accessibilityHint("Photos are rendered in this colour space before the printer's colour matching")
        }
        .formStyle(.columns)
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .frame(width: 460)
    }

    private func lengthSlider(_ value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack {
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / 3).rounded() * 3 }),
                   in: range)
                .frame(width: 180)
                .accessibilityLabel(label)
                .accessibilityValue(PrintLength.text(points: value.wrappedValue))
            Text(PrintLength.text(points: value.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .accessibilityHidden(true)
        }
    }
}

/// The renderers a print made for the printer, so the presenter can ask
/// the last one what it substituted once the job is over. The job makes
/// a fresh one when the colour choice changes (`PrintJob.update`).
final class PrintRenderers: @unchecked Sendable {
    private let lock = NSLock()
    private var renderers: [SheetRenderer] = []

    func made(_ renderer: SheetRenderer) {
        lock.withLock { renderers.append(renderer) }
    }

    var last: SheetRenderer? { lock.withLock { renderers.last } }
}
