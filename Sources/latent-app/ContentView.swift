import SwiftUI
import Metal
import PixelEngine
import MLKit
import ColorKit
import Catalog
import LensKit
import MergeKit
import UniformTypeIdentifiers

/// Which part of the app is showing: the grid (Library), one image
/// (Loupe), two side by side (Compare), two to four (Survey) or the editor
/// (Develop), after Lightroom's Library and Develop modules.
enum AppMode: String, CaseIterable, Identifiable {
    case library, loupe, compare, survey, develop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: "Library"
        case .loupe: "Loupe"
        case .compare: "Compare"
        case .survey: "Survey"
        case .develop: "Develop"
        }
    }
    /// Modes that show a rendered image and so support zoom controls.
    var showsImage: Bool { self != .library }
    /// Modes showing the editor's own image (in Compare, the Candidate).
    /// Survey's panes have models of their own, and the editor may still
    /// hold an image from before that nobody sees there.
    var showsEditorImage: Bool { showsImage && self != .survey }
}

/// Layout follows Lightroom's Develop module, which is what people expect:
/// image centred on a neutral surround, histogram at the top of the right
/// panel, adjustments below it, status along the bottom. Panel order also
/// follows Lightroom — white balance first, then tone — because that's the
/// order the adjustments actually want to be made in.
///
/// Sections that aren't reached for often are collapsed by default, which
/// keeps the panel from becoming a wall of sliders. The folder sidebar
/// (`FolderSidebar`) is on the left.
struct ContentView: View {
    // Not the window's own: reopening the window must not build a second set.
    @ObservedObject private var model = MainWindowModels.shared.model
    @ObservedObject private var library = MainWindowModels.shared.library
    @ObservedObject private var exportQueue = MainWindowModels.shared.exportQueue
    @ObservedObject private var photoMerge = MainWindowModels.shared.photoMerge
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var handOff = ExternalEditorHandOff.shared
    @ObservedObject private var fileOperations = MainWindowModels.shared.library.fileOperations
    @ObservedObject private var navigator = FolderNavigator.shared
    @ObservedObject private var fullScreen = FullScreenImageMode.shared
    @ObservedObject private var secondDisplay = SecondaryDisplay.shared
    /// The second display's Loupe waiting to load a grid selection.
    @State private var secondDisplayLoad: Task<Void, Never>?
    @State private var mode: AppMode = .library
    @State private var showingExportSheet = false
    /// The HDR Merge dialog's state, while it is up (Photo › Photo Merge › HDR…).
    @State private var hdrMergeSheet: HDRMergeSheetModel?
    /// The Panorama dialog's state, while it is up (Photo › Photo Merge › Panorama…).
    @State private var panoramaMergeSheet: PanoramaMergeSheetModel?
    /// The HDR Panorama dialog's state, while it is up (Photo › Photo Merge ›
    /// HDR Panorama…, experimental).
    @State private var hdrPanoramaMergeSheet: HDRPanoramaMergeSheetModel?
    /// Compare's left pane ("Select"): its own render, created the first
    /// time Compare opens. The right pane ("Candidate") is the main model,
    /// which follows the selection as arrow keys move it.
    @State private var compareModel: EditorModel?
    @State private var whiteBalanceExpanded = true
    @State private var toneExpanded = true
    @State private var cropExpanded = false
    @State private var presenceExpanded = true
    @State private var healExpanded = false
    @State private var compareRecord: ImageRecord?
    /// The sidebar and filmstrip stay as the user left them.
    @AppStorage("latent.sidebarVisible") private var sidebarVisible = true
    @AppStorage("latent.filmstripVisible") private var filmstripVisible = true
    /// The folder being opened, highlighted in the sidebar until it has
    /// opened (or failed to, when the highlight goes back).
    @State private var openingFolder: URL?
    /// A text field in the window has the keyboard (BareKeyMonitor says).
    @State private var editingText = false
    /// Compare's panes zoom and pan together (see `EditorModel.linkedPane`).
    @State private var compareSyncsView = true
    /// The image Rename (F2) is naming, while its sheet is up.
    @State private var renaming: ImageRecord?
    /// What Undo and Redo would do outside Develop (see LibraryUndo.swift).
    @StateObject private var libraryUndo = LibraryUndoObserver()
    /// Survey's panes (N), each with its own view-only model.
    @StateObject private var survey = SurveyModel()

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            FolderSidebar(favourites: FavouriteFolders.shared, currentFolder: openingFolder ?? library.folderURL,
                          onOpen: { openFolder($0) }, onChooseFolder: chooseFavouriteFolder,
                          onDropImages: { fileCommands.dropImages($0, on: $1, mode: $2) },
                          areLibraryImages: { fileCommands.areLibraryImages($0) },
                          navigator: navigator, onStepHistory: stepFolderHistory)
                .navigationSplitViewColumnWidth(min: 170, ideal: 220, max: 360)
        } detail: {
            mainArea
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(fullScreen.isActive ? .hidden : .automatic, for: .windowToolbar)
        .motionFollowsAccessibility()
    }

    /// The full-screen image hides the sidebar without forgetting its state.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarVisible && !fullScreen.isActive ? .all : .detailOnly },
                set: { if !fullScreen.isActive { sidebarVisible = $0 != .detailOnly } })
    }

    private var showsFilmstrip: Bool {
        filmstripVisible && (mode == .loupe || mode == .develop) && library.folderURL != nil && !fullScreen.isActive
    }

    private var mainArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !fullScreen.isActive {
                    libraryPanel
                    Divider()
                }
                switch mode {
                case .library:
                    VStack(spacing: 0) {
                        FilterBar(library: library)
                        Divider()
                        ThumbnailGridView(library: library, onOpen: openInEditor, actions: gridActions)
                    }
                    .onDisappear { model.flushPendingSave() }
                case .loupe:
                    VStack(spacing: 0) {
                        ImageViewport(model: model, allowsTools: false, onStep: { _ = perform(.step($0)) })
                        if !fullScreen.isActive {
                            Divider()
                            ImageCaption(record: library.selectedImage)
                        }
                    }
                case .compare:
                    compareArea
                case .survey:
                    SurveyView(survey: survey, library: library,
                               onRemove: surveyRemove, onSelectionChange: surveyFollowSelection)
                case .develop:
                    imageArea
                    if !fullScreen.isActive {
                        Divider()
                        adjustmentPanel
                            .frame(width: 280)
                    }
                }
            }
            if showsFilmstrip {
                Divider()
                FilmstripView(library: library, onSelect: openFromFilmstrip)
                    .frame(height: FilmstripView.height)
            }
            if !fullScreen.isActive {
                Divider()
                statusBar
            }
        }
        .fullScreenFlyouts(fullScreen, available: FullScreenImagePolicy.availableEdges(mode: mode, hasFolder: library.folderURL != nil),
                           left: { libraryPanel },
                           right: { adjustmentPanel.frame(width: 280) },
                           bottom: {
                               FilmstripView(library: library, onSelect: openFromFilmstrip)
                                   .frame(height: FilmstripView.height)
                           })
        .background(navigationShortcuts)
        .focusedSceneValue(\.commandContext, CommandContext(state: commandState) { command in
            // A sheet over the window has the keyboard; menus wait, as keys do.
            guard NSApp.mainWindow?.attachedSheet == nil else { return }
            _ = perform(command)
        })
        .onChange(of: mode) { old, _ in modeDidChange(from: old) }
        .onChange(of: library.selectedImageID) { followSelectionOnSecondDisplay() }
        .onChange(of: secondDisplay.isShowing) { followSelectionOnSecondDisplay(at: .zero) }
        // A move or rename closed the image the grid showed there.
        .onChange(of: fileOperations.isBusy) { _, busy in if !busy { followSelectionOnSecondDisplay(at: .zero) } }
        // What a VoiceOver user would otherwise have to go and look for.
        .onChange(of: currentProblem) { _, problem in
            if let problem { Announcement.post(problem, priority: .high) }
        }
        .onChange(of: exportQueue.isRunning) { wasRunning, running in
            guard wasRunning, !running else { return }
            let failed = exportQueue.failures.count
            Announcement.post(exportQueue.summary + (failed == 0 ? "" : ", \(failed) failed"))
        }
        .onChange(of: model.isExporting) { wasExporting, exporting in
            if wasExporting, !exporting { Announcement.post(model.status) }
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(count: library.selectedImageIDs.count,
                        sample: library.selectedImages.first ?? library.selectedImage,
                        records: library.selectedImages,
                        catalogName: library.folderURL?.lastPathComponent ?? "",
                        preview: ExportPreviewSource(library: library, gpu: model.gpu)) { preset, destination in
                guard let gpu = model.gpu else { return }
                // Flush the editor's pending edit so the export sees it.
                model.flushPendingSave()
                exportQueue.start(records: library.selectedImages, library: library,
                                  preset: preset, destination: destination, gpu: gpu)
            }
            .motionFollowsAccessibility()
        }
        .sheet(item: $hdrMergeSheet) { sheet in
            HDRMergeSheet(model: sheet, thumbnail: { await library.loadThumbnail(for: $0) },
                          onMerge: { startHDRMerge($0, options: $1, autoSettings: $2, from: sheet) },
                          canMerge: !exportQueue.isGPUBusy)
                .motionFollowsAccessibility()
        }
        .sheet(item: $panoramaMergeSheet) { sheet in
            PanoramaMergeSheet(model: sheet, thumbnail: { await library.loadThumbnail(for: $0) },
                               onMerge: { startPanoramaMerge($0, options: $1, from: sheet) },
                               canMerge: !exportQueue.isGPUBusy)
                .motionFollowsAccessibility()
        }
        .sheet(item: $hdrPanoramaMergeSheet) { sheet in
            HDRPanoramaMergeSheet(model: sheet, thumbnail: { await library.loadThumbnail(for: $0) },
                                  onMerge: { startHDRPanoramaMerge($0, options: $1, from: sheet) },
                                  canMerge: !exportQueue.isGPUBusy)
                .motionFollowsAccessibility()
        }
        .sheet(item: $renaming) { record in
            RenameSheet(record: record) { name in
                do {
                    try await library.fileOperations.rename(record, to: name)
                    return nil
                } catch {
                    return "\(error)"
                }
            }
            .motionFollowsAccessibility()
        }
        .onAppear {
            LensfunDatabase.warmUp()
            wireEditSaving()
            wireFileOperations()
            // Quitting flushes and waits for these (AppDelegate).
            AppDelegate.register(model: model, library: library, exportQueue: exportQueue)
            if let gpu = model.gpu {
                library.thumbnailRenderer = PipelineThumbnailRenderer(gpu: gpu)
            }
            // Once per launch: the window closed and opened again still has
            // its folder and image, and reopening them would close the image.
            guard !MainWindowModels.shared.openedAtLaunch else { return }
            MainWindowModels.shared.openedAtLaunch = true
            #if DEBUG
            if SnapshotHarness.start(model: model, library: library, perform: perform, exportSheet: $showingExportSheet) { return }
            #endif
            // Developer convenience: `swift run latent-app <folder-or-file>`
            // opens it straight away, skipping the dialogs. Defaults
            // overrides such as `-AppleLanguages (en)` are skipped.
            if let path = LaunchArguments.paths(from: Array(CommandLine.arguments.dropFirst())).first {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                if isDir.boolValue {
                    openFolder(URL(fileURLWithPath: path, isDirectory: true))
                } else {
                    model.open(url: URL(fileURLWithPath: path))
                    mode = .develop
                }
            } else if let last = BookmarkStore.resolve(key: BookmarkStore.lastFolder) {
                // Reopen where the user left off; the bookmark carries the
                // sandbox permission the open panel granted last time. A
                // folder that has gone says so rather than leaving an empty
                // window.
                openFolder(last)
            } else if let stored = BookmarkStore.storedPath(key: BookmarkStore.lastFolder) {
                // The bookmark didn't resolve: its disk isn't mounted (it is
                // never mounted for this), or the folder was deleted.
                let trouble: FolderAccess.Trouble = FolderAccess.isOnDisconnectedVolume(stored.path) ? .notConnected : .missing
                model.lastError = FolderAccess.message(for: trouble, folder: stored)
            }
        }
    }

    private var libraryPanel: some View {
        LibraryPanel(library: library, exportQueue: exportQueue, photoMerge: photoMerge, model: model,
                     onOpenFolder: showOpenFolderPanel,
                     onRate: rate, onFlag: flag,
                     onExport: { showingExportSheet = true },
                     presets: model.presets,
                     onApplyPreset: { applyPresetToSelection($0) },
                     onPaste: { pasteSettings() },
                     exportsOpenImage: mode != .survey)
    }

    // MARK: - Library wiring

    private func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of raw files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    /// Opens `url` as the catalog, from Open Folder, the sidebar or launch.
    /// Always starts: whether the folder can be read is found out off the
    /// main thread, and a refusal arrives a moment later, with the reason
    /// in the status bar and the sidebar's highlight moved back.
    @discardableResult
    private func openFolder(_ url: URL, restoring entry: FolderHistory.Entry? = nil) -> Bool {
        openingFolder = url
        // Through perform, so quitting waits for the catalog it is building.
        library.perform("Opening \(url.lastPathComponent)") {
            defer { if openingFolder == url { openingFolder = nil } }
            // A favourite whose disk wasn't there is resolved again first.
            let target = await FavouriteFolders.shared.retry(url) ?? url
            // Off the main thread, as everything in FolderAccess: on a share
            // that stopped answering, opening the directory waits for the
            // network to time out. Opening it, not asking whether it exists:
            // the sandbox lets the app see folders it won't let it read. And
            // an included subfolder belongs to the catalog above it; opening
            // it alone would give it a container and split that catalog.
            let (refusal, owner) = await Task.detached(priority: .userInitiated) {
                () -> (String?, FolderAccess.Membership?) in
                if let trouble = FolderAccess.problem(opening: target) {
                    return (FolderAccess.message(for: trouble, folder: target), nil)
                }
                return (nil, FolderAccess.owningCatalog(of: target))
            }.value
            if let refusal {
                model.lastError = refusal
                return
            }
            let folder = owner?.root ?? target
            if let owner {
                model.lastError = "“\(url.lastPathComponent)” is part of the catalog of “\(owner.root.lastPathComponent)” "
                    + "(an included subfolder), so that catalog is open."
                if let open = library.folderURL, FolderAccess.samePath(open, owner.root) { return }
            }
            closeEditorForFolderChange()
            // And again as the new list replaces the old, for an image of the
            // old folder opened while this one loaded.
            library.willReplaceCatalog = {
                FolderNavigator.shared.remember(library)
                closeEditorForFolderChange()
            }
            mode = .library
            await attachEditedThumbnailRenderer()
            do {
                // Overtaken by a folder clicked after this one, which saves
                // itself as the one to reopen.
                guard try await library.open(folder: folder, defaultSubfolderMode: prefs.defaultSubfolderMode) else {
                    return
                }
                // Back and Forward: a folder gone back to gets its selection
                // back; any other becomes the newest in the history.
                if let entry {
                    navigator.restoreSelection(entry, in: library)
                } else {
                    navigator.visit(folder)
                }
                BookmarkStore.save(folder, key: BookmarkStore.lastFolder)
                if let setAside = library.catalog?.damagedDatabaseSetAside {
                    // After this operation, so the alert doesn't hold it open.
                    DispatchQueue.main.async { reportRebuiltCatalog(folder, setAside: setAside) }
                }
            } catch {
                let trouble = FolderAccess.trouble(for: error, folder: folder)
                if case .other = trouble {
                    model.reportFailure("Opening \(folder.lastPathComponent)", error)
                } else {
                    model.lastError = FolderAccess.message(for: trouble, folder: folder)
                    Log.catalog.error("Opening a folder failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
        return true
    }

    /// Before another folder opens. The editor's image and catalog id
    /// belong to the catalog being left, and the same id in the next one is
    /// a different photo, so the pending edit is saved (into the catalog it
    /// belongs to; see `wireEditSaving`) and the image closed. Compare's
    /// Select pane holds a record of the old catalog too.
    private func closeEditorForFolderChange() {
        model.closeImage()
        compareModel = nil
        compareRecord = nil
        survey.closeAll()
    }

    // MARK: - Files

    private var fileCommands: LibraryFileCommands {
        LibraryFileCommands(library: library, canChangeFiles: { !fileOperations.isBusy && !exportQueue.isRunning })
    }

    /// Once: undoing a copy uses the Trash, and an image about to move or be
    /// renamed is saved and closed in the editor (its path is changing).
    /// Survey's panes never save and keep showing their images: an image
    /// that left the folder is deselected, and its pane goes with it.
    private func wireFileOperations() {
        library.fileOperations.recycle = { urls in
            _ = try await NSWorkspace.shared.recycle(urls)
        }
        library.fileOperations.willMoveImages = { ids in
            let editorImage = model.catalogImageID.map(ids.contains) ?? false
            let compareImage = compareRecord?.id.map(ids.contains) ?? false
            guard editorImage || compareImage else { return }
            model.closeImage()
            compareModel = nil
            compareRecord = nil
        }
    }

    /// F2: the rename sheet for the selected image.
    private func beginRename() {
        guard let record = library.selectedImage else { return }
        renaming = record
    }

    /// Back (-1) or Forward (+1). The history moves at once, so pressing
    /// twice goes two folders, and the folder opens as any other does.
    private func stepFolderHistory(_ offset: Int) {
        guard let entry = navigator.step(offset) else { return }
        if let open = library.folderURL, FolderAccess.samePath(open, entry.folder) {
            navigator.restoreSelection(entry, in: library)
            return
        }
        openFolder(entry.folder, restoring: entry)
    }

    /// Adds a folder to the sidebar's Favourites through the open panel,
    /// which is also what grants the sandbox access to it.
    private func chooseFavouriteFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to add to Favourites. Every folder inside them opens from the sidebar."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !FavouriteFolders.shared.add(url) {
            model.lastError = "“\(url.lastPathComponent)” couldn’t be added to Favourites."
        }
    }

    /// The database was unreadable and has been set aside (Catalog.open).
    /// Rare and worth a dialog: the user should know what was lost.
    private func reportRebuiltCatalog(_ folder: URL, setAside: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "The catalog of “\(folder.lastPathComponent)” was damaged and has been rebuilt"
        alert.informativeText = "Ratings, keywords and edits were read back from the sidecar files. "
            + "Choices about subfolders were kept only in the damaged catalog, so Latent will ask about "
            + "subfolders again. The damaged file is kept as \(setAside.lastPathComponent) in the folder’s "
            + "\(Catalog.containerName) folder."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([setAside])
        }
    }

    /// Edited thumbnails render through the pipeline, so they need the
    /// GPU, which starts in the background as the app launches. Waiting for
    /// it here, which only ever happens at launch and for no longer than
    /// the GPU takes to start, keeps the folder reopened at launch from
    /// getting unedited thumbnails for its edited images.
    private func attachEditedThumbnailRenderer() async {
        guard library.thumbnailRenderer == nil, let gpu = try? await GPUContext.shared() else { return }
        library.thumbnailRenderer = PipelineThumbnailRenderer(gpu: gpu)
    }

    private func openInEditor(_ record: ImageRecord) {
        load(record)
        mode = .develop
    }

    /// The grid's right-click menu, acting as the same keys and buttons do.
    private var gridActions: GridActions {
        GridActions(
            openLoupe: { if library.selectedImage != nil { mode = .loupe } },
            openDevelop: { if let selected = library.selectedImage { openInEditor(selected) } },
            openCompare: { if library.selectedImage != nil { mode = .compare } },
            openSurvey: { _ = perform(.survey) },
            rate: rate, flag: flag, rotate: { rotate(by: $0) },
            copySettings: copySettings, pasteSettings: pasteSettings,
            canPasteSettings: { EditorModel.clipboardStack() != nil },
            presets: { model.presets }, applyPreset: applyPresetToSelection,
            export: { showingExportSheet = true },
            canExport: { !exportQueue.isRunning },
            rename: beginRename,
            canChangeFiles: { !fileOperations.isBusy && !exportQueue.isRunning && !OutputJobs.shared.isRunning },
            transfer: { fileCommands.transferSelection($0, to: $1) },
            recentDestinations: { RecentDestinations.shared.availableFolders })
    }

    /// Loads `record` (with its stored edit, history and snapshots) into
    /// the main editor model and makes it the selection. Used by Develop,
    /// Loupe and Compare's candidate pane alike.
    private func load(_ record: ImageRecord) {
        guard let url = library.fileURL(for: record) else { return }
        let catalog = library.catalog
        library.selectedImageID = record.id
        Task {
            let stack: String?
            do {
                stack = try await library.editStack(for: record)
            } catch {
                // Don't open at defaults over an edit we couldn't read: the
                // next save would replace it. Say so and stop.
                model.reportFailure("Reading the edit for \(record.fileName)", error)
                return
            }
            // Another folder may have opened meanwhile. The record and its
            // id belong to the old catalog; opened now, its edits would be
            // saved onto whatever photo has that id in the new one.
            guard library.catalog === catalog else { return }
            model.open(url: url, userRotation: record.userRotation,
                       catalogImageID: record.id, editStackJSON: stack)
            // History and snapshots follow, from the catalog.
            do {
                let steps = try await library.history(for: record)
                let snaps = try await library.snapshots(for: record)
                if model.catalogImageID == record.id, library.catalog === catalog {
                    model.loadHistory(steps: steps, snapshots: snaps)
                }
            } catch {
                model.reportFailure("Reading history for \(record.fileName)", error)
            }
        }
    }

    /// Loads a record into Compare's left pane. No catalog id is passed,
    /// so that model never writes edits; it's a viewer.
    private func loadCompareSelect(_ record: ImageRecord) {
        guard let url = library.fileURL(for: record) else { return }
        if compareModel == nil {
            compareModel = EditorModel()
            updateCompareLink()
        }
        compareRecord = record
        let catalog = library.catalog
        Task {
            do {
                let stack = try await library.editStack(for: record)
                guard library.catalog === catalog else { return }
                compareModel?.open(url: url, userRotation: record.userRotation,
                                   catalogImageID: nil, editStackJSON: stack)
            } catch {
                model.reportFailure("Reading the edit for \(record.fileName)", error)
            }
        }
    }

    /// Entering Loupe or Compare from the grid renders the selection;
    /// leaving Develop flushes edits. Compare's Select pane starts as the
    /// other selected image if there is one, else the same image, and
    /// arrow keys then walk the Candidate.
    private func modeDidChange(from old: AppMode) {
        defer { secondDisplay.follow(viewedModel) }
        updateCompareLink()
        if fullScreen.isActive, !FullScreenImagePolicy.keepsFullScreen(in: mode) { fullScreen.leave() }
        if old == .develop {
            model.flushPendingSave()
            // Loupe and Compare share the viewport; a click there must
            // never place a patch or move a crop.
            model.disarmTools()
        }
        guard surveyModeDidChange(from: old) else { return }
        guard mode != .library, let selected = library.selectedImage else { return }
        if model.catalogImageID != selected.id { load(selected) }
        if mode == .compare {
            let other = library.selectedImages.first { $0.id != selected.id }
            loadCompareSelect(other ?? compareRecord ?? selected)
        }
    }

    /// Links the two panes' views while Compare shows and Sync is on, and
    /// tells the Select pane whether it's on screen. Leaving Compare on a
    /// Mac with little memory closes its image straight away, since
    /// Compare reloads it on the way back in; elsewhere it waits for the
    /// system to ask for memory.
    private func updateCompareLink() {
        let showing = mode == .compare
        let linked = showing && compareSyncsView
        model.linkedPane = linked ? compareModel : nil
        compareModel?.linkedPane = linked ? model : nil
        compareModel?.isOffScreen = !showing
        if !showing, !MemoryPolicy.current.keepsIdleImages { compareModel?.closeImage() }
    }

    /// Turning Sync on lines the Select pane up with the candidate.
    private var compareSyncBinding: Binding<Bool> {
        Binding(get: { compareSyncsView }, set: { syncs in
            compareSyncsView = syncs
            updateCompareLink()
            if syncs { compareModel?.takeLinkedView(model.relativeView) }
        })
    }

    /// Promote the candidate to the Select side, or swap the two.
    private func compareMakeSelect() {
        guard let candidate = library.selectedImage else { return }
        loadCompareSelect(candidate)
    }

    private func compareSwap() {
        guard let candidate = library.selectedImage, let select = compareRecord else { return }
        loadCompareSelect(candidate)
        load(select)
    }

    private var compareArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                VStack(spacing: 0) {
                    if let compareModel {
                        ImageViewport(model: compareModel, mirror: model, allowsTools: false)
                    } else {
                        prefs.surroundColor
                    }
                    Divider()
                    ImageCaption(record: compareRecord, title: "Select")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Select pane")
                VStack(spacing: 0) {
                    ImageViewport(model: model, mirror: compareModel, allowsTools: false)
                    Divider()
                    ImageCaption(record: library.selectedImage, title: "Candidate")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Candidate pane")
            }
            Divider()
            HStack(spacing: 10) {
                Button("Make Select") { compareMakeSelect() }
                    .help("Promote the candidate to the left pane (⇧X)")
                Button("Swap") { compareSwap() }
                    .help("Exchange the two panes")
                Toggle("Sync", isOn: compareSyncBinding)
                    .toggleStyle(.checkbox)
                    .help("Zoom and pan both panes together, matched by position in each picture")
                    .accessibilityLabel("Sync zoom and pan")
                Text("← → step the candidate · rating and flag keys act on it")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Left and right arrow keys step the candidate; rating and flag keys act on it")
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }

    // MARK: - Survey

    /// Entering or leaving Survey; false when there is nothing more for
    /// `modeDidChange` to do. Survey needs two to four selected images, and
    /// asked for with any other number the mode goes back (though nothing
    /// asks: the mode picker refuses as the command does). The editor's
    /// model loads nothing for Survey, and on a Mac with little memory its
    /// catalog image closes while Survey shows: Loupe, Compare and Develop
    /// load it again.
    private func surveyModeDidChange(from old: AppMode) -> Bool {
        if old == .survey { survey.end() }
        guard mode == .survey else { return true }
        guard survey.begin(library: library, onFailure: model.reportFailure) else {
            NSSound.beep()
            mode = old
            return false
        }
        if !MemoryPolicy.current.keepsIdleImages, model.catalogImageID != nil { model.closeImage() }
        return false
    }

    /// ← and → in Survey.
    private func surveyMoveFocus(by offset: Int) {
        guard survey.moveFocus(by: offset) else { return }
        survey.writeSelection(to: library)
        survey.announceFocus(in: library)
    }

    /// ✕ or / : the pane goes and its image is deselected. With one image
    /// left, Survey becomes Loupe on it.
    private func surveyRemove(_ id: Int64) {
        guard survey.remove(id) else { return }
        survey.writeSelection(to: library)
        surveyLeaveIfIncomplete()
    }

    /// A filter hiding a rated image deselects it, and so on: panes follow.
    private func surveyFollowSelection() {
        guard mode == .survey,
              survey.follow(selected: library.selectedImageIDs, primary: library.selectedImageID) else { return }
        survey.writeSelection(to: library)
        surveyLeaveIfIncomplete()
    }

    private func surveyLeaveIfIncomplete() {
        guard let panes = survey.panes, !panes.isComplete else { return }
        mode = panes.ids.isEmpty ? .library : .loupe
    }

    /// Edits settle in the editor and land in the catalog here; so do
    /// history steps and snapshots.
    ///
    /// Each write names the catalog open when the editor handed it over,
    /// which is the catalog the id belongs to (the editor closes its image
    /// before another folder opens). The write itself runs later, and by
    /// then another folder may be open, where that id is another photo.
    private func wireEditSaving() {
        model.onEditSettled = { imageID, json in
            guard let catalog = library.catalog else { return }
            library.perform("Saving the edit") {
                try await library.saveEditStack(json, schemaVersion: EditStack.schemaVersion,
                                                 processVersion: EditStack.processVersion,
                                                 forImageID: imageID, in: catalog)
            }
        }
        model.onHistoryChanged = { imageID, steps in
            guard let catalog = library.catalog else { return }
            library.perform("Saving history") { try await library.setHistory(steps, forImageID: imageID, in: catalog) }
        }
        library.didRestoreImages = { ids, aspect in editorFollowUndo(ids, aspect) }
        model.onSnapshotsChanged = { imageID, snapshots in
            guard let catalog = library.catalog else { return }
            library.perform("Saving snapshots") {
                try await library.setSnapshots(snapshots, forImageID: imageID, in: catalog)
            }
        }
    }

    /// An undo or redo in the Library put back the rotation or stored edit
    /// of images the editor may hold. A rotation turns the image on screen,
    /// as rotating does; an edit is read again where the image shows, and
    /// where it is hidden (the grid, Survey) the image is closed, to be read
    /// again when shown, as the second display's Loupe does at once. Never
    /// by `load` in Survey, which would make a hidden image the primary
    /// selection. Survey's panes and Compare's Select pane catch up too.
    private func editorFollowUndo(_ ids: Set<Int64>, _ aspect: Library.RestoredAspect) {
        survey.followRestore(ids, aspect, library: library, onFailure: model.reportFailure)
        compareSelectFollowUndo(ids, aspect)
        guard let id = model.catalogImageID, ids.contains(id),
              let record = library.images.first(where: { $0.id == id }) else { return }
        switch aspect {
        case .rotation:
            model.setUserRotation(record.userRotation)
        case .edits where mode.showsEditorImage:
            load(record)
        case .edits:
            model.closeImage()
            followSelectionOnSecondDisplay(at: .zero)
        }
    }

    /// Compare's Select pane never saves, so an undo that put back its
    /// image's rotation or edit is shown on it here. Only while Compare
    /// shows: entering Compare opens that pane again.
    private func compareSelectFollowUndo(_ ids: Set<Int64>, _ aspect: Library.RestoredAspect) {
        guard mode == .compare, let pane = compareModel, let id = compareRecord?.id, ids.contains(id),
              let record = library.images.first(where: { $0.id == id }) else { return }
        compareRecord = record
        guard aspect == .edits else { pane.setUserRotation(record.userRotation); return }
        let catalog = library.catalog
        Task {
            do {
                let stack = try await library.editStack(for: record)
                guard library.catalog === catalog, compareModel === pane, compareRecord?.id == id else { return }
                pane.showStoredEdit(stack, userRotation: record.userRotation)
            } catch {
                model.reportFailure("Reading the edit for \(record.fileName)", error)
            }
        }
    }

    // MARK: - Photo Merge

    /// Opens the HDR Merge dialog on the whole selection, which the engine
    /// starts measuring at once.
    private func beginHDRMerge() {
        guard let gpu = model.gpu else { return }
        let records = library.selectedImages
        let urls = records.compactMap { library.fileURL(for: $0) }
        guard records.count >= 2, urls.count == records.count else { return }
        let catalog = library.catalog
        let sheet = HDRMergeSheetModel(records: records, urls: urls,
                                       engine: PhotoMergeEngine.hdr(gpu: gpu, forDialog: true)) { reference in
            // The name as it would be now; the job plans it again on Merge.
            guard let catalog,
                  let relPath = try? await catalog.planMergeResult(forReference: reference.relPath, suffix: "HDR")
            else { return nil }
            return (relPath as NSString).lastPathComponent
        }
        hdrMergeSheet = sheet
        sheet.start()
    }

    /// Merge in the dialog: the job runs in the background from here, with
    /// the same engine that measured the photos and the dialog's options.
    private func startHDRMerge(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, autoSettings: Bool,
                               from sheet: HDRMergeSheetModel) {
        let records = sheet.recordsInFrameOrder.compactMap { $0 }
        guard records.count == analysis.frames.count,
              photoMerge.start(analysis, options: options, records: records, library: library,
                               engine: sheet.engine, autoSettings: autoSettings ? hdrAutoSettings() : nil) else {
            library.lastError = "HDR merge couldn’t start: an export or another merge is using the graphics processor, "
                + "or the photos are no longer in the open folder."
            return
        }
    }

    /// HDR Merge Without Dialog: the whole selection, measured and merged in
    /// the background with the options the dialog was last left with.
    private func mergeHDRWithoutDialog() {
        guard let gpu = model.gpu else { return }
        let records = library.selectedImages
        let urls = records.compactMap { library.fileURL(for: $0) }
        guard records.count >= 2, urls.count == records.count else { return }
        let preferences = HDRMergePreferences()
        guard photoMerge.startWithoutDialog(records: records, urls: urls, options: preferences.options,
                                            library: library, engine: PhotoMergeEngine.hdr(gpu: gpu),
                                            autoSettings: preferences.autoSettings ? hdrAutoSettings() : nil) else {
            library.lastError = "HDR merge couldn’t start: an export or another merge is using the graphics processor."
            return
        }
    }

    /// Opens the Panorama dialog on the whole selection, which the engine
    /// starts measuring at once.
    private func beginPanoramaMerge() {
        guard let gpu = model.gpu else { return }
        let records = library.selectedImages
        let urls = records.compactMap { library.fileURL(for: $0) }
        guard records.count >= 2, urls.count == records.count else { return }
        let catalog = library.catalog
        let sheet = PanoramaMergeSheetModel(records: records, urls: urls,
                                            engine: PhotoMergeEngine.panorama(gpu: gpu)) { reference in
            // The name as it would be now; the job plans it again on Merge.
            guard let catalog,
                  let relPath = try? await catalog.planMergeResult(forReference: reference.relPath,
                                                                   suffix: PhotoMergeKind.panorama.suffix)
            else { return nil }
            return (relPath as NSString).lastPathComponent
        }
        panoramaMergeSheet = sheet
        sheet.start()
    }

    /// Merge in the Panorama dialog: the job stitches in the background
    /// from here, with the same engine that measured the photos.
    private func startPanoramaMerge(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                                    from sheet: PanoramaMergeSheetModel) {
        let records = sheet.recordsInFrameOrder.compactMap { $0 }
        guard records.count == analysis.frames.count,
              photoMerge.startPanorama(analysis, options: options, records: records, library: library,
                                       engine: sheet.engine,
                                       firstEdit: panoramaFirstEdit(analysis, options: options)) else {
            library.lastError = "The panorama couldn’t start: an export or another merge is using the graphics "
                + "processor, or the photos are no longer in the open folder."
            return
        }
    }

    /// Opens the HDR Panorama dialog (experimental) on the whole selection,
    /// which the engine starts sorting into positions at once.
    private func beginHDRPanoramaMerge() {
        guard let gpu = model.gpu else { return }
        let records = library.selectedImages
        let urls = records.compactMap { library.fileURL(for: $0) }
        guard records.count >= 2, urls.count == records.count else { return }
        let catalog = library.catalog
        let sheet = HDRPanoramaMergeSheetModel(records: records, urls: urls,
                                               engine: PhotoMergeEngine.hdrPanorama(gpu: gpu)) { reference in
            // The name as it would be now; the job plans it again on Merge.
            guard let catalog,
                  let relPath = try? await catalog.planMergeResult(forReference: reference.relPath,
                                                                   suffix: PhotoMergeKind.hdrPanorama.suffix)
            else { return nil }
            return (relPath as NSString).lastPathComponent
        }
        hdrPanoramaMergeSheet = sheet
        sheet.start()
    }

    /// Merge in the HDR Panorama dialog: the job merges each bracket and
    /// stitches the results in the background from here.
    private func startHDRPanoramaMerge(_ analysis: HDRPanoramaAnalysis, options: HDRPanoramaOptions,
                                       from sheet: HDRPanoramaMergeSheetModel) {
        let records = sheet.recordsInPhotoOrder.compactMap { $0 }
        guard records.count == analysis.photos.count,
              photoMerge.startHDRPanorama(analysis, options: options, records: records, library: library,
                                          engine: sheet.engine,
                                          firstEdit: panoramaFirstEdit(analysis.panorama,
                                                                       options: options.panorama)) else {
            library.lastError = "The HDR panorama couldn’t start: an export or another merge is using the graphics "
                + "processor, or the photos are no longer in the open folder."
            return
        }
    }

    /// The panorama's first edit: Auto Crop's rectangle and Auto Settings'
    /// adjustments together, worked out away from the main thread.
    private func panoramaFirstEdit(_ analysis: PanoramaMergeAnalysis,
                                   options: PanoramaMergeOptions) -> PhotoMergeQueue.FirstEdit? {
        guard let gpu = model.gpu else { return nil }
        let crop = options.autoCrop ? PanoramaResultEdit.crop(for: analysis) : nil
        let autoAdjust = options.autoSettings
        guard crop != nil || autoAdjust else { return nil }
        return { url in
            try await Task.detached(priority: .userInitiated) {
                try PanoramaResultEdit.editStackJSON(forPhotoAt: url, crop: crop, autoAdjust: autoAdjust, gpu: gpu)
            }.value
        }
    }

    /// Auto Settings' edit for a merged photo: Develop's Auto Adjust, worked
    /// out away from the main thread.
    private func hdrAutoSettings() -> PhotoMergeQueue.FirstEdit? {
        guard let gpu = model.gpu else { return nil }
        return { url in
            try await Task.detached(priority: .userInitiated) {
                try HDRAutoSettings.edit(forPhotoAt: url, gpu: gpu).editStackJSON
            }.value
        }
    }

    // MARK: - Metadata shortcuts (both modes)

    /// In the grid these act on the whole selection. Loupe, Compare and
    /// Develop show one image, so they act on that image only, even when
    /// the grid selection behind it holds more.
    private func rate(_ stars: Int) {
        library.perform("Rating") { try await library.setRating(stars, onlyPrimary: mode != .library) }
    }

    private func flag(_ flag: ImageFlag) {
        library.perform("Flagging") { try await library.setFlag(flag, onlyPrimary: mode != .library) }
    }

    /// Rotates the selected image in the catalog and, if it's the one in
    /// the editor, on screen too.
    private func rotate(by quarterTurns: Int) {
        library.perform("Rotating") {
            try await library.rotateSelected(by: quarterTurns, onlyPrimary: mode != .library)
            if let selected = library.selectedImage,
               model.imageTitle == selected.fileName {
                model.setUserRotation(selected.userRotation)
            }
            if let selected = library.selectedImage {
                survey.model(for: selected.id)?.setUserRotation(selected.userRotation)
            }
        }
    }

    /// Left/right arrows step through the catalog; in Develop that also
    /// loads the image, so you can flick through a shoot without going
    /// back to the grid. Return opens the selection. Single keys go through
    /// BareKeyMonitor, which stands aside while a text field has the
    /// keyboard; Command shortcuts are the menu bar's (LatentCommands).
    private var navigationShortcuts: some View {
        Group {
            BareKeyMonitor(perform: { perform($0.panningImage(commandState.arrowKeysPan)) },
                           onTextFocusChange: { editingText = $0 })
            Color.clear.onAppear { libraryUndo.attach(to: library) }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    /// Runs a command from a key or the menu bar. Returns false when the
    /// key has nothing to do here, so it carries on to whatever else wants it.
    private func perform(_ command: KeyCommand) -> Bool {
        // The menus grey out what this refuses, by the same rules.
        guard commandState.isEnabled(command) else {
            return !CommandState.passesThroughWhenUnavailable(command)
        }
        switch command {
        case .step(let offset):
            if mode == .survey { surveyMoveFocus(by: offset) } else { step(offset) }
        case .openSelection:
            if let selected = library.selectedImage { openInEditor(selected) }
        case .library:
            mode = .library
        case .develop:
            if model.hasImage || library.selectedImage != nil { mode = .develop }
        // Culling views: E for loupe, C for compare, space toggles
        // grid ↔ loupe, Z toggles fit ↔ 100% (Lightroom's keys).
        case .loupe:
            if library.selectedImage != nil { mode = .loupe }
        case .compare:
            if library.selectedImage != nil { mode = .compare }
        case .survey:
            mode = .survey
        case .removeFromSurvey:
            if let focused = survey.panes?.focusedID { surveyRemove(focused) }
        case .toggleLoupe:
            if mode == .library, library.selectedImage != nil { mode = .loupe }
            else if mode == .loupe { mode = .library }
        case .toggleZoom:
            guard mode.showsImage else { break }
            if mode == .survey { survey.focusedModel?.toggleZoomAtCenter(); break }
            model.toggleZoomAtCenter()
            if mode == .compare { compareModel?.toggleZoomAtCenter() }
        // Ratings 0-5 and flags P/X/U, the same keys Lightroom uses.
        case .rate(let stars):
            rate(stars)
        case .pick:
            flag(.picked)
        case .reject:
            flag(.rejected)
        case .unflag:
            flag(.none)
        case .beforeAfter:
            if model.hasImage { model.showingBefore.toggle() }
        case .crop:
            guard mode == .develop, model.hasImage else { break }
            model.cropToolActive.toggle()
            if model.cropToolActive { cropExpanded = true }
        case .heal:
            guard mode == .develop, model.hasImage else { break }
            model.healToolActive.toggle()
            if model.healToolActive { healExpanded = true }
        case .redEye:
            guard mode == .develop, model.hasImage else { break }
            model.redEyeToolActive.toggle()
            if model.redEyeToolActive { healExpanded = true }
        case .deleteHeal:
            if model.redEyeToolActive { model.deleteSelectedRedEye(); break }
            guard model.healToolActive else { return false }
            model.deleteSelectedHeal()
        case .disarmTools:
            // Esc leaves the tool first, then the full-screen image.
            if fullScreen.isActive, !model.imageToolActive, !model.cropToolActive {
                fullScreen.leave()
            } else {
                model.disarmTools()
            }
        case .makeSelect:
            guard mode == .compare else { return false }
            compareMakeSelect()
        case .openFolder:
            showOpenFolderPanel()
        case .openFile:
            model.showOpenPanel(); mode = .develop
        case .export:
            showingExportSheet = true
        case .exportOpenImage:
            LibraryPanel.exportOpenImage(model: model, library: library)
        case .print:
            // Survey prints its panes, the selection, as the grid does.
            PrintPresenter.present(openImage: mode.showsEditorImage && model.hasImage, model: model, library: library)
        case .contactSheet:
            ContactSheetPresenter.present(model: model, library: library)
        case .photoMergeHDR:
            beginHDRMerge()
        case .photoMergeHDRWithoutDialog:
            mergeHDRWithoutDialog()
        case .photoMergePanorama:
            beginPanoramaMerge()
        case .photoMergeHDRPanorama:
            beginHDRPanoramaMerge()
        case .slideshow:
            SlideshowController.start(model: model, library: library)
        case .editExternally:
            // Survey's focused pane is the lead selected image.
            ExternalEditorHandOff.shared.start(model: model, library: library, preferOpenImage: mode.showsEditorImage)
        // Develop undoes edits in its own history; the other modes undo
        // library actions. The editor saves first, so an undo restoring the
        // open image's edit isn't overwritten by an edit still waiting.
        case .undo where mode == .develop:
            model.undo()
        case .redo where mode == .develop:
            model.redo()
        case .undo:
            model.flushPendingSave(); library.undoManager?.undo()
        case .redo:
            model.flushPendingSave(); library.undoManager?.redo()
        case .copySettings:
            copySettings()
        case .pasteSettings:
            pasteSettings()
        case .rotate(let quarterTurns):
            rotate(by: quarterTurns)
        case .zoomIn where mode == .library, .zoomOut where mode == .library:
            prefs.thumbnailSize = ThumbnailGridLayout.stepped(prefs.thumbnailSize, larger: command == .zoomIn)
        case .zoomIn:
            viewedModel.zoomIn(); mirrorModel?.zoomIn()
        case .zoomOut:
            viewedModel.zoomOut(); mirrorModel?.zoomOut()
        case .revealInFinder:
            GridContextMenu.revealInFinder(library)
        case .zoomToFit:
            viewedModel.zoomToFit(); mirrorModel?.zoomToFit()
        case .zoomToActualSize:
            viewedModel.zoomToActualSize(); mirrorModel?.zoomToActualSize()
        case .autoAdjust:
            model.autoAdjust()
        case .clearFilter:
            library.filter = LibraryFilter()
        case .swapCompare:
            compareSwap()
        case .addMask(let shape):
            switch shape {
            case .linear: model.addLocal(.linear)
            case .radial: model.addLocal(.radial)
            case .brush: model.addLocal(.brush)
            }
        case .toggleMaskOverlay:
            model.showMaskOverlay.toggle()
        case .toolSize(let steps):
            model.stepToolSize(by: steps)
        case .rename:
            beginRename()
        case .moveToFolder:
            fileCommands.transferSelection(.move, to: nil)
        case .copyToFolder:
            fileCommands.transferSelection(.copy, to: nil)
        case .back:
            stepFolderHistory(-1)
        case .forward:
            stepFolderHistory(1)
        case .fullScreenImage:
            if fullScreen.isActive {
                fullScreen.leave()
            } else {
                mode = FullScreenImagePolicy.entryMode(from: mode)
                fullScreen.enter(window: NSApp.keyWindow ?? NSApp.mainWindow)
            }
        case .secondaryDisplay:
            if secondDisplay.isShowing {
                secondDisplay.close()
            } else {
                secondDisplay.show(model: viewedModel, library: library, beside: NSApp.keyWindow ?? NSApp.mainWindow)
            }
        case .panImage(let direction):
            model.panImage(direction)
        }
        return true
    }

    /// The second display's Loupe shows the selection. Loupe, Compare and
    /// Develop load it anyway; the grid doesn't, so while the Loupe shows,
    /// a selection that settles for a moment is loaded for it. Survey's
    /// selection is its focused pane, which the Loupe draws instead.
    private func followSelectionOnSecondDisplay(at delay: Duration = .milliseconds(150)) {
        secondDisplay.follow(viewedModel)
        secondDisplayLoad?.cancel()
        guard secondDisplay.isShowing, mode == .library, let selected = library.selectedImage,
              model.catalogImageID != selected.id else { return }
        secondDisplayLoad = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, secondDisplay.isShowing, mode == .library,
                  library.selectedImageID == selected.id, model.catalogImageID != selected.id else { return }
            load(selected)
        }
    }

    /// What the menu bar shows and `perform` allows, from the models.
    private var commandState: CommandState {
        var state = CommandState()
        let selected = library.selectedImage
        state.mode = mode
        state.hasVisibleImages = !library.visibleImages.isEmpty
        state.hasSelection = selected != nil
        state.selectionCount = library.selectedImageIDs.count
        state.primaryFlag = selected.flatMap { ImageFlag(rawValue: $0.flag) } ?? .none
        state.hasImage = model.hasImage
        state.editorReady = model.isReady
        state.exportingOpenImage = model.isExporting
        state.exportQueueRunning = exportQueue.isRunning
        state.photoMergeRunning = exportQueue.slotHeldByOtherJob || photoMerge.isRunning
        state.outputJobRunning = OutputJobs.shared.isRunning
        let history = model.history
        state.undoLabel = history.canUndo ? history.steps[history.cursor].label : nil
        state.redoLabel = history.canRedo ? history.steps[history.cursor + 1].label : nil
        if mode != .develop {
            (state.undoLabel, state.redoLabel) = (libraryUndo.labels.undo, libraryUndo.labels.redo)
            (state.undoChangesFiles, state.redoChangesFiles) = (libraryUndo.labels.undoChangesFiles, libraryUndo.labels.redoChangesFiles)
        }
        state.isEditingText = editingText
        state.arrowKeysPanImage = prefs.arrowKeysPanImage
        state.imageZoomedIn = model.hasImage && !model.fitMode
        state.showingBefore = model.showingBefore
        state.cropToolActive = model.cropToolActive
        state.healToolActive = model.healToolActive
        state.hasSelectedHeal = model.selectedHeal != nil
        state.redEyeToolActive = model.redEyeToolActive
        state.hasSelectedRedEye = model.selectedRedEye != nil
        state.toolSizeAdjustable = model.toolSizeAdjustable
        state.canAddMask = model.hasImage && model.parameters.locals.count < LocalAdjustment.maximumCount
        state.hasSelectedMask = model.selectedLocal != nil
        state.showMaskOverlay = model.showMaskOverlay
        state.filterActive = library.filter.isActive
        state.hasCompareSelect = compareRecord != nil
        state.canGoBack = navigator.history.canGoBack
        state.canGoForward = navigator.history.canGoForward
        state.fileOperationRunning = fileOperations.isBusy
        state.surveyHasImage = survey.focusedModel?.hasImage ?? false
        state.fullScreenImage = fullScreen.isActive
        state.hasSecondDisplay = secondDisplay.hasSecondScreen
        state.secondaryDisplayShowing = secondDisplay.isShowing
        return state
    }

    // MARK: - Settings clipboard and presets, in either mode

    private func copySettings() {
        // In the grid the editor may still hold an image other than the one
        // selected; that one's stored edit is what gets copied then.
        if mode == .develop || (library.selectedImageIDs.count <= 1 && model.catalogImageID == library.selectedImageID),
           model.hasImage {
            model.copySettings()
        } else if let first = library.selectedImage {
            // In the grid with nothing open: copy the primary selection's stored edit.
            Task {
                do {
                    guard let json = try await library.editStack(for: first) else {
                        model.reportError("\(first.fileName) has no edits to copy"); return
                    }
                    let stack = try EditStack.decode(json: json)
                    let text = try stack.restricted(to: model.pasteGroups).encodeJSON()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: EditorModel.pasteboardType)
                    NSPasteboard.general.setString(text, forType: .string)
                    model.reportError("Copied settings from \(first.fileName)")
                } catch {
                    model.reportFailure("Copying settings from \(first.fileName)", error)
                }
            }
        }
    }

    private func pasteSettings() {
        guard let stack = EditorModel.clipboardStack() else { model.reportError("Nothing to paste"); return }
        applyToSelectionOrEditor(stack, groups: model.pasteGroups, what: "Pasted", undoName: "Paste Settings")
    }

    /// Where pasted settings and a preset go. The grid changes the stored
    /// edit of every selected image. Loupe, Compare, Survey and Develop show
    /// one image (in Survey, the focused pane) and change that one only, as
    /// rating does. Develop changes it through the editor, whose history
    /// Undo goes back through there; the other modes change its stored
    /// edit, filing the Library undo their Undo takes back (the editor,
    /// when it holds the image, then shows the change). Compare's Select
    /// image and Survey's panes are never written.
    enum SettingsTarget: Equatable {
        case editor, primary, selection

        static func choose(mode: AppMode, editorHasImage: Bool) -> SettingsTarget {
            guard mode != .library else { return .selection }
            // Develop may hold a file opened on its own, outside the catalog.
            return mode == .develop && editorHasImage ? .editor : .primary
        }
    }

    private func applyToSelectionOrEditor(_ stack: EditStack, groups: Set<EditGroup>, what: String, undoName: String) {
        let target = SettingsTarget.choose(mode: mode, editorHasImage: model.hasImage)
        // Compare's Select pane may show the candidate's own photo. It never
        // saves, so it takes the new look directly rather than going stale.
        if target != .selection, mode == .compare, let select = compareRecord?.id, select == library.selectedImageID {
            compareModel?.apply(stack, groups: groups)
        }
        // So may a Survey pane, the focused one.
        if target != .selection, mode == .survey { survey.model(for: library.selectedImageID)?.apply(stack, groups: groups) }
        if target == .editor {
            model.apply(stack, groups: groups)
            return
        }
        // Through perform, so quitting waits for the edits being rewritten.
        library.perform(what) {
            let outcome: Library.TransformOutcome
            do {
                outcome = try await library.transformSelectedEdits(
                    onlyPrimary: target == .primary,
                    schemaVersion: EditStack.schemaVersion, processVersion: EditStack.processVersion,
                    undoName: undoName
                ) { existing in
                    // An unreadable existing edit throws here and the image
                    // is skipped, never replaced by the pasted modules alone.
                    let current = try existing.map { try EditStack.decode(json: $0) } ?? EditStack()
                    let merged = current.merged(with: stack, groups: groups)
                    return merged == EditStack() ? nil : try merged.encodeJSON()
                }
            } catch {
                model.reportFailure("\(what) settings", error)
                return
            }
            let n = outcome.changed
            var message = "\(what) settings to \(n) image\(n == 1 ? "" : "s")"
            if !outcome.skipped.isEmpty {
                message += " · skipped \(outcome.skipped.count) with unreadable edits: " + outcome.skipped.joined(separator: ", ")
            }
            model.reportError(message)
            // If the open image was among them, reload its sliders.
            if let selected = library.selectedImage, model.imageTitle == selected.fileName,
               target == .primary || library.selectedImageIDs.contains(selected.id ?? -1) {
                model.apply(stack, groups: groups)
            }
        }
    }

    private func applyPresetToSelection(_ preset: Preset) {
        applyToSelectionOrEditor(preset.stack, groups: preset.groups, what: "Applied “\(preset.name)” —",
                                 undoName: "Apply Preset")
    }

    private func step(_ offset: Int) {
        guard let record = library.moveSelection(by: offset) else { return }
        if mode.showsImage { load(record) }
    }

    /// A click in the filmstrip: that image becomes the selection, as an
    /// arrow key would make it, and opens in the current mode.
    private func openFromFilmstrip(_ record: ImageRecord) {
        guard let id = record.id else { return }
        library.setSelection([id], primary: id)
        if model.catalogImageID != id { load(record) }
    }

    private var imageArea: some View {
        ZStack {
            ImageViewport(model: model, onStep: { _ = perform(.step($0)) })
            if model.isExporting {
                Color.black.opacity(0.4)
                ProgressView("Exporting…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var adjustmentPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScopePanel(model: model)

                if let title = model.imageTitle {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                DisclosureGroup(isExpanded: $whiteBalanceExpanded) {
                    whiteBalanceSection.padding(.top, 8)
                } label: {
                    disclosureLabel("White Balance")
                }

                DisclosureGroup(isExpanded: $toneExpanded) {
                    toneSection.padding(.top, 8)
                } label: {
                    disclosureLabel("Tone")
                }

                DisclosureGroup(isExpanded: $presenceExpanded) {
                    presenceSection.padding(.top, 8)
                } label: {
                    disclosureLabel("Presence")
                }

                DisclosureGroup(isExpanded: $cropExpanded) {
                    cropSection.padding(.top, 8)
                } label: {
                    HStack {
                        disclosureLabel("Crop & Straighten")
                        if model.cropToolActive { activeToolBadge }
                    }
                }

                DisclosureGroup(isExpanded: $healExpanded) {
                    healSection.padding(.top, 8)
                } label: {
                    HStack {
                        disclosureLabel("Spot Removal")
                        if model.healToolActive || model.redEyeToolActive { activeToolBadge }
                    }
                }

                EmptyView()
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        sliderRow(title: "Recovery",
                                   value: $model.parameters.highlightRecovery,
                                   range: 0...1, format: "%.2f", defaultValue: 1.0)
                        sliderRow(title: "Threshold",
                                   value: $model.parameters.highlightThreshold,
                                   range: 0.5...1.0, format: "%.2f", defaultValue: 0.85)
                    }
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Highlight Reconstruction")
                }

                DisclosureGroup {
                    PresetsPanel(model: model, onApply: { applyPresetToSelection($0) })
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("Presets & Clipboard")
                }

                DisclosureGroup {
                    LocalAdjustmentsPanel(model: model)
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("Local Adjustments")
                }

                DisclosureGroup {
                    ToneCurvePanel(master: $model.parameters.toneCurve,
                                   channels: $model.parameters.channelCurves)
                        .disabled(!model.hasImage)
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("Tone Curve")
                }

                DisclosureGroup {
                    HSLPanel(hsl: $model.parameters.hsl)
                        .disabled(!model.hasImage)
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("HSL / Colour")
                }

                DisclosureGroup {
                    SplitToningPanel(toning: $model.parameters.splitToning)
                        .disabled(!model.hasImage)
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("Split Toning")
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.lensProfileDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Distortion", isOn: $model.parameters.lensDistortion)
                        Toggle("Chromatic aberration", isOn: $model.parameters.lensTCA)
                        Toggle("Vignetting", isOn: $model.parameters.lensVignetting)
                        disclosureLabel("Manual")
                        sliderRow(title: "Distortion", value: $model.parameters.manualDistortion,
                                  range: -0.1...0.1, format: "%+.3f")
                        sliderRow(title: "Vignetting", value: $model.parameters.manualVignetting,
                                  range: -1...1, format: "%+.2f")
                        disclosureLabel("Defringe")
                        sliderRow(title: "Purple", value: $model.parameters.defringePurple,
                                  range: 0...1, format: "%.2f")
                        sliderRow(title: "Green", value: $model.parameters.defringeGreen,
                                  range: 0...1, format: "%.2f")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.hasImage)
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Lens Corrections")
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Demosaic", selection: $model.parameters.demosaic) {
                            ForEach(DemosaicMethod.allCases, id: \.self) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        Text("Only affects full-resolution renders — export and 100% zoom. The fit-to-window preview bins Bayer quads and never interpolates.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        disclosureLabel("Sharpening")
                        sliderRow(title: "Amount", value: $model.parameters.sharpenAmount,
                                  range: 0...2, format: "%.2f")
                        sliderRow(title: "Radius", value: $model.parameters.sharpenRadius,
                                  range: 0.5...3, format: "%.1f px", defaultValue: 1.0)
                        sliderRow(title: "Threshold", value: $model.parameters.sharpenThreshold,
                                  range: 0...0.1, format: "%.3f", defaultValue: 0.01)

                        disclosureLabel("Noise Reduction")
                        sliderRow(title: "Luminance", value: $model.parameters.denoiseLuminance,
                                  range: 0...1, format: "%.2f")
                        sliderRow(title: "Colour", value: $model.parameters.denoiseColor,
                                  range: 0...1, format: "%.2f")
                        Text("Judge both at 100% zoom; the fit-to-window preview is scaled to match but hides fine grain.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Detail")
                }

                DisclosureGroup {
                    aiDenoiseSection.padding(.top, 8)
                } label: {
                    disclosureLabel("AI Noise Reduction")
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Soft proof", isOn: $model.proofEnabled)
                            .toggleStyle(.switch).controlSize(.small)
                        Picker("Soft proof target", selection: Binding(
                            get: { model.proofTarget == .sRGB ? 0 : model.proofTarget == .displayP3 ? 1 : 2 },
                            set: { v in
                                if v == 0 { model.proofTarget = .sRGB }
                                else if v == 1 { model.proofTarget = .displayP3 }
                                else { model.chooseProofProfile() }
                            })) {
                            Text("sRGB").tag(0)
                            Text("Display P3").tag(1)
                            Text(model.proofTarget.displayName == "sRGB" || model.proofTarget.displayName == "Display P3"
                                 ? "ICC profile…" : model.proofTarget.displayName + "…").tag(2)
                        }
                        .pickerStyle(.menu).labelsHidden().controlSize(.small)
                        Toggle("Gamut warning (grey = can't be reproduced)", isOn: $model.gamutWarning)
                            .toggleStyle(.checkbox).controlSize(.small)
                        if !model.proofStatus.isEmpty {
                            Text(model.proofStatus).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Shows what the file will look like in the target's gamut. HDR headroom is off while proofing.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(!model.hasImage)
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Soft Proof")
                }

                Button("Reset All") { model.resetAdjustments() }
                    .disabled(!model.hasImage)

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        // A number typed for one photo must not land on the next.
        .sliderFieldSubject(model.sourceURL)
    }

    /// Temperature gets its own row because the slider travels in mired
    /// while reading out in Kelvin, and its range is centred on this
    /// image's as-shot value rather than being fixed — see ColorKit.
    private var temperatureRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The slider carries the name and the Kelvin reading for VoiceOver.
            HStack {
                Text("Temperature").font(.subheadline)
                Spacer()
                Text(String(format: "%.0f K", model.parameters.whiteBalance.temperature))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            ResettableSlider(value: model.temperatureSliderBinding,
                             in: model.temperatureSliderRange, label: "Temperature",
                             accessibilityValue: String(format: "%.0f kelvin",
                                                        model.parameters.whiteBalance.temperature)) {
                model.resetWhiteBalance()
            }
            .help("Double-click for the camera's white balance")
        }
        .disabled(!model.hasImage)
    }

    private func disclosureLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    private var whiteBalanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {

                    temperatureRow
                    sliderRow(title: "Tint",
                               value: $model.parameters.whiteBalance.tint,
                               range: ColorKit.WhiteBalance.tintRange,
                               format: "%+.0f", defaultValue: model.asShotWhiteBalance.tint)
                    HStack {
                        Button("As Shot") { model.resetWhiteBalance() }
                            .controlSize(.small)
                            .disabled(!model.hasImage)
                        Spacer()
                        Text(String(format: "camera: %.0fK %+.0f",
                                     model.asShotWhiteBalance.temperature,
                                     model.asShotWhiteBalance.tint))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                
        }
    }

    private var toneSection: some View {
        VStack(alignment: .leading, spacing: 10) {

                    HStack {
                        Button("Auto") { model.autoAdjust() }
                            .controlSize(.small)
                            .disabled(!model.hasImage)
                            .help("Estimate exposure, contrast and white balance from the image (⌘U)")
                        Spacer()
                    }
                    sliderRow(title: "Exposure",
                               value: $model.parameters.exposureEV,
                               range: -5...5, format: "%+.2f EV")
                    sliderRow(title: "Contrast",
                               value: $model.parameters.contrast,
                               range: 0.5...3.0, format: "%.2f", defaultValue: 1.5)
                    sliderRow(title: "Mid Grey",
                               value: $model.parameters.greyPoint,
                               range: 0.05...0.5, format: "%.3f", defaultValue: 0.1845)
                    ToneRangeSliders(ranges: $model.parameters.toneRanges)
                        .disabled(!model.hasImage)

                    // Only offered on screens that can actually show more
                    // than paper white; on an SDR display it would be a
                    // switch that does nothing.
                    if model.displayHasHeadroom {
                        Toggle(isOn: $model.hdrDisplayEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("HDR display")
                                    .font(.subheadline)
                                Text(String(format: "this screen: up to %.1f× above white",
                                            model.displayHeadroom))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!model.hasImage)
                    }
                
        }
    }

    /// Texture, clarity, dehaze and vibrance: the controls people reach
    /// for on most images, so this group starts open.
    private var presenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow(title: "Texture", value: $model.parameters.texture, range: -1...1, format: "%+.2f")
            sliderRow(title: "Clarity", value: $model.parameters.clarity, range: -1...1, format: "%+.2f")
            sliderRow(title: "Dehaze", value: $model.parameters.dehaze, range: -1...1, format: "%+.2f")
            sliderRow(title: "Vibrance", value: $model.parameters.vibrance, range: -1...1, format: "%+.2f")
        }
    }

    /// Neural denoise: one run per image (cached with the session), then
    /// the strength blends it in instantly. For a merged or linear DNG the
    /// controls give way to a line saying why they aren't there.
    @ViewBuilder
    private var aiDenoiseSection: some View {
        if !model.aiDenoiseSupported {
            Text("Not available for merged images and other linear DNGs: the model only handles brightness up to white, and these files go well beyond it. Detail › Noise Reduction still works.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            aiDenoiseControls
        }
    }

    private var aiDenoiseControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow(title: "Strength",
                      value: Binding(get: { model.aiDenoiseStrength }, set: { model.aiDenoiseStrength = $0 }),
                      range: 0...1, format: "%.2f")
            HStack {
                if model.aiDenoiseRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelAIDenoise() }
                } else {
                    Button(model.hasAIDenoiseResult ? "Run again" : "Denoise") { model.runAIDenoise() }
                        .disabled(!model.hasImage || !model.aiDenoiseAvailable)
                }
                Spacer()
            }
            .controlSize(.small)
            if !model.aiDenoiseStatus.isEmpty {
                Text(model.aiDenoiseStatus).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The optional width-64 model (OptionalModel, ModelDownloader and
            // the .high variant) is wired up but not offered here for now.
            Text("NAFNet (SIDD) on the GPU, in camera space before colour. About 11 s per 24 MP frame; the result is kept while the image is open and recomputed on export.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Marks a group whose tool is armed on the image.
    private var activeToolBadge: some View {
        Text("ON")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
            .accessibilityLabel("tool on")
    }

    /// Crop & straighten. R opens and closes the tool; the rectangle is
    /// edited on the image, the angle here.
    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.cropToolActive) {
                    Text(model.cropToolActive ? "Cropping: on" : "Crop…")
                }
                .toggleStyle(.button)
                .help("Show the crop rectangle on the image (R)")
                Picker("Aspect", selection: Binding(
                    get: { CropAspectOption.matching(model.cropAspectDisplayRatio, original: model.originalDisplayRatio) },
                    set: { model.setCropAspect(displayRatio: $0.ratio(original: model.originalDisplayRatio)) })) {
                    ForEach(CropAspectOption.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 96)
                Spacer()
                Button("Reset") { model.resetCrop() }
                    .disabled(model.parameters.crop == .none && model.parameters.perspective.isIdentity)
            }
            .controlSize(.small)
            .disabled(!model.hasImage)

            sliderRow(title: "Straighten",
                      value: Binding(get: { model.parameters.crop.angle },
                                     set: { model.setStraighten($0) }),
                      range: -45...45, format: "%.2f°")
            disclosureLabel("Perspective")
            sliderRow(title: "Vertical", value: $model.parameters.perspective.vertical,
                      range: -1...1, format: "%+.2f")
            sliderRow(title: "Horizontal", value: $model.parameters.perspective.horizontal,
                      range: -1...1, format: "%+.2f")

            if model.hasImage {
                let s = model.croppedPixelSize
                Text("\(Int(s.width.rounded())) × \(Int(s.height.rounded())) px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Spot removal. H opens the tool; patches are placed on the image.
    private var healSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.healToolActive) {
                    Text(model.healToolActive ? "Healing: on" : "Heal…")
                }
                .toggleStyle(.button)
                .help("Arm the tool, then click a spot to remove it; drag to pick the source, or paint with Brush (H)")
                Picker("Heal mode", selection: Binding(get: { model.activeHealMode },
                                                  set: { model.activeHealMode = $0 })) {
                    Text("Heal").tag(HealPatch.Mode.heal)
                    Text("Clone").tag(HealPatch.Mode.clone)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 100)
                Spacer()
                Button("Delete") { model.deleteSelectedHeal() }
                    .disabled(model.selectedHeal == nil)
                    .help("Remove the selected patch (⌫)")
            }
            .controlSize(.small)
            .disabled(!model.hasImage)

            HealShapePicker(model: model)

            sliderRow(title: "Size",
                      value: Binding(get: { model.activeHealRadiusPixels },
                                     set: { model.activeHealRadiusPixels = $0 }),
                      range: 4...600, format: "%.0f px")
            sliderRow(title: "Feather",
                      value: Binding(get: { model.activeHealFeather },
                                     set: { model.activeHealFeather = $0 }),
                      range: 0...1, format: "%.2f", defaultValue: 0.35)

            HStack {
                let n = model.parameters.heals.count
                Text(n == 0 ? "No patches. Click a dust spot or blemish to remove it."
                     : "\(n) patch\(n == 1 ? "" : "es")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if n > 0 {
                    Button("Clear all") { model.clearHeals() }.controlSize(.mini)
                }
            }

            Divider()
            RedEyeSection(model: model)
        }
    }

    private func section<Content: View>(_ title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            disclosureLabel(title)
            content()
        }
    }

    private func sliderRow(title: String, value: Binding<Float>,
                            range: ClosedRange<Float>, format: String,
                            defaultValue: Float = 0) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // The field and slider are both named, so VoiceOver skips this.
                Text(title).font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: value, in: range, format: SliderValueFormat(printf: format), label: title)
            }
            ResettableSlider(value: value, in: range, label: title,
                             format: SliderValueFormat(printf: format)) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
        }
        .disabled(!model.hasImage)
    }

    /// In Compare, zoom buttons drive both panes.
    private var mirrorModel: EditorModel? { mode == .compare ? compareModel : nil }

    /// What zoom commands act on and the status bar describes: Survey's
    /// focused pane (which carries a zoom to the others while Sync is on),
    /// else the editor.
    private var viewedModel: EditorModel { mode == .survey ? survey.focusedModel ?? model : model }

    /// The mode picker: Survey, like its command, only with two to four
    /// selected. Picked without, it beeps and nothing changes.
    private var modeBinding: Binding<AppMode> {
        Binding(get: { mode }, set: { picked in
            guard commandState.allowsChoosing(picked) else { NSSound.beep(); return }
            mode = picked
        })
    }

    /// The failure the status bar shows in red, if any.
    private var currentProblem: String? { model.setupError ?? library.lastError ?? model.lastError }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: modeBinding) {
                ForEach(AppMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 340)

            Button("Open File…") { model.showOpenPanel(); mode = .develop }
                .controlSize(.small)
                .disabled(!model.isReady)

            HStack(spacing: 4) {
                Button("↺") { rotate(by: -1) }
                    .accessibilityLabel("Rotate left")
                Button("↻") { rotate(by: 1) }
                    .accessibilityLabel("Rotate right")
            }
            .controlSize(.small)
            .disabled(library.selectedImage == nil)
            .help("Rotate the selected image (⌘[ and ⌘]). Remembered in the catalog.")

            Toggle(isOn: $filmstripVisible) { Image(systemName: "film") }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(mode != .loupe && mode != .develop)
                .help(filmstripVisible ? "Hide the filmstrip in Loupe and Develop" : "Show the filmstrip in Loupe and Develop")
                .accessibilityLabel("Filmstrip")

            FileOperationStatus(operations: fileOperations)

            if let problem = currentProblem {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(problem)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(problem)
                        .accessibilityLabel("Error: \(problem)")
                    if model.setupError == nil {
                        Button { library.lastError = nil; model.lastError = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss error")
                    }
                }
                .accessibilityElement(children: .contain)
                .font(.caption)
                .foregroundStyle(Color.red)
            } else {
                Text(mode == .library ? handOff.notice ?? library.statusText : viewedModel.status)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Zoom controls. Pinch, option-scroll and double-click do the
            // same things from the image itself; these exist for the
            // keyboard and for people who like buttons.
            HStack(spacing: 6) {
                Button("−") { viewedModel.zoomOut(); mirrorModel?.zoomOut() }
                    .accessibilityLabel("Zoom out")
                Text(viewedModel.zoomLabel)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 40)
                    .accessibilityLabel("Zoom")
                    .accessibilityValue(SpokenText.zoom(viewedModel.zoomLabel))
                    .accessibilityHidden(viewedModel.zoomLabel.isEmpty)
                Button("+") { viewedModel.zoomIn(); mirrorModel?.zoomIn() }
                    .accessibilityLabel("Zoom in")
                Button("Fit") { viewedModel.zoomToFit(); mirrorModel?.zoomToFit() }
                    .accessibilityLabel("Zoom to fit")
                Button("100%") { viewedModel.zoomToActualSize(); mirrorModel?.zoomToActualSize() }
                    .accessibilityLabel("Actual size")
            }
            .controlSize(.small)
            .disabled(!viewedModel.hasImage || !mode.showsImage)

            if !model.renderReport.isEmpty && mode == .develop && prefs.showRenderTimings {
                // What the last action rendered and how long it took, on
                // screen during development: the Phase 1 exit criterion is
                // under 16ms at fit-to-window, and having it visible while
                // dragging a slider is the only honest way to judge that.
                // "no render" means the presenter just redrew, which is
                // the cheap path pans are supposed to take.
                Text(model.renderReport)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(model.lastRenderMs < 16 ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The aspect menu's entries, as displayed (portrait images see "3:2" tall).
enum CropAspectOption: String, CaseIterable, Identifiable {
    case free, original, square, r3x2, r2x3, r4x3, r3x4, r5x4, r4x5, r16x9, r9x16
    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .r3x2: "3:2"
        case .r2x3: "2:3"
        case .r4x3: "4:3"
        case .r3x4: "3:4"
        case .r5x4: "5:4"
        case .r4x5: "4:5"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        }
    }

    func ratio(original: Float) -> Float? {
        switch self {
        case .free: nil
        case .original: original
        case .square: 1
        case .r3x2: 3 / 2
        case .r2x3: 2 / 3
        case .r4x3: 4 / 3
        case .r3x4: 3 / 4
        case .r5x4: 5 / 4
        case .r4x5: 4 / 5
        case .r16x9: 16 / 9
        case .r9x16: 9 / 16
        }
    }

    /// The entry whose ratio matches `ratio` (within a hair), else Free.
    static func matching(_ ratio: Float?, original: Float) -> CropAspectOption {
        guard let ratio else { return .free }
        return allCases.first { option in
            guard let r = option.ratio(original: original) else { return false }
            return abs(r - ratio) < 0.002
        } ?? .free
    }
}
