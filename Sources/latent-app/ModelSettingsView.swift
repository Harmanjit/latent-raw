import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MLKit

extension SpokenText {
    /// One row of Settings › AI › Models as VoiceOver reads it: "BiRefNet
    /// Lite, subject, MIT licence, 103 megabytes, bundled, default". A
    /// built-in model has no size to say; a research-only licence says so.
    static func model(name: String, kind: ModelManifest.Kind, licence: String, commercialUse: Bool,
                      sizeMB: Int, status: ModelEntry.Status, isDefault: Bool) -> String {
        var parts = [name, ModelSettingsModel.purpose(kind).lowercased(), "\(licence) licence"]
        if !commercialUse { parts.append("research use only") }
        if sizeMB > 0 { parts.append(sizeMB == 1 ? "1 megabyte" : "\(sizeMB) megabytes") }
        parts.append(ModelSettingsModel.status(status).lowercased())
        if isDefault { parts.append("default") }
        return parts.joined(separator: ", ")
    }
}

/// The rows and actions of Settings › AI › Models, apart from the view:
/// which models the registry lists, which is the default of its kind,
/// and what Use, Get…, Remove and Add Model… do (docs/Retouch.md §5).
@MainActor
final class ModelSettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let entry: ModelEntry
        /// The model a NEW mask of this kind is made with.
        let isDefault: Bool
        var id: String { entry.id }
    }

    /// An import under way, for the progress sheet.
    struct ImportProgress: Equatable {
        /// The model's display name when the manifest could be read
        /// before the import, else the chosen file's name.
        var name: String
        var stage: String
        var fraction: Double
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var importing: ImportProgress?
    /// What last happened, under the list: "Added BiRefNet General
    /// (446 MB)", or the importer's sentence for why it refused.
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false

    let registry: ModelRegistry
    /// Records the user's choice of default for a kind. The app's writes
    /// the preference `ModelRegistry` reads; tests pass their own.
    private let choose: @MainActor (ModelManifest.Kind, String) -> Void

    init(registry: ModelRegistry = .shared, choose: (@MainActor (ModelManifest.Kind, String) -> Void)? = nil) {
        self.registry = registry
        self.choose = choose ?? { kind, id in
            switch kind {
            case .subjectSegmentation: AppPreferences.shared.subjectModel = id
            case .promptedSegmentation: AppPreferences.shared.promptedModel = id
            default: break
            }
        }
        reload()
    }

    /// Reads the registry again: after an import, a removal or a choice.
    func reload() {
        let subjectDefault = registry.defaultSubject().id
        let promptedDefault = registry.defaultPrompted()?.id
        // The denoiser keeps its own loading and its picker stays hidden
        // (docs/Retouch.md §2 A), so its row would offer nothing.
        rows = registry.entries().filter { $0.manifest.kind != .denoise }.map { entry in
            let isDefault: Bool
            switch entry.manifest.kind {
            case .subjectSegmentation: isDefault = entry.id == subjectDefault
            case .promptedSegmentation: isDefault = entry.id == promptedDefault
            default: isDefault = false
            }
            return Row(entry: entry, isDefault: isDefault)
        }
    }

    // MARK: - Wording

    /// The For column: what masks the kind makes.
    nonisolated static func purpose(_ kind: ModelManifest.Kind) -> String {
        switch kind {
        case .subjectSegmentation: "Subject"
        case .promptedSegmentation: "Click to select"
        case .semanticSegmentation: "Classes"
        case .denoise: "Denoise"
        }
    }

    nonisolated static func status(_ status: ModelEntry.Status) -> String {
        switch status {
        case .builtIn: "Built in"
        case .bundled: "Bundled"
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        }
    }

    nonisolated static let caption = "Latent never downloads anything. Get… opens a model's page in your browser; "
        + "convert it with the script named there, then choose Add Model…"

    /// Whether Use applies: an installed subject or click-to-select model
    /// that is not the default already. Class models have no choice to
    /// make (the installed one runs).
    nonisolated static func canUse(_ row: Row) -> Bool {
        guard row.entry.isInstalled, !row.isDefault else { return false }
        return row.entry.manifest.kind == .subjectSegmentation || row.entry.manifest.kind == .promptedSegmentation
    }

    /// "Removed BiRefNet General." or, for the default of its kind, what
    /// new masks use from now on.
    nonisolated static func removedMessage(name: String, wasDefault: Bool, kind: ModelManifest.Kind, fallback: String?) -> String {
        guard wasDefault else { return "Removed \(name)." }
        let what = kind == .promptedSegmentation ? "click-to-select" : "subject"
        guard let fallback else { return "Removed \(name); no \(what) model is installed now." }
        return "Removed \(name); new \(what) masks use \(fallback)."
    }

    // MARK: - Actions

    /// Makes `entry` the model new masks of its kind are made with.
    func use(_ entry: ModelEntry) {
        guard entry.isInstalled else { return }
        choose(entry.manifest.kind, entry.id)
        reload()
        message = nil
    }

    /// Opens the model's source page in the browser.
    func get(_ entry: ModelEntry) {
        NSWorkspace.shared.open(entry.manifest.sourceURL)
    }

    /// Deletes an installed model's folder. A removed default falls back
    /// (`ModelRegistry.defaultSubject`), and the message says to what;
    /// the preference follows so the rows and the registry agree.
    func remove(_ entry: ModelEntry) {
        guard entry.status == .installed else { return }
        let kind = entry.manifest.kind
        let wasDefault = rows.first { $0.id == entry.id }?.isDefault ?? false
        do {
            try ModelImporter.remove(id: entry.id, from: registry)
        } catch {
            // A sentence, not a domain, a code and the folder's path.
            message = "Removing \(entry.manifest.displayName) failed: \(PhotoMergeQueue.describe(error))"
            messageIsError = true
            reload()
            return
        }
        var fallback: ModelEntry?
        if wasDefault {
            fallback = kind == .promptedSegmentation ? registry.defaultPrompted() : registry.defaultSubject()
            if let fallback { choose(kind, fallback.id) }
        }
        reload()
        message = Self.removedMessage(name: entry.manifest.displayName, wasDefault: wasDefault, kind: kind,
                                      fallback: fallback?.manifest.displayName)
        messageIsError = false
        Announcement.post(message ?? "")
    }

    /// Add Model…: the chooser, then the import.
    func addModel() {
        let panel = NSOpenPanel()
        panel.message = "Choose a model folder, an .mlpackage or a .zip"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // An .mlpackage is a folder to the file system; the panel should
        // offer it as one file, beside zips and plain folders.
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.folder, .zip] + [UTType("com.apple.coreml.mlpackage")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await add(from: url) }
    }

    /// Imports the model at `url`, showing the importer's stages in the
    /// sheet; the result or the refusal ends up in `message`.
    func add(from url: URL) async {
        guard importing == nil else { return }
        let name = Self.manifestName(at: url) ?? url.deletingPathExtension().lastPathComponent
        importing = ImportProgress(name: name, stage: "Checking \(url.lastPathComponent)…", fraction: 0)
        message = nil
        do {
            let manifest = try await ModelImporter.importModel(from: url, into: registry) { progress in
                Task { @MainActor [weak self] in
                    self?.importing?.stage = progress.stage
                    self?.importing?.fraction = progress.fraction
                }
            }
            message = "Added \(manifest.displayName) (\(manifest.sizeMB) MB)"
            messageIsError = false
        } catch {
            // The importer's own sentence; anything else as a sentence too.
            message = PhotoMergeQueue.describe(error)
            messageIsError = true
        }
        importing = nil
        reload()
        Announcement.post(message ?? "")
    }

    /// The display name of the manifest beside what was chosen, when one
    /// can be read without unpacking anything: a folder's, or, for an
    /// .mlpackage, the one in the folder holding it or else inside it
    /// (the folder is out of reach when only the package was chosen). A
    /// zip's is known only once it is unpacked.
    nonisolated static func manifestName(at url: URL) -> String? {
        let folders = url.pathExtension.lowercased() == "mlpackage" ? [url.deletingLastPathComponent(), url] : [url]
        for folder in folders {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            let manifests = names.filter { $0.hasSuffix(".model.json") }.sorted()
            guard manifests.count == 1 else { continue }
            return (try? ModelManifest.load(from: folder.appendingPathComponent(manifests[0])))?.displayName
        }
        return nil
    }

    /// Shows the models folder in Finder, making it first if it has never
    /// held a model.
    func revealModelsFolder() {
        let folder = CoreMLStore.externalModelsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// The tallest row the Models list has laid out, so the list can be as
/// tall as whole rows need (`ModelSettingsView.measuredRowHeight`).
private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Settings › AI › Models: every model the app knows, with where it
/// stands and what can be done about it. Mounted by `PreferencesView.aiTab`
/// above the compute picker. A `List` of rows rather than a `Table`,
/// which collapses in a grouped Form and reads as cells, not rows.
struct ModelSettingsView: View {
    @StateObject private var model = ModelSettingsModel()
    @State private var removing: ModelEntry?
    /// The tallest row on screen, measured (`RowHeightKey`). A row is a
    /// name, up to two lines of purpose, a line of facts and a line of
    /// buttons, so it is far taller than a plain list row and grows with
    /// the text size; `rowHeight` is only the height before the first
    /// row reports back.
    @State private var measuredRowHeight: CGFloat = ModelSettingsView.rowHeight

    private static let rowHeight: CGFloat = 104

    /// Rows shown before the list scrolls, the half telling you it does.
    private static let visibleRows: CGFloat = 4.5

    /// What the List puts round a row's own content, which the measure
    /// above does not see.
    private static let rowInset: CGFloat = 8

    var body: some View {
        Section {
            Text(ModelSettingsModel.caption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(model.rows) { row in
                ModelRowView(row: row, model: model) { removing = row.entry }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: RowHeightKey.self, value: proxy.size.height)
                    })
            }
            .onPreferenceChange(RowHeightKey.self) { height in
                // The list is sized from what a row really measures, so
                // whole rows show at any text size.
                guard height > 0 else { return }
                Task { @MainActor in measuredRowHeight = height + Self.rowInset }
            }
            .frame(height: min(CGFloat(model.rows.count), Self.visibleRows) * measuredRowHeight + 8)
            .accessibilityLabel("Models")
            HStack {
                Button("Add Model…") { model.addModel() }
                    .disabled(model.importing != nil)
                    .help("Add a converted model from a folder, an .mlpackage or a .zip on this Mac")
                Button("Reveal in Finder") { model.revealModelsFolder() }
                    .help("Show the folder added models live in")
                    .accessibilityLabel("Reveal the models folder in Finder")
                Spacer()
            }
            .controlSize(.small)
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.messageIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Models")
        }
        .sheet(isPresented: Binding(get: { model.importing != nil }, set: { _ in })) {
            importSheet
        }
        .confirmationDialog("Remove \(removing?.manifest.displayName ?? "the model")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { entry in
            Button("Remove", role: .destructive) { model.remove(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its files leave the models folder. Masks made with it show with a built-in model until it is added again.")
        }
    }

    /// "Checking BiRefNet General…" with the importer's stage under it.
    /// No Cancel: the compile check under way cannot be stopped, and the
    /// import leaves nothing behind whichever way it ends.
    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checking \(model.importing?.name ?? "the model")…")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(model.importing?.stage ?? "")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            ProgressView(value: model.importing?.fraction ?? 0)
                .accessibilityLabel("Import progress")
                .accessibilityValue("\(Int((model.importing?.fraction ?? 0) * 100)) percent")
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}

/// One model: name and purpose, what it is for, its licence, size and
/// status, a link to its source page, and its actions. VoiceOver reads
/// the row as one sentence (`SpokenText.model`); the buttons stay
/// reachable as its actions.
private struct ModelRowView: View {
    let row: ModelSettingsModel.Row
    @ObservedObject var model: ModelSettingsModel
    let onRemove: () -> Void

    private var manifest: ModelManifest { row.entry.manifest }
    private var name: String { manifest.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name).fontWeight(.semibold)
                if row.isDefault {
                    Text("Default")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text(ModelSettingsModel.status(row.entry.status))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(manifest.purpose)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Text("For: \(ModelSettingsModel.purpose(manifest.kind))")
                Text("Licence: \(manifest.licence.name)")
                    .lineLimit(1).truncationMode(.middle)
                if !manifest.licence.commercialUse {
                    Text("Research use only").foregroundStyle(.orange)
                }
                if manifest.sizeMB > 0 { Text("\(manifest.sizeMB) MB") }
                Link("Source", destination: manifest.sourceURL)
                    .help("Open the source page for \(name) in your browser")
                    .accessibilityLabel("Source page for \(name), opens in your browser")
            }
            .font(.caption)
            HStack(spacing: 8) {
                Button("Use") { model.use(row.entry) }
                    .disabled(!ModelSettingsModel.canUse(row))
                    .help(row.isDefault ? "New masks of this kind already use \(name)"
                          : "Make new masks of this kind with \(name)")
                    .accessibilityLabel("Use \(name) for new masks")
                if row.entry.status == .notInstalled {
                    Button("Get…") { model.get(row.entry) }
                        .help("Open the page for \(name) in your browser; nothing is downloaded by Latent")
                        .accessibilityLabel("Get \(name), opens its page in your browser")
                }
                if row.entry.status == .installed {
                    Button("Remove", role: .destructive, action: onRemove)
                        .help("Delete \(name) from the models folder")
                        .accessibilityLabel("Remove \(name)")
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SpokenText.model(name: name, kind: manifest.kind, licence: manifest.licence.name,
                                             commercialUse: manifest.licence.commercialUse, sizeMB: manifest.sizeMB,
                                             status: row.entry.status, isDefault: row.isDefault))
    }
}
