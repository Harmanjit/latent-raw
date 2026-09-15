import AppKit
import UniformTypeIdentifiers
import Catalog
import PixelEngine
import MLKit

/// An application the user sends images to from Latent, chosen in
/// Settings > External Editor (from minivu's editor list).
struct ExternalEditorApp: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var bundleIdentifier: String?
    /// Where the application was when it was added.
    var path: String
    /// A security-scoped bookmark made from the open panel: it finds the
    /// application again after it moves, and carries the sandbox's
    /// permission to it.
    var bookmark: Data?

    var id: String { bundleIdentifier ?? path }

    /// An entry for the application at `url`; nil if it isn't one.
    static func application(at url: URL, makeBookmark: Bool = true) -> ExternalEditorApp? {
        guard url.pathExtension.lowercased() == "app" || (try? url.resourceValues(forKeys: [.contentTypeKey]))?
            .contentType?.conforms(to: .application) == true else { return nil }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ExternalEditorApp(name: name, bundleIdentifier: bundle?.bundleIdentifier, path: url.path,
                                 bookmark: makeBookmark ? BookmarkStore.bookmark(for: url) : nil)
    }

    /// Where the application is now: the bookmark (which follows a move),
    /// else the path it was added from, else wherever Launch Services knows
    /// its bundle identifier to be. `isScoped` pairs the URL with
    /// start/stopAccessingSecurityScopedResource.
    func locate() -> (url: URL, isScoped: Bool)? {
        if let bookmark, let resolved = BookmarkStore.resolveQuietly(bookmark),
           FileManager.default.fileExists(atPath: resolved.url.path) {
            return (resolved.url, true)
        }
        if FileManager.default.fileExists(atPath: path) {
            return (URL(fileURLWithPath: path), false)
        }
        if let bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return (url, false)
        }
        return nil
    }
}

/// Settings > External Editor: the applications added, which one Edit in
/// External Editor (⌘E) opens (none chosen: the system's default for TIFF),
/// and the folder the TIFFs go to (none chosen: the default export folder).
@MainActor
final class ExternalEditorSettings: ObservableObject {
    static let shared = ExternalEditorSettings(defaults: .standard)
    nonisolated static let appsKey = "latent.externalEditor.apps"
    nonisolated static let chosenKey = "latent.externalEditor.chosen"
    nonisolated static let folderKey = "latent.externalEditor.folder"

    private let defaults: UserDefaults

    @Published private(set) var apps: [ExternalEditorApp]
    /// The chosen application's id, nil for the system default.
    @Published var chosenID: String? {
        didSet { defaults.set(chosenID, forKey: Self.chosenKey) }
    }
    /// The folder chosen for hand-offs; nil uses the default export folder,
    /// or asks the first time when there is none.
    @Published private(set) var folder: URL?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        apps = defaults.data(forKey: Self.appsKey)
            .flatMap { try? JSONDecoder().decode([ExternalEditorApp].self, from: $0) } ?? []
        chosenID = defaults.string(forKey: Self.chosenKey)
        // Only the app's own settings hold a folder bookmark; a test's
        // scratch defaults never resolve one.
        folder = defaults === UserDefaults.standard ? BookmarkStore.resolve(key: Self.folderKey) : nil
    }

    /// The application ⌘E opens with; nil for the system default (also when
    /// the chosen one has been removed).
    var chosen: ExternalEditorApp? {
        chosenID.flatMap { id in apps.first { $0.id == id } }
    }

    /// Adds an application (unless it is already listed) and chooses it.
    @discardableResult
    func add(_ app: ExternalEditorApp) -> Bool {
        defer { chosenID = apps.first { $0.id == app.id || $0.path == app.path }?.id }
        guard !apps.contains(where: { $0.id == app.id || $0.path == app.path }) else { return false }
        apps.append(app)
        save()
        return true
    }

    func remove(id: String) {
        apps.removeAll { $0.id == id }
        if chosenID == id { chosenID = nil }
        save()
    }

    func setFolder(_ url: URL?) {
        folder = url
        // Bookmarks live in the app's own defaults, never a test's.
        guard defaults === UserDefaults.standard else { return }
        if let url { BookmarkStore.save(url, key: Self.folderKey) } else { BookmarkStore.clear(key: Self.folderKey) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(apps) { defaults.set(data, forKey: Self.appsKey) }
    }
}

/// What a hand-off's files are called: "<name>-Edit.tif", then
/// "<name>-Edit-2.tif" and on, so nothing already there is replaced.
enum ExternalEditorNaming {
    static let fileExtension = ExportSettings.Format.tiff.fileExtension

    static func fileName(forSourceNamed sourceName: String, attempt: Int = 1) -> String {
        let stem = ExportNaming.sanitized((sourceName as NSString).deletingPathExtension)
        let base = "\(stem.isEmpty ? "Image" : stem)-Edit.\(fileExtension)"
        return attempt <= 1 ? base : ExportNaming.numbered(base, attempt)
    }

    /// The first name from `attempt` on that `exists` says is free.
    static func freeName(forSourceNamed sourceName: String, from attempt: Int = 1,
                         exists: (String) -> Bool) -> (name: String, attempt: Int) {
        var n = max(attempt, 1)
        while exists(fileName(forSourceNamed: sourceName, attempt: n)) && n < 10_000 { n += 1 }
        return (fileName(forSourceNamed: sourceName, attempt: n), n)
    }
}

/// Opens files in another application: NSWorkspace in the app, a fake in
/// tests, so no test ever launches anything.
protocol ApplicationOpening {
    @MainActor func open(_ file: URL, with app: URL?, completion: @escaping @MainActor (Error?) -> Void)
}

struct WorkspaceOpener: ApplicationOpening {
    @MainActor func open(_ file: URL, with app: URL?, completion: @escaping @MainActor (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                completion(message.map { NSError(domain: "latent.externalEditor", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: $0]) })
            }
        }
        if let app {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration,
                                    completionHandler: done)
        } else {
            NSWorkspace.shared.open(file, configuration: configuration, completionHandler: done)
        }
    }
}

/// Edit in External Editor (⌘E): renders the open image, or the lead
/// selected one, with its edit to a 16-bit Display P3 TIFF through
/// `ExportWorker` (as Export Open Image would, so masks are regenerated and
/// neural denoise runs), writes it beside nothing it could replace, and
/// opens it in the chosen application.
///
/// Latent catalogs raws, so the TIFF doesn't come back into the Library and
/// isn't watched; the status bar says where it went.
@MainActor
final class ExternalEditorHandOff: ObservableObject {
    static let shared = ExternalEditorHandOff()

    /// Where the last hand-off went, for the Library's status bar (Loupe
    /// and Develop show the editor's status, which says the same). Cleared
    /// after a while.
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    /// A catalog read for the lead image's edit is under way (milliseconds).
    private var isReadingEdit = false

    var opener: ApplicationOpening = WorkspaceOpener()
    var settings: ExternalEditorSettings = .shared

    /// What to render.
    struct Source {
        var url: URL
        var editStackJSON: String?
        var userRotation: Int
        var rating: Int
        var readKeywords: (@Sendable () async throws -> [String])?
    }

    /// Runs the hand-off for the image the command means: in Loupe, Compare
    /// and Develop the open image; in the grid the lead selected image, or
    /// the open one when nothing is selected.
    func start(model: EditorModel, library: Library, preferOpenImage: Bool) {
        guard !model.isExporting, model.gpu != nil else { return }
        let lead = library.selectedImage
        let openIsLead = model.hasImage && lead != nil && model.catalogImageID == lead?.id
            && model.imageTitle == lead?.fileName
        if model.hasImage && (preferOpenImage || lead == nil || openIsLead) {
            startWithOpenImage(model: model, library: library)
        } else if let lead {
            startWithRecord(lead, model: model, library: library)
        }
    }

    private func startWithOpenImage(model: EditorModel, library: Library) {
        guard let url = model.sourceURL else { return }
        let json: String?
        do {
            json = EditStack.isDefault(model.parameters, relativeTo: model.defaultParameters)
                ? nil : try model.stackWithProvenance().encodeJSON()
        } catch {
            model.reportFailure("Encoding the edit for the external editor", error)
            return
        }
        model.flushPendingSave()
        var source = Source(url: url, editStackJSON: json, userRotation: model.userRotation, rating: 0)
        // Keywords and rating from the catalog, as Export Open Image has them.
        if let id = model.catalogImageID, let catalog = library.catalog,
           let record = library.images.first(where: { $0.id == id && $0.fileName == model.imageTitle }) {
            source.rating = record.rating
            source.readKeywords = { try await catalog.keywords(forImageID: id) }
        }
        send(source, name: url.lastPathComponent, model: model)
    }

    private func startWithRecord(_ record: ImageRecord, model: EditorModel, library: Library) {
        guard !isReadingEdit, let url = library.fileURL(for: record), let id = record.id,
              let catalog = library.catalog else { return }
        isReadingEdit = true
        Task {
            defer { isReadingEdit = false }
            let json: String?
            do {
                json = try await library.editStack(for: record)
            } catch {
                model.reportFailure("Reading the edit for \(record.fileName)", error)
                return
            }
            guard library.catalog === catalog else { return }
            send(Source(url: url, editStackJSON: json, userRotation: record.userRotation, rating: record.rating,
                        readKeywords: { try await catalog.keywords(forImageID: id) }),
                 name: record.fileName, model: model)
        }
    }

    /// The folder to write to: the one chosen for hand-offs, else the
    /// default export folder, else asked for once and remembered.
    func destinationFolder() -> URL? {
        for folder in [settings.folder, AppPreferences.shared.defaultExportFolder].compactMap({ $0 })
        where FolderAccess.problem(opening: folder) == nil {
            return folder
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for images sent to an external editor. Latent remembers it; change it in Settings > External Editor."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        settings.setFolder(url)
        return url
    }

    private func send(_ source: Source, name: String, model: EditorModel) {
        guard let gpu = model.gpu, !model.isExporting, let folder = destinationFolder() else { return }
        let app = settings.chosen
        let options = OpenImageExportOptions.load()
        model.isExporting = true
        model.status = "Rendering \(name) for \(app?.name ?? "the external editor")…"

        Task {
            var keywords: [String] = []
            if options.includeMetadata, let read = source.readKeywords {
                do {
                    keywords = try await read()
                } catch {
                    model.isExporting = false
                    model.status = "Edit in External Editor cancelled"
                    model.reportFailure("Reading keywords for the external editor", error)
                    return
                }
            }
            var attempt = 1
            var written: URL?
            var failure: Error?
            // A file that appears under the name during the render is kept,
            // and the next number is tried.
            while written == nil, failure == nil, attempt < 20 {
                let free = ExternalEditorNaming.freeName(forSourceNamed: name, from: attempt) {
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                }
                let destination = folder.appendingPathComponent(free.name)
                let request = ExportWorker.Request(
                    sourceURL: source.url, destinationURL: destination, editStackJSON: source.editStackJSON,
                    userRotation: source.userRotation, settings: ExportSettings(format: .tiff),
                    colorSpace: .displayP3, maxLongEdge: nil, keywords: keywords,
                    rating: options.includeMetadata ? source.rating : 0,
                    includeMetadata: options.includeMetadata,
                    includeLocation: options.includeMetadata && options.includeLocation,
                    replacesExisting: false)
                let gpuContext = gpu
                let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                    do { _ = try await ExportWorker.export(request, gpu: gpuContext); return .success(()) }
                    catch { return .failure(error) }
                }.value
                switch outcome {
                case .success: written = destination
                case .failure(let error) where error is SafeFileWriter.DestinationExists: attempt = free.attempt + 1
                case .failure(let error): failure = error
                }
            }
            guard let written else {
                model.isExporting = false
                model.status = "Edit in External Editor failed"
                model.reportFailure("Rendering \(name) for the external editor",
                                    failure ?? CocoaError(.fileWriteFileExists))
                return
            }
            let place = (folder.path as NSString).abbreviatingWithTildeInPath
            let message = "\(written.lastPathComponent) is in \(place), opening in \(app?.name ?? "the default app for TIFF")"
            model.status = message
            post(message)
            model.isExporting = false
            open(written, in: app, model: model)
        }
    }

    private func open(_ file: URL, in app: ExternalEditorApp?, model: EditorModel) {
        var applicationURL: URL?
        var scoped = false
        if let app {
            guard let located = app.locate() else {
                model.lastError = "\(app.name) can’t be found. \(file.lastPathComponent) is in \((file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath); choose the application again in Settings > External Editor."
                return
            }
            applicationURL = located.url
            scoped = located.isScoped && located.url.startAccessingSecurityScopedResource()
        }
        opener.open(file, with: applicationURL) { error in
            if scoped { applicationURL?.stopAccessingSecurityScopedResource() }
            if let error {
                model.lastError = "\(app?.name ?? "The default app") couldn’t open \(file.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func post(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
