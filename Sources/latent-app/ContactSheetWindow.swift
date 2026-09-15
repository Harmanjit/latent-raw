import AppKit
import SwiftUI
import Catalog
import PixelEngine
import MLKit

/// The Contact Sheet dialog's state: the selection, the settings, the title,
/// a small preview of page 1 that follows them, and the save under way.
@MainActor
final class ContactSheetModel: ObservableObject {
    let items: [SheetItem]
    @Published var settings: ContactSheetSettings {
        didSet {
            // A number typed out of range shows what will be used (a margin
            // of 5000 becomes 800), rather than the sheet quietly differing.
            if settings != settings.validated { settings = settings.validated; return }
            guard settings != oldValue else { return }
            store?.settings = settings
            schedulePreview()
        }
    }
    @Published var title: String {
        didSet { if title != oldValue { schedulePreview() } }
    }
    @Published private(set) var preview: CGImage?
    @Published private(set) var isSaving = false
    @Published private(set) var drawnCount = 0
    @Published var errorMessage: String?

    private let store: ContactSheetStore?
    /// Renders photos for the file, in the settings' colour space.
    private let makeRenderer: ((ContactSheetSettings) -> SheetRenderer)?
    private var previewImages: SheetPreviewImages!
    /// Set when a newer preview is asked for, so an older one stops.
    private var previewStale: SheetCancellation?
    private var previewGeneration = 0
    private var cancel: SheetCancellation?
    /// Previews drawn so far; for tests.
    private(set) var previewsDrawn = 0

    /// The preview's long edge in pixels: about 300 points on a Retina screen.
    static let previewLongEdge = 600.0
    /// Changes closer together than this make one preview.
    static let previewDelay = 0.15

    /// `previewRenderer` renders small previews of what has no thumbnail;
    /// `makeRenderer` the photos for the file (nil: Save does nothing).
    init(items: [SheetItem], title: String, thumbnails: @escaping SheetThumbnailSource,
         previewRenderer: SheetRenderer?, makeRenderer: ((ContactSheetSettings) -> SheetRenderer)?,
         store: ContactSheetStore? = ContactSheetStore()) {
        self.items = items
        self.title = title
        self.store = store
        self.makeRenderer = makeRenderer
        settings = store?.settings ?? ContactSheetSettings()
        previewImages = SheetPreviewImages(renderer: previewRenderer, thumbnail: thumbnails,
                                           onReady: { [weak self] in self?.schedulePreview() })
    }

    /// The app's: thumbnails from the Library, renders through ExportWorker.
    convenience init(items: [SheetItem], title: String, library: Library, gpu: GPUContext) {
        self.init(items: items, title: title, thumbnails: SheetPreviewImages.libraryThumbnails(library),
                  previewRenderer: SheetRenderer(gpu: gpu, colorSpace: .sRGB, bitsPerComponent: 8, aiDenoiseFrom: .max,
                                                 profile: nil, cacheBudget: 32 << 20),
                  makeRenderer: { settings in
                      // 8 bits, as the page is. AI denoise only for cells
                      // large enough to show it.
                      SheetRenderer(gpu: gpu, colorSpace: settings.colorSpace.outputSpace, bitsPerComponent: 8,
                                    aiDenoiseFrom: 1600, profile: nil, cacheBudget: 128 << 20)
                  })
    }

    var pageCount: Int { settings.pageCount(imageCount: items.count) }

    /// The scale the preview is drawn at, page pixels to preview pixels.
    var previewScale: Double {
        let size = settings.pagePixelSize
        return min(1, Self.previewLongEdge / max(size.width, size.height))
    }

    /// "24 photos · 2 pages · 2480 × 3508 px".
    var summary: String {
        let size = settings.pagePixelSize
        let photos = items.count == 1 ? "1 photo" : "\(items.count) photos"
        let pages = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        return "\(photos) · \(pages) · \(Int(size.width)) × \(Int(size.height)) px"
    }

    /// Draws page 1 small from thumbnails, after a short pause so a stepper
    /// held down or a number typed makes one drawing, not one per step.
    func schedulePreview(after delay: Double = ContactSheetModel.previewDelay) {
        guard !isClosed else { return }
        previewStale?.cancel()
        let stale = SheetCancellation()
        previewStale = stale
        previewGeneration += 1
        let generation = previewGeneration
        let items = items, settings = settings, title = title, scale = previewScale, images = previewImages!
        // Sendable, so it runs on the worker as nonisolated code rather than
        // inheriting the main actor.
        let work: @Sendable () -> Void = {
            guard !stale.isCancelled else { return }
            let image = ContactSheetWriter.pageImage(settings: settings, imageCount: items.count, title: title,
                                                     scale: scale) { layout, style, context in
                SheetPageDrawer.drawPreviewPage(0, items: items, layout: layout, style: style, preview: images,
                                                in: context)
            }
            let box = image.map(RenderedImage.init)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, generation == self.previewGeneration else { return }
                    self.preview = box?.cgImage
                    self.previewsDrawn += 1
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stopPreview() {
        previewStale?.cancel()
        previewGeneration += 1
    }

    /// The dialog has gone: thumbnails still arriving draw nothing more,
    /// and a save under way stops.
    private(set) var isClosed = false

    func close() {
        isClosed = true
        cancelSaving()
        stopPreview()
    }

    /// Names of photos the last save couldn't render (drawn as empty cells).
    @Published private(set) var unrenderedNames: [String] = []

    /// Makes the sheet and writes it to `url`, off the main thread; calls
    /// `completion` on the main actor with nil on success, or the error.
    func save(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        guard !isSaving, let makeRenderer else { return }
        let cancel = SheetCancellation()
        self.cancel = cancel
        isSaving = true
        drawnCount = 0
        errorMessage = nil
        stopPreview()
        let items = items, settings = settings.validated, title = title, preview = previewImages!
        let renderer = makeRenderer(settings)
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            var failure: Error?
            do {
                try ContactSheetWriter.write(items: items, settings: settings, title: title, to: url,
                                             renderer: renderer, preview: preview, cancel: cancel) { drawn in
                    DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.drawnCount = drawn } }
                }
            } catch {
                failure = error
            }
            let box = failure.map { ErrorBox(error: $0) }
            let unrendered = renderer.failedNames
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    self?.unrenderedNames = unrendered
                    self?.isSaving = false
                    self?.cancel = nil
                    completion(box?.error)
                }
            }
        }
    }

    func cancelSaving() {
        cancel?.cancel()
    }

    private struct ErrorBox: @unchecked Sendable { let error: Error }
}

/// The dialog: a preview of page 1 beside the settings.
struct ContactSheetView: View {
    @ObservedObject var model: ContactSheetModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                previewPane
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                form
                    .frame(width: 420)
                    .disabled(model.isSaving)
            }
            Divider()
            footer
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 751, height: 660)
        .onAppear { model.schedulePreview(after: 0) }
        .onDisappear { model.stopPreview() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isSaving {
                ProgressView(value: Double(model.drawnCount), total: Double(max(model.items.count, 1)))
                    .frame(width: 180)
                    .accessibilityLabel("Making the contact sheet")
                    .accessibilityValue("\(model.drawnCount) of \(model.items.count) photos")
                Text("\(model.drawnCount) of \(model.items.count) photos")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            } else if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if model.isSaving {
                Button("Stop", role: .cancel) { model.cancelSaving() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops making the contact sheet; nothing is written")
            } else {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save…", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.items.isEmpty)
            }
        }
    }

    private var previewPane: some View {
        VStack(spacing: 10) {
            Text("Contact Sheet")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            let size = model.settings.pagePixelSize
            let fit = min(290 / size.width, 520 / size.height)
            Group {
                if let image = model.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Rectangle().fill(Color(cgColor: model.settings.background.color.cgColor))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: size.width * fit, height: size.height * fit)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of page 1")
            .accessibilityValue(model.summary)
            Text(model.pageCount > 1 ? "Page 1 of \(model.pageCount)" : "Page 1")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var form: some View {
        Form {
            Section {
                Picker("Format", selection: $model.settings.format) {
                    ForEach(ContactSheetFormat.allCases) { Text($0.title).tag($0) }
                }
                Picker("Colour space", selection: $model.settings.colorSpace) {
                    ForEach(ContactSheetColorSpace.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("File")
            } footer: {
                Text(model.settings.format == .pdf
                     ? "One PDF with as many pages as the grid needs."
                     : "One picture with every photo on it; choose PDF for several pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Page") {
                Picker("Size", selection: $model.settings.pageSize) {
                    ForEach(ContactSheetPageSize.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.pageSize == .custom {
                    LabeledContent("Width") { pixelField($model.settings.customWidth, label: "Width") }
                    LabeledContent("Height") { pixelField($model.settings.customHeight, label: "Height") }
                } else {
                    Picker("Orientation", selection: $model.settings.orientation) {
                        ForEach(ContactSheetOrientation.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Background", selection: $model.settings.background) {
                    ForEach(ContactSheetBackground.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Grid") {
                LabeledContent("Columns") {
                    counter("\(model.settings.columns)", label: "Columns", $model.settings.columns,
                            in: ContactSheetSettings.columnRange)
                }
                LabeledContent("Rows per page") {
                    counter(model.settings.effectiveRows.map(String.init) ?? "Auto (one page)", label: "Rows per page",
                            $model.settings.rows, in: ContactSheetSettings.rowRange)
                        .disabled(model.settings.format.isImage)
                }
                LabeledContent("Spacing") { pixelField($model.settings.spacing, label: "Spacing") }
                LabeledContent("Margin") { pixelField($model.settings.margin, label: "Margin") }
                Picker("Photos", selection: $model.settings.scaling) {
                    Text("Fit in Cell").tag(LayoutScaling.fit)
                    Text("Fill Cell").tag(LayoutScaling.fill)
                }
                .pickerStyle(.segmented)
            }
            Section("Text") {
                Toggle("Title", isOn: $model.settings.showsTitle)
                if model.settings.showsTitle {
                    TextField("Title text", text: $model.title, prompt: Text("Title"))
                        .accessibilityLabel("Title text")
                }
                Picker("Captions", selection: $model.settings.caption) {
                    ForEach(CaptionContent.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Text size") { pixelField($model.settings.captionSize, label: "Text size") }
                Toggle("Page numbers", isOn: $model.settings.showsPageNumbers)
                    .disabled(model.settings.format.isImage)
            }
        }
        .formStyle(.grouped)
    }

    /// The value, then the stepper's arrows beside it, as System Settings
    /// sets them out.
    private func counter(_ text: String, label: String, _ value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Text(text).monospacedDigit().accessibilityHidden(true)
            Stepper(label, value: value, in: range)
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(text)
        }
    }

    private func pixelField(_ value: Binding<Int>, label: String) -> some View {
        HStack(spacing: 6) {
            TextField(label, value: value, format: .number.grouping(.never))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .accessibilityLabel("\(label) in pixels")
            Text("px").foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

/// Presents the dialog as a sheet on the main window and carries a Save
/// through choosing where, making the sheet, and saying how it went.
@MainActor
final class ContactSheetPresenter {
    let model: ContactSheetModel
    private weak var parent: NSWindow?
    private var sheet: NSWindow?
    private let startFolder: URL?
    private let onSaved: (URL) -> Void

    /// The dialog open now, so a second command doesn't stack another.
    private(set) static var current: ContactSheetPresenter?

    #if DEBUG
    /// Where Save writes without asking; set by the snapshot harness only.
    var debugDestination: URL?

    /// Save, as the button does; for the snapshot harness.
    func saveForSnapshot() { chooseDestination() }
    #endif

    init(model: ContactSheetModel, startFolder: URL?, onSaved: @escaping (URL) -> Void) {
        self.model = model
        self.startFolder = startFolder
        self.onSaved = onSaved
    }

    /// Gathers the selection (reading its edits), then shows the dialog.
    static func present(model editor: EditorModel, library: Library) {
        guard current == nil, let gpu = editor.gpu, let window = NSApp.mainWindow, window.attachedSheet == nil else { return }
        Task {
            do {
                let items = try await SheetItems.selection(library: library, model: editor)
                guard !items.isEmpty, current == nil, window.attachedSheet == nil else { return }
                let model = ContactSheetModel(items: items, title: library.folderURL?.lastPathComponent ?? "",
                                              library: library, gpu: gpu)
                let presenter = ContactSheetPresenter(model: model, startFolder: nil) { url in
                    let missing = model.unrenderedNames
                    let message = "Saved “\(url.lastPathComponent)”" + (missing.isEmpty ? "" :
                        missing.count == 1 ? "; \(missing[0]) couldn’t be rendered" : "; \(missing.count) photos couldn’t be rendered")
                    editor.reportError(message)
                    Announcement.post(message)
                }
                presenter.begin(on: window)
            } catch {
                editor.reportFailure("Reading the edits for the contact sheet", error)
            }
        }
    }

    func begin(on window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        parent = window
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 751, height: 660), styleMask: [.titled],
                             backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.title = "Contact Sheet"
        let view = ContactSheetView(model: model, onCancel: { [weak self] in self?.close() },
                                    onSave: { [weak self] in self?.chooseDestination() })
            .motionFollowsAccessibility()
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        sheet = panel
        Self.current = self
        window.beginSheet(panel)
        // Nothing focused at first, so Return saves rather than landing in
        // the first number field.
        panel.makeFirstResponder(nil)
    }

    func close() {
        model.close()
        if let sheet, let parent { parent.endSheet(sheet) }
        sheet?.orderOut(nil)
        sheet = nil
        if Self.current === self { Self.current = nil }
    }

    private func chooseDestination() {
        guard let sheet else { return }
        // The dialog's text fields commit what is typed when they lose focus.
        sheet.makeFirstResponder(nil)
        let name = ContactSheetNaming.fileName(title: model.title, format: model.settings.format)
        #if DEBUG
        if let folder = debugDestination {
            save(to: folder.appendingPathComponent(name))
            return
        }
        #endif
        let panel = NSSavePanel()
        panel.allowedContentTypes = [model.settings.format.contentType]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let startFolder { panel.directoryURL = startFolder }
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.save(to: url) }
        }
    }

    private func save(to url: URL) {
        model.save(to: url) { [weak self] error in
            guard let self else { return }
            switch error {
            case nil:
                self.close()
                self.onSaved(url)
            case ContactSheetWriter.Failure.cancelled?:
                break
            case let error?:
                self.model.errorMessage = "The contact sheet couldn’t be saved: \(error.localizedDescription)"
                Announcement.post(self.model.errorMessage ?? "", priority: .high)
            }
        }
    }
}
